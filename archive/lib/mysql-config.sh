#!/bin/bash

source "${LIB_PATH}/mysql-logging.sh"
source "${LIB_PATH}/core/config.sh"

# Generate optimized MySQL configurations based on available resources
generate_mysql_configs() {
    local mem_bytes=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    if [ -z "$mem_bytes" ] || [ "$mem_bytes" -eq 0 ]; then
        echo "Error: Could not determine system memory" >&2
        return 1
    fi
    
    local mem_mb=$((mem_bytes / 1024))
    local cpu_cores=$(nproc)
    if [ -z "$cpu_cores" ] || [ "$cpu_cores" -eq 0 ]; then
        echo "Error: Could not determine CPU cores" >&2
        return 1
    fi

    # Calculate key memory settings with minimum values
    local innodb_buffer_pool_size=$((mem_mb * 70 / 100))  # 70% of total memory
    innodb_buffer_pool_size=$((innodb_buffer_pool_size < 128 ? 128 : innodb_buffer_pool_size))
    
    local innodb_buffer_pool_instances=$(( cpu_cores > 8 ? 8 : cpu_cores ))
    innodb_buffer_pool_instances=$((innodb_buffer_pool_instances < 1 ? 1 : innodb_buffer_pool_instances))
    
    local tmp_table_size=$((mem_mb * 5 / 100))  # 5% of memory
    tmp_table_size=$((tmp_table_size < 16 ? 16 : tmp_table_size))
    local max_heap_table_size=$tmp_table_size

    echo "Generating MySQL configuration with:"
    echo "- Memory: ${mem_mb}MB"
    echo "- CPU cores: ${cpu_cores}"
    echo "- InnoDB buffer pool: ${innodb_buffer_pool_size}MB"
    echo "- Buffer pool instances: ${innodb_buffer_pool_instances}"

    local config_dir="/etc/mysql/conf.d"
    local config_file="$config_dir/optimizations.cnf"

    # Ensure config directory exists
    if ! mkdir -p "$config_dir"; then
        log_error "Failed to create configuration directory: $config_dir"
        return 1
    fi

    # Write the base configuration
    if ! cat > "$config_file" << 'EOF'
[mysqld]
# Network
max_connections = 1000
max_connect_errors = 10000
max_allowed_packet = 64M
wait_timeout = 600
interactive_timeout = 600
EOF
    then
        echo "Error: Failed to write initial MySQL configuration" >&2
        return 1
    fi

    # Append InnoDB settings
    if ! cat >> "$config_file" << EOF

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
innodb_io_capacity = 2000
innodb_io_capacity_max = 4000

# Table Settings
table_open_cache = 4000
table_definition_cache = 4000
tmp_table_size = ${tmp_table_size}M
max_heap_table_size = ${max_heap_table_size}M

# Performance and Connection Pooling
thread_cache_size = $((cpu_cores * 32))
thread_pool_size = $((cpu_cores * 16))
thread_pool_idle_timeout = 30
thread_handling = 'pool-of-threads'
thread_pool_high_prio_tickets = 32
thread_pool_high_prio_mode = 'transactions'
thread_pool_max_active_query_threads = $((cpu_cores * 16))
thread_pool_max_threads = $((cpu_cores * 24))
thread_pool_stall_limit = 50
thread_pool_oversubscribe = 3
thread_pool_prio_kickup_timer = 1000
max_delayed_threads = $((cpu_cores * 8))
thread_pool_queue_length_limit = 100000

# Query Cache Settings
query_cache_type = 1
query_cache_size = $((mem_mb * 15 / 100))M
query_cache_limit = $((mem_mb * 1 / 100))M
query_cache_min_res_unit = 4K
query_cache_wlock_invalidate = 0
query_cache_strip_comments = 1

# Logging and Timeout Settings
slow_query_log = 1
slow_query_log_file = /var/log/mysql/slow.log
long_query_time = 2
log_queries_not_using_indexes = 1
log_slow_admin_statements = 1
log_slow_slave_statements = 1
log_throttle_queries_not_using_indexes = 10
expire_logs_days = 7
min_examined_row_limit = 1000

# Character Set
character-set-server = utf8mb4
collation-server = utf8mb4_general_ci

# MyISAM Settings
key_buffer_size = 32M
myisam_recover_options = FORCE,BACKUP
EOF
    then
        echo "Error: Failed to write main MySQL configuration" >&2
        return 1
    fi

    # Add performance schema settings if we have enough memory
    if [ $mem_mb -gt 8192 ]; then
        if ! cat >> "$config_file" << EOF

# Performance Schema Settings
performance_schema = ON
performance_schema_consumer_events_statements_history_long = ON
performance_schema_max_digest_length = 4096
performance_schema_max_sql_text_length = 4096

# Enhanced Connection Settings
max_connections = $((mem_mb / 8))
max_user_connections = $((mem_mb / 16))
thread_pool_size = $((cpu_cores * 24))
thread_pool_max_threads = $((cpu_cores * 48))
EOF
        then
            echo "Error: Failed to write performance schema configuration" >&2
            return 1
        fi
    fi

    if ! chmod 644 "$config_file"; then
        log_error "Failed to set permissions on configuration file"
        return 1
    fi

    if ! validate_config "$config_file"; then
        log_error "Configuration validation failed"
        return 1
    fi

    log_info "MySQL configuration generated successfully at $config_file"
    return 0
}

# Import configuration module
source "${LIB_PATH}/features/config/mysql.sh"
