#!/bin/bash

# Prevent multiple inclusion
[ -n "${MYSQL_CONFIG_SOURCED}" ] && return 0
declare -g MYSQL_CONFIG_SOURCED=1

source "${LIB_PATH}/core/logging.sh"
source "${LIB_PATH}/core/constants.sh"

# Check MySQL configuration
_check_config() {
  echo "Checking MySQL configuration"
    if ! errors="$(mysqld "$@" --verbose --help 2>&1 >/dev/null)"; then
      echo "MySQL configuration check failed: ${errors}"
        log_error "MySQL configuration check failed: ${errors}"
        return 1
    fi

    echo "MySQL configuration check passed"
    return 0
}

# Get MySQL configuration value
_get_config() {
    local conf="$1"; shift
    "$@" --verbose --help --log-bin-index="$(mktemp -u)" 2>/dev/null \
        | awk '$1 == "'"$conf"'" && /^[^ \t]/ { sub(/^[^ \t]+[ \t]+/, ""); print; exit }'
}

# Generate optimized MySQL configurations based on available resources
generate_mysql_configs() {
    # Resource detection using cgroups v2
    local mem_source="Unknown"
    local cpu_source="Unknown"

    # Memory detection
    local mem_bytes
    local mem_mb
    if [ -f "/sys/fs/cgroup/memory.max" ]; then
        mem_source="Container cgroups v2"
        local mem_max=$(cat /sys/fs/cgroup/memory.max)
        
        if [ "$mem_max" = "max" ]; then
            # No limit set, use 85% of available memory
            mem_bytes=$(grep MemAvailable /proc/meminfo | awk '{print $2 * 1024}')
            mem_mb=$((mem_bytes / 1024 / 1024 * 85 / 100))
            log_info "Memory Source: Available memory (85% allocation)"
        else
            # Use container limit with 85% allocation
            mem_bytes=$mem_max
            mem_mb=$((mem_bytes / 1024 / 1024 * 85 / 100))
            log_info "Memory Source: Container memory limit (85% allocation)"
        fi
    else
        # Fallback to available memory
        mem_bytes=$(grep MemAvailable /proc/meminfo | awk '{print $2 * 1024}')
        mem_mb=$((mem_bytes / 1024 / 1024 * 85 / 100))
        log_info "Memory Source: Available memory (85% allocation)"
    fi

    # Ensure minimum memory allocation
    mem_mb=$((mem_mb < 512 ? 512 : mem_mb))

    if [ -z "$mem_mb" ] || [ "$mem_mb" -eq 0 ]; then
        log_error "Could not determine system memory"
        return 1
    fi

    # CPU detection using cgroups v2
    local cpu_cores
    if [ -f "/sys/fs/cgroup/cpu.max" ]; then
        cpu_source="Container cgroups v2"
        local cpu_quota_period=$(cat /sys/fs/cgroup/cpu.max)
        local cpu_quota=$(echo "$cpu_quota_period" | cut -d' ' -f1)
        local cpu_period=$(echo "$cpu_quota_period" | cut -d' ' -f2)
        
        if [ "$cpu_quota" = "max" ]; then
            # No quota set, use available CPUs
            cpu_cores=$(nproc)
            log_info "CPU Cores (from nproc, no quota): $cpu_cores"
        else
            cpu_cores=$((cpu_quota / cpu_period))
            log_info "CPU Quota: ${cpu_quota}us"
            log_info "CPU Period: ${cpu_period}us"
            log_info "CPU Cores (from quota): $cpu_cores"
        fi
    else
        # Fallback to available CPUs
        cpu_cores=$(nproc)
        cpu_source="System CPUs"
        log_info "CPU Cores (from system): $cpu_cores"
    fi

    # Ensure at least 1 CPU core
    cpu_cores=$((cpu_cores < 1 ? 1 : cpu_cores))

    if [ -z "$cpu_cores" ] || [ "$cpu_cores" -eq 0 ]; then
        log_error "Could not determine CPU cores"
        return 1
    fi

    # Log detailed configuration detection
    log_info "Environment Configuration Detected:"
    log_info "--------------------------------"
    log_info "Environment Type: $env_type"
    log_info "Memory Source: $mem_source"
    log_info "Total Memory: ${mem_mb}MB"
    log_info "CPU Source: $cpu_source"
    log_info "CPU Cores: $cpu_cores"
    log_info "--------------------------------"

    # Calculate key memory settings with minimum values
    local innodb_buffer_pool_size
    local performance_schema_enabled=0

    if [ $mem_mb -gt 8192 ]; then
        performance_schema_enabled=1
        # For systems with >8GB RAM, reserve memory for Performance Schema
        innodb_buffer_pool_size=$((mem_mb * 50 / 100))  # 50% for buffer pool
        local perf_schema_size=$((mem_mb * 20 / 100))   # 20% for Performance Schema
        local system_reserved=$((mem_mb * 30 / 100))    # 30% for system and other MySQL operations
        innodb_buffer_pool_instances=$((cpu_cores > 8 ? 8 : cpu_cores))
    else
        # For smaller systems, maintain the original allocation
        innodb_buffer_pool_size=$((mem_mb * 70 / 100))  # 70% for buffer pool
        innodb_buffer_pool_instances=1
    fi

    # Ensure minimum buffer pool size
    innodb_buffer_pool_size=$((innodb_buffer_pool_size < 128 ? 128 : innodb_buffer_pool_size))

    # Adjust other memory-related settings
    local tmp_table_size
    if [ $performance_schema_enabled -eq 1 ]; then
        tmp_table_size=$((mem_mb * 3 / 100))  # Reduced from 5% to 3% when Performance Schema is enabled
    else
        tmp_table_size=$((mem_mb * 5 / 100))  # Original 5% allocation
    fi
    tmp_table_size=$((tmp_table_size < 16 ? 16 : tmp_table_size))
    local max_heap_table_size=$tmp_table_size

    log_info "Memory Allocation Configuration:"
    log_info "- Total Memory: ${mem_mb}MB"
    log_info "- InnoDB Buffer Pool: ${innodb_buffer_pool_size}MB"
    if [ $performance_schema_enabled -eq 1 ]; then
        log_info "- Performance Schema Enabled"
        log_info "- Performance Schema Reserved: ${perf_schema_size}MB"
        log_info "- System Reserved: ${system_reserved}MB"
    fi
    log_info "- Temp Table Size: ${tmp_table_size}MB"

    local config_file="$CONFIG_DIR/optimizations.cnf"

    # Ensure config directory exists
    if ! mkdir -p "$CONFIG_DIR" 2>/dev/null; then
        log_info "Config directory $CONFIG_DIR already exists"
    fi

    # Write the configuration with k8s-specific settings if detected
cat > "$config_file" << EOF
[mysqld]
# Container/Pod Settings
skip-name-resolve
secure-file-priv = /var/lib/mysql-files
host_cache_size = 0

# Authentication settings
default_password_lifetime = 0

# Plugin settings - commenting out potentially problematic ones
#early-plugin-load = ''
#plugin-load-add = ''
#skip-plugin-load = ON
#disabled_storage_engines = ''
#disabled_plugins = "mysql_native_password"
EOF

    cat >> "$config_file" << EOF
# Network Settings
max_connections = 1000
max_connect_errors = 10000
max_allowed_packet = 64M
wait_timeout = 600
interactive_timeout = 600

# InnoDB Settings
innodb_buffer_pool_size = ${innodb_buffer_pool_size}M
innodb_buffer_pool_instances = $innodb_buffer_pool_instances
innodb_file_per_table = 1
innodb_flush_log_at_trx_commit = 2
innodb_flush_method = O_DIRECT
innodb_log_buffer_size = 16M
innodb_log_file_size = 1G
innodb_write_io_threads = $cpu_cores
innodb_read_io_threads = $cpu_cores
innodb_io_capacity = 200                    # More conservative default
innodb_io_capacity_max = 400                # More conservative default

# Table Settings
table_open_cache = 2000                     # More reasonable default
table_definition_cache = 2000               # More reasonable default
tmp_table_size = ${tmp_table_size}M
max_heap_table_size = ${max_heap_table_size}M

# Performance Settings
thread_cache_size = $((cpu_cores * 16))     # Reduced from 32

# Logging Settings
slow_query_log = 1
slow_query_log_file = "$LOG_DIR/slow-query.log"
long_query_time = 2
log_queries_not_using_indexes = 0           # Disabled by default
expire_logs_days = 7
min_examined_row_limit = 1000

# Character Set
character-set-server = utf8mb4
collation-server = utf8mb4_general_ci

# MyISAM Settings
key_buffer_size = 32M
myisam_recover_options = FORCE,BACKUP
EOF

    # Add performance schema settings if we have enough memory
if [ $mem_mb -gt 8192 ]; then
    cat >> "$config_file" << EOF

# Performance Schema Settings
performance_schema = ON
performance_schema_consumer_events_statements_history_long = ON
performance_schema_consumer_events_stages_history_long = ON    # Track statement stages
performance_schema_consumer_events_transactions_history = ON   # Track transaction history
performance_schema_max_digest_length = 4096
performance_schema_max_sql_text_length = 4096

# Performance Schema Memory Settings
performance_schema_max_memory_classes = 320
performance_schema_digests_size = 10000                       # Number of digested statements to store
performance_schema_events_statements_history_size = 100       # Statements per thread
performance_schema_events_transactions_history_size = 100     # Transactions per thread

# Enhanced Connection Settings for Monitoring
max_connections = $((mem_mb / 10))
max_user_connections = $((mem_mb / 20))

# Enable Metrics Collection
innodb_monitor_enable = all                                   # Monitor InnoDB metrics
EOF
fi
    log_info "MySQL configuration generated successfully at $config_file"
    return 0
}

