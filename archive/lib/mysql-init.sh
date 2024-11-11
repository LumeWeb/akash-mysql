#!/bin/bash

# Prevent multiple inclusion
[ -n "${MYSQL_INIT_SOURCED}" ] && return 0
declare -g MYSQL_INIT_SOURCED=1

source "${LIB_PATH}/core/logging.sh"
source "${LIB_PATH}/core/constants.sh"
source "${LIB_PATH}/mysql-env.sh"

# Source core setup functions
source "${LIB_PATH}/core/setup.sh"

# Source core setup functions
source "${LIB_PATH}/core/setup.sh"

# Initialize FD tracking
source "${LIB_PATH}/core/fd.sh"
init_fd_tracker

# Initialize temp cleanup
source "${LIB_PATH}/mysql-temp-cleanup.sh"
init_temp_cleanup
