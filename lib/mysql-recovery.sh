#!/bin/bash

# Prevent multiple inclusion
[ -n "${MYSQL_RECOVERY_SOURCED}" ] && return 0
declare -g MYSQL_RECOVERY_SOURCED=1

source "${LIB_PATH}/core/logging.sh"
source "${LIB_PATH}/mysql-backup.sh"
source "${LIB_PATH}/mysql-role.sh"

# Return codes:
# 0 = Fresh install needed
# 1 = Existing valid installation
# 2 = Recovery needed
# 3 = Error state
detect_mysql_state() {
    log_info "Detecting MySQL installation state..."
    
    # Case 1: Completely new installation
    if [ ! -d "${DATA_DIR}/mysql" ] && [ ! -f "${DATA_DIR}/ibdata1" ]; then
        log_info "Fresh installation needed - no existing data"
        return 0
    fi

    # Case 2: Check for valid installation
    if [ -d "${DATA_DIR}/mysql" ] && \
       [ -f "${DATA_DIR}/ibdata1" ] && \
       [ -f "${DATA_DIR}/auto.cnf" ]; then
        # Additional corruption checks
        if [ -f "${DATA_DIR}/ib_logfile0" ]; then
            if grep -q "corrupt" "${LOG_DIR}/error.log" 2>/dev/null; then
                log_warn "Found corruption markers in error log"
                return 2
            fi
        fi
        
        # Check for clean shutdown
        if [ -f "${DATA_DIR}/aria_log_control" ]; then
            log_warn "Found aria control file indicating unclean shutdown"
            return 2
        fi
        
        log_info "Valid existing installation detected"
        return 1
    fi

    # Case 3: Partial/corrupt installation
    if [ -f "${DATA_DIR}/ibdata1" ] || [ -d "${DATA_DIR}/mysql" ]; then
        log_warn "Partial or corrupt installation detected"
        return 2
    fi

    # Case 4: Unknown state
    log_error "Unknown MySQL data directory state"
    return 3
}

# Legacy wrapper for compatibility
detect_recovery_needed() {
    local state
    detect_mysql_state
    state=$?
    
    case $state in
        0) return 1 ;; # Fresh install = no recovery
        1) return 1 ;; # Valid install = no recovery
        2) return 0 ;; # Recovery needed = yes
        *) return 0 ;; # Unknown = try recovery
    esac
}

# Validate cluster state before recovery
validate_cluster_state() {
    local force=${1:-0}
    local master_validation_timeout=30  # seconds

    if [ "$CLUSTER_MODE" != "true" ]; then
        log_info "Standalone mode - cluster validation skipped"
        return 0
    fi

    # Check if we're trying to restore on a running master
    if [ "$CURRENT_ROLE" = "master" ] && [ "$force" != "1" ]; then
        log_error "Cannot restore on running master without force flag"
        return 1
    fi

    # Verify no other viable master exists if we need promotion
    local master_info
    master_info=$(etcdctl get "$ETCD_MASTER_KEY" --print-value-only)
    
    if [ -n "$master_info" ] && [ "$force" != "1" ]; then
        log_info "Found master key in etcd, validating master availability..."
        
        # Extract master host and port
        local master_host
        local master_port
        master_host=$(get_node_hostname "$master_info")
        master_port=$(get_node_port "$master_info")

        # Try to connect to master
        local start_time=$(date +%s)
        local master_reachable=0
        
        while [ $(($(date +%s) - start_time)) -lt $master_validation_timeout ]; do
            if timeout 5 mysql -h "$master_host" -P "$master_port" -u"$MYSQL_REPL_USERNAME" \
                -p"$MYSQL_REPL_PASSWORD" -e "SELECT 1" >/dev/null 2>&1; then
                master_reachable=1
                break
            fi
            sleep 2
        done

        if [ $master_reachable -eq 1 ]; then
            log_error "Cannot restore/promote while viable master exists and is reachable"
            return 1
        else
            log_warn "Master key exists but master is unreachable - proceeding with recovery"
            # Optionally clean up the stale master key
            if etcdctl del "$ETCD_MASTER_KEY" >/dev/null; then
                log_info "Cleaned up stale master key"
            fi
        fi
    fi

    return 0
}

