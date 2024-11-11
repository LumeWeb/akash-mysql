#!/bin/bash

# Prevent multiple inclusion
[ -n "${CORE_FD_SOURCED}" ] && return 0
declare -g CORE_FD_SOURCED=1

source "${LIB_PATH}/core/logging.sh"

# Track open file descriptors
declare -A FD_TRACKER
declare -g FD_TRACKER_INITIALIZED=0
declare -g FD_TRACKER_LOCK="/var/run/mysqld/fd_tracker.lock"

# Track FDs by type
declare -A FD_TYPES=(
    ["temp"]="Temporary files"
    ["socket"]="Network sockets" 
    ["pipe"]="Named pipes"
    ["lock"]="Lock files"
    ["log"]="Log files"
)

# Initialize tracker
init_fd_tracker() {
    if [ "$FD_TRACKER_INITIALIZED" -eq 0 ]; then
        mkdir -p "$(dirname "$FD_TRACKER_LOCK")"
        chmod 755 "$(dirname "$FD_TRACKER_LOCK")"
        : > "$FD_TRACKER_LOCK"
        chmod 644 "$FD_TRACKER_LOCK"
        FD_TRACKER_INITIALIZED=1
    fi
}

# Track a file descriptor
track_fd() {
    local fd=$1
    local description=$2
    
    if [ -z "$fd" ] || [ -z "$description" ]; then
        log_error "Invalid fd tracking attempt: fd=$fd, desc=$description"
        return 1
    fi
    
    if [ ! -e "/proc/$$/fd/$fd" ]; then
        log_error "Attempting to track invalid fd: $fd"
        return 1
    fi
    
    FD_TRACKER[$fd]="$description:$$"
    return 0
}

# Untrack a file descriptor
untrack_fd() {
    local fd=$1
    unset FD_TRACKER[$fd]
}

# Cleanup tracked file descriptors
cleanup_fds() {
    local errors=0
    
    for fd in "${!FD_TRACKER[@]}"; do
        if [ "$fd" != "9" ] && [ -e "/proc/$$/fd/$fd" ]; then
            if ! eval "exec $fd>&-" 2>/dev/null; then
                log_warn "Failed to close file descriptor $fd (${FD_TRACKER[$fd]})"
                errors=$((errors + 1))
            else
                untrack_fd "$fd"
            fi
        fi
    done
    
    if [ $errors -gt 0 ]; then
        log_error "Failed to close $errors file descriptors"
        return 1
    fi
    
    return 0
}
