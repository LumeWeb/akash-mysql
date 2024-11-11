#!/bin/bash

# Prevent multiple inclusion
[ -n "${ETCD_PATHS_SOURCED}" ] && return 0
declare -g ETCD_PATHS_SOURCED=1

source "${LIB_PATH}/core/logging.sh"

# Validate and read etcd configuration
if [ -z "$ETCDCTL_ENDPOINTS" ]; then
    log_error "ETCDCTL_ENDPOINTS environment variable is not set"
    exit 1
fi

# Authentication is optional but both username and password must be set if used
if [ -n "$ETC_USERNAME" ] && [ -z "$ETC_PASSWORD" ]; then
    log_error "ETC_USERNAME must be set when ETC_PASSWORD is provided"
    exit 1
fi

if [ -z "$ETC_USERNAME" ] && [ -n "$ETC_PASSWORD" ]; then
    log_error "ETC_USERNAME must be set when ETC_PASSWORD is provided"
    exit 1
fi
# Log etcd configuration
log_info "Using etcd endpoint: $ETCDCTL_ENDPOINTS"
if [ -n "$ETCD_USERNAME" ]; then
    log_info "Using etcd authentication with user: $ETCD_USERNAME"
fi

# Base paths for MySQL cluster coordination
declare -gr ETCD_BASE="/mysql"
declare -gr ETCD_NODES="${ETCD_BASE}/nodes"
declare -gr ETCD_TOPOLOGY_PREFIX="${ETCD_BASE}/topology"
declare -gr ETCD_MASTER_KEY="${ETCD_TOPOLOGY_PREFIX}/master"
declare -gx ETCDCTL_USER
declare -gx ETCDCTL_API

# Configure etcdctl environment variables
setup_etcd_env() {
    ETCDCTL_API=3
    
    # Configure authentication if credentials are provided
    if [ -n "$ETC_USERNAME" ] && [ -n "$ETC_PASSWORD" ]; then
        ETCDCTL_USER="$ETC_USERNAME:$ETC_PASSWORD"
    fi
    
    return 0
}

# Retry wrapper for etcd operations
etcd_retry() {
    local max_attempts=${ETCD_MAX_RETRIES:-3}
    local attempt=1
    local timeout=${ETCD_TIMEOUT:-5}
    
    while [ $attempt -le $max_attempts ]; do
        if timeout $timeout "$@"; then
            return 0
        fi
        log_warn "Etcd operation failed (attempt $attempt/$max_attempts): $*"
        sleep $((2 * attempt))
        attempt=$((attempt + 1))
    done
    
    log_error "Etcd operation failed after $max_attempts attempts: $*"
    return 1
}

# Initialize etcd configuration
if ! setup_etcd_env; then
    log_error "Failed to configure etcd environment"
    exit 1
fi
