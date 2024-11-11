#!/bin/bash
set -e

# Prevent multiple inclusion
[ -n "${MYSQL_STARTUP_SOURCED}" ] && return 0
declare -g MYSQL_STARTUP_SOURCED=1

source "${LIB_PATH}/core/logging.sh"
source "${LIB_PATH}/core/constants.sh"
source "${LIB_PATH}/mysql-role.sh"
source "${LIB_PATH}/replication-functions.sh"

# Main execution
main() {
    # Source cleanup functions and set up handlers
    source "${LIB_PATH}/cleanup-functions.sh"
    trap cleanup SIGTERM SIGINT EXIT

    log_info "Starting MySQL in cluster mode..."
    log_info "Node ID: $NODE_ID"

    # Wait for etcd before proceeding
    if ! wait_for_etcd; then
        log_error "Failed to connect to etcd"
        exit 1
    fi

    # Determine role
    ROLE_INFO=$(determine_role)
    if [ $? -ne 0 ]; then
        log_error "Failed to determine role"
        exit 1
    fi

    ROLE=$(echo "$ROLE_INFO" | cut -d: -f1)
    SERVER_ID=$(echo "$ROLE_INFO" | cut -d: -f2)

    # Start MySQL with appropriate role and enhanced monitoring
    if ! start_mysql "$ROLE" "$SERVER_ID" "$@"; then
        log_error "Failed to start MySQL"
        exit 1
    fi
    
    # Initialize monitoring systems
    source "${LIB_PATH}/mysql-connection-pool.sh"
    source "${LIB_PATH}/mysql-query-analyzer.sh"
    #init_connection_pool
    #init_query_analyzer

    log_info "Registering node in cluster..."
    register_node

    # Start role monitoring
    log_info "Starting role monitor..."
    watch_role_changes &
    ROLE_WATCH_PID=$!

    # If initial master, register as master
    if [ "$ROLE" = "master" ]; then
        etcdctl put "$ETCD_TOPOLOGY_MASTER" "{\"id\": \"$NODE_ID\", \"host\": \"$NODE_HOST\", \"port\": $PORT}"
    fi

    log_info "Node startup complete. Role: $ROLE"
    log_info "Waiting for MySQL process..."

    # Wait for MySQL process
    wait $MYSQL_PID
}

main "$@"
