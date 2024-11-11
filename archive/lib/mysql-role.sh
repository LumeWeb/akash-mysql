#!/bin/bash

# Prevent multiple inclusion
[ -n "${MYSQL_ROLE_SOURCED}" ] && return 0
declare -g MYSQL_ROLE_SOURCED=1

source "${LIB_PATH}/core/logging.sh"
source "${LIB_PATH}/etcd-paths.sh"

# Track role change handlers
declare -A ROLE_CHANGE_HANDLERS

# Lock file for role changes
declare -gr ROLE_CHANGE_LOCK="/var/lock/mysql/role_change.lock"

# Register a handler to be called on role changes
register_role_change_handler() {
    local handler_name=$1
    local handler_function=$2
    ROLE_CHANGE_HANDLERS[$handler_name]=$handler_function
}

# Track role change timing and status
declare -g ROLE_CHANGE_START_TIME=""
declare -g ROLE_CHANGE_STATUS="none"
declare -g ROLE_CHANGE_LOCK_PATH="/var/lock/mysql/role_change"
declare -g ROLE_FENCE_KEY="/mysql/fence"
declare -g FAILBACK_ENABLED=1

# Verify cluster quorum
# Verify node is registered in etcd
verify_node_registered() {
    local node_id=$1
    
    if ! etcdctl get "$(get_node_path $node_id)" --print-value-only | grep -q "online"; then
        log_error "Node $node_id not registered or not online"
        return 1
    fi
    
    return 0
}

# Monitor replication lag
monitor_replication_lag() {
    local master_host=$1
    local master_port=$2
    local max_lag=30
    local check_interval=1
    local start_time=$(date +%s)
    local timeout=300
    
    while true; do
        local current_time=$(date +%s)
        if [ $((current_time - start_time)) -gt $timeout ]; then
            log_error "Replication lag monitoring timed out after ${timeout}s"
            return 1
        fi
        
        local lag=$(mysql -N -e "SHOW SLAVE STATUS\G" | grep "Seconds_Behind_Master:" | awk '{print $2}')
        if [ "$lag" = "NULL" ] || [ -z "$lag" ]; then
            log_error "Cannot determine replication lag"
            return 1
        fi
        
        if [ "$lag" -gt "$max_lag" ]; then
            log_warn "High replication lag detected: ${lag}s"
        elif [ "$lag" -eq 0 ]; then
            log_info "Replication caught up"
            return 0
        fi
        
        sleep $check_interval
    done
}

# Automatic failback to original master
handle_failback() {
    local old_master_host=$1
    local old_master_port=$2
    
    if [ "$FAILBACK_ENABLED" -ne 1 ]; then
        return 0
    fi
    
    # Wait for old master to come back
    local max_wait=3600
    local wait_interval=10
    local waited=0
    
    while [ $waited -lt $max_wait ]; do
        if nc -z "$old_master_host" "$old_master_port"; then
            log_info "Old master is back online"
            
            # Verify old master health
            if mysql -h "$old_master_host" -P "$old_master_port" -e "SELECT 1" &>/dev/null; then
                log_info "Old master is healthy, initiating failback"
                
                # Configure old master as slave first
                mysql -h "$old_master_host" -P "$old_master_port" -e "
                    STOP SLAVE;
                    RESET SLAVE ALL;
                    CHANGE MASTER TO
                        MASTER_HOST='$HOST',
                        MASTER_PORT=$PORT,
                        MASTER_USER='$MYSQL_REPL_USER',
                        MASTER_PASSWORD='$MYSQL_REPL_PASSWORD',
                        MASTER_AUTO_POSITION=1;
                    START SLAVE;
                "
                
                # Wait for replication to catch up
                if ! monitor_replication_lag "$HOST" "$PORT"; then
                    log_error "Failback aborted - replication not caught up"
                    return 1
                fi
                
                # Initiate role switch back
                log_info "Initiating failback to original master"
                if notify_role_change "slave" "master"; then
                    log_info "Failback completed successfully"
                    return 0
                else
                    log_error "Failback failed"
                    return 1
                fi
            fi
        fi
        
        sleep $wait_interval
        waited=$((waited + wait_interval))
    done
    
    log_warn "Failback timeout exceeded, staying with current topology"
    return 0
}

