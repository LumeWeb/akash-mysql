#!/bin/bash

# Prevent multiple inclusion
[ -n "${MYSQL_STARTUP_SOURCED}" ] && return 0
declare -g MYSQL_STARTUP_SOURCED=1

source "${LIB_PATH}/core/logging.sh"
source "${LIB_PATH}/mysql-common.sh"
source "${LIB_PATH}/mysql-config.sh"

# Process initialization files
process_init_file() {
    local f="$1"; shift
    local mysql=( "$@" )

    case "$f" in
        *.sh)     log_info "Running $f"; . "$f" ;;
        *.sql)    log_info "Running $f"; mysql_retry "${mysql[@]}" < "$f"; echo ;;
        *.sql.gz) log_info "Running $f"; gunzip -c "$f" | mysql_retry "${mysql[@]}"; echo ;;
        *)        log_info "Ignoring $f" ;;
    esac
}

# Initialize MySQL database if needed
init_mysql() {
    log_info "Checking if MySQL initialization is needed..."
    
    # Check if data directory is empty or not properly initialized
    if [ ! -d "/var/lib/mysql/mysql" ] || [ ! -f "/var/lib/mysql/ibdata1" ] || [ ! -f "/var/lib/mysql/mysql.ibd" ]; then
        log_info "MySQL data directory is empty, initializing..."
        
        # Gracefully stop any running MySQL instances
        if [ -f /var/run/mysqld/mysqld.pid ]; then
            mysqladmin shutdown 2>/dev/null || true
            sleep 5
        fi
        
        # Force kill if still running
        pkill mysqld || true
        sleep 2
        
        # Remove socket files
        rm -f /var/run/mysqld/mysqld.pid
        rm -f /var/run/mysqld/mysqld.sock*
        
        # Verify directory permissions before initialization
        if [ ! -w "$DATA_DIR" ]; then
            log_error "Data directory $DATA_DIR is not writable"
            return 1
        fi
        
        # Initialize MySQL with explicit paths
        mysqld --initialize-insecure --user=mysql \
            --datadir="$DATA_DIR" \
            --basedir=/usr \
            --secure-file-priv=/var/lib/mysql-files \
            --pid-file=/var/run/mysqld/mysqld.pid
            
        # Wait for initialization to complete
        sync
        sleep 2

        # Start MySQL with skip-grant-tables to set root password
        if [ -n "$MYSQL_ROOT_PASSWORD" ]; then
            log_info "Starting MySQL with skip-grant-tables to set root password..."
            
            # Verify socket directory is writable
            if [ ! -w "$RUN_DIR" ]; then
                log_error "Socket directory $RUN_DIR is not writable"
                return 1
            fi
            
            # Remove any stale files
            rm -f /var/run/mysqld/mysqld.sock* 
            rm -f /var/run/mysqld/mysqld.pid
            
            # Start with error logging and explicit paths
            mysqld --skip-grant-tables --skip-networking \
                  --datadir="$DATA_DIR" \
                  --socket=/var/run/mysqld/mysqld.sock \
                  --pid-file=/var/run/mysqld/mysqld.pid \
                  --log-error=/var/log/mysql/init-error.log \
                  --port="${MYSQL_PORT}" \
                  --user=mysql &
            TEMP_MYSQL_PID=$!
            
            # Give mysqld time to create socket and verify process is running
            sleep 5
            if ! kill -0 $TEMP_MYSQL_PID 2>/dev/null; then
                log_error "Temporary MySQL process died immediately"
                if [ -f "/var/log/mysql/init-error.log" ]; then
                    log_error "Error log contents:"
                    cat "/var/log/mysql/init-error.log"
                fi
                return 1
            fi
            
            # Wait for MySQL socket and connectivity
            local max_attempts=30
            local attempt=1
            while [ $attempt -le $max_attempts ]; do
                if [ -S "/var/run/mysqld/mysqld.sock" ]; then
                    if mysql -u root --socket=/var/run/mysqld/mysqld.sock -e "SELECT 1" >/dev/null 2>&1; then
                        log_info "Temporary MySQL instance is ready"
                        break
                    fi
                fi
                
                if [ $((attempt % 5)) -eq 0 ]; then
                    log_info "Still waiting for temporary MySQL instance (attempt $attempt/$max_attempts)"
                    if [ -f "/var/log/mysql/init-error.log" ]; then
                        log_info "Last 5 lines of error log:"
                        tail -n 5 "/var/log/mysql/init-error.log"
                    fi
                fi
                
                sleep 1
                attempt=$((attempt + 1))
            done
            
            if [ $attempt -gt $max_attempts ]; then
                log_error "Temporary MySQL instance failed to start"
                if [ -f "/var/log/mysql/init-error.log" ]; then
                    log_error "Error log contents:"
                    cat "/var/log/mysql/init-error.log"
                fi
                return 1
            fi
            
            # Set root password and fix privileges with enhanced access
            mysql_retry_auth root "${MYSQL_ROOT_PASSWORD}" << EOF
FLUSH PRIVILEGES;
DROP USER IF EXISTS 'root'@'localhost';
DROP USER IF EXISTS 'root'@'%';
CREATE USER 'root'@'%' IDENTIFIED WITH caching_sha2_password BY '${MYSQL_ROOT_PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF

            if [ $? -ne 0 ]; then
                log_error "Failed to set root password"
                return 1
            fi
            
            # Shutdown MySQL gracefully
            log_info "Shutting down temporary MySQL instance..."
            kill $TEMP_MYSQL_PID
            wait $TEMP_MYSQL_PID 2>/dev/null || true
            
            log_info "Root password set successfully during initialization"
        fi
        
        log_info "MySQL initialization completed"
        return 0
    else
        log_info "MySQL data directory already initialized"
        return 0
    fi
}

