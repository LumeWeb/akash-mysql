#!/bin/bash
set -e

source "${LIB_PATH}/mysql-common.sh"
source "${LIB_PATH}/mysql-startup.sh"
source "${LIB_PATH}/mysql-config.sh"

# Source cleanup functions
source "${LIB_PATH}/core/logging.sh"

log_info "Starting MySQL in standalone mode..."

# Set role for this instance
ROLE="standalone"

# Start MySQL in standalone mode
if ! start_mysql "$ROLE" 1; then
    log_error "Failed to start MySQL server"
    exit 1
fi

log_info "MySQL is running in standalone mode"
log_info "Port: ${PORT}"

# Wait for MySQL process
wait $MYSQL_PID || {
    rc=$?
    log_error "MySQL process exited with code $rc"
    exit $rc
}
