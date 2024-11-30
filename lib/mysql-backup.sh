#!/bin/bash

# Prevent multiple inclusion
[ -n "${MYSQL_BACKUP_SOURCED}" ] && return 0
declare -g MYSQL_BACKUP_SOURCED=1

source "${LIB_PATH}/core/logging.sh"
source "${LIB_PATH}/core/constants.sh"
source "${LIB_PATH}/mysql-common.sh"

# Initialize backup environment and validate all required settings
init_backup_env() {
    # Validate required S3 variables
    for var in "${REQUIRED_S3_VARS[@]}"; do
        if [ -z "${!var}" ]; then
            log_error "Required S3 variable $var is not set"
            return 1
        fi
    done

    # Validate backup paths and directories
    if [ -z "$BACKUP_CONFIG_DIR" ]; then
        log_error "BACKUP_CONFIG_DIR is not set"
        return 1
    fi

    if [ ! -d "$BACKUP_CONFIG_DIR" ] && ! mkdir -p "$BACKUP_CONFIG_DIR"; then
        log_error "Failed to create BACKUP_CONFIG_DIR: $BACKUP_CONFIG_DIR"
        return 1
    fi

    # Validate backup retention period
    if [ -z "$BACKUP_RETENTION_DAYS" ] || ! [[ "$BACKUP_RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
        log_error "BACKUP_RETENTION_DAYS must be a positive integer"
        return 1
    fi

    # Validate backup intervals
    if [ -z "$BACKUP_FULL_INTERVAL" ] || ! [[ "$BACKUP_FULL_INTERVAL" =~ ^[0-9]+$ ]]; then
        log_error "BACKUP_FULL_INTERVAL must be a positive integer"
        return 1
    fi

    if [ -z "$BACKUP_INCR_INTERVAL" ] || ! [[ "$BACKUP_INCR_INTERVAL" =~ ^[0-9]+$ ]]; then
        log_error "BACKUP_INCR_INTERVAL must be a positive integer"
        return 1
    fi

    # Validate MySQL credentials
    if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
        log_error "MYSQL_ROOT_PASSWORD is not set"
        return 1
    fi

    # Validate S3 SSL setting
    if [ -n "$S3_SSL" ] && [ "$S3_SSL" != "true" ] && [ "$S3_SSL" != "false" ]; then
        log_error "S3_SSL must be either 'true' or 'false'"
        return 1
    fi

    # Validate S3 path
    if [ -z "$S3_PATH" ]; then
        log_error "S3_PATH is not set"
        return 1
    fi
    
    # Create and secure encryption key directory
    mkdir -p "$BACKUP_KEY_DIR"
    chmod 750 "$BACKUP_KEY_DIR"
    chown -R mysql:mysql "$BACKUP_KEY_DIR"

    # Generate encryption key if it doesn't exist
    if [ ! -f "$BACKUP_KEY_DIR/backup.key" ]; then
        log_info "Generating new backup encryption key"
        openssl rand -base64 32 > "$BACKUP_KEY_DIR/backup.key"
        chmod 400 "$BACKUP_KEY_DIR/backup.key"
    else
        log_info "Using existing backup encryption key"
    fi

    # Start streaming backup server for master or standalone
    if [ "$CURRENT_ROLE" = "master" ] || [ "$CURRENT_ROLE" = "standalone" ]; then
        start_streaming_backup_server
        start_backup_scheduler
    fi
}

# Backup streaming security model:
# - Backup server only binds to 127.0.0.1:4444
# - Only accessible from within the same pod
# - No authentication needed as it's localhost-only
# - Backups still encrypted at rest using AES256
# - Encryption key stored in /etc/mysql/backup-keys/backup.key

start_streaming_backup_server() {
    local encrypt_key="$BACKUP_KEY_DIR/backup.key"
    
    # Allow both master and standalone roles to run backup server
    if [ "$CURRENT_ROLE" != "master" ] && [ "$CURRENT_ROLE" != "standalone" ]; then
        return 0
    fi
    
    # Validate requirements
    if [ ! -f "$encrypt_key" ]; then
        log_error "Encryption key file not found: $encrypt_key"
        return 1
    fi
    
    if [ ! -r "$encrypt_key" ]; then
        log_error "Cannot read encryption key file: $encrypt_key"
        return 1
    fi
    
    log_info "Starting backup stream server on localhost:4444"
    
    # Simple netcat server - no auth needed since it's localhost only
    (
        while true; do
            nc -l 127.0.0.1 4444 | \
            xtrabackup --backup --stream=xbstream \
                --encrypt=AES256 \
                --encrypt-key-file="$encrypt_key" \
                --target-dir=- \
                --user="root" --password="$MYSQL_ROOT_PASSWORD"
        done
    ) &
    
    STREAMING_BACKUP_PID=$!
    log_info "Backup stream server started with PID: $STREAMING_BACKUP_PID"
}

# Stop streaming backup server
stop_streaming_backup_server() {
    if [ -n "$STREAMING_BACKUP_PID" ]; then
        kill $STREAMING_BACKUP_PID 2>/dev/null || true
        wait $STREAMING_BACKUP_PID 2>/dev/null || true
        STREAMING_BACKUP_PID=""
        log_info "Streaming backup server stopped"
    fi
}

# Create incremental backup
create_incremental_backup() {
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local s3_url="s3://${S3_BUCKET}/${S3_PATH}/incr/backup-${timestamp}"
    local encrypt_key="$BACKUP_KEY_DIR/backup.key"
    
    # Get latest full backup path from S3
    local latest_full
    latest_full=$(xtrabackup --backup --target-dir="s3://${S3_BUCKET}/${S3_PATH}/full/" --backup-dir=- --user=root --password="${MYSQL_ROOT_PASSWORD}" 2>/dev/null | grep -o 's3://.*full/backup-[0-9-]*' | sort | tail -n1)
    
    if [ -z "$latest_full" ]; then
        log_error "No full backup found for incremental"
        return 1
    fi

    log_info "Starting incremental encrypted backup to S3"
    
    if ! xtrabackup --backup \
        --target-dir="${s3_url}" \
        --incremental-basedir="${latest_full}" \
        --user="root" \
        --password="${MYSQL_ROOT_PASSWORD}" \
        --encrypt=AES256 \
        --encrypt-key-file="${encrypt_key}" \
        --s3-endpoint="${S3_ENDPOINT}" \
        --s3-access-key="${S3_ACCESS_KEY}" \
        --s3-secret-key="${S3_SECRET_KEY}" \
        --s3-ssl="${S3_SSL}"; then
        log_error "Incremental backup to S3 failed"
        return 1
    fi

    log_info "Incremental backup completed: ${s3_url}"
    return 0
}

# Create full backup
create_full_backup() {
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local s3_url="s3://${S3_BUCKET}/${S3_PATH}/full/backup-${timestamp}"
    local encrypt_key="$BACKUP_KEY_DIR/backup.key"

    log_info "Starting full encrypted backup to S3"

    if ! xtrabackup --backup \
        --target-dir="${s3_url}" \
        --user="root" \
        --password="${MYSQL_ROOT_PASSWORD}" \
        --encrypt=AES256 \
        --encrypt-key-file="${encrypt_key}" \
        --s3-endpoint="${S3_ENDPOINT}" \
        --s3-access-key="${S3_ACCESS_KEY}" \
        --s3-secret-key="${S3_SECRET_KEY}" \
        --s3-ssl="${S3_SSL}"; then
        log_error "Full backup to S3 failed"
        return 1
    fi

    log_info "Full backup completed: ${s3_url}"
    return 0
}

# Verify backup integrity
verify_backup() {
    local s3_path="$1"
    local verify_dir="${2:-$(mktemp -d)}"
    local encrypt_key="$BACKUP_KEY_DIR/backup.key"
    local cleanup_temp=0

    # If no verify_dir provided, mark for cleanup
    if [ "$#" -eq 1 ]; then
        cleanup_temp=1
    fi

    log_info "Verifying S3 backup: $s3_path"
    log_info "Using verification directory: $verify_dir"

    # Download and decrypt backup for verification
    if ! timeout 300 xtrabackup --backup \
        --target-dir="$verify_dir" \
        --s3-endpoint="${S3_ENDPOINT}" \
        --s3-access-key="${S3_ACCESS_KEY}" \
        --s3-secret-key="${S3_SECRET_KEY}" \
        --s3-ssl="${S3_SSL}" \
        --s3-upload-retries=3 \
        --decrypt=AES256 \
        --encrypt-key-file="$encrypt_key" \
        --verify-only 2>&1; then
        log_error "Backup verification failed: $s3_path"
        [ $cleanup_temp -eq 1 ] && rm -rf "$verify_dir"
        return 1
    fi

    log_info "Backup verified successfully"
    [ $cleanup_temp -eq 1 ] && rm -rf "$verify_dir"
    return 0
}

# Restore from backup
restore_backup() {
    # Get latest backup from S3
    local latest_backup
    latest_backup=$(xtrabackup --backup --target-dir="s3://${S3_BUCKET}/${S3_PATH}/full/" --backup-dir=- --user=root --password="${MYSQL_ROOT_PASSWORD}" 2>/dev/null | grep -o 's3://.*full/backup-[0-9-]*' | sort | tail -n1)

    if [ -z "$latest_backup" ]; then
        log_error "No backup found in S3 to restore"
        update_backup_status "failed" "restore"
        return 1
    fi

    log_info "Preparing to restore from S3: $latest_backup"

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
    if ! xtrabackup --prepare --target-dir="${latest_backup}"; then
        log_error "Failed to prepare backup from S3"
        return 1
    fi

    # Copy files to data directory from S3
    if ! xtrabackup --copy-back --target-dir="${latest_backup}" \
        --datadir="$DATA_DIR"; then
        log_error "Failed to restore backup from S3"
        return 1
    fi

    # Fix permissions
    chown -R mysql:mysql "$DATA_DIR"
    
    log_info "Backup restored successfully from S3"
    return 0
}

# Cleanup old backups
cleanup_old_backups() {
    log_info "Cleaning up old S3 backups"
    
    # List and parse backup dates from S3 paths
    local full_backups
    full_backups=$(xtrabackup --backup \
        --target-dir="s3://${S3_BUCKET}/${S3_PATH}/full/" \
        --backup-dir=- \
        --s3-endpoint="${S3_ENDPOINT}" \
        --s3-access-key="${S3_ACCESS_KEY}" \
        --s3-secret-key="${S3_SECRET_KEY}" \
        --s3-ssl="${S3_SSL}" 2>/dev/null | grep -o 's3://.*full/backup-[0-9-]*')

    local incr_backups
    incr_backups=$(xtrabackup --backup \
        --target-dir="s3://${S3_BUCKET}/${S3_PATH}/incr/" \
        --backup-dir=- \
        --s3-endpoint="${S3_ENDPOINT}" \
        --s3-access-key="${S3_ACCESS_KEY}" \
        --s3-secret-key="${S3_SECRET_KEY}" \
        --s3-ssl="${S3_SSL}" 2>/dev/null | grep -o 's3://.*incr/backup-[0-9-]*')

    # Calculate cutoff date
    local cutoff
    cutoff=$(date -d "$BACKUP_RETENTION_DAYS days ago" +%Y%m%d)

    # Process full backups
    echo "$full_backups" | while read -r backup; do
        local backup_date
        backup_date=$(echo "$backup" | grep -o '[0-9]\{8\}')
        if [ "$backup_date" -lt "$cutoff" ]; then
            log_info "Removing old full backup: $backup"
            xtrabackup --remove-backup \
                --target-dir="$backup" \
                --s3-endpoint="${S3_ENDPOINT}" \
                --s3-access-key="${S3_ACCESS_KEY}" \
                --s3-secret-key="${S3_SECRET_KEY}" \
                --s3-ssl="${S3_SSL}"
        fi
    done

    # Process incremental backups
    echo "$incr_backups" | while read -r backup; do
        local backup_date
        backup_date=$(echo "$backup" | grep -o '[0-9]\{8\}')
        if [ "$backup_date" -lt "$cutoff" ]; then
            log_info "Removing old incremental backup: $backup"
            xtrabackup --remove-backup \
                --target-dir="$backup" \
                --s3-endpoint="${S3_ENDPOINT}" \
                --s3-access-key="${S3_ACCESS_KEY}" \
                --s3-secret-key="${S3_SECRET_KEY}" \
                --s3-ssl="${S3_SSL}"
        fi
    done
}
