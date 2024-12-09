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
    # Get a valid lease with retries
    local max_attempts=10
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        LEASE_ID=$(etcdctl lease grant 10 2>/dev/null | awk '{print $2}')
        if [ -n "$LEASE_ID" ]; then
            log_info "Got valid lease ID: $LEASE_ID"
            break
        fi
        log_warn "Failed to get valid lease (attempt $attempt/$max_attempts)"
        sleep 2
        attempt=$((attempt + 1))
    done

    if [ -z "$LEASE_ID" ]; then
        log_error "Failed to get valid lease after $max_attempts attempts"
        return 1
    fi

    # Get MySQL status values with fallbacks
    local connections=$(mysqladmin status 2>/dev/null | awk '{print $4}')
    local uptime=$(mysqladmin status 2>/dev/null | awk '{print $2}')

    # Initial registration with all required fields
    local status_json=$(jq -n \
        --arg status "online" \
        --arg role "$initial_role" \
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

    etcdctl put "$(get_node_path $NODE_ID)" "$status_json" --lease=$LEASE_ID >/dev/null

    # Start lease keepalive in background
    etcdctl lease keep-alive $LEASE_ID &
    LEASE_KEEPALIVE_PID=$!

    # Start health status updater in background
    (
        while true; do
            sleep 5
            check_mysql_health
            health_status=$?

            # Get current MySQL stats with fallbacks
            local curr_connections=$(mysqladmin status 2>/dev/null | awk '{print $4}')
            local curr_uptime=$(mysqladmin status 2>/dev/null | awk '{print $2}')

            local status_json
            if [ $health_status -ne 0 ]; then
                status_json=$(jq -n \
                    --arg status "offline" \
                    --arg role "$CURRENT_ROLE" \
                    --arg host "$HOST" \
                    --arg port "${MYSQL_EXTERNAL_PORT}" \
                    --arg last_seen "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                    --arg gtid "$(get_gtid_position)" \
                    --arg connections "${curr_connections:-0}" \
                    --arg uptime "${curr_uptime:-0}" \
                    --arg health_status "$HEALTH_STATUS_DETAILS" \
                    --arg errors "$health_status" \
                    '{
                        status: $status,
                        role: $role,
                        host: $host,
                        port: $port,
                        last_seen: $last_seen,
                        gtid_position: $gtid,
                        health: {
                            status: $health_status,
                            connections: ($connections | tonumber),
                            uptime: ($uptime | tonumber),
                            errors: ($errors | tonumber)
                        }
                    }')
            else
                status_json=$(jq -n \
                    --arg status "online" \
                    --arg role "$CURRENT_ROLE" \
                    --arg host "$HOST" \
                    --arg port "${MYSQL_EXTERNAL_PORT}" \
                    --arg last_seen "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                    --arg gtid "$(get_gtid_position)" \
                    --arg connections "${curr_connections:-0}" \
                    --arg uptime "${curr_uptime:-0}" \
                    --arg health_status "$HEALTH_STATUS_DETAILS" \
                    '{
                        status: $status,
                        role: $role,
                        host: $host,
                        port: $port,
                        last_seen: $last_seen,
                        gtid_position: $gtid,
                        health: {
                            status: $health_status,
                            connections: ($connections | tonumber),
                            uptime: ($uptime | tonumber)
                        }
                    }')
            fi

            if ! etcdctl put "$(get_node_path $NODE_ID)" "$status_json" --lease=$LEASE_ID >/dev/null; then
                log_error "Failed to update node status in etcd"
            fi
            sleep 5
        done
    ) &
    HEALTH_UPDATE_PID=$!

    return $?
}

# Get the etcd path for a node
get_node_path() {
    local node_id=$1
    echo "${ETCD_NODES}/${node_id}"
}