# Verify replication consistency
verify_replication_consistency() {
    local master_host=$1
    local master_port=$2
    
    # Compare checksums of key system tables
    local tables="mysql.user mysql.db mysql.tables_priv mysql.proxies_priv"
    for table in $tables; do
        local master_sum=$(mysql -h "$master_host" -P "$master_port" -N -e "CHECKSUM TABLE $table" | awk '{print $2}')
        local slave_sum=$(mysql -N -e "CHECKSUM TABLE $table" | awk '{print $2}')
        
        if [ "$master_sum" != "$slave_sum" ]; then
            log_error "Checksum mismatch for $table between master and slave"
            return 1
        fi
    done
    
    # Verify no temporary tables exist
    local temp_tables=$(mysql -N -e "SHOW STATUS LIKE 'Slave_open_temp_tables'" | awk '{print $2}')
    if [ "$temp_tables" -gt 0 ]; then
        log_error "Slave has $temp_tables open temporary tables"
        return 1
    fi
    
    # Verify replication positions match
    local master_pos=$(mysql -h "$master_host" -P "$master_port" -N -e "SHOW MASTER STATUS\G")
    local slave_pos=$(mysql -N -e "SHOW SLAVE STATUS\G")
    
    if ! echo "$slave_pos" | grep -q "Slave_SQL_Running: Yes"; then
        log_error "Slave SQL thread not running"
        return 1
    fi
    
    if ! echo "$slave_pos" | grep -q "Slave_IO_Running: Yes"; then
        log_error "Slave IO thread not running"
        return 1
    fi
    
    return 0
}

# Implement fencing mechanism
acquire_fence_token() {
    local node_id=$1
    local current_token=0
    
    # Get current fence token
    if ! current_token=$(etcdctl get "$ROLE_FENCE_KEY" --print-value-only); then
        current_token=0
    fi
    
    # Increment token
    local new_token=$((current_token + 1))
    
    # Try to set new token with compare-and-swap
    if ! etcdctl put "$ROLE_FENCE_KEY" "$new_token" --prev-value="$current_token"; then
        log_error "Failed to acquire fence token - possible split brain"
        return 1
    fi
    
    # Store token locally
    echo "$new_token" > "$ROLE_CHANGE_LOCK_PATH.token"
    return 0
}

# Validate role change with enhanced checks
validate_role_change() {
    local new_role=$1
    local current_role=$2
    local errors=0
    
    ROLE_CHANGE_START_TIME=$(date +%s)
    ROLE_CHANGE_STATUS="validating"

    # Don't allow invalid transitions
    case "$current_role:$new_role" in
        "slave:master")
            # Verify slave is caught up and healthy
            local slave_status
            slave_status=$(mysql -N -e "SHOW SLAVE STATUS\G")
            
            # Check replication health
            if ! echo "$slave_status" | grep -q "Seconds_Behind_Master: 0"; then
                log_error "Slave is lagging behind master"
                errors=$((errors + 1))
            fi
            
            if ! echo "$slave_status" | grep -q "Slave_IO_Running: Yes"; then
                log_error "Slave IO thread not running"
                errors=$((errors + 1))
            fi
            
            if ! echo "$slave_status" | grep -q "Slave_SQL_Running: Yes"; then
                log_error "Slave SQL thread not running" 
                errors=$((errors + 1))
            fi
            
            # Check for replication errors
            local last_error=$(echo "$slave_status" | grep "Last_Error:" | cut -d: -f2-)
            if [ -n "$last_error" ]; then
                log_error "Replication error: $last_error"
                errors=$((errors + 1))
            fi

            # Verify no temporary tables on slave
            local temp_tables=$(mysql -N -e "SHOW STATUS LIKE 'Slave_open_temp_tables'" | awk '{print $2}')
            if [ "$temp_tables" -gt 0 ]; then
                log_error "Slave has $temp_tables open temporary tables"
                errors=$((errors + 1))
            fi

            # Enhanced replication validation
            local Exec_Master_Log_Pos=$(mysql -N -e "SHOW SLAVE STATUS\G" | grep "Exec_Master_Log_Pos:" | awk '{print $2}')
            local Read_Master_Log_Pos=$(mysql -N -e "SHOW SLAVE STATUS\G" | grep "Read_Master_Log_Pos:" | awk '{print $2}')
            
            if [ "$Exec_Master_Log_Pos" != "$Read_Master_Log_Pos" ]; then
                log_error "Replication positions not in sync: Exec=$Exec_Master_Log_Pos Read=$Read_Master_Log_Pos"
                errors=$((errors + 1))
            fi

            # Verify cluster quorum first
            if ! verify_cluster_quorum; then
                log_error "Cannot proceed without cluster quorum"
                errors=$((errors + 1))
            fi

            # Enhanced split-brain prevention
            if ! timeout 30 verify_old_master_down; then
                log_error "Old master may still be active - split-brain prevention"
                errors=$((errors + 1))
            fi
            
            # Verify replication consistency
            local old_master_host=$(echo "$MASTER_INFO" | jq -r .host)
            local old_master_port=$(echo "$MASTER_INFO" | jq -r .port)
            
            # Monitor replication lag during transition
            if ! monitor_replication_lag "$old_master_host" "$old_master_port"; then
                log_error "Replication lag too high for safe transition"
                errors=$((errors + 1))
            fi
            
            if ! verify_replication_consistency "$old_master_host" "$old_master_port"; then
                log_error "Replication consistency check failed"
                errors=$((errors + 1))
            fi
            
            # Acquire fence token
            if ! acquire_fence_token "$NODE_ID"; then
                log_error "Failed to acquire fence token"
                errors=$((errors + 1))
            fi

            # Verify no data drift
            local checksum_master=$(mysql -N -e "CHECKSUM TABLE mysql.user" | awk '{print $2}')
            local checksum_slave=$(mysql -h "$old_master_host" -P "$old_master_port" -N -e "CHECKSUM TABLE mysql.user" | awk '{print $2}')
            
            if [ "$checksum_master" != "$checksum_slave" ]; then
                log_error "Data drift detected between master and slave"
                errors=$((errors + 1))
            fi

            [ $errors -eq 0 ] && return 0 || return 1
            ;;
        "master:slave")
            # Verify no active writes
            local active_writes
            active_writes=$(mysql -N -e "SELECT COUNT(*) FROM information_schema.processlist WHERE command = 'Query' AND info NOT LIKE 'SELECT%'")
            if [ "$active_writes" -eq 0 ]; then
                return 0
            fi
            log_error "Active writes detected during master->slave transition"
            return 1
            ;;
        *) return 0 ;;
    esac
}

