#!/bin/bash

# Prevent multiple inclusion
[ -n "${MYSQL_RECOVERY_SOURCED}" ] && return 0
declare -g MYSQL_RECOVERY_SOURCED=1

source "${LIB_PATH}/core/logging.sh"
source "${LIB_PATH}/mysql-backup.sh"
source "${LIB_PATH}/mysql-role.sh"

# Detect if recovery is needed
detect_recovery_needed() {
    # Check for corrupt data directory
    if [ ! -f "${DATA_DIR}/ibdata1" ] || [ ! -d "${DATA_DIR}/mysql" ]; then
        log_warn "Data directory appears corrupt or empty"
        return 0
    fi

    # Check for crash recovery files
    if [ -f "${DATA_DIR}/ib_logfile0" ]; then
        if grep -q "corrupt" "${LOG_DIR}/error.log" 2>/dev/null; then
            log_warn "Found corruption markers in error log"
            return 0
        fi
    fi

    # Check for incomplete shutdown
    if [ -f "${DATA_DIR}/aria_log_control" ]; then
        log_warn "Found aria control file indicating unclean shutdown"
        return 0
    fi

    return 1
}

# Validate cluster state before recovery
validate_cluster_state() {
    local force=${1:-0}

    if [ "$CLUSTER_MODE" != "true" ]; then
        log_info "Standalone mode - cluster validation skipped"
        return 0
    fi

    # Check if we're trying to restore on a running master
    if [ "$CURRENT_ROLE" = "master" ] && [ "$force" != "1" ]; then
        log_error "Cannot restore on running master without force flag"
        return 1
    fi

    # Verify no other master exists if we need promotion
    local master_info
    master_info=$(etcdctl get "$ETCD_MASTER_KEY" --print-value-only)
    
    if [ -n "$master_info" ] && [ "$force" != "1" ]; then
        log_error "Cannot restore/promote while viable master exists"
        return 1
    fi

    return 0
}

# Main recovery workflow
perform_recovery() {
    local force=${1:-0}
    
    log_info "Starting recovery workflow"

    # Validate cluster state first
    if ! validate_cluster_state "$force"; then
        log_error "Cluster validation failed - recovery aborted"
        return 1
    fi

    # For slaves, just reset replication
    if [ "$CLUSTER_MODE" = "true" ] && [ "$CURRENT_ROLE" = "slave" ]; then
        log_info "Slave recovery - using replication"
        if ! handle_demotion_to_slave; then
            log_error "Failed to configure replication"
            return 1
        fi
        return 0
    fi

    # For master or standalone, try S3 backups first if enabled
    if [ "${BACKUP_ENABLED}" = "true" ]; then
        log_info "Checking for S3 backup for recovery"
        
        # Find latest backup from S3
        local latest_backup
        latest_backup=$(xtrabackup --backup \
            --target-dir="s3://${S3_BUCKET}/${S3_PATH}/full/" \
            --backup-dir=- \
            --s3-endpoint="${S3_ENDPOINT}" \
            --s3-access-key="${S3_ACCESS_KEY}" \
            --s3-secret-key="${S3_SECRET_KEY}" \
            --s3-ssl="${S3_SSL}" 2>/dev/null | grep -o 's3://.*full/backup-[0-9-]*' | sort | tail -n1)
        
        if [ -z "$latest_backup" ]; then
            log_info "No existing backup found in S3 - this is normal for new deployments"
            log_info "Proceeding with fresh initialization"
            return 0
        fi
    else
        log_info "Backup recovery skipped - backups are disabled"
        return 0
    fi

    log_info "Found latest backup in S3: $latest_backup"

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
