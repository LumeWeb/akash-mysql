#!/bin/bash
set -e

source "${LIB_PATH}/etcd-paths.sh"
source "${LIB_PATH}/etcd.sh"
source "${LIB_PATH}/core/logging.sh"
source "${LIB_PATH}/core/health.sh"
source "${LIB_PATH}/mysql-common.sh"
source "${LIB_PATH}/mysql-startup.sh"
source "${LIB_PATH}/mysql-config.sh"
source "${LIB_PATH}/mysql-role.sh"
source "${LIB_PATH}/mysql-recovery.sh"

# Source cleanup functions
source "${LIB_PATH}/cleanup-functions.sh"
trap 'err=$?; cleanup; exit $err' SIGTERM SIGINT EXIT

# Validate required credentials for cluster mode
if [ -z "${MYSQL_ROOT_PASSWORD}" ]; then
    log_error "MYSQL_ROOT_PASSWORD must be set in cluster mode"
    exit 1
fi

if [ -z "${MYSQL_REPL_USERNAME}" ] || [ -z "${MYSQL_REPL_PASSWORD}" ]; then
    log_error "MYSQL_REPL_USERNAME and MYSQL_REPL_PASSWORD must be set in cluster mode"
    exit 1
fi

log_info "Starting MySQL in cluster mode..."
log_info "Node ID: $NODE_ID"

# Wait for etcd
if ! wait_for_etcd; then
    log_error "Failed to connect to etcd"
    exit 1
fi

# Always start as slave initially
initial_role="slave"
CURRENT_ROLE="$initial_role"
export CURRENT_ROLE
log_info "Starting MySQL with initial slave role: $CURRENT_ROLE"

# Check MySQL state
detect_mysql_state
state_code=$?

case $state_code in
    0) log_info "Fresh installation needed" ;;
    1) log_info "Valid installation detected" ;;
    2) 
        log_warn "Recovery needed - attempting repair"
        if ! perform_recovery 0; then
            log_error "Recovery failed"
            exit 1
        fi
        ;;
    *)
        log_error "Unknown database state"
        exit 1
        ;;
esac

# Start MySQL server initialization
log_info "Starting MySQL server initialization..."
if ! start_mysql "$initial_role" "$SERVER_ID" "$HOST" "$@"; then
    log_error "Failed to start MySQL server"
    error_json=$(jq -n \
        '{
            status: "failed",
            error: "startup_failed"
        }')
    etcdctl put "$ETCD_NODES/$NODE_ID" "$error_json" >/dev/null
    exit 1
fi

# Wait for MySQL to be fully ready
log_info "Waiting for MySQL to be fully ready..."
if ! wait_for_mysql "${MYSQL_START_TIMEOUT:-60}" "${MYSQL_ROOT_PASSWORD}"; then
    log_error "MySQL failed to become ready"
    exit 1
fi

# Verify GTID configuration
log_info "Verifying GTID configuration..."
if ! verify_gtid_configuration; then
    log_error "GTID configuration verification failed"
    exit 1
fi

log_info "MySQL is fully initialized and running"

# Register node in cluster
log_info "Registering node in cluster..."
if ! register_node; then
    log_error "Failed to register node"
    exit 1
fi

# Only start role monitoring after MySQL is fully ready
log_info "Starting role monitoring..."
watch_role_changes &
ROLE_WATCH_PID=$!

# Start health updater now that MySQL is fully configured
log_info "Starting health updater..."
if ! start_health_updater; then
    log_error "Failed to start health updater"
    exit 1
fi
log_info "Started health updater successfully"

# Wait for MySQL process
wait $MYSQL_PID || {
    rc=$?
    log_error "MySQL process exited with code $rc"
    error_json=$(jq -n \
        --arg exit_code "process_exit_$rc" \
        '{
            status: "failed",
            error: $exit_code
        }')
    etcdctl put "$ETCD_NODES/$NODE_ID" "$error_json" >/dev/null

    # Kill role monitoring before exit
    if [ -n "$ROLE_WATCH_PID" ]; then
        kill $ROLE_WATCH_PID 2>/dev/null || true
    fi
    exit $rc
}

# Ensure state directories exist
ensure_state_dirs() {
    mkdir -p "${STATE_DIR}" "${BACKUP_STATE_DIR}" "${BACKUP_CONFIG_DIR}"
    chown -R mysql:mysql "${STATE_DIR}"
    chmod 750 "${STATE_DIR}"
}

# Call during startup
ensure_state_dirs
