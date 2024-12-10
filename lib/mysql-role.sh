#!/bin/bash

source "${LIB_PATH}/core/cron.sh"

# Track current role and state
declare -g CURRENT_ROLE=""
declare -g ROLE_STATE_FILE="/var/lib/mysql/last_role"
declare -g LAST_KNOWN_GTID=""
declare -g GTID_MONITOR_PID=""
declare -g REPLICATION_CONFIGURED=0

# Get last known role
get_last_role() {
    if [ -f "$ROLE_STATE_FILE" ]; then
        cat "$ROLE_STATE_FILE"
    else
        echo "slave"
    fi
}

# Save role state
save_role_state() {
    local role=$1
    echo "$role" > "$ROLE_STATE_FILE"
    chmod 644 "$ROLE_STATE_FILE"
}

# Switch node to source (master) role
handle_promotion_to_master() {
    log_info "Handling promotion to source (primary) role"

    # Stop any existing backup services first
    if ! stop_cron; then
        log_error "Failed to stop existing cron jobs"
        return 1
    fi
    
    if ! stop_streaming_backup_server; then
        log_error "Failed to stop existing backup server"
        return 1
    fi

    # Stop replication and reset configuration
    mysql_retry_auth root "${MYSQL_ROOT_PASSWORD}" -e "
        STOP REPLICA;
        RESET REPLICA ALL;
        SET GLOBAL read_only = OFF;
        SET GLOBAL super_read_only = OFF;"

    if [ $? -ne 0 ]; then
        log_error "Failed to configure node as source"
        return 1
    fi

    # Start GTID monitoring
    monitor_gtid

    # Start backup services for master if enabled
    if [ "${BACKUP_ENABLED}" = "true" ]; then
        if ! setup_backup_cron; then
            log_error "Failed to setup backup cron jobs"
            return 1
        fi
        
        if ! start_streaming_backup_server; then
            log_error "Failed to start backup streaming server"
            return 1
        fi
    else
        log_info "Backup services not started - backups disabled"
    fi

    # Update our status in etcd
    update_node_status "$NODE_ID" "online" "master"
}

