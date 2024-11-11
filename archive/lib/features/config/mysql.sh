#!/bin/bash

# Prevent multiple inclusion
[ -n "${MYSQL_CONFIG_SOURCED}" ] && return 0
declare -g MYSQL_CONFIG_SOURCED=1

source "${LIB_PATH}/core/logging.sh"
source "${LIB_PATH}/core/constants.sh"

# MySQL configuration paths
declare -gr MYSQL_CONFIG_DIR="/etc/mysql/conf.d"
declare -gr MYSQL_BASE_CONFIG="/etc/mysql/my.cnf"
declare -gr MYSQL_CUSTOM_CONFIG="${MYSQL_CONFIG_DIR}/custom.cnf"

# Generate MySQL configuration
generate_mysql_config() {
    local role=$1
    local server_id=$2
    local mem_mb=$3
    local cpu_cores=$4

    # Validate inputs
    if [ -z "$role" ] || [ -z "$server_id" ] || [ -z "$mem_mb" ] || [ -z "$cpu_cores" ]; then
        log_error "Missing required configuration parameters"
        return 1
    fi

    # Calculate resource-based settings
    local buffer_pool_size=$((mem_mb * 70 / 100))  # 70% of memory
    local thread_cache_size=$((cpu_cores * 32))
    local max_connections=$((mem_mb / 8))  # Scale with memory

    # Create base configuration
    cat > "$MYSQL_CUSTOM_CONFIG" << EOF
[mysqld]
# Server identification
server-id = $server_id
bind-address = 0.0.0.0

# Resource settings
innodb_buffer_pool_size = ${buffer_pool_size}M
thread_cache_size = $thread_cache_size
max_connections = $max_connections

# Role-specific settings
EOF

    # Add role-specific settings
    case "$role" in
        "master")
            cat >> "$MYSQL_CUSTOM_CONFIG" << EOF
log_bin = mysql-bin
binlog_format = ROW
sync_binlog = 1
innodb_flush_log_at_trx_commit = 1
EOF
            ;;
        "slave")
            cat >> "$MYSQL_CUSTOM_CONFIG" << EOF
relay-log = mysql-relay-bin
read_only = ON
super_read_only = ON
slave_parallel_workers = $cpu_cores
slave_parallel_type = LOGICAL_CLOCK
EOF
            ;;
        "standalone")
            cat >> "$MYSQL_CUSTOM_CONFIG" << EOF
innodb_flush_log_at_trx_commit = 1
sync_binlog = 1
EOF
            ;;
        *)
            log_error "Invalid MySQL role: $role"
            return 1
            ;;
    esac

    chmod 644 "$MYSQL_CUSTOM_CONFIG"
    return 0
}

# Initialize configuration
init_mysql_config() {
    mkdir -p "$MYSQL_CONFIG_DIR"
    chmod 755 "$MYSQL_CONFIG_DIR"
    
    # Generate initial configurations
    if ! generate_mysql_configs; then
        log_error "Failed to generate MySQL configurations"
        return 1
    fi
}

# Initialize on source
init_mysql_config

# Configure MySQL settings
configure_mysql() {
    local mode=$1    # 'standalone' or cluster roles ('master'/'slave')
    local server_id=${2:-1}  # defaults to 1 for standalone

    # Configure deadlock prevention
    mysql_retry "mysql -e \"
        SET GLOBAL innodb_deadlock_detect = ON;
        SET GLOBAL innodb_lock_wait_timeout = 50;
        SET GLOBAL innodb_print_all_deadlocks = ON;
        SET GLOBAL innodb_rollback_on_timeout = ON;
        SET GLOBAL innodb_lock_schedule_algorithm = FCFS;\""

    # Ensure config directory exists
    mkdir -p "$MYSQL_CONFIG_DIR"
    chmod 755 "$MYSQL_CONFIG_DIR"

    # Generate optimized configurations first
    if ! generate_mysql_configs; then
        log_error "Failed to generate MySQL configurations"
        return 1
    fi

    case "$mode" in
        "standalone")
            cat > "${MYSQL_CONFIG_DIR}/server.cnf" << EOF
[mysqld]
server-id = $server_id
bind-address = 0.0.0.0
port = ${PORT}

# Standalone optimizations
innodb_flush_log_at_trx_commit = 1
sync_binlog = 1
EOF
            ;;

        "master")
            cat > "${REPLICATION_CONFIG}" << EOF
[mysqld]
server-id = $server_id
log_bin = mysql-bin
binlog_format = ROW
sync_binlog = 1  # Ensure durability for master
innodb_flush_log_at_trx_commit = 1  # Full ACID compliance for master
max_binlog_size = 1G
binlog_cache_size = 4M
gtid_mode=ON
enforce_gtid_consistency=ON
log_slave_updates=ON
EOF
            ;;

        "slave")
            cat > "${MYSQL_CONFIG_DIR}/replication.cnf" << EOF
[mysqld]
server-id = $server_id
relay-log = mysql-relay-bin
read_only = ON
slave_parallel_workers = ${cpu_cores:-4}  # Default to 4 if cpu_cores not set
slave_parallel_type = LOGICAL_CLOCK
master_info_repository = TABLE
relay_log_info_repository = TABLE
relay_log_recovery = ON
skip_slave_start = ON  # Don't auto-start slave
EOF
            ;;

        *)
            log_error "Invalid mode: $mode"
            return 1
            ;;
    esac

    # Set proper permissions
    chmod 644 "${MYSQL_CONFIG_DIR}"/*.cnf

    return 0
}
