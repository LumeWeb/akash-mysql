#!/bin/bash

# Prevent multiple inclusion
[ -n "${ETCD_UTILS_SOURCED}" ] && return 0
declare -g ETCD_UTILS_SOURCED=1

source "${LIB_PATH}/core/logging.sh"

# Convert decimal lease ID to hex format
lease_id_to_hex() {
    local decimal_id=$1
    printf '%x' "$decimal_id"
}

# Convert hex lease ID to decimal format
lease_id_to_decimal() {
    local hex_id=$1
    printf '%d' "0x$hex_id"
}

# Get a new lease with retries
get_etcd_lease() {
    local ttl=${1:-10}
    local max_attempts=${2:-10}
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        local lease_response
        lease_response=$(etcdctl lease grant "$ttl" -w json)
        local decimal_id
        decimal_id=$(echo "$lease_response" | jq -r '.ID')
        
        if [ -n "$decimal_id" ]; then
            echo $(lease_id_to_hex "$decimal_id")
            return 0
        fi
        log_warn "Failed to get valid lease (attempt $attempt/$max_attempts)"
        sleep 2
        attempt=$((attempt + 1))
    done

    return 1
}

# Start lease keepalive in background
start_lease_keepalive() {
    local lease_id=$1
    
    # Create named pipe for lease updates if it doesn't exist
    local lease_pipe="/var/run/mysqld/lease_updates.pipe"
    [ -p "$lease_pipe" ] || mkfifo "$lease_pipe"
    
    # Start the main keepalive process
    (
        # Start keepalive in background
        etcdctl lease keep-alive "$lease_id" -w json >/dev/null 2>&1 &
        local keepalive_pid=$!
        
        # Store the PID for cleanup
        echo $keepalive_pid > "/var/run/mysqld/keepalive.pid"
        
        # Monitor the keepalive process
        while kill -0 $keepalive_pid 2>/dev/null; do
            sleep 5
            
            # Verify lease is still valid
            if ! etcdctl lease timetolive "$lease_id" >/dev/null 2>&1; then
                log_error "Lease $lease_id is no longer valid"
                kill $keepalive_pid 2>/dev/null || true
                
                # Try to get new lease
                new_lease=$(etcdctl lease grant 10 -w json 2>/dev/null)
                new_lease_id=$(echo "$new_lease" | jq -r '.ID')
                if [ -n "$new_lease_id" ]; then
                    lease_id=$(lease_id_to_hex "$new_lease_id")
                    log_info "Acquired new lease (hex): $lease_id"
                    echo "$lease_id" > "$lease_pipe" &
                    
                    # Start new keepalive process
                    etcdctl lease keep-alive "$lease_id" -w json >/dev/null 2>&1 &
                    keepalive_pid=$!
                    echo $keepalive_pid > "/var/run/mysqld/keepalive.pid"
                fi
            fi
        done
    ) &
    
    local monitor_pid=$!
    echo $monitor_pid > "/var/run/mysqld/lease_monitor.pid"
    
    # Return immediately while keeping track of the PID
    echo $monitor_pid
    return 0
}

# Stop lease keepalive process
stop_lease_keepalive() {
    local pid=$1
    
    # Stop the keepalive child process if it exists
    if [ -f "/var/run/mysqld/keepalive.pid" ]; then
        kill $(cat "/var/run/mysqld/keepalive.pid") 2>/dev/null || true
        rm -f "/var/run/mysqld/keepalive.pid"
    fi
    
    # Stop the monitor process
    if [ -n "$pid" ]; then
        kill $pid 2>/dev/null || true
        wait $pid 2>/dev/null || true
    fi
    
    # Clean up the named pipe and monitor PID file
    rm -f "/var/run/mysqld/lease_updates.pipe"
    rm -f "/var/run/mysqld/lease_monitor.pid"
    
    unset ETCD_LEASE_ID
}

# Get current lease ID
get_current_lease_id() {
    if [ -f "/var/run/mysqld/current_lease_id" ]; then
        cat "/var/run/mysqld/current_lease_id"
    fi
}