# Main recovery workflow
perform_recovery() {
    local force=${1:-0}
    
    log_info "Starting recovery workflow"

    # Create recovery lock file
    local lock_file="/var/run/mysqld/recovery.lock"
    if ! mkdir -p "$(dirname "$lock_file")" 2>/dev/null; then
        log_error "Failed to create recovery lock directory"
        return 1
    fi

    # Try to acquire lock
    exec 200>"$lock_file"
    if ! flock -n 200; then
        log_error "Another recovery process is running"
        return 1
    fi

    # Ensure lock is released on exit
    trap 'exec 200>&-; rm -f "$lock_file"' EXIT

    # Backup existing data if any
    if [ -d "${DATA_DIR}/mysql" ] || [ -f "${DATA_DIR}/ibdata1" ]; then
        local backup_dir="/var/backup/mysql_backup_$(date +%Y%m%d_%H%M%S)"
        log_info "Backing up existing data to $backup_dir"
        mkdir -p "$backup_dir"
        rsync -av --delete "${DATA_DIR}/" "$backup_dir/" 2>/dev/null || true
    fi

    # For cluster mode, validate topology first
    if [ "$CLUSTER_MODE" = "true" ]; then
        if ! validate_cluster_state "$force"; then
            log_error "Cluster validation failed - recovery aborted"
            return 1
        fi

        # Handle slave recovery differently
        if [ "$CURRENT_ROLE" = "slave" ]; then
            log_info "Slave recovery - using replication"
            if ! handle_demotion_to_slave; then
                log_error "Failed to configure replication"
                return 1
            fi
            return 0
        fi
    fi

    # Clean data directory
    log_info "Cleaning data directory for recovery"
    if ! safe_clear_directory "$DATA_DIR"; then
        log_error "Failed to clear data directory"
        return 1
    fi

    # Try backup recovery only if explicitly enabled
    if [ "${BACKUP_ENABLED}" = "true" ] && [ "${RECOVER_FROM_BACKUP}" = "true" ]; then
        log_info "Backup recovery enabled, attempting restore..."
        if restore_from_backup; then
            log_info "Successfully restored from backup"
            return 0
        fi
        log_info "No backup available or restore failed, falling back to fresh initialization"
    else
        log_info "Backup recovery disabled or not requested, proceeding with fresh initialization"
    fi

    # Always proceed with fresh initialization if we get here
    log_info "Performing fresh initialization"
    if ! init_mysql; then
        log_error "Failed to initialize MySQL"
        return 1
    fi

    # Perform fresh initialization
    log_info "Performing fresh initialization"
    if ! init_mysql; then
        log_error "Failed to initialize MySQL"
        return 1
    fi

    return 0
}

    if [ -n "$latest_backup" ]; then
        log_info "Found latest backup in S3: $latest_backup"
    else
        log_info "No backup found in S3"
        return 1
    fi

    # Stop MySQL if running
    if pgrep mysqld >/dev/null; then
        log_info "Stopping MySQL for recovery"
        mysqladmin shutdown
        sleep 5
    fi

    # Stop MySQL if running
    if pgrep mysqld >/dev/null; then
        log_info "Stopping MySQL for restore"
        mysqladmin shutdown
        sleep 5
    fi

    # Safely clear data directory
    if ! safe_clear_directory "$DATA_DIR"; then
        log_error "Failed to clear data directory"
        return 1
    fi

    # Prepare backup directly from S3
    if ! xtrabackup --prepare \
        --target-dir="${latest_backup}" \
        --s3-endpoint="${S3_ENDPOINT}" \
        --s3-access-key="${S3_ACCESS_KEY}" \
        --s3-secret-key="${S3_SECRET_KEY}" \
        --s3-ssl="${S3_SSL}"; then
        log_error "Failed to prepare backup from S3"
        return 1
    fi

    # Copy files to data directory from S3
    if ! xtrabackup --copy-back \
        --target-dir="${latest_backup}" \
        --datadir="$DATA_DIR" \
        --s3-endpoint="${S3_ENDPOINT}" \
        --s3-access-key="${S3_ACCESS_KEY}" \
        --s3-secret-key="${S3_SECRET_KEY}" \
        --s3-ssl="${S3_SSL}"; then
        log_error "Failed to restore backup from S3"
        return 1
    fi

    # Fix permissions
    chown -R mysql:mysql "$DATA_DIR"
    
    log_info "Backup restored successfully from S3"

    # If in cluster mode, handle promotion if needed
    if [ "$CLUSTER_MODE" = "true" ]; then
        if [ -z "$master_info" ] || [ "$force" = "1" ]; then
            if [ "$force" = "1" ]; then
                log_info "Forced master promotion requested"
            else
                log_info "No viable master found"
            fi
            log_info "Promoting this node to master"
            CURRENT_ROLE="master"
            save_role_state "master"
        fi
    fi

    log_info "Recovery completed successfully"
    return 0
}