# Switch node to replica (slave) role
handle_demotion_to_slave() {
    log_info "Handling demotion to replica role"
    
    # Stop backup services first before any role change
    if ! stop_cron; then
        log_error "Failed to stop cron jobs"
        return 1
    fi
    
    if ! stop_streaming_backup_server; then
        log_error "Failed to stop backup streaming server"
        return 1
    fi

    local max_attempts=10
    local attempt=1
    local wait_time=5

    while [ $attempt -le $max_attempts ]; do
        # Get source info from etcd
        local source_info
        source_info=$(etcdctl get "$ETCD_MASTER_KEY" --print-value-only)
        if [ -z "$source_info" ]; then
            log_info "No source found in etcd yet - this is normal during initial cluster bootstrap"
            log_info "Configuring as standalone read-only node until cluster topology is established"

            mysql_retry_auth root "${MYSQL_ROOT_PASSWORD}" -e "
                STOP REPLICA;
                RESET REPLICA ALL;
                SET GLOBAL read_only = ON;
                SET GLOBAL super_read_only = ON;"

            if [ $? -ne 0 ]; then
                # If MySQL isn't running yet, just set flags for later
                log_warn "MySQL not ready - deferring read-only configuration"
                export PENDING_READONLY=1
                REPLICATION_CONFIGURED=0
                update_node_status "$NODE_ID" "starting" "slave"
                return 0
            fi

            REPLICATION_CONFIGURED=0
            
            # Stop backup services when becoming slave
            if ! stop_cron; then
                log_error "Failed to stop cron jobs"
                return 1
            fi
            if ! stop_streaming_backup_server; then
                log_error "Failed to stop backup streaming server"
                return 1
            fi
            
            update_node_status "$NODE_ID" "online" "slave"
            return 0
        fi

        local source_host
        local source_port
        source_host=$(get_node_hostname "$source_info")
        source_port=$(get_node_port "$source_info")

        # Avoid self-replication
        if [ "$source_host" = "$(hostname)" ]; then
            log_info "Source would be ourselves - skipping replication setup"
            mysql_retry_auth root "${MYSQL_ROOT_PASSWORD}" -e "
                STOP REPLICA;
                RESET REPLICA ALL;
                SET GLOBAL read_only = ON;
                SET GLOBAL super_read_only = ON;"

            if [ $? -ne 0 ]; then
                log_error "Failed to configure read-only mode"
                return 1
            fi

            update_node_status "$NODE_ID" "online" "slave"
            return 0
        fi

        log_info "Setting up replication from source at $source_host:$source_port"

        # Verify replication user exists and has correct permissions
        log_info "Verifying replication user configuration"
        local repl_user_count
        repl_user_count=$(mysql_retry_auth root "${MYSQL_ROOT_PASSWORD}" -N -s -e \
            "SELECT COUNT(*) FROM mysql.user WHERE user = '$MYSQL_REPL_USERNAME' AND repl_slave_priv = 'Y';")

        if [ "$repl_user_count" -lt 1 ]; then
            log_warn "Replication user not found or lacks privileges (attempt $attempt/$max_attempts)"
            log_info "Waiting for source initialization"
            attempt=$((attempt + 1))
            sleep $wait_time
            wait_time=$((wait_time * 2))
            continue
        fi

        # Configure replication without credentials
        log_info "Configuring replication channel"
        if ! mysql_retry_auth root "${MYSQL_ROOT_PASSWORD}" -e "
            STOP REPLICA;
            CHANGE REPLICATION SOURCE TO
                SOURCE_HOST='$source_host',
                SOURCE_PORT=$source_port,
                SOURCE_AUTO_POSITION=1;
            SET GLOBAL read_only = ON;
            SET GLOBAL super_read_only = ON;"; then
            log_error "Failed to configure replication channel"
            attempt=$((attempt + 1))
            sleep $wait_time
            wait_time=$((wait_time * 2))
            continue
        fi

        # Start replica with credentials
        log_info "Starting replication"
        if ! mysql_retry_auth root "${MYSQL_ROOT_PASSWORD}" -e "
            START REPLICA USER='$MYSQL_REPL_USERNAME' PASSWORD='$MYSQL_REPL_PASSWORD';"; then
            log_error "Failed to start replication"
            attempt=$((attempt + 1))
            sleep $wait_time
            wait_time=$((wait_time * 2))
            continue
        fi

        # Verify replication is running
        log_info "Verifying replication status"
        if ! verify_replication_status; then
            log_error "Replication verification failed"
            # Get detailed replica status for debugging
            local replica_status
            replica_status=$(mysql_retry_auth root "${MYSQL_ROOT_PASSWORD}" -e "SHOW REPLICA STATUS\G")
            log_error "Replica status: $replica_status"
            attempt=$((attempt + 1))
            sleep $wait_time
            wait_time=$((wait_time * 2))
            continue
        fi

        # If we get here, everything worked
        REPLICATION_CONFIGURED=1
        update_node_status "$NODE_ID" "online" "slave"
        log_info "Successfully configured as slave"
        return 0
    done

    log_error "Failed to set up replication after $max_attempts attempts"
    return 1
}

# Monitor GTID changes and update etcd
monitor_gtid() {
    if [ -n "$GTID_MONITOR_PID" ]; then
        kill $GTID_MONITOR_PID 2>/dev/null || true
        wait $GTID_MONITOR_PID 2>/dev/null || true
    fi

    (
        # Use flock for the entire monitoring loop
        flock -n 200 || {
            log_warn "Another GTID monitor is running"
            return 1
        }
        
        while true; do
                
                # Retry GTID position check a few times before giving up
                local gtid_attempts=3
                while [ $gtid_attempts -gt 0 ]; do
                    if gtid_position=$(get_gtid_position); then
                        break
                    fi
                    log_warn "Failed to get GTID position, retrying..."
                    sleep 2
                    gtid_attempts=$((gtid_attempts - 1))
                done

                if [ $gtid_attempts -eq 0 ]; then
                    log_error "Failed to get GTID position after multiple attempts"
                    sleep 5
                    return 1
                fi
            if [ -n "$gtid_position" ] && [ "$gtid_position" != "$LAST_KNOWN_GTID" ]; then
                LAST_KNOWN_GTID="$gtid_position"
                log_info "GTID position updated: $gtid_position"

                # Get current node info using helper
                local current_info
                current_info=$(get_node_info "$NODE_ID")
                local current_role
                current_role=$(echo "$current_info" | jq -r '.role // "slave"')

                node_status=$(jq -n \
                    --arg host "$HOST" \
                    --arg port "${MYSQL_EXTERNAL_PORT}" \
                    --arg last_seen "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                    --arg gtid "$gtid_position" \
                    --arg role "$current_role" \
                    '{
                        status: "online",
                        role: $role,
                        host: $host,
                        port: $port,
                        last_seen: $last_seen,
                        gtid_position: $gtid,
                        health: {
                            connections: 0,
                            uptime: 0
                        }
                    }')
                etcdctl put "$ETCD_NODES/$NODE_ID" "$node_status" >/dev/null
            fi
            sleep 5
        done 200>/var/run/mysqld/gtid_monitor.lock
    ) &
    GTID_MONITOR_PID=$!
}

