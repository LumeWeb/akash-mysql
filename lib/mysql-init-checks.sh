#!/bin/bash

# Prevent multiple inclusion
[ -n "${MYSQL_INIT_CHECKS_SOURCED}" ] && return 0
declare -g MYSQL_INIT_CHECKS_SOURCED=1

source "${LIB_PATH}/core/logging.sh"
source "${LIB_PATH}/core/constants.sh"

# Consolidated function to check MySQL initialization state
check_mysql_initialized() {
    local data_dir="${1:-${DATA_DIR}}"
    
    # First check if mysql dir exists and is non-empty
    if [ ! -d "${data_dir}/mysql" ] || [ ! "$(ls -A ${data_dir}/mysql 2>/dev/null)" ]; then
        return 1  # Not initialized or empty
    fi
    
    # Then check for required files
    if [ ! -f "${data_dir}/ibdata1" ] || \
       [ ! -f "${data_dir}/auto.cnf" ] || \
       [ ! -f "${data_dir}/mysql/user.ibd" ]; then
        return 1  # Missing required files
    fi
    
    return 0  # Initialized
}

# Check for corruption markers
check_mysql_corruption() {
    local data_dir="${1:-${DATA_DIR}}"
    local log_dir="${2:-${LOG_DIR}}"
    
    # Check for corruption indicators
    if [ -f "${data_dir}/ib_logfile0" ] || [ -f "${data_dir}/ib_logfile1" ]; then
        if grep -q "corrupt\|Invalid\|error\|Cannot create redo log\|Table .* is marked as crashed\|InnoDB: Database page corruption" \
            "${log_dir}/error.log" 2>/dev/null; then
            return 0  # Corruption found
        fi
    fi
    
    return 1  # No corruption
}
