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
    
    # Start the keepalive process directly without monitoring
    etcdctl lease keep-alive "$lease_id" >/dev/null 2>&1 &
    local keepalive_pid=$!
    
    # Store the PID for cleanup
    echo $keepalive_pid > "/var/run/mysqld/keepalive.pid"
    
    # Export the lease ID for other processes
    export ETCD_LEASE_ID="$lease_id"
    
    # Return immediately with the PID
    echo $keepalive_pid
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