# Rollback role change
rollback_role_change() {
    local role=$1
    local old_role=$2
    
    log_warn "Rolling back role change from $old_role to $role"
    
    case "$old_role" in
        "master")
            mysql -e "
                SET GLOBAL read_only = OFF;
                SET GLOBAL super_read_only = OFF;
                FLUSH TABLES WITH READ LOCK;
                FLUSH LOGS;
                UNLOCK TABLES;
            "
            ;;
        "slave")
            mysql -e "
                SET GLOBAL super_read_only = ON;
                SET GLOBAL read_only = ON;
            "
            ;;
    esac
    
    ROLE_CHANGE_STATUS="rolled_back"
    return 0
}

# Notify handlers of role change with transaction coordination
notify_role_change() {
    local new_role=$1
    local old_role=$2
    
    ROLE_CHANGE_STATUS="in_progress"
    
    # Acquire role change lock
    (
        if ! flock -w 30 9; then
            log_error "Failed to acquire role change lock"
            return 1
        fi

        # Validate role change
        if ! validate_role_change "$new_role" "$old_role"; then
            log_error "Invalid role transition: $old_role -> $new_role"
            return 1
        fi

        # Stop replication if changing from slave
        if [ "$old_role" = "slave" ]; then
            mysql -e "STOP SLAVE; RESET SLAVE ALL;"
        fi

        # Clean up replication state if changing from master
        if [ "$old_role" = "master" ]; then
            mysql -e "RESET MASTER;"
        fi

        # Notify all handlers
        for handler_name in "${!ROLE_CHANGE_HANDLERS[@]}"; do
            local handler_function=${ROLE_CHANGE_HANDLERS[$handler_name]}
            log_info "Notifying handler $handler_name of role change to $new_role"
            if ! $handler_function "$new_role"; then
                log_error "Handler $handler_name failed during role change"
                return 1
            fi
        done

        # Enhanced transaction coordination
        mysql -e "
            SET GLOBAL TRANSACTION ISOLATION LEVEL SERIALIZABLE;
            SET innodb_lock_wait_timeout = 180;
            SET GLOBAL sync_binlog = 1;
            SET GLOBAL innodb_flush_log_at_trx_commit = 1;
            START TRANSACTION WITH CONSISTENT SNAPSHOT;
        "
        
        # Set role change monitoring
        mysql -e "
            SET GLOBAL slow_query_log = 1;
            SET GLOBAL long_query_time = 1;
            SET GLOBAL log_queries_not_using_indexes = 1;
            SET GLOBAL log_slow_slave_statements = 1;
        "
        
        local role_change_success=1
        
        # Configure new role with enhanced error handling and rollback
        case "$new_role" in
            "master")
                local role_errors=0
                
                # Stop slave threads first if transitioning from slave
                if [ "$old_role" = "slave" ]; then
                    mysql -e "STOP SLAVE" || role_errors=$((role_errors + 1))
                    mysql -e "RESET SLAVE ALL" || role_errors=$((role_errors + 1))
                fi
                
                # Configure master settings atomically
                mysql -e "
                    SET GLOBAL read_only = OFF;
                    SET GLOBAL super_read_only = OFF;
                    FLUSH TABLES WITH READ LOCK;
                    FLUSH LOGS;
                    UNLOCK TABLES;
                " || role_errors=$((role_errors + 1))
                
                # Verify master status
                local master_status
                master_status=$(mysql -N -e "SHOW MASTER STATUS\G")
                if [ -z "$master_status" ]; then
                    log_error "Failed to initialize master status"
                    role_errors=$((role_errors + 1))
                fi
                
                if [ $role_errors -gt 0 ]; then
                    log_error "Failed to configure master role ($role_errors errors)"
                    mysql -e "ROLLBACK"
                    rollback_role_change "$new_role" "$old_role"
                    return 1
                fi
                
                # Commit transaction if successful
                mysql -e "COMMIT"
                role_change_success=0
                ;;
            "slave") 
                mysql -e "
                    FLUSH TABLES WITH READ LOCK;
                    SET GLOBAL super_read_only = ON;
                    SET GLOBAL read_only = ON;
                    UNLOCK TABLES;
                "
                ;;
        esac

        # Calculate role change duration
        local duration=$(($(date +%s) - ROLE_CHANGE_START_TIME))
        log_info "Role change complete: $old_role -> $new_role (duration: ${duration}s)"
        
        if [ $role_change_success -eq 0 ]; then
            ROLE_CHANGE_STATUS="completed"
            return 0
        else
            ROLE_CHANGE_STATUS="failed"
            return 1
        fi
    ) 9>"$ROLE_CHANGE_LOCK"
}

