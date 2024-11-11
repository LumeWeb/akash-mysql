#!/bin/bash

# Prevent multiple inclusion
[ -n "${CORE_PROCESS_SOURCED}" ] && return 0
declare -g CORE_PROCESS_SOURCED=1

source "${LIB_PATH}/core/logging.sh"
source "${LIB_PATH}/core/fd.sh"

# Process management functions
declare -A MANAGED_PROCESSES
declare -g PROCESS_MONITOR_PID=""

# Initialize process management
init_process_manager() {
    mkdir -p /var/run/mysql
    chmod 755 /var/run/mysql
}

# Start a managed process
start_managed_process() {
    local name=$1
    local command=$2
    shift 2
    local args=("$@")

    if [ -n "${MANAGED_PROCESSES[$name]}" ]; then
        log_warn "Process $name is already managed"
        return 1
    }

    # Start process with proper argument handling
    if ! "${command}" "${args[@]}" & pid=$!; then
        log_error "Failed to start process: $name"
        return 1
    }

    MANAGED_PROCESSES[$name]=$pid
    log_info "Started managed process $name (PID: $pid)"
    return 0
}

# Stop a managed process
stop_managed_process() {
    local name=$1
    local timeout=${2:-30}
    local force=${3:-0}

    local pid=${MANAGED_PROCESSES[$name]}
    if [ -z "$pid" ]; then
        log_warn "Process $name is not managed"
        return 1
    }

    if ! kill -0 $pid 2>/dev/null; then
        log_warn "Process $name (PID: $pid) is not running"
        unset MANAGED_PROCESSES[$name]
        return 0
    }

    # Try graceful shutdown first
    kill $pid
    local waited=0
    while [ $waited -lt $timeout ]; do
        if ! kill -0 $pid 2>/dev/null; then
            unset MANAGED_PROCESSES[$name]
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done

    # Force kill if requested
    if [ $force -eq 1 ]; then
        kill -9 $pid
        unset MANAGED_PROCESSES[$name]
        return 0
    fi

    log_error "Failed to stop process $name (PID: $pid)"
    return 1
}

# Monitor managed processes
monitor_processes() {
    while true; do
        for name in "${!MANAGED_PROCESSES[@]}"; do
            local pid=${MANAGED_PROCESSES[$name]}
            if ! kill -0 $pid 2>/dev/null; then
                log_error "Managed process $name (PID: $pid) died"
                unset MANAGED_PROCESSES[$name]
            fi
        done
        sleep 5
    done &
    PROCESS_MONITOR_PID=$!
}

# Stop all managed processes
stop_all_processes() {
    local timeout=${1:-30}
    local force=${2:-0}

    # Stop process monitor first
    if [ -n "$PROCESS_MONITOR_PID" ]; then
        kill $PROCESS_MONITOR_PID
        wait $PROCESS_MONITOR_PID 2>/dev/null
    fi

    for name in "${!MANAGED_PROCESSES[@]}"; do
        stop_managed_process "$name" $timeout $force
    done
}

# Initialize on source
init_process_manager
