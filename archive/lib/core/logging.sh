#!/bin/bash

# Prevent multiple inclusion
[ -n "${CORE_LOGGING_SOURCED}" ] && return 0
declare -g CORE_LOGGING_SOURCED=1

# Default log directory if not set externally
declare -gr LOG_DIR=${LOG_DIR:-"/var/log/mysql-manager"}

# Core logging levels
declare -gr LOG_DEBUG=0
declare -gr LOG_INFO=1
declare -gr LOG_WARN=2
declare -gr LOG_ERROR=3
declare -g CURRENT_LOG_LEVEL=${LOG_INFO}

# Current log level - can be changed at runtime
declare -g CURRENT_LOG_LEVEL=${LOG_INFO}

# Core logging function with no dependencies
core_log() {
    local level=$1
    local message=$2
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case $level in
        $LOG_DEBUG) level_str="DEBUG" ;;
        $LOG_INFO)  level_str="INFO " ;;
        $LOG_WARN)  level_str="WARN " ;;
        $LOG_ERROR) level_str="ERROR" ;;
        *) level_str="?????" ;;
    esac
    
    if [ $level -ge $CURRENT_LOG_LEVEL ]; then
        echo "[$timestamp] [$level_str] $message" >&2
    fi
}

# Basic logging functions
log_debug() { core_log $LOG_DEBUG "$1"; }
log_info()  { core_log $LOG_INFO  "$1"; }
log_warn()  { core_log $LOG_WARN  "$1"; }
log_error() { core_log $LOG_ERROR "$1"; }

# Set log level with validation
set_log_level() {
    case "${1,,}" in
        debug) CURRENT_LOG_LEVEL=$LOG_DEBUG ;;
        info)  CURRENT_LOG_LEVEL=$LOG_INFO ;;
        warn)  CURRENT_LOG_LEVEL=$LOG_WARN ;;
        error) CURRENT_LOG_LEVEL=$LOG_ERROR ;;
        *)     log_error "Invalid log level: $1" 
               return 1 ;;
    esac
    return 0
}

# Initialize logging
init_logging() {
    # Create log directory if it doesn't exist
    if [ ! -d "$LOG_DIR" ]; then
        if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
            echo "ERROR: Failed to create log directory: $LOG_DIR" >&2
            return 1
        fi
        if ! chmod 755 "$LOG_DIR" 2>/dev/null; then
            echo "ERROR: Failed to set permissions on log directory: $LOG_DIR" >&2
            return 1
        fi
    fi
    return 0
}

# Initialize on source
init_logging
