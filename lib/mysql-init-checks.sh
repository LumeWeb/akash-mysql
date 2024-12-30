#!/bin/bash

# Prevent multiple inclusion
[ -n "${MYSQL_INIT_CHECKS_SOURCED}" ] && return 0
declare -g MYSQL_INIT_CHECKS_SOURCED=1

source "${LIB_PATH}/core/logging.sh"
source "${LIB_PATH}/core/constants.sh"

# Detect MySQL installation state and handle recovery if needed
# Returns:
# 0 = Fresh Install Needed
# 1 = Valid Installation
# 2 = Recovery Failed
# 3 = Error State
detect_mysql_state() {
    local data_dir="${1:-${DATA_DIR}}"
    
    log_info "Detecting MySQL installation state..."
    
    # 1. Check Lock Files
    if [ -f "${RUN_DIR}/init.lock" ]; then
        log_info "MySQL initialization in progress"
        return 0
    fi

    # 2. Check Critical System Files
    local critical_files=("ibdata1" "auto.cnf")
    local missing_critical=0
    
    for file in "${critical_files[@]}"; do
        if [ ! -f "${data_dir}/${file}" ]; then
            log_info "Missing critical file: ${file}"
            missing_critical=1
            break
        fi
    done

    if [ $missing_critical -eq 1 ]; then
        log_info "Missing critical system files - fresh install needed"
        return 0
    fi

    # Validate System Directories
    local system_dbs=("mysql" "performance_schema" "sys")
    local missing_sysdb=0
    
    for db in "${system_dbs[@]}"; do
        if [ ! -d "${data_dir}/${db}" ]; then
            log_info "Missing system database: ${db}"
            missing_sysdb=1
            break
        fi
    done

    if [ $missing_sysdb -eq 1 ]; then
        log_info "Missing system databases - fresh install needed"
        return 0
    fi

    # 3. Check for Corruption
    if [ -f "${LOG_DIR}/error.log" ]; then
        if grep -q "corrupt\|Invalid\|error\|Cannot create redo log\|Table .* is marked as crashed\|InnoDB: Database page corruption" \
            "${LOG_DIR}/error.log"; then
            log_warn "Found corruption markers in error log"
            return 2
        fi
    fi

    # Check for crash recovery files
    if [ -f "${data_dir}/ib_logfile0" ] || \
       [ -f "${data_dir}/ib_logfile1" ] || \
       [ -f "${data_dir}/aria_log_control" ] || \
       [ -f "${data_dir}/#innodb_temp/temp_*.ibt" ]; then
        log_warn "Found crash recovery files - attempting recovery"
        if ! perform_recovery 0; then
            log_error "Recovery failed"
            return 2
        fi
        # After successful recovery, treat as valid installation
        return 1
    fi

    # 4. Analyze Installation Type
    local has_user_db=0
    for entry in "$data_dir"/*; do
        local basename=$(basename "$entry")
        
        # Skip if not a directory
        [ ! -d "$entry" ] && continue
        
        # Skip system databases and temp dirs
        [[ " ${system_dbs[@]} " =~ " ${basename} " ]] && continue
        [[ "$basename" == "#"* ]] && continue
        [[ "$basename" == "undo_"* ]] && continue
        [[ "$basename" == "performance_schema" ]] && continue
        
        # Found a user database
        log_info "Found user database: $basename"
        has_user_db=1
        break
    done

    if [ $has_user_db -eq 1 ]; then
        log_info "Valid installation with user databases detected"
        return 1
    fi

    # Validate System-Only Installation
    if [ -f "${data_dir}/auto.cnf" ] && \
       [ -f "${data_dir}/ibdata1" ] && \
       [ -d "${data_dir}/mysql" ]; then
        log_info "Valid system-only installation detected"
        return 1
    fi

    # 5. Unknown State
    log_error "Unknown database state detected"
    return 3
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
