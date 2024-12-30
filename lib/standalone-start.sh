#!/bin/bash
set -e

source "${LIB_PATH}/mysql-common.sh"
source "${LIB_PATH}/mysql-startup.sh"
source "${LIB_PATH}/mysql-config.sh"
source "${LIB_PATH}/mysql-recovery.sh"

# Source cleanup functions
source "${LIB_PATH}/core/logging.sh"
source "${LIB_PATH}/mysql-backup.sh"
source "${LIB_PATH}/mysql-backup-scheduler.sh"

log_info "Starting MySQL in standalone mode..."

# Set role for this instance
CURRENT_ROLE="standalone"
ROLE="standalone"

# Ensure state directories exist
ensure_state_dirs() {
    mkdir -p "${STATE_DIR}" "${BACKUP_STATE_DIR}" "${BACKUP_CONFIG_DIR}"
    chown -R mysql:mysql "${STATE_DIR}"
    chmod 750 "${STATE_DIR}"
}

# Call during startup
ensure_state_dirs

# Check if recovery is needed
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

# Start MySQL in standalone mode (server_id=1 for standalone)
if ! start_mysql "$ROLE" 1 "$HOST" "${MYSQL_ARGS[@]}"; then
    log_error "Failed to start MySQL server"
    exit 1
fi


# Start MySQL exporter (internal only)
export MYSQLD_EXPORTER_PASSWORD="${MYSQL_ROOT_PASSWORD}"
mysqld_exporter \
 --web.listen-address=":9104" \
 --config.my-cnf="${CONFIG_DIR}/exporter.cnf" \
 --tls.insecure-skip-verify &

 # Start Akash metrics registrar
 akash-metrics-registrar \
     --target-host="localhost" \
     --target-port=9104 \
     --target-path="/metrics" \
     --metrics-port=9090 \
     --exporter-type="mysql" \
     --metrics-password="${METRICS_PASSWORD}" &

log_info "MySQL is running in standalone mode"
log_info "Port: ${MYSQL_PORT}"

# Start backup monitoring if enabled
if [ "${BACKUP_ENABLED}" = "true" ]; then
    # Create monitor directory if it doesn't exist
    mkdir -p "${MONITOR_STATE_DIR}"
    
    # Start backup monitoring
    monitor_log "${BACKUP_LOG}" "${BACKUP_MONITOR_PID}"
fi

# Wait for MySQL process
wait $MYSQL_PID || {
    rc=$?
    log_error "MySQL process exited with code $rc"
    exit $rc
}
