#!/bin/bash

# Prevent multiple inclusion
[ -n "${MYSQL_INIT_CHECKS_SOURCED}" ] && return 0
declare -g MYSQL_INIT_CHECKS_SOURCED=1

source "${LIB_PATH}/core/logging.sh"
source "${LIB_PATH}/core/constants.sh"

# Consolidated function to check MySQL initialization state
check_mysql_initialized() {
    local data_dir="${1:-${DATA_DIR}}"
    
    # System databases/files we expect
    local system_dbs=("mysql" "performance_schema" "sys" "information_schema")
    local system_files=("ibdata1" "ib_buffer_pool" "ibtmp1" "auto.cnf" "mysqld-auto.cnf" 
                       "private_key.pem" "public_key.pem")
    
    # First check for user databases
    for entry in "$data_dir"/*; do
        local basename=$(basename "$entry")
        
        # Skip if not a directory
        [ ! -d "$entry" ] && continue
        
        # Skip system databases
        [[ " ${system_dbs[@]} " =~ " ${basename} " ]] && continue
        
        # Skip temp/system directories
        [[ "$basename" == "#"* ]] && continue
        [[ "$basename" == "undo_"* ]] && continue
        [[ "$basename" == "#innodb_"* ]] && continue
        
        # If we get here, it's a user database - consider MySQL initialized
        log_info "Found user database: $basename"
        return 0
    done
    
    # If no user databases found, check for basic MySQL initialization
    if [ ! -d "${data_dir}/mysql" ] || [ ! "$(ls -A ${data_dir}/mysql 2>/dev/null)" ]; then
        return 1  # Not initialized or empty
    fi
    
    # Then check for required files
    if [ ! -f "${data_dir}/ibdata1" ] || \
       [ ! -f "${data_dir}/auto.cnf" ] || \
       [ ! -f "${data_dir}/mysql/user.ibd" ]; then
        return 1  # Missing required files
    fi
    
    return 0  # Initialized with system databases only
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
