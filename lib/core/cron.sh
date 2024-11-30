#!/bin/bash

# Prevent multiple inclusion
[ -n "${CORE_CRON_SOURCED}" ] && return 0
declare -g CORE_CRON_SOURCED=1

source "${LIB_PATH}/core/logging.sh"

# Start cron daemon if not running
start_cron() {
    # First ensure cron is stopped
    stop_cron

    if ! pgrep crond >/dev/null; then
        log_info "Starting crond daemon"
        if ! crond; then
            log_error "Failed to start crond daemon"
            return 1
        fi
        
        # Verify crond is running
        sleep 1
        if ! pgrep crond >/dev/null; then
            log_error "crond failed to start properly"
            return 1
        fi
        return 0
    else
        log_info "crond already running, reloading configuration"
        if ! reload_cron; then
            log_error "Failed to reload crond configuration"
            return 1
        fi
    fi
    return 0
}

# Stop cron daemon
stop_cron() {
    if pgrep crond >/dev/null; then
        log_info "Stopping crond daemon"
        pkill crond
        
        # Wait for process to stop
        local timeout=10
        local counter=0
        while pgrep crond >/dev/null && [ $counter -lt $timeout ]; do
            sleep 1
            counter=$((counter + 1))
        done
        
        if pgrep crond >/dev/null; then
            log_error "Failed to stop crond daemon gracefully, forcing..."
            pkill -9 crond
            sleep 1
        fi
        
        if pgrep crond >/dev/null; then
            log_error "Failed to stop crond daemon"
            return 1
        fi
    fi
    return 0
}

# Reload cron configuration
reload_cron() {
    if pgrep crond >/dev/null; then
        log_info "Reloading crond configuration"
        pkill -HUP crond
        return $?
    fi
    return 1
}

# Check if cron is running
is_cron_running() {
    if pgrep crond >/dev/null; then
        return 0
    fi
    return 1
}
