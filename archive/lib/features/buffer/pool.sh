#!/bin/bash

source "${LIB_PATH}/core/logging.sh"
source "${LIB_PATH}/core/constants.sh"

# Monitor and adjust buffer pool size
monitor_buffer_pool() {
    while true; do
        # Get current memory stats
        local meminfo
        meminfo=$(cat /proc/meminfo)
        local total_memory=$(echo "$meminfo" | awk '/MemTotal/ {print $2}')
        local available_memory=$(echo "$meminfo" | awk '/MemAvailable/ {print $2}')
        local buffer_pool_size=$(mysql -N -e "SHOW VARIABLES LIKE 'innodb_buffer_pool_size'" | awk '{print $2}')
        
        # Calculate memory pressure
        local memory_pressure=$(( (total_memory - available_memory) * 100 / total_memory ))
        
        if [ $memory_pressure -gt ${MEMORY_PRESSURE_THRESHOLD} ]; then
            log_warn "High memory pressure detected: ${memory_pressure}%"
            local new_size=$((buffer_pool_size * 80 / 100))
            mysql -e "SET GLOBAL innodb_buffer_pool_size = $new_size"
            log_info "Reduced buffer pool size to $new_size bytes"
        elif [ $memory_pressure -lt 60 ]; then
            local new_size=$((buffer_pool_size * 120 / 100))
            local max_size=$((total_memory * ${BUFFER_POOL_MAX_PCT} / 100))
            
            if [ $new_size -lt $max_size ]; then
                mysql -e "SET GLOBAL innodb_buffer_pool_size = $new_size"
                log_info "Increased buffer pool size to $new_size bytes"
            fi
        fi
        
        sleep ${BUFFER_POOL_CHECK_INTERVAL}
    done &
}

# Initialize buffer pool monitoring
init_buffer_pool() {
    log_info "Initializing buffer pool monitoring..."
    monitor_buffer_pool
}
