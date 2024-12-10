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

# Check if recovery is needed
if detect_mysql_state; then
    state_code=$?
    case $state_code in
        0) log_info "Fresh installation needed" ;;
        1) log_info "Valid installation detected" ;;
        2) 
            log_warn "Recovery needed - attempting repair"
            if ! perform_recovery 1; then
                log_error "Recovery failed"
                exit 1
            fi
            ;;
        *)
            log_error "Unknown database state"
            exit 1
            ;;
    esac
fi

# Start MySQL in standalone mode (server_id=1 for standalone)
if ! start_mysql "$ROLE" 1 "" "${MYSQL_ARGS[@]}"; then
    log_error "Failed to start MySQL server"
    exit 1
fi

log_info "MySQL is running in standalone mode"
log_info "Port: ${MYSQL_PORT}"


# Start monitoring backup status
monitor_backup_status &
BACKUP_MONITOR_PID=$!

# Wait for MySQL process
wait $MYSQL_PID || {
    rc=$?
    log_error "MySQL process exited with code $rc"
    exit $rc
}
