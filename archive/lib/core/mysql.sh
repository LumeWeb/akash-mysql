#!/bin/bash

# Prevent multiple inclusion
[ -n "${CORE_MYSQL_SOURCED}" ] && return 0
declare -g CORE_MYSQL_SOURCED=1

source "${LIB_PATH}/core/constants.sh"

# Basic MySQL retry wrapper
mysql_retry() {
    local max_attempts=${MYSQL_MAX_RETRIES:-5}
    local attempt=1
    local command="$*"
    local wait_time=1
    
    while [ $attempt -le $max_attempts ]; do
        if timeout ${MYSQL_QUERY_TIMEOUT} $command; then
            return 0
        fi
        log_warn "MySQL command failed (attempt $attempt/$max_attempts): $command"
        sleep $((wait_time * attempt))
        attempt=$((attempt + 1))
    done
    
    log_error "MySQL command failed after $max_attempts attempts"
    return 1
}

# Wait for MySQL to be ready
wait_for_mysql() {
    local max_attempts=${MYSQL_START_TIMEOUT:-30}
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if mysqladmin ping -h localhost --silent; then
            return 0
        fi
        sleep 1
        attempt=$((attempt + 1))
    done
    
    return 1
}

# Basic health check
check_mysql_health() {
    local errors=0
    
    # Check process
    if ! pgrep mysqld >/dev/null; then
        log_error "MySQL process not running"
        return 1
    fi
    
    # Check connectivity
    if ! mysql_retry "mysqladmin ping -h localhost --silent"; then
        log_error "MySQL not responding to ping"
        errors=$((errors + 1))
    fi
    
    # Check read/write
    if ! mysql_retry "mysql -e 'SELECT 1'"; then
        log_error "MySQL cannot execute queries"
        errors=$((errors + 1))
    fi
    
    return $errors
}