# Configure MySQL files before startup
configure_mysql_files() {
    local role=$1
    local server_id=$2

    # Try to ensure directories exist, but don't fail if we can't
    mkdir -p "${CONFIG_DIR}" 2>/dev/null || true
    mkdir -p /var/run/mysqld 2>/dev/null || true
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    
    # Skip writing main config as it should be handled by root during container build
    # Skip permissions as they should be handled by root during container build

    case "$role" in
        "standalone")
            cat > "${CONFIG_DIR}/server.cnf" << EOF
[mysqld]
server-id = $server_id
bind-address = 0.0.0.0
port = ${MYSQL_PORT}

# Binary logging
log_bin = ${server_id}-bin
log_bin_index = ${server_id}-bin.index
max_binlog_size = 1G
binlog_cache_size = 4M
binlog_format = ROW
sync_binlog = 1

# GTID settings
gtid_mode = ON
enforce_gtid_consistency = ON
log_slave_updates = ON

# Standalone optimizations
innodb_flush_log_at_trx_commit = 1
EOF
            ;;

        "master")
            cat > "${CONFIG_DIR}/replication.cnf" << EOF
[mysqld]
server-id = $server_id

# Binary logging
log_bin = ${server_id}-bin
log_bin_index = ${server_id}-bin.index
max_binlog_size = 1G
binlog_cache_size = 4M
binlog_format = ROW
sync_binlog = 1