# Watch for role changes
watch_role_changes() {
    while true; do
        NODE_DATA=$(etcdctl get "$ETCD_NODES/$NODE_ID" --print-value-only 2>/dev/null)
        if [ -z "$NODE_DATA" ]; then
            log_info "Waiting for node registration..."
            sleep 5
            continue
        fi

        # Get current master from etcd
        MASTER_DATA=$(etcdctl get "$ETCD_MASTER_KEY" --print-value-only 2>/dev/null)
        MASTER_NODE=$(echo "$MASTER_DATA" | jq -r '.node_id // empty')

        # If we're the designated master
        if [ "$MASTER_NODE" = "$NODE_ID" ]; then
            if [ "$CURRENT_ROLE" != "master" ]; then
                log_info "ProxySQL designated us as master - handling promotion"
                handle_promotion_to_master
            fi
        else
            # If we're not the master, ensure we're a slave
            if [ "$CURRENT_ROLE" != "slave" ]; then
                log_info "We are not the designated master - handling demotion"
                handle_demotion_to_slave
            elif [ $REPLICATION_CONFIGURED -eq 0 ]; then
                log_info "Slave needs replication configuration"
                handle_demotion_to_slave
            fi
        fi

        sleep 5
    done
}

# Verify replication status
verify_replication_status() {
    local max_attempts=5
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        local status
        status=$(mysql_retry_auth root "${MYSQL_ROOT_PASSWORD}" -N -s -e "
            SELECT
                COALESCE(MAX(io.SERVICE_STATE = 'ON'), 0) as io_running,
                COALESCE(MAX(app.SERVICE_STATE = 'ON'), 0) as sql_running
            FROM performance_schema.replication_connection_status io
            LEFT JOIN performance_schema.replication_applier_status app
            ON io.CHANNEL_NAME = app.CHANNEL_NAME;")

        if [ "$status" = "1	1" ]; then
            log_info "Replication verified successfully"
            return 0
        fi

        log_warn "Replication not fully running (attempt $attempt/$max_attempts)"
        sleep 5
        attempt=$((attempt + 1))
    done

    log_error "Failed to verify replication status after $max_attempts attempts"
    return 1
}

update_node_status() {
    local node_id=$1
    local status=$2
    local new_role=$3

    if [ -z "$LEASE_ID" ]; then
        log_error "No lease ID available for status update"
        return 1
    fi

    log_info "Updating node status: $status (role: $new_role)"

    local status_json=$(jq -n \
        --arg status "$status" \
        --arg role "$new_role" \
        --arg host "$HOST" \
        --arg port "${MYSQL_EXTERNAL_PORT}" \
        --arg last_seen "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg gtid "$(get_gtid_position)" \
        '{
            status: $status,
            role: $role,
            host: $host,
            port: $port,
            last_seen: $last_seen,
            gtid_position: $gtid,
            health: {
                connections: 0,
                uptime: 0
            }
        }')

    etcdctl put "$ETCD_NODES/$node_id" "$status_json" --lease=$LEASE_ID >/dev/null
}

# Get current node info
 get_node_info() {
     local node=$1
     etcdctl --insecure-transport --insecure-skip-tls-verify \
         get "$ETCD_NODES/$node" -w json | \
         jq -r '.kvs[0].value' | \
         base64 -d
 }

 get_node_hostname() {
   local node=$1
   # If node contains hostname:port format, extract hostname
   if [[ "$node" =~ ^([^:]+):([0-9]+)$ ]]; then
       echo "${BASH_REMATCH[1]}"
   else
       get_node_info "$node" | jq -r '.host // empty'
   fi
}

get_node_port() {
   local node=$1
   # If node contains hostname:port format, extract port
   if [[ "$node" =~ ^([^:]+):([0-9]+)$ ]]; then
       echo "${BASH_REMATCH[2]}"
   else
       get_node_info "$node" | jq -r '.port // empty'
   fi
}
