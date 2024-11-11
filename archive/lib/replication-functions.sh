#!/bin/bash

source "${LIB_PATH}/etcd-paths.sh"

# Switch node to master role
switch_to_master() {
    log_info "Switching to master role..."

    mysql -u root -p"$MYSQL_ROOT_PASSWORD" << EOF
STOP SLAVE;
RESET SLAVE ALL;
SET GLOBAL read_only = OFF;
SET GLOBAL super_read_only = OFF;
EOF

    # Configure replication user
    mysql -u root -p"$MYSQL_ROOT_PASSWORD" << EOF
CREATE USER IF NOT EXISTS '$MYSQL_REPL_USER'@'%' IDENTIFIED BY '$MYSQL_REPL_PASSWORD';
GRANT REPLICATION SLAVE ON *.* TO '$MYSQL_REPL_USER'@'%';
FLUSH PRIVILEGES;
EOF

    return $?
}

# Switch node to slave role
switch_to_slave() {
    local master_host=$1
    local master_port=$2

    log_info "Switching to slave role. Master: $master_host:$master_port"

    mysql -u root -p"$MYSQL_ROOT_PASSWORD" << EOF
STOP SLAVE;
CHANGE MASTER TO
    MASTER_HOST='$master_host',
    MASTER_PORT=$master_port,
    MASTER_USER='$MYSQL_REPL_USER',
    MASTER_PASSWORD='$MYSQL_REPL_PASSWORD',
    MASTER_AUTO_POSITION=1;
SET GLOBAL read_only = ON;
SET GLOBAL super_read_only = ON;
START SLAVE;
EOF

    return $?
}

# Attempt to take over as master
attempt_master_takeover() {
    log_info "Attempting master takeover..."

    # Try to acquire master lock
    MASTER_LEASE=$(acquire_lock "$ETCD_LOCK_MASTER" "$NODE_ID" 10)

    if [ $? -eq 0 ]; then
        echo "Acquired master lock. Verifying old master status..."

        # Verify old master is actually gone
        OLD_MASTER_INFO=$(etcdctl get "$ETCD_TOPOLOGY_MASTER" --print-value-only)
        if [ -n "$OLD_MASTER_INFO" ]; then
            OLD_MASTER_ID=$(echo $OLD_MASTER_INFO | jq -r .id)
            OLD_MASTER_STATUS=$(etcdctl get "$(get_node_path $OLD_MASTER_ID)" --print-value-only 2>/dev/null)

            if [ -n "$OLD_MASTER_STATUS" ]; then
                log_warn "Old master still active. Abandoning takeover."
                release_lock "$ETCD_LOCK_MASTER" "$MASTER_LEASE"
                return 1
            fi
        fi

        log_info "Old master confirmed down. Proceeding with takeover..."

        # Perform master switch
        if ! switch_to_master; then
            log_error "Failed to switch to master role"
            release_lock "$ETCD_LOCK_MASTER" "$MASTER_LEASE"
            return 1
        fi

        CURRENT_ROLE="master"
        etcd_retry etcdctl put "$ETCD_TOPOLOGY_MASTER" "{\"id\": \"$NODE_ID\", \"host\": \"$NODE_HOST\", \"port\": $PORT}"
        etcd_retry etcdctl put "$(get_node_role_path $NODE_ID)" "master"

        release_lock "$ETCD_LOCK_MASTER" "$MASTER_LEASE"
        log_info "Master takeover completed successfully"
        return 0
    fi

    log_error "Failed to acquire master lock"
    return 1
}

# Check slave status
check_slave_status() {
    local slave_status
    slave_status=$(mysql -u root -p"$MYSQL_ROOT_PASSWORD" -e "SHOW SLAVE STATUS\G")

    if echo "$slave_status" | grep -q "Slave_IO_Running: Yes" && \
       echo "$slave_status" | grep -q "Slave_SQL_Running: Yes"; then
        return 0
    fi
    return 1
}

# Monitor role changes
watch_role_changes() {
    local failed_master_checks=0

    while true; do
        ROLE=$(etcdctl get "$(get_node_role_path $NODE_ID)" --print-value-only 2>/dev/null)

        if [ -z "$ROLE" ]; then
            echo "Waiting for role assignment..."
            sleep 5
            continue
        fi

        case $ROLE in
            "master")
                if [ "$CURRENT_ROLE" != "master" ]; then
                    echo "Role change detected: slave -> master"
                    if switch_to_master; then
                        CURRENT_ROLE="master"
                        etcdctl put "$ETCD_TOPOLOGY_MASTER" "{\"id\": \"$NODE_ID\", \"host\": \"$NODE_HOST\", \"port\": $PORT}"
                    else
                        echo "Failed to switch to master role"
                    fi
                fi
                ;;
            "slave")
                if [ "$CURRENT_ROLE" != "slave" ]; then
                    while true; do
                        MASTER_INFO=$(etcdctl get "$ETCD_TOPOLOGY_MASTER" --print-value-only)

                        if [ -z "$MASTER_INFO" ]; then
                            failed_master_checks=$((failed_master_checks + 1))

                            if [ $failed_master_checks -ge 3 ]; then
                                echo "Master appears to be down. Attempting takeover..."
                                if attempt_master_takeover; then
                                    failed_master_checks=0
                                    break
                                fi
                            fi

                            sleep 5
                            continue
                        fi

                        failed_master_checks=0
                        MASTER_HOST=$(echo $MASTER_INFO | jq -r .host)
                        MASTER_PORT=$(echo $MASTER_INFO | jq -r .port)

                        if switch_to_slave $MASTER_HOST $MASTER_PORT; then
                            CURRENT_ROLE="slave"
                            # Verify replication is working
                            sleep 5
                            if ! check_slave_status; then
                                echo "Slave setup failed. Replication is not running."
                                CURRENT_ROLE=""
                                continue
                            fi
                        else
                            echo "Failed to switch to slave role"
                            CURRENT_ROLE=""
                            continue
                        fi
                        break
                    done
                elif [ "$CURRENT_ROLE" = "slave" ]; then
                    # Periodic slave health check
                    if ! check_slave_status; then
                        echo "Slave replication issue detected. Attempting to repair..."
                        CURRENT_ROLE=""
                    fi
                fi
                ;;
        esac

        sleep 5
    done
}
