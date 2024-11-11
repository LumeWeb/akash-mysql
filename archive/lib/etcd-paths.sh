#!/bin/bash

# Source constants only if not already sourced
if [ -z "$ETCD_CONSTANTS_SOURCED" ]; then
    source "${LIB_PATH}/etcd-constants.sh"
    ETCD_CONSTANTS_SOURCED=1
fi

# Node status and registration paths
get_node_path() {
    local node_id=$1
    echo "$ETCD_NODES/$node_id"
}

get_node_role_path() {
    local node_id=$1
    echo "$ETCD_TOPOLOGY/$node_id/role"
}

get_node_server_id_path() {
    local node_id=$1
    echo "$ETCD_TOPOLOGY/$node_id/server_id"
}

# Helper to list all topology keys with retry
get_topology_prefix() {
    local max_attempts=3
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if output=$(echo "$ETCD_TOPOLOGY/"); then
            echo "$output"
            return 0
        fi
        echo "Failed to get topology prefix (attempt $attempt/$max_attempts)"
        sleep 1
        attempt=$((attempt + 1))
    done
    return 1
}

# Helper to list all node keys with retry
get_nodes_prefix() {
    local max_attempts=3
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if output=$(echo "$ETCD_NODES/"); then
            echo "$output"
            return 0
        fi
        echo "Failed to get nodes prefix (attempt $attempt/$max_attempts)"
        sleep 1
        attempt=$((attempt + 1))
    done
    return 1
}

# Enhanced retry wrapper for etcd operations with comprehensive error handling
etcd_retry() {
    local max_attempts=3
    local attempt=1
    local timeout=5
    local result
    
    while [ $attempt -le $max_attempts ]; do
        if result=$(timeout $timeout "$@" 2>&1); then
            echo "$result"
            return 0
        fi
        
        local exit_code=$?
        case $exit_code in
            1) # Generic error
                log_warn "Etcd command failed with generic error (attempt $attempt/$max_attempts)"
                sleep 1
                ;;
            2) # Command timed out
                log_warn "Etcd command timed out (attempt $attempt/$max_attempts)"
                sleep 2
                ;;
            3) # Key not found
                log_warn "Etcd key not found (attempt $attempt/$max_attempts)"
                return 3
                ;;
            4) # Key already exists
                log_warn "Etcd key already exists (attempt $attempt/$max_attempts)"
                return 4
                ;;
            5) # Not a file
                log_warn "Etcd path is not a file (attempt $attempt/$max_attempts)"
                return 5
                ;;
            6) # Not a directory
                log_warn "Etcd path is not a directory (attempt $attempt/$max_attempts)" 
                return 6
                ;;
            7) # Key already exists
                log_warn "Etcd key already exists (attempt $attempt/$max_attempts)"
                return 7
                ;;
            8) # Compare failed
                log_warn "Etcd compare failed (attempt $attempt/$max_attempts)"
                sleep 1
                ;;
            9) # Invalid field
                log_error "Etcd invalid field specified"
                return 9
                ;;
            10) # Invalid auth token
                log_error "Etcd invalid auth token"
                return 10
                ;;
            11) # Invalid range
                log_error "Etcd invalid range"
                return 11
                ;;
            12) # Internal server error
                log_warn "Etcd internal server error (attempt $attempt/$max_attempts)"
                sleep 3
                ;;
            124) # Command timeout
                log_warn "Command timed out after ${timeout}s (attempt $attempt/$max_attempts)"
                timeout=$((timeout * 2))
                ;;
            *) # Other errors
                log_warn "Etcd command failed with exit code $exit_code (attempt $attempt/$max_attempts)"
                sleep 1
                ;;
        esac
        local exit_code=$?
        if [ $exit_code -eq 124 ]; then
            echo "Command timed out after ${timeout} seconds (attempt $attempt/$max_attempts)"
        else
            echo "Command failed with exit code $exit_code (attempt $attempt/$max_attempts)"
        fi
        sleep 1
        attempt=$((attempt + 1))
    done
    return 1
}

# Validation helper
validate_node_id() {
    local node_id=$1
    if [[ ! $node_id =~ ^[a-zA-Z0-9_.-]+:[0-9]+$ ]]; then
        echo "Invalid node ID format. Expected format: host:port" >&2
        return 1
    fi
    return 0
}
