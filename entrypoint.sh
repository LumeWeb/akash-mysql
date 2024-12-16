#!/bin/bash
set -eo pipefail
shopt -s nullglob

source ./paths.sh
source "${LIB_PATH}/core/logging.sh"
source "${LIB_PATH}/core/constants.sh"
source "${LIB_PATH}/core/cron.sh"
source "${LIB_PATH}/core/setup.sh"

# If we're running as root, set up permissions and re-execute as mysql
if [ "$(id -u)" = "0" ]; then
    # Create and set permissions on required directories
    mkdir -p $DATA_ROOT $DATA_DIR $RUN_DIR $LOG_DIR $CONFIG_DIR $MYSQL_FILES_DIR
    
    # Set proper permissions for MySQL directories
    chown -R mysql:mysql $DATA_ROOT $RUN_DIR $LOG_DIR $CONFIG_DIR
    chmod 750 $DATA_ROOT $DATA_DIR $MYSQL_FILES_DIR
    chmod 755 $RUN_DIR $LOG_DIR $CONFIG_DIR
    
    # Ensure directory is clean for initialization
    if [ ! -d "$DATA_DIR/mysql" ]; then
        rm -rf "$DATA_DIR"/*
    fi
    
    # Create base MySQL configuration
    cat > "/etc/my.cnf" << EOF
[mysqld]
user = mysql
pid-file = /var/run/mysqld/mysqld.pid
socket = ${MYSQL_SOCKET}
port = ${MYSQL_PORT}
basedir = /usr
datadir = ${DATA_DIR}
tmpdir = /tmp
bind-address = 0.0.0.0
log-error = ${LOG_DIR}/error.log
secure-file-priv = ${MYSQL_FILES_DIR}
log_error_suppression_list='MY-013360'

!includedir /etc/my.cnf.d
EOF
    
    # Create global MySQL client configuration
    cat > "/root/.my.cnf" << EOF
[client]
socket = ${MYSQL_SOCKET}
EOF
    chmod 600 /root/.my.cnf

    mkdir -p /home/mysql
    cp /root/.my.cnf /home/mysql/.my.cnf
    chown -R mysql:mysql /home/mysql

    # Set proper permissions
    chown -R mysql:mysql $DATA_ROOT $RUN_DIR $LOG_DIR $CONFIG_DIR
    chmod 750 $DATA_ROOT $DATA_DIR
    chmod 755 $RUN_DIR $LOG_DIR $CONFIG_DIR
    chmod 644 /etc/my.cnf

    touch /var/run/crond.pid && chown mysql:mysql /var/run/crond.pid

    # Initialize all state directories
    init_state_directories

    # Re-execute script as mysql user
    exec su mysql -s /bin/bash -c "$0 $*"
    exit 1
fi

# Start required services
start_services() {
    # Start crond if it exists
    if command -v crond >/dev/null 2>&1; then
        start_cron
    fi
}

# Stop services before exit
stop_services() {
    stop_cron
}

# Main entrypoint logic
main() {
    # Start required services
    start_services
    
    # Set up cleanup trap
    trap stop_services EXIT
    
    # Environment setup
    declare -gx HOST
    declare -gx MYSQL_PORT
    declare -gx MYSQL_EXTERNAL_PORT
    declare -gx NODE_ID
    declare -gx CLUSTER_MODE
    declare -gx SERVER_ID
    CLUSTER_MODE=${CLUSTER_MODE:-false}
    HOST=${AKASH_INGRESS_HOST:-localhost}
    MYSQL_PORT=${MYSQL_PORT:-3306}
    MYSQL_EXTERNAL_PORT=${AKASH_EXTERNAL_PORT_3306:-$MYSQL_PORT}
    log_info "Configured MySQL internal port: ${MYSQL_PORT}"
    log_info "Configured MySQL external port: ${MYSQL_EXTERNAL_PORT}"
    log_info "Configured hostname: ${HOST}"
    
    # Use Akash environment variables directly and export
    NODE_ID=$(echo "${AKASH_INGRESS_HOST}:${AKASH_EXTERNAL_PORT_3306}" | sha256sum | cut -c1-8)
    SERVER_ID=$(echo "$NODE_ID" | cksum | cut -d ' ' -f1)
    log_info "Using Akash Node ID (SHA-256): ${NODE_ID}"
    log_info "Using Replication Server ID (CRC-32): ${SERVER_ID}"

    # Check if command starts with an option
    if [ "${1:0:1}" = '-' ]; then
        set -- mysqld "$@"
    fi

    # Check for help flags
    for arg; do
        case "$arg" in
            -'?'|--help|--print-defaults|-V|--version)
                exec "$@"
                ;;
        esac
    done

    if [ "$1" = 'mysqld' ]; then
        if [ "$CLUSTER_MODE" = "true" ]; then
            exec "${LIB_PATH}/cluster-start.sh" "$@"
        else
            exec "${LIB_PATH}/standalone-start.sh" "$@"
        fi
    fi

    # Execute command directly (we're already the mysql user)
    exec "$@"
}

main "$@"
