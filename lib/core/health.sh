#!/bin/bash

# Prevent multiple inclusion
[ -n "${CORE_HEALTH_SOURCED}" ] && return 0
declare -g CORE_HEALTH_SOURCED=1

source "${LIB_PATH}/core/logging.sh"
source "${LIB_PATH}/mysql-common.sh"

declare -g HEALTH_UPDATE_PID=""

start_health_updater() {
    log_info "Starting health status updater"
    
    # Start health status updater in background
    (
        log_info "Starting health status updater background process (PID: $$)"
        while true; do
            check_mysql_health
            health_status=$?

            # Get current MySQL stats with fallbacks
            local curr_connections=$(mysqladmin status 2>/dev/null | awk '{print $4}')
            local curr_uptime=$(mysqladmin status 2>/dev/null | awk '{print $2}')

            # Get current node info from etcd
            local node_info
            node_info=$(get_node_info "$NODE_ID")
            local current_role
            current_role=$(echo "$node_info" | jq -r '.role // "slave"')

            local status_json
            if [ $health_status -ne 0 ]; then
                status_json=$(jq -n \
                    --arg status "offline" \
                    --arg role "$current_role" \
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
                    --arg role "$current_role" \
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

            # Get current lease ID from environment
            if [ -n "$ETCD_LEASE_ID" ]; then
                LEASE_ID="$ETCD_LEASE_ID"
            fi

            if ! etcdctl put "$(get_node_path $NODE_ID)" "$status_json" --lease=$LEASE_ID >/dev/null; then
                log_error "Failed to update node status in etcd"
            fi

            # Add a small delay between health checks
            sleep 5
        done
    ) &
    HEALTH_UPDATE_PID=$!
    log_info "Started health status updater with PID: $HEALTH_UPDATE_PID"
}

stop_health_updater() {
    if [ -n "$HEALTH_UPDATE_PID" ]; then
        log_info "Stopping health status updater (PID: $HEALTH_UPDATE_PID)"
        kill $HEALTH_UPDATE_PID 2>/dev/null || true
        wait $HEALTH_UPDATE_PID 2>/dev/null || true
        HEALTH_UPDATE_PID=""
    fi
}