# Determine initial role for node
determine_role() {
    local ROLE=""
    local SERVER_ID=""
    local STARTUP_LEASE=""

    log_info "Attempting to acquire startup lock..."
    STARTUP_LEASE=$(acquire_lock "$ETCD_LOCK_STARTUP" "$NODE_ID" 30)

    if [ $? -eq 0 ]; then
        log_info "Acquired startup lock. Checking cluster state..."

        # Enhanced etcd master check with proper error handling and retries
        local MASTER_INFO
        if ! MASTER_INFO=$(etcd_retry etcdctl get "$ETCD_TOPOLOGY_MASTER" --print-value-only); then
            log_error "Failed to query etcd for master info"
            return 1
        fi
    
        # Validate master info format
        if [ -n "$MASTER_INFO" ] && ! echo "$MASTER_INFO" | jq -e . >/dev/null 2>&1; then
            log_error "Invalid master info format in etcd"
            return 1
        fi

        if [ -z "$MASTER_INFO" ]; then
            log_info "No master found. Evaluating master eligibility..."

            # Check for existing nodes that might be more eligible
            NODES=$(etcdctl get "$(get_nodes_prefix)" --prefix --keys-only)
            if [ -z "$NODES" ] || [ "$NODE_ID" = "$(echo "$NODES" | head -n1)" ]; then
                log_info "Taking master role..."
                ROLE="master"
                SERVER_ID=1
            else
                log_info "Other nodes exist. Taking slave role..."
                ROLE="slave"
                SERVER_ID=2
            fi
        else
            log_info "Master exists. Taking slave role..."
            ROLE="slave"
            SERVER_ID=$(etcdctl get "$(get_node_server_id_path $NODE_ID)" --print-value-only 2>/dev/null || echo $RANDOM)
        fi

        # Store our role and server ID in etcd atomically
        etcd_retry etcdctl txn --interactive << EOF
compares:
success_requests:
  - put: "$(get_node_role_path $NODE_ID)"
    value: "$ROLE"
  - put: "$(get_node_server_id_path $NODE_ID)"
    value: "$SERVER_ID"
failure_requests:
EOF

        release_lock "$ETCD_LOCK_STARTUP" "$STARTUP_LEASE"

        echo "$ROLE:$SERVER_ID"
        return 0
    fi

    log_info "Waiting for startup lock to be released..."
    local max_attempts=30
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        ROLE=$(etcdctl get "$(get_node_role_path $NODE_ID)" --print-value-only 2>/dev/null)
        if [ -n "$ROLE" ]; then
            SERVER_ID=$(etcdctl get "$(get_node_server_id_path $NODE_ID)" --print-value-only)
            echo "$ROLE:$SERVER_ID"
            return 0
        fi
        log_info "Waiting for role assignment (attempt $attempt/$max_attempts)..."
        sleep 5
        attempt=$((attempt + 1))
    done

    log_error "Failed to get role assignment after $max_attempts attempts"
    return 1
}
