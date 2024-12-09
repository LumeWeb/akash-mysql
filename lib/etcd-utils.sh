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
    
    (
        # Use exec to replace shell process with etcdctl
        # This allows the keepalive to run continuously without polling
        exec etcdctl lease keep-alive "$lease_id" -w json >/dev/null 2>&1
    ) &
    
    local keepalive_pid=$!
    
    # Start a separate monitor process
    (
        while true; do
            # Check if keepalive process is still running
            if ! kill -0 $keepalive_pid 2>/dev/null; then
                log_error "Lost etcd lease keepalive process"
                # Try to get new lease
                new_lease=$(etcdctl lease grant 10 -w json 2>/dev/null)
                new_lease_id=$(echo "$new_lease" | jq -r '.ID')
                if [ -n "$new_lease_id" ]; then
                    lease_id=$(lease_id_to_hex "$new_lease_id")
                    log_info "Acquired new lease (hex): $lease_id"
                    # Export the new lease ID for parent process
                    echo "$lease_id" > "/tmp/etcd_lease_$BASHPID"
                    
                    # Start new keepalive process
                    (
                        exec etcdctl lease keep-alive "$lease_id" -w json >/dev/null 2>&1
                    ) &
                    keepalive_pid=$!
                fi
            fi
            sleep 5
        done
    ) &
    
    echo $!
}

# Stop lease keepalive process
stop_lease_keepalive() {
    local pid=$1
    if [ -n "$pid" ]; then
        kill $pid 2>/dev/null || true
        wait $pid 2>/dev/null || true
        rm -f "/tmp/etcd_lease_$pid" 2>/dev/null || true
    fi
}

# Get current lease ID from keepalive process
get_current_lease_id() {
    local pid=$1
    if [ -f "/tmp/etcd_lease_$pid" ]; then
        cat "/tmp/etcd_lease_$pid"
    fi
}
