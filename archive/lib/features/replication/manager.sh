#!/bin/bash

# Prevent multiple inclusion
[ -n "${REPLICATION_MANAGER_SOURCED}" ] && return 0
declare -g REPLICATION_MANAGER_SOURCED=1

# Core dependencies only
source "${LIB_PATH}/core/logging.sh"
source "${LIB_PATH}/core/constants.sh"
source "${LIB_PATH}/core/fd.sh"
source "${LIB_PATH}/core/mysql.sh"
source "${LIB_PATH}/core/locks.sh"

# Replication management functions
