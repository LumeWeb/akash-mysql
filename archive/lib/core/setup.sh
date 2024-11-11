#!/bin/bash

# Prevent multiple inclusion
[ -n "${CORE_SETUP_SOURCED}" ] && return 0
declare -g CORE_SETUP_SOURCED=1

source "${LIB_PATH}/core/logging.sh"
source "${LIB_PATH}/core/constants.sh"

# Setup MySQL directories with proper permissions
setup_mysql_dirs() {
    local dirs=(
        "$DATA_DIR"
        "$RUN_DIR"
        "$CONFIG_DIR"
        "$LOG_DIR"
    )
    
    for dir in "${dirs[@]}"; do
        mkdir -p "$dir"
        chown mysql:mysql "$dir"
        chmod 750 "$dir"
    done
    
    # Create and set permissions for log files
    touch "$LOG_DIR/error.log"
    chown mysql:mysql "$LOG_DIR/error.log"
    chmod 640 "$LOG_DIR/error.log"
}

# Initialize MySQL data directory
initialize_mysql() {
    local datadir="${1:-/var/lib/mysql}"  # Default to /var/lib/mysql if not specified
    local root_password="$2"

    # Verify environment variables
    if ! verify_env; then
        log_error "Environment verification failed"
        return 1
    fi

    # Setup MySQL directories
    setup_mysql_dirs

    if [ ! -d "$datadir/mysql" ]; then
        if [ -z "$root_password" ] && [ -z "$MYSQL_ALLOW_EMPTY_PASSWORD" ] && [ -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
            log_error "Database is uninitialized and no root password specified"
            return 1
        fi
        
        log_info "Initializing database in $datadir"
        # Ensure proper permissions on all required directories
        mkdir -p "$datadir"
        mkdir -p /var/run/mysqld
        mkdir -p /var/log/mysql
        
        chown -R mysql:mysql "$datadir"
        chown -R mysql:mysql /var/run/mysqld
        chown -R mysql:mysql /var/log/mysql
        
        chmod 750 "$datadir"
        chmod 755 /var/run/mysqld
        chmod 750 /var/log/mysql

        # Initialize with proper datadir and socket path
        # Create a flag file to indicate initialization is in progress
        touch "/var/run/mysqld/initializing.flag"
        
        if ! mysqld --initialize-insecure \
               --datadir="$datadir" \
               --user=mysql \
               --pid-file=/var/run/mysqld/mysqld.pid \
               --socket=/var/run/mysqld/mysqld.sock \
               --basedir=/usr \
               --log-error=/var/log/mysql/error.log; then
            log_error "Failed to initialize MySQL data directory"
            rm -f "/var/run/mysqld/initializing.flag"
            return 1
        fi

        # Remove initialization flag to indicate completion
        rm -f "/var/run/mysqld/initializing.flag"
        
        # Set proper permissions after initialization
        chown -R mysql:mysql "$datadir"
        chmod 750 "$datadir"
        
        return 0
    fi
    
    return 1
}
