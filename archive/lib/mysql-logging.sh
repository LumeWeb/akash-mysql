#!/bin/bash

# Prevent multiple inclusion
[ -n "${MYSQL_LOGGING_SOURCED}" ] && return 0
declare -g MYSQL_LOGGING_SOURCED=1

# Core dependencies only
source "${LIB_PATH}/core/logging.sh"
source "${LIB_PATH}/core/constants.sh"

# Enhanced MySQL-specific logging with proper dependency management
# Avoid circular dependencies by using core modules only

# Rotate log files with proper locking
rotate_logs() {
    local log_file=$1
    local max_size=$((50*1024*1024))  # 50MB
    
    (
        if ! flock -n 9; then
            core_log $LOG_WARN "Could not acquire lock for log rotation"
            return 1
        fi
        
        if [ -f "$log_file" ] && [ $(stat -f%z "$log_file") -gt $max_size ]; then
            mv "$log_file" "${log_file}.1"
            touch "$log_file"
            chmod 640 "$log_file"
        fi
    ) 9>/var/lock/mysql-logging.lock
}

# Monitor MySQL error log with atomic operations
monitor_mysql_logs() {
    local error_log="/var/log/mysql/error.log"
    local slow_log="/var/log/mysql/slow.log"
    
    while true; do
        (
            if ! flock -n 9; then
                core_log $LOG_WARN "Could not acquire lock for log monitoring"
                return 1
            fi
            
            if [ -f "$error_log" ]; then
                rotate_logs "$error_log"
                if grep -i "error" "$error_log" >/dev/null; then
                    core_log $LOG_WARN "Errors detected in MySQL error log"
                fi
            fi
            
            if [ -f "$slow_log" ]; then
                rotate_logs "$slow_log"
                analyze_slow_queries
            fi
            
        ) 9>/var/lock/mysql-logging-monitor.lock
        
        sleep 300
    done
}




# Function to analyze slow queries
analyze_slow_queries() {
    local slow_log="/var/log/mysql/slow.log"
    local threshold=10

    if [ -f "$slow_log" ]; then
        local slow_count=$(grep -c "Query_time:" "$slow_log")
        if [ "$slow_count" -gt "$threshold" ]; then
            log_warn "High number of slow queries detected: $slow_count"
            
            # Get top 5 slowest queries
            grep -A 2 "Query_time:" "$slow_log" | tail -n 20 > "/var/log/mysql/slow_analysis.log"
        fi
    fi
}

# Function to check connection usage
check_connection_usage() {
    local max_conn=$(mysql -N -e "SHOW VARIABLES LIKE 'max_connections'" | awk '{print $2}')
    local current_conn=$(mysql -N -e "SHOW STATUS LIKE 'Threads_connected'" | awk '{print $2}')
    local usage_pct=$((current_conn * 100 / max_conn))

    if [ "$usage_pct" -gt 80 ]; then
        log_warn "High connection usage: ${usage_pct}% ($current_conn/$max_conn)"
        
        if [ "$usage_pct" -gt 90 ]; then
            log_error "Critical connection usage. Increasing max_connections"
            mysql -e "SET GLOBAL max_connections = $((max_conn * 120 / 100))"
        fi
    fi
}

# Function to monitor deadlocks
monitor_deadlocks() {
    local deadlocks=$(mysql -N -e "SHOW STATUS LIKE 'Innodb_deadlocks'" | awk '{print $2}')
    if [ "$deadlocks" -gt 0 ]; then
        log_warn "Deadlocks detected: $deadlocks"
        mysql -e "SHOW ENGINE INNODB STATUS\G" > "/var/log/mysql/deadlock_status.log"
    fi
}

# Function to adjust memory settings
adjust_memory_settings() {
    local total_memory
    local available_memory
    local buffer_pool_size
    total_memory=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    available_memory=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
    buffer_pool_size=$(mysql -N -e "SHOW VARIABLES LIKE 'innodb_buffer_pool_size'" | awk '{print $2}')
    
    if [ "$available_memory" -lt "$((total_memory * 20 / 100))" ]; then
        log_warn "Low memory condition detected. Adjusting buffer pool size."
        mysql -e "SET GLOBAL innodb_buffer_pool_size = $((buffer_pool_size * 80 / 100))"
    fi
}

# Function to notify admin (placeholder)
notify_admin() {
    log_error "ALERT: Critical MySQL condition detected"
    # Add notification logic here (email, Slack, etc.)
}
