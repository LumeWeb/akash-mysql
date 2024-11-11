#!/bin/bash

# Prevent multiple inclusion
[ -n "${CORE_MONITOR_SOURCED}" ] && return 0
declare -g CORE_MONITOR_SOURCED=1

source "${LIB_PATH}/core/logging.sh"
source "${LIB_PATH}/core/process.sh"

# System monitoring thresholds
declare -gr CPU_THRESHOLD=80
declare -gr MEMORY_THRESHOLD=90
declare -gr DISK_THRESHOLD=85
declare -gr LOAD_THRESHOLD=10

# Initialize monitoring
init_monitoring() {
    mkdir -p /var/log/mysql/monitoring
    chmod 755 /var/log/mysql/monitoring
}

# Monitor system resources
monitor_system_resources() {
    while true; do
        # CPU usage
        local cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}')
        if [ $(echo "$cpu_usage > $CPU_THRESHOLD" | bc) -eq 1 ]; then
            log_warn "High CPU usage: ${cpu_usage}%"
        fi

        # Memory usage
        local mem_info=$(free -m)
        local total_mem=$(echo "$mem_info" | awk '/Mem:/ {print $2}')
        local used_mem=$(echo "$mem_info" | awk '/Mem:/ {print $3}')
        local mem_usage=$((used_mem * 100 / total_mem))
        
        if [ $mem_usage -gt $MEMORY_THRESHOLD ]; then
            log_warn "High memory usage: ${mem_usage}%"
        fi

        # Disk usage
        local disk_usage=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')
        if [ $disk_usage -gt $DISK_THRESHOLD ]; then
            log_warn "High disk usage: ${disk_usage}%"
        fi

        # System load
        local load_avg=$(uptime | awk -F'load average:' '{print $2}' | awk -F, '{print $1}')
        if [ $(echo "$load_avg > $LOAD_THRESHOLD" | bc) -eq 1 ]; then
            log_warn "High system load: $load_avg"
        fi

        sleep 60
    done &
}

# Monitor file descriptors
monitor_file_descriptors() {
    while true; do
        local fd_usage=$(lsof -p $(pidof mysqld) | wc -l)
        local fd_limit=$(ulimit -n)
        local fd_percent=$((fd_usage * 100 / fd_limit))

        if [ $fd_percent -gt 80 ]; then
            log_warn "High file descriptor usage: ${fd_percent}% ($fd_usage/$fd_limit)"
        fi

        sleep 300
    done &
}

# Initialize monitoring on source
init_monitoring
