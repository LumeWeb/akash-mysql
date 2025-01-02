#!/bin/bash

# Prevent multiple inclusion
[ -n "${MYSQL_BACKUP_SCHEDULER_SOURCED}" ] && return 0
declare -g MYSQL_BACKUP_SCHEDULER_SOURCED=1

source "${LIB_PATH}/core/logging.sh"
source "${LIB_PATH}/core/constants.sh"
source "${LIB_PATH}/core/cron.sh"
source "${LIB_PATH}/mysql-backup.sh"

declare -g BACKUP_SCHEDULER_PID=""

# Start backup scheduler
start_backup_scheduler() {
    if [ "${BACKUP_ENABLED}" != "true" ]; then
        return 0
    fi
    
    setup_backup_cron
}

# Setup cron jobs for standalone mode
setup_backup_cron() {
    # Create cron entries
    cat > "${CRON_TAB_FILE}" << EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Full backup every hour
${BACKUP_SCHEDULE_FULL:-0 * * * *} root /usr/local/bin/mysql-backup-full

# Incremental backup disabled
# ${BACKUP_SCHEDULE_INCREMENTAL:-0 */6 * * *} root /usr/local/bin/mysql-backup-incremental

# Cleanup old backups daily
0 1 * * * root /usr/local/bin/mysql-backup-cleanup
EOF

    # Set proper permissions
    chmod 644 "${CRON_TAB_FILE}"
    
    # Only start cron if we're standalone or master
    if [ "$CLUSTER_MODE" != "true" ] || [ "$CURRENT_ROLE" = "master" ]; then
        if start_cron; then
            log_info "Started backup cron jobs for role: ${CURRENT_ROLE:-standalone}"
        else
            log_error "Failed to start backup cron jobs"
            return 1
        fi
    else
        # Stop cron if we're a slave
        if stop_cron; then
            log_info "Disabled backup cron jobs for slave role"
        else
            log_warn "Failed to stop backup cron jobs"
        fi
    fi
}

# Update backup status in etcd or local file for standalone
update_backup_status() {
    local status=$1
    local type=$2
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    local status_json=$(jq -n \
        --arg status "$status" \
        --arg type "$type" \
        --arg timestamp "$timestamp" \
        '{
            last_backup: {
                status: $status,
                type: $type,
                timestamp: $timestamp
            }
        }')

    if [ "$CLUSTER_MODE" = "true" ] && [ -n "$LEASE_ID" ]; then
        # Update etcd in cluster mode
        etcdctl put "$ETCD_NODES/$NODE_ID/backup" "$status_json" --lease=$LEASE_ID >/dev/null
    else
        # Update local status file in standalone mode
        local status_dir="${STATE_DIR}/backup/status"
        mkdir -p "$status_dir"
        echo "$status_json" > "$status_dir/backup_status.json"
        chmod 640 "$status_dir/backup_status.json"
    fi
}

# Monitor backup status and log results
monitor_backup_status() {
    while true; do
        if [ -f "${STATE_DIR}/backup/status/backup_status.json" ]; then
            local status
            status=$(jq -r '.last_backup.status' < "${STATE_DIR}/backup/status/backup_status.json")
            local type
            type=$(get_node_role "$(cat "${STATE_DIR}/backup/status/backup_status.json")")
            local timestamp
            timestamp=$(jq -r '.last_backup.timestamp' < "${STATE_DIR}/backup/status/backup_status.json")
            
            log_info "Backup Status - Type: $type, Status: $status, Time: $timestamp"
        fi
        sleep 300  # Check every 5 minutes
    done
}

# Initialize backup directories
init_backup_dirs() {
    mkdir -p "${BACKUP_STATE_DIR}" "${BACKUP_CONFIG_DIR}/keys"
    chmod 750 "${BACKUP_STATE_DIR}" "${BACKUP_CONFIG_DIR}"
    chmod 700 "${BACKUP_CONFIG_DIR}/keys"
}
