#!/bin/bash

# Prevent multiple inclusion
[ -n "${CORE_METRICS_SOURCED}" ] && return 0
declare -g CORE_METRICS_SOURCED=1

source "${LIB_PATH}/core/logging.sh"

# Metrics collection settings
declare -gr METRICS_INTERVAL=60
declare -gr METRICS_RETENTION_DAYS=7

# Initialize metrics collection
init_metrics_collector() {
    mkdir -p /var/log/mysql/metrics
    chmod 755 /var/log/mysql/metrics
    
    # Rotate old metrics
    find /var/log/mysql/metrics -type f -mtime +${METRICS_RETENTION_DAYS} -delete
}

# Collect system metrics
collect_system_metrics() {
    while true; do
        local timestamp=$(date +%s)
        local metrics_file="/var/log/mysql/metrics/system_${timestamp}.json"
        
        # Collect CPU metrics
        local cpu_metrics=$(top -bn1 | grep "Cpu(s)" | \
            sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | \
            awk '{print 100 - $1}')
            
        # Collect memory metrics
        local mem_metrics=$(free -m | grep Mem | \
            awk '{print $3/$2 * 100}')
            
        # Collect disk metrics
        local disk_metrics=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')
        
        # Write metrics to file atomically
        cat > "${metrics_file}.tmp" << EOF
{
    "timestamp": $timestamp,
    "cpu_usage": $cpu_metrics,
    "memory_usage": $mem_metrics,
    "disk_usage": $disk_metrics
}
EOF
        mv "${metrics_file}.tmp" "$metrics_file"
        
        sleep $METRICS_INTERVAL
    done &
}

# Collect process metrics
collect_process_metrics() {
    local pid=$1
    local name=$2
    
    while true; do
        local timestamp=$(date +%s)
        local metrics_file="/var/log/mysql/metrics/process_${name}_${timestamp}.json"
        
        # Collect process metrics
        local cpu=$(ps -p $pid -o %cpu= 2>/dev/null)
        local mem=$(ps -p $pid -o %mem= 2>/dev/null)
        local fd_count=$(ls -l /proc/$pid/fd 2>/dev/null | wc -l)
        local threads=$(ps -p $pid -L | wc -l)
        
        # Write metrics to file atomically
        cat > "${metrics_file}.tmp" << EOF
{
    "timestamp": $timestamp,
    "process_name": "$name",
    "pid": $pid,
    "cpu_usage": ${cpu:-0},
    "memory_usage": ${mem:-0},
    "fd_count": ${fd_count:-0},
    "thread_count": ${threads:-0}
}
EOF
        mv "${metrics_file}.tmp" "$metrics_file"
        
        sleep $METRICS_INTERVAL
    done &
}

# Initialize metrics collector
init_metrics_collector
