#!/bin/bash

# Prevent multiple inclusion
[ -n "${CORE_CONFIG_SOURCED}" ] && return 0
declare -g CORE_CONFIG_SOURCED=1

source "${LIB_PATH}/core/logging.sh"
source "${LIB_PATH}/core/constants.sh"


# Initialize config directory
init_config_dir() {
    mkdir -p "$CONFIG_DIR"
    chmod 755 "$CONFIG_DIR"
}

# Validate configuration file
validate_config() {
    local config_file=$1
    
    if [ ! -f "$config_file" ]; then
        log_error "Configuration file not found: $config_file"
        return 1
    fi

    # Test configuration file
    if ! mysqld --verbose --help --log-bin-index="$(mktemp -u)" 2>/dev/null > /dev/null; then
        log_error "Invalid MySQL configuration in $config_file"
        return 1
    fi

    return 0
}

# Write configuration with atomic operations
write_config() {
    local config_file=$1
    local content=$2
    local tmp_file="${config_file}.tmp.$$"
    
    echo "$content" > "$tmp_file"
    chmod 644 "$tmp_file"
    
    if ! mv "$tmp_file" "$config_file"; then
        log_error "Failed to write configuration file: $config_file"
        rm -f "$tmp_file"
        return 1
    fi
    
    return 0
}

# Calculate optimal settings based on system resources
calculate_system_settings() {
    local mem_bytes=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    local mem_mb=$((mem_bytes / 1024))
    local cpu_cores=$(nproc)
    
    # Buffer pool size (70% of total memory)
    local buffer_pool_size=$((mem_mb * 70 / 100))
    buffer_pool_size=$((buffer_pool_size < 128 ? 128 : buffer_pool_size))
    
    # Buffer pool instances (1 per core, max 8)
    local buffer_pool_instances=$(( cpu_cores > 8 ? 8 : cpu_cores ))
    buffer_pool_instances=$((buffer_pool_instances < 1 ? 1 : buffer_pool_instances))
    
    # Temp table size (5% of memory)
    local tmp_table_size=$((mem_mb * 5 / 100))
    tmp_table_size=$((tmp_table_size < 16 ? 16 : tmp_table_size))
    
    echo "BUFFER_POOL_SIZE=$buffer_pool_size"
    echo "BUFFER_POOL_INSTANCES=$buffer_pool_instances"
    echo "TMP_TABLE_SIZE=$tmp_table_size"
}

# Initialize config module
init_config() {
    init_config_dir
}

# Configure MySQL replication settings
configure_replication() {
    local role=$1
    local master_host=$2
    local master_port=$3
    
    case "$role" in
        "master")
            mysql -e "
                RESET MASTER;
                SET GLOBAL read_only = OFF;
                SET GLOBAL super_read_only = OFF;
            "
            ;;
        "slave")
            mysql -e "
                STOP SLAVE;
                CHANGE MASTER TO
                    MASTER_HOST='$master_host',
                    MASTER_PORT=$master_port,
                    MASTER_USER='$MYSQL_REPL_USER',
                    MASTER_PASSWORD='$MYSQL_REPL_PASSWORD',
                    MASTER_AUTO_POSITION=1;
                SET GLOBAL read_only = ON;
                SET GLOBAL super_read_only = ON;
                START SLAVE;
            "
            ;;
    esac
}

# Initialize on source
init_config
