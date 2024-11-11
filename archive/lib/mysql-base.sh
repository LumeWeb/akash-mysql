#!/bin/bash

# Prevent multiple inclusion
[ -n "${MYSQL_BASE_SOURCED}" ] && return 0
declare -g MYSQL_BASE_SOURCED=1

# Core dependencies only
source "${LIB_PATH}/core/logging.sh"

# Basic MySQL retry function
mysql_base_retry() {
    local max_attempts=3
    local attempt=1
    local command="$*"
    
    while [ $attempt -le $max_attempts ]; do
        if $command; then
            return 0
        fi
        log_base "WARN" "Command failed (attempt $attempt/$max_attempts): $command"
        sleep $((attempt * 2))
        attempt=$((attempt + 1))
    done
    
    log_base "ERROR" "Command failed after $max_attempts attempts: $command"
    return 1
}