# Start MySQL with enhanced configuration and monitoring
start_mysql() {
    local ROLE=$1
    local SERVER_ID=$2
    local HOST=$3
    shift 3
    local MYSQL_ARGS=("$@")

    # Always start as slave initially
    ROLE="slave"
    log_info "Starting MySQL initially as slave (waiting for ProxySQL topology)"
    log_info "Configuring MySQL for role: $ROLE"
    
    if ! generate_mysql_configs; then
        log_error "Failed to generate MySQL configurations"
        return 1
    fi

    if ! configure_mysql_files "$ROLE" "$SERVER_ID"; then
        log_error "Failed to configure MySQL files for role: $ROLE"
        return 1
    fi

    # Check for forced master recovery
    FORCE_MASTER_RECOVERY=${FORCE_MASTER_RECOVERY:-0}
    
    # Check if recovery is needed
    if detect_recovery_needed; then
        log_warn "Recovery needed - initiating recovery workflow"
        if ! perform_recovery "$FORCE_MASTER_RECOVERY"; then
            log_error "Recovery failed"
            return 1
        fi
        log_info "Recovery completed successfully"
        
        # After recovery or if no backup found, ensure MySQL is initialized
        if ! init_mysql; then
            log_error "MySQL initialization failed"
            return 1
        fi
    else
        # Normal initialization
        if ! init_mysql; then
            log_error "MySQL initialization failed"
            return 1
        fi
    fi
        
    # Skip permissions as we're already running as mysql user
    
    # Wait for files to be fully written
    sync
    sleep 2
    
    # Start MySQL with configs
    if [ "$ROLE" != "standalone" ]; then
        log_info "[INFO] Using Replication Server ID (CRC-32): $SERVER_ID"
    fi
    log_info "Starting MySQL server..."
    
    # Get and validate configuration
    if ! _check_config "${MYSQL_ARGS[@]}"; then
        log_error "Configuration check failed"
        return 1
    fi

    local DATADIR="$(_get_config 'datadir' "${MYSQL_ARGS[@]}")"

    # Ensure plugin directory is clean
    rm -rf /var/lib/mysql/plugin/*
    
    # Ensure error log directory exists
    local ERROR_LOG="$LOG_DIR/error.log"
    mkdir -p "$(dirname "$ERROR_LOG")" 2>/dev/null || true
    touch "$ERROR_LOG" 2>/dev/null || true
    
    # Start log monitoring in background
    monitor_log "$ERROR_LOG" "/var/run/mysqld/error_monitor.pid"
    

    # Kill any existing MySQL processes
    pkill mysqld || true
    
    # Wait for processes to die and files to be unlocked
    sleep 2
    
    # Remove any stale files
    rm -f /var/run/mysqld/mysqld.pid
    rm -f /var/run/mysqld/mysqld.sock
    
    # Start MySQL
    mysqld \
        --user=mysql \
        --port="${MYSQL_PORT}" \
        --log-error="$LOG_DIR/error.log" \
        --skip-mysqlx \
        --datadir=/var/lib/mysql \
        --pid-file=/var/run/mysqld/mysqld.pid \
        --socket="${MYSQL_SOCKET}" &

    MYSQL_PID=$!

    # Check if MySQL process is still running
    if ! kill -0 $MYSQL_PID 2>/dev/null; then
        log_error "MySQL process died during startup"
        if [ -f "$LOG_DIR/error.log" ]; then
            log_error "Last 10 lines of error log:"
            tail -n 10 "$LOG_DIR/error.log" >&2
        fi
        return 1
    fi

    echo "MySQL process started with PID: $MYSQL_PID"

    # Wait for MySQL to be ready using enhanced function
    if ! wait_for_mysql $MYSQL_START_TIMEOUT "${MYSQL_ROOT_PASSWORD}"; then
        kill $MYSQL_PID 2>/dev/null || true
        return 1
    fi

    # Root password is now set during initialization

    # Process initialization files after MySQL is running
    
    # Initialize backup environment after init files are processed
    if [ -d "/docker-entrypoint-initdb.d" ]; then
        log_info "Processing initialization files..."
        local mysql_opts=()
        
        # Try different authentication methods
        local auth_attempts=0
        local auth_success=0
        
        while [ $auth_attempts -lt 3 ] && [ $auth_success -eq 0 ]; do
            if [ $auth_attempts -eq 0 ]; then
                # First try: with password
                mysql_opts=( -uroot -p"${MYSQL_ROOT_PASSWORD}" )
            elif [ $auth_attempts -eq 1 ]; then
                # Second try: without password
                mysql_opts=( -uroot )
            else
                # Third try: wait and retry with password
                sleep 5
                mysql_opts=( -uroot -p"${MYSQL_ROOT_PASSWORD}" )
            fi
            
            if mysqladmin -u root -p"${MYSQL_ROOT_PASSWORD}" ping --silent 2>/dev/null; then
                auth_success=1
                break
            fi
            
            auth_attempts=$((auth_attempts + 1))
        done
        
        if [ $auth_success -eq 0 ]; then
            log_error "Failed to authenticate with MySQL after multiple attempts"
            return 1
        fi
        
        for f in /docker-entrypoint-initdb.d/*; do
            # Skip if not a file
            [ -f "$f" ] || continue
            
            log_info "Processing initialization file: $f"
            # Expand environment variables in SQL files before executing
            if [[ "$f" == *.sql ]]; then
                if ! envsubst < "$f" | mysql_retry_auth root "${MYSQL_ROOT_PASSWORD}"; then
                    log_error "Failed to process SQL file: $f"
                    return 1
                fi
            else
                if ! process_init_file "$f" "${mysql_opts[@]}"; then
                    log_error "Failed to process initialization file: $f"
                    return 1
                fi
            fi
            log_info "Successfully processed: $f"
        done
    fi

    # Initialize backup environment after all initialization
    if [ "${BACKUP_ENABLED}" = "true" ]; then
        if ! init_backup_env; then
            log_error "Failed to initialize backup environment"
            return 1
        fi
        # Start backup scheduler for standalone/master roles
        if [ "$ROLE" = "standalone" ] || [ "$ROLE" = "master" ]; then
            if ! start_backup_scheduler; then
                log_warn "Failed to start backup scheduler"
            fi
        fi
    else
        log_info "Skipping backup initialization - backups disabled"
    fi

    return 0
}
