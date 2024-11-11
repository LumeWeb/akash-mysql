#!/bin/bash

# Prevent multiple inclusion
[ -n "${MYSQL_MAINTENANCE_SOURCED}" ] && return 0
declare -g MYSQL_MAINTENANCE_SOURCED=1

# Core dependencies only
source "${LIB_PATH}/core/logging.sh"
source "${LIB_PATH}/core/constants.sh"

# Initialize maintenance functions
init_maintenance() {
    # Start monitoring and maintenance
    source "${LIB_PATH}/features/monitoring/table_monitor.sh"
    source "${LIB_PATH}/features/maintenance/table_maintenance.sh"
}
