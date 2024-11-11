#!/bin/bash

# Prevent multiple inclusion
[ -n "${CORE_LOCKS_SOURCED}" ] && return 0
declare -g CORE_LOCKS_SOURCED=1

source "${LIB_PATH}/core/logging.sh"

# Lock file paths
declare -gr LOCK_DIR="/var/lock/mysql"
declare -gr MYSQL_LOCK="${LOCK_DIR}/mysql.lock"
declare -gr STARTUP_LOCK="${LOCK_DIR}/startup.lock" 
declare -gr SHUTDOWN_LOCK="${LOCK_DIR}/shutdown.lock"
declare -gr MEMORY_LOCK="${LOCK_DIR}/memory.lock"
declare -gr CONNECTION_LOCK="${LOCK_DIR}/connection.lock"

# Initialize lock directory
init_locks() {
    # Create lock directory if it doesn't exist, ignoring errors if it does
    mkdir -p "$LOCK_DIR" 2>/dev/null || true
    chmod 755 "$LOCK_DIR" 2>/dev/null || true
    
    # Create lock files with proper permissions
    for lock in "$MYSQL_LOCK" "$STARTUP_LOCK" "$SHUTDOWN_LOCK" "$MEMORY_LOCK" "$CONNECTION_LOCK"; do
        touch "$lock" 2>/dev/null || true
        chmod 644 "$lock" 2>/dev/null || true
    done
}

# Acquire a lock with timeout and proper cleanup
acquire_lock() {
    local lock_path="$1"
    local timeout="${2:-10}"
    local description="${3:-unknown}"
    
    (
        if ! flock -w "$timeout" 9; then
            log_error "Failed to acquire lock: $description (timeout: ${timeout}s)"
            return 1
        fi
        
        echo "$$" > "$lock_path"
        chmod 644 "$lock_path"
        
        return 0
    ) 9>"$lock_path"
}

# Release a lock with validation
release_lock() {
    local lock_path="$1"
    local pid="$2"
    
    if [ -f "$lock_path" ]; then
        local lock_pid
        local fd_num
        local file_path
        lock_pid=$(cat "$lock_path" 2>/dev/null)
        
        # Only release if we own the lock
        if [ "$lock_pid" = "$pid" ]; then
            rm -f "$lock_path"
        fi
    fi
}

# Cleanup stale locks
cleanup_stale_locks() {
    find "$LOCK_DIR" -type f -name "*.lock" -mmin +60 -delete
}

# Initialize locks on source
init_locks
