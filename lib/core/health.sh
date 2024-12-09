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
            log_info "Running health check update cycle"
            check_mysql_health
            health_status=$?
            log_info "Health check status: $health_status"

            # Get current MySQL stats with fallbacks
            local curr_connections=$(mysqladmin status 2>/dev/null | awk '{print $4}')
            local curr_uptime=$(mysqladmin status 2>/dev/null | awk '{print $2}')
            
            log_info "Current stats - Connections: ${curr_connections:-0}, Uptime: ${curr_uptime:-0}"

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

            log_info "Attempting to update etcd with status"
            log_info "Node path: $(get_node_path $NODE_ID)"
            log_info "Status JSON: $status_json"
            log_info "Lease ID: $LEASE_ID"

            if ! etcdctl put "$(get_node_path $NODE_ID)" "$status_json" --lease=$LEASE_ID >/dev/null; then
                log_error "Failed to update node status in etcd"
            else
                log_info "Successfully updated node status in etcd"
            fi
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
