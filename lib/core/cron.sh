#!/bin/bash

# Prevent multiple inclusion
[ -n "${CORE_CRON_SOURCED}" ] && return 0
declare -g CORE_CRON_SOURCED=1

source "${LIB_PATH}/core/logging.sh"

# Global variable for cron daemon PID
declare -g CROND_PID=""

# Start cron daemon if not running
start_cron() {
    # First ensure cron is stopped
    stop_cron

    if ! pgrep supercronic >/dev/null; then
        log_info "Starting supercronic daemon"
        
        # Run supercronic with appropriate flags in background
        supercronic --json --split-logs --overlapping "${CRON_TAB_FILE}" &
        CROND_PID=$!
        
        # Verify supercronic is running
        sleep 1
        if ! kill -0 $CROND_PID 2>/dev/null; then
            log_error "supercronic failed to start properly"
            return 1
        fi
        log_info "Started supercronic with PID: $CROND_PID"
        return 0
    else
        log_info "supercronic already running"
        return 0
    fi
    return 0
}

# Stop cron daemon
stop_cron() {
    if [ -n "$CROND_PID" ]; then
        log_info "Stopping supercronic daemon (PID: $CROND_PID)"
        kill $CROND_PID 2>/dev/null || true
        
        # Wait for process to stop
        local timeout=10
        local counter=0
        while kill -0 $CROND_PID 2>/dev/null && [ $counter -lt $timeout ]; do
            sleep 1
            counter=$((counter + 1))
        done
        
        if kill -0 $CROND_PID 2>/dev/null; then
            log_error "Failed to stop supercronic daemon gracefully, forcing..."
            kill -9 $CROND_PID 2>/dev/null || true
            sleep 1
        fi
        
        CROND_PID=""
    else
        # Cleanup any other supercronic processes
        pkill supercronic 2>/dev/null || true
    fi
    return 0
}


# Check if cron is running
is_cron_running() {
    if pgrep supercronic >/dev/null; then
        return 0
    fi
    return 1
}

# Cron state tracking
declare -gr CRON_STATE_FILE="${STATE_DIR}/cron_state"