# Relay log settings (in case of failover)
relay_log = ${server_id}--relay-bin
relay_log_index = ${server_id}-relay-bin.index
master_info_repository = TABLE
relay_log_info_repository = TABLE
relay_log_recovery = ON
relay_log_purge = ON

# GTID settings
gtid_mode = ON
enforce_gtid_consistency = ON
log_slave_updates = ON

innodb_flush_log_at_trx_commit = 1
EOF
            ;;

        "slave")
            cat > "${CONFIG_DIR}/replication.cnf" << EOF
[mysqld]
server-id = $server_id

# Binary logging (for promotion readiness)
log_bin = ${server_id}-bin
log_bin_index = ${server_id}-bin.index
max_binlog_size = 1G
binlog_cache_size = 4M
binlog_format = ROW

# Relay log settings
relay_log = ${server_id}-relay-bin
relay_log_index = ${server_id}-relay-bin.index
master_info_repository = TABLE
relay_log_info_repository = TABLE
relay_log_recovery = ON
relay_log_purge = ON

# Replication performance
slave_parallel_workers = ${cpu_cores:-4}
slave_parallel_type = LOGICAL_CLOCK
skip_slave_start = ON

# GTID settings
gtid_mode = ON
enforce_gtid_consistency = ON
log_slave_updates = ON
EOF
            ;;

        *)
            log_error "Invalid mode: $mode"
            return 1
            ;;
    esac

    chmod 644 "${CONFIG_DIR}"/*.cnf

    # Configure backup streaming
    configure_backup_streaming
    return 0
}

# Configure backup streaming settings
configure_backup_streaming() {
    # Always bind to localhost only
    BACKUP_STREAM_PORT=4444  # Fixed port, no need for dynamic
    BACKUP_STREAM_BIND="127.0.0.1"  # Always localhost
    
    # Save configuration
    cat > "$CONFIG_DIR/backup-stream.conf" << EOF
backup_stream_port=4444
backup_stream_bind=127.0.0.1
EOF
    chmod 600 "$CONFIG_DIR/backup-stream.conf"
}
# Function to verify and initialize GTID configuration
verify_gtid_configuration() {
    log_info "Verifying GTID configuration..."

    # Check if this is first boot by looking for auto.cnf
    local is_first_boot=0
    if [ ! -f "${DATA_DIR}/auto.cnf" ]; then
        log_info "First boot detected"
        is_first_boot=1
    fi

    # Check current GTID mode before making changes
    local current_mode
    current_mode=$(mysql_retry_auth root "${MYSQL_ROOT_PASSWORD}" -N -s -e "SELECT @@GLOBAL.gtid_mode")
    log_info "Current GTID mode: $current_mode"

    # Enable GTID consistency first
    if ! mysql_retry_auth root "${MYSQL_ROOT_PASSWORD}" -e "SET @@GLOBAL.enforce_gtid_consistency=ON;"; then
        log_error "Failed to enable GTID consistency"
        return 1
    fi
    log_info "Enabled GTID consistency"
    sleep 5

    # Step through GTID modes only if not already in desired state
    if [ "$current_mode" != "ON" ]; then
        # Step 1: OFF to OFF_PERMISSIVE (if needed)
        if [ "$current_mode" = "OFF" ]; then
            if ! mysql_retry_auth root "${MYSQL_ROOT_PASSWORD}" -e "SET @@GLOBAL.gtid_mode=OFF_PERMISSIVE;"; then
                log_error "Failed to set GTID mode to OFF_PERMISSIVE"
                return 1
            fi
            log_info "Set GTID mode to OFF_PERMISSIVE"
            sleep 5
        fi

        # Step 2: OFF_PERMISSIVE to ON_PERMISSIVE
        if ! mysql_retry_auth root "${MYSQL_ROOT_PASSWORD}" -e "SET @@GLOBAL.gtid_mode=ON_PERMISSIVE;"; then
            log_error "Failed to set GTID mode to ON_PERMISSIVE"
            return 1
        fi
        log_info "Set GTID mode to ON_PERMISSIVE"
        sleep 5

        # Step 3: ON_PERMISSIVE to ON
        if ! mysql_retry_auth root "${MYSQL_ROOT_PASSWORD}" -e "SET @@GLOBAL.gtid_mode=ON;"; then
            log_error "Failed to set GTID mode to ON"
            return 1
        fi
        log_info "Set GTID mode to ON"
    fi

    # Verify final GTID mode
    current_mode=$(mysql_retry_auth root "${MYSQL_ROOT_PASSWORD}" -N -s -e "SELECT @@GLOBAL.gtid_mode")
    if [ "$current_mode" != "ON" ]; then
        log_error "Failed to verify GTID mode is ON (current mode: $current_mode)"
        return 1
    fi

    # Verify GTID mode is now enabled
    local gtid_mode
    gtid_mode=$(mysql_retry_auth root "${MYSQL_ROOT_PASSWORD}" -N -s -e "SELECT @@GLOBAL.gtid_mode")

    if [ "$gtid_mode" != "ON" ]; then
        log_error "Failed to enable GTID mode (current mode: $gtid_mode)"
        return 1
    fi

    # If this is first boot, initialize GTID state
    if [ $is_first_boot -eq 1 ]; then
        log_info "Initializing GTID state on first boot"

        if ! mysql_retry_auth root "${MYSQL_ROOT_PASSWORD}" -e "
            RESET MASTER;
            SET GLOBAL gtid_purged='';
        "; then
            log_error "Failed to initialize GTID state on first boot"
            return 1
        fi
    fi

    log_info "GTID configuration verified and enabled successfully"
    return 0
}
