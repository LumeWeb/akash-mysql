#!/bin/bash

# Prevent multiple inclusion
[ -n "${MYSQL_STARTUP_SOURCED}" ] && return 0
declare -g MYSQL_STARTUP_SOURCED=1

# Core dependencies
source "${LIB_PATH}/core/logging.sh"
source "${LIB_PATH}/core/constants.sh"
source "${LIB_PATH}/core/mysql.sh"

# Base layer
source "${LIB_PATH}/mysql-common.sh"
source "${LIB_PATH}/mysql-config.sh"

# Start MySQL with enhanced configuration and monitoring
start_mysql() {
    local ROLE=$1
    local SERVER_ID=$2
    shift 2
    local MYSQL_ARGS=("$@")

    # Configure MySQL based on role using core module
    log_info "Configuring MySQL for role: $ROLE"
    
    # Load system settings
    eval "$(calculate_system_settings)"
    
    if ! configure_mysql "$ROLE" "$SERVER_ID" "$BUFFER_POOL_SIZE" "$BUFFER_POOL_INSTANCES" "$TMP_TABLE_SIZE"; then
        log_error "Failed to configure MySQL for role: $ROLE"
        return 1
    fi

    # Configure connection rate limiting
    if [ ! -f /etc/mysql/conf.d/limits.cnf ]; then
        cat > /etc/mysql/conf.d/limits.cnf << EOF
[mysqld]
max_connect_errors = 10000
connect_timeout = 10
max_connections = 1000
max_user_connections = 500
EOF
    fi

    # Ensure optimizations config exists
    if [ ! -f /etc/mysql/conf.d/optimizations.cnf ]; then
        log_info "Generating MySQL optimizations..."
        generate_mysql_configs
    fi

    # Core monitoring setup
    source "${LIB_PATH}/mysql-query-analyzer.sh"
    source "${LIB_PATH}/features/connection/pool.sh"
    
    # Initialize monitoring
    #init_query_analyzer "$ROLE"
   # init_connection_pool
    
    # Initialize FD tracking and maintenance with role awareness
    source "${LIB_PATH}/mysql-fd-tracker.sh"
    #init_mysql_fd_tracker "$ROLE"
    
    # Initialize maintenance last
    source "${LIB_PATH}/features/maintenance/table_maintenance.sh"
   # schedule_table_maintenance "$ROLE"

    # Start MySQL with all config files and enhanced error handling
    log_info "Starting MySQL server..."
    
    # Validate configurations before starting
    if ! validate_mysql_config "/etc/mysql/my.cnf"; then
        log_error "Invalid MySQL configuration"
        return 1
    fi
    
    if ! validate_mysql_config "/etc/mysql/conf.d/optimizations.cnf"; then
        log_error "Invalid optimizations configuration"
        return 1
    fi
    
    # Wait for any ongoing initialization to complete
    while [ -f "/var/run/mysqld/initializing.flag" ]; do
        log_info "Waiting for MySQL initialization to complete..."
        sleep 2
    done

    # Start MySQL with validated configs
    if ! mysqld --defaults-file=/etc/mysql/my.cnf \
           --defaults-extra-file=/etc/mysql/conf.d/optimizations.cnf \
           --innodb-buffer-pool-load-at-startup=1 \
           --innodb-buffer-pool-dump-at-shutdown=1 \
           "${MYSQL_ARGS[@]}" & MYSQL_PID=$!; then
        log_error "Failed to start MySQL server"
        return 1
    fi
    
    # Verify process started successfully
    if ! ps -p $MYSQL_PID > /dev/null 2>&1; then
        log_error "MySQL process failed to start"
        return 1
    fi

    # Verify process started successfully
    if ! ps -p $MYSQL_PID > /dev/null 2>&1; then
        log_error "MySQL process failed to start"
        return 1
    fi

    # Wait for MySQL to be ready
    if ! wait_for_mysql; then
        log_error "Failed to start MySQL"
        return 1
    fi

    log_info "MySQL is running. Configuring replication..."

    # Configure replication users if needed
    if [ "$ROLE" = "master" ]; then
        if [ -z "$MYSQL_REPL_USER" ] || [ -z "$MYSQL_REPL_PASSWORD" ]; then
            log_error "MYSQL_REPL_USER and MYSQL_REPL_PASSWORD must be set for master role"
            return 1
        fi
        
        echo "Configuring replication user..."
        if ! mysql -u root -p"$MYSQL_ROOT_PASSWORD" << EOF
CREATE USER IF NOT EXISTS '$MYSQL_REPL_USER'@'%' IDENTIFIED BY '$MYSQL_REPL_PASSWORD';
GRANT REPLICATION SLAVE ON *.* TO '$MYSQL_REPL_USER'@'%';
FLUSH PRIVILEGES;
EOF
        then
            log_error "Failed to configure replication user"
            return 1
        fi
    fi

    log_info "MySQL startup completed successfully"
    return 0
}

