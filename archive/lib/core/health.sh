#!/bin/bash

# Prevent multiple inclusion
[ -n "${CORE_HEALTH_SOURCED}" ] && return 0
declare -g CORE_HEALTH_SOURCED=1

source "${LIB_PATH}/core/logging.sh"
source "${LIB_PATH}/core/process.sh"

# Health check thresholds
declare -gr HEALTH_CHECK_INTERVAL=60
declare -gr HEALTH_CHECK_TIMEOUT=5
declare -gr MAX_HEALTH_FAILURES=3

# Initialize health checking
init_health_checker() {
    mkdir -p /var/log/mysql/health
    chmod 755 /var/log/mysql/health
}

# Generic health check function
check_health() {
    local check_type=$1
    local check_command=$2
    local timeout=${3:-$HEALTH_CHECK_TIMEOUT}
    
    if ! timeout $timeout $check_command; then
        log_error "Health check failed: $check_type"
        return 1
    fi
    return 0
}

# Monitor process health
monitor_process_health() {
    local pid=$1
    local name=$2
    local failures=0
    
    while true; do
        if ! kill -0 $pid 2>/dev/null; then
            log_error "Process $name (PID: $pid) died"
            return 1
        fi
        
        # Check process resource usage
        local cpu=$(ps -p $pid -o %cpu= 2>/dev/null)
        local mem=$(ps -p $pid -o %mem= 2>/dev/null)
        local fd_count=$(ls -l /proc/$pid/fd 2>/dev/null | wc -l)
        
        if [ -n "$cpu" ] && [ $(echo "$cpu > 90" | bc) -eq 1 ]; then
            log_warn "High CPU usage for $name: ${cpu}%"
            failures=$((failures + 1))
        fi
        
        if [ -n "$mem" ] && [ $(echo "$mem > 90" | bc) -eq 1 ]; then
            log_warn "High memory usage for $name: ${mem}%"
            failures=$((failures + 1))
        fi
        
        if [ $failures -ge $MAX_HEALTH_FAILURES ]; then
            log_error "Too many health check failures for $name"
            return 1
        fi
        
        sleep $HEALTH_CHECK_INTERVAL
    done &
}

# Initialize health checker
init_health_checker
