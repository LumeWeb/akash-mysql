# Wait for etcd to be ready
wait_for_etcd() {
    local max_attempts=30
    local attempt=1
    local timeout=5

    log_info "Waiting for etcd connection..."
    log_info "Endpoint: $ETCDCTL_ENDPOINTS"
    log_info "Timeout: ${timeout}s"
    log_info "Max attempts: $max_attempts"

    # Validate ETCDCTL_ENDPOINTS is set
    if [ -z "$ETCDCTL_ENDPOINTS" ]; then
        log_error "ETCDCTL_ENDPOINTS is not set"
        return 1
    fi

    # Extract host and port from ETCDCTL_ENDPOINTS
    local etcd_host=$(echo "$ETCDCTL_ENDPOINTS" | sed -E 's|^http[s]?://||' | cut -d: -f1)
    local etcd_port=$(echo "$ETCDCTL_ENDPOINTS" | sed -E 's|^http[s]?://||' | cut -d: -f2)

    log_info "Parsed etcd host: $etcd_host"
    log_info "Parsed etcd port: $etcd_port"

    while [ $attempt -le $max_attempts ]; do
        log_info "Connection attempt $attempt/$max_attempts"

        # First try basic TCP connection
        if timeout $timeout nc -z -w5 "$etcd_host" "$etcd_port" 2>/dev/null; then
            log_info "TCP connection successful"

            # Then try etcd health check
            if timeout $timeout etcdctl endpoint health 2>&1 >/dev/null; then
                local status=$(etcdctl endpoint status --write-out=json 2>&1)
                local version=$(etcdctl version 2>&1)

                log_info "Successfully connected to etcd"
                log_info "Etcd version: $version"
                log_info "Endpoint status: $status"
                return 0
            else
                log_error "TCP connection successful but etcd health check failed"
                log_error "Health check output: $(etcdctl endpoint health 2>&1)"
            fi
        else
            log_error "TCP connection failed to $etcd_host:$etcd_port"
            # Try to get more network diagnostic information
            timeout $timeout nc -zv "$etcd_host" "$etcd_port" 2>&1 || true
        fi

        local wait_time=$((2 * attempt))
        log_info "Connection failed, waiting ${wait_time}s before retry"
        sleep $wait_time
        attempt=$((attempt + 1))
    done

    log_error "Failed to connect to etcd after $max_attempts attempts"
    log_error "Final connection test results:"
    log_error "TCP connection: $(nc -zv "$etcd_host" "$etcd_port" 2>&1)"
    log_error "Etcd health: $(etcdctl endpoint health 2>&1)"
    log_error "Etcd status: $(etcdctl endpoint status 2>&1)"
    return 1
}

# Register node in etcd with lease and health status
register_node() {
    log_info "Starting node registration process"

    # Ensure CURRENT_ROLE is set
    CURRENT_ROLE=${CURRENT_ROLE:-"slave"}
    log_info "Using role: $CURRENT_ROLE"

    # Get a valid lease
    LEASE_ID=$(get_etcd_lease 10)
    if [ -z "$LEASE_ID" ]; then
        log_error "Failed to get valid lease"
        return 1
    fi
    log_info "Got valid lease ID (hex): $LEASE_ID"

    # Get MySQL status values with fallbacks
    local connections=$(mysqladmin status 2>/dev/null | awk '{print $4}')
    local uptime=$(mysqladmin status 2>/dev/null | awk '{print $2}')

    # Initial registration with all required fields
    local status_json=$(jq -n \
        --arg status "online" \
        --arg role "$CURRENT_ROLE" \
        --arg host "$HOSTNAME" \
        --arg port "${MYSQL_EXTERNAL_PORT}" \
        --arg last_seen "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg gtid "$(get_gtid_position)" \
        --arg connections "${connections:-0}" \
        --arg uptime "${uptime:-0}" \
        '{
            status: $status,
            role: $role,
            host: $host,
            port: $port,
            last_seen: $last_seen,
            gtid_position: $gtid,
            health: {
                connections: ($connections | tonumber),
                uptime: ($uptime | tonumber)
            }
        }')

    etcdctl put "$(get_node_path $NODE_ID)" "$status_json" --lease="$LEASE_ID" >/dev/null

    # Start lease keepalive in background
    LEASE_KEEPALIVE_PID=$(start_lease_keepalive "$LEASE_ID")
    
    # Monitor for lease ID changes
    (
        while true; do
            new_lease_id=$(get_current_lease_id "$LEASE_KEEPALIVE_PID")
            if [ -n "$new_lease_id" ] && [ "$new_lease_id" != "$LEASE_ID" ]; then
                LEASE_ID="$new_lease_id"
                log_info "Updated to new lease ID: $LEASE_ID"
            fi
            sleep 5
        done
    ) &

    log_info "About to start health status updater background process"
    log_info "Current LEASE_ID: $LEASE_ID"
    log_info "Current NODE_ID: $NODE_ID"
    log_info "Current CURRENT_ROLE: $CURRENT_ROLE"


    return $?
}

# Get the etcd path for a node
get_node_path() {
    local node_id=$1
    echo "${ETCD_NODES}/${node_id}"
}
