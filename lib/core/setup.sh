# Initialize all state directories
init_state_directories() {
    local dirs=(
        "${STATE_DIR}"
        "${BACKUP_STATE_DIR}"
        "${BACKUP_CONFIG_DIR}"
        "${LOCKS_DIR}"
        "${CONFIG_STATE_DIR}"
        "${CRON_STATE_DIR}"
        "${ETCD_STATE_DIR}"
    )

    for dir in "${dirs[@]}"; do
        mkdir -p "$dir"
        chown mysql:mysql "$dir"
        chmod 750 "$dir"
    done
} 