#!/bin/bash

# Prevent multiple inclusion
[ -n "${CORE_LOGGING_SOURCED}" ] && return 0
declare -g CORE_LOGGING_SOURCED=1

# Log levels
declare -gr LOG_INFO=0
declare -gr LOG_WARN=1
declare -gr LOG_ERROR=2

# Logging function
log() {
    local level=$1
    shift
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local message="[$timestamp] [$HOSTNAME] "
    
    case $level in
        $LOG_INFO)
            message+="[INFO] $*"
            printf '%s\n' "$message" | stdbuf -oL cat ;;
        $LOG_WARN)
            message+="[WARN] $*"
            printf '%s\n' "$message" | stdbuf -eL cat >&2 ;;
        $LOG_ERROR)
            message+="[ERROR] $*"
            printf '%s\n' "$message" | stdbuf -eL cat >&2 ;;
    esac
}

# Convenience functions
log_info() { log $LOG_INFO "$@"; }
log_warn() { log $LOG_WARN "$@"; }
log_error() { log $LOG_ERROR "$@"; }

# Monitor log file and stream to console
monitor_log() {
    local log_file=$1
    local pid_file=$2
    
    # Ensure log file exists
    touch "$log_file"
    
    # Start tail process in background
    tail -n 0 -F "$log_file" &
    local tail_pid=$!
    
    # Store PID if requested
    if [ -n "$pid_file" ]; then
        echo $tail_pid > "$pid_file"
    fi
    
    return 0
}
