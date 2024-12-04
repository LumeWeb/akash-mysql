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

# Start MySQL in standalone mode
if ! start_mysql "$ROLE" 1; then
    log_error "Failed to start MySQL server"
    exit 1
fi

log_info "MySQL is running in standalone mode"
log_info "Port: ${PORT}"

# Initialize backup system explicitly for standalone mode if enabled
if [ "${BACKUP_ENABLED}" = "true" ]; then
    if ! init_backup_env; then
        log_warn "Failed to initialize backup system"
    else
        # Start backup scheduler in standalone mode
        if ! start_backup_scheduler; then
            log_warn "Failed to start backup scheduler"
        fi
    fi
else
    log_info "Backup system disabled via BACKUP_ENABLED environment variable"
fi

# Start monitoring backup status
monitor_backup_status &
BACKUP_MONITOR_PID=$!

# Wait for MySQL process
wait $MYSQL_PID || {
    rc=$?
    log_error "MySQL process exited with code $rc"
    exit $rc
}
