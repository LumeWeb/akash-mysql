#!/bin/bash

# Prevent multiple inclusion
[ -n "${MYSQL_STARTUP_SOURCED}" ] && return 0
declare -g MYSQL_STARTUP_SOURCED=1

source "${LIB_PATH}/core/logging.sh"
source "${LIB_PATH}/mysql-common.sh"
source "${LIB_PATH}/mysql-config.sh"
source "${LIB_PATH}/mysql-init-checks.sh"

# Process initialization files
process_init_file() {
    local f="$1"; shift
    local mysql=( "$@" )

    case "$f" in
         *.sh)     log_info "Running $f"; . "$f" ;;
         *.sql)    log_info "Running $f"; mysql_retry "${mysql[@]}" < "$f" >/dev/null 2>&1 ;;
         *.sql.gz) log_info "Running $f"; gunzip -c "$f" | mysql_retry "${mysql[@]}" >/dev/null 2>&1 ;;
         *)        log_info "Ignoring $f" ;;
    esac
}

# Initialize MySQL database if needed
init_mysql() {
    log_info "Checking if MySQL initialization is needed..."
    
    # Check initialization state
    detect_mysql_state
    state_code=$?
    
    case $state_code in
        0)  # Fresh install needed
            log_info "MySQL data directory needs initialization..."
            # Proceed with initialization below
            ;;
        1)  # Valid installation
            log_info "Using existing MySQL installation"
            return 0  # Skip initialization for valid installations
            ;;
        2)  # Recovery needed
            log_error "Recovery needed - initialization aborted"
            return 1
            ;;
        *)  # Unknown state
            log_error "Unknown MySQL state detected"
            return 1
            ;;
    esac

    # Only proceed with initialization for fresh installs
    if [ $state_code -eq 0 ]; then
        
        # Ensure directories exist and are writable
        for dir in "$DATA_DIR" "$RUN_DIR" "$LOG_DIR"; do
            if ! mkdir -p "$dir" 2>/dev/null; then
                log_error "Failed to create directory: $dir"
                return 1
            fi
            if [ ! -w "$dir" ]; then
                log_error "Directory not writable: $dir"
                return 1
            fi
        done

        # Create initialization lock
        touch "${LOCKS_DIR}/init.lock"
            
        # Gracefully stop any running MySQL instances
        if [ -f "${RUN_DIR}/mysqld.pid" ]; then
            mysqladmin shutdown 2>/dev/null || true
            sleep 5
        fi
        
        # Force kill if still running
        pkill mysqld || true
        sleep 2
        
        # Remove socket files
        rm -f "${RUN_DIR}/mysqld.pid"
        rm -f "${MYSQL_SOCKET}"*
        
        # Ensure directory permissions
        if ! mkdir -p "$DATA_DIR" 2>/dev/null; then
            log_error "Failed to create data directory $DATA_DIR"
            return 1
        fi

        # Clean directory but preserve protected paths
        if ! safe_clear_directory "$DATA_DIR"; then
            log_error "Failed to clear data directory"
            return 1
        fi

        # Initialize MySQL with minimal configuration
        if ! mysqld --initialize-insecure --user=mysql \
            --datadir="$DATA_DIR" \
            --basedir=/usr \
            --secure-file-priv="${MYSQL_FILES_DIR}" \
            --pid-file="${RUN_DIR}/mysqld.pid" \
            --log-error="${INIT_ERROR_LOG}" \
            --innodb-buffer-pool-size=32M \
            --innodb-log-file-size=48M \
            --max-connections=10 \
            --performance-schema=OFF \
            --skip-log-bin \
            --skip-mysqlx; then
            log_error "MySQL initialization failed"
            if [ -f "${INIT_ERROR_LOG}" ]; then
                log_error "Initialization error log:"
                cat "${INIT_ERROR_LOG}"
            fi
            return 1
        fi
            
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
            rm -f "${MYSQL_SOCKET}"* 
            rm -f "${RUN_DIR}/mysqld.pid"
            
            # Start with error logging and explicit paths
            SSL_CERT_DIR="${MYSQL_SSL_DIR}" \
            SSL_CERT_FILE="${MYSQL_SSL_CA}" \
            mysqld --skip-grant-tables --skip-networking \
                  --datadir="$DATA_DIR" \
                  --socket="${MYSQL_SOCKET}" \
                  --pid-file="${RUN_DIR}/mysqld.pid" \
                  --log-error="${LOG_DIR}/init-error.log" \
                  --port="${MYSQL_PORT}" \
                  --ssl-ca="${MYSQL_SSL_CA}" \
                  --ssl-cert="${MYSQL_SSL_CERT}" \
                  --ssl-key="${MYSQL_SSL_KEY}" \
                  --ssl-cipher="ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256" \
                  --tls-version="TLSv1.2" \
                  --skip-mysqlx \
                  --user=mysql &
            TEMP_MYSQL_PID=$!
            
            # Give mysqld time to create socket and verify process is running
            sleep 5
            if ! kill -0 $TEMP_MYSQL_PID 2>/dev/null; then
                log_error "Temporary MySQL process died immediately"
                if [ -f "${LOG_DIR}/init-error.log" ]; then
                    log_error "Error log contents:"
                    cat "${LOG_DIR}/init-error.log"
                fi
                return 1
            fi
            
            # Wait for MySQL socket and connectivity
            local max_attempts=30
            local attempt=1
            while [ $attempt -le $max_attempts ]; do
                if [ -S "${MYSQL_SOCKET}" ]; then
                    if mysql --no-defaults -u root --socket="${MYSQL_SOCKET}" -e "SELECT 1" >/dev/null 2>&1; then
                        log_info "Temporary MySQL instance is ready"
                        break
                    fi
                fi
                
                if [ $((attempt % 5)) -eq 0 ]; then
                    log_info "Still waiting for temporary MySQL instance (attempt $attempt/$max_attempts)"
                    if [ -f "${LOG_DIR}/init-error.log" ]; then
                        log_info "Last 5 lines of error log:"
                        tail -n 5 "${LOG_DIR}/init-error.log"
                    fi
                fi
                
                sleep 1
                attempt=$((attempt + 1))
            done
            
            if [ $attempt -gt $max_attempts ]; then
                log_error "Temporary MySQL instance failed to start"
                if [ -f "${LOG_DIR}/init-error.log" ]; then
                    log_error "Error log contents:"
                    cat "${LOG_DIR}/init-error.log"
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
        rm -f "${LOCKS_DIR}/init.lock"
        return 0
    else
        log_info "MySQL data directory already initialized"
        return 0
    fi
}

# Initialize state directory
init_state_dir() {
    mkdir -p "${STATE_DIR}"
    chown mysql:mysql "${STATE_DIR}"
    chmod 750 "${STATE_DIR}"
}

# Call during startup
init_state_dir

# Initialize CA trust directory
init_ca_trust() {
    # Check if CA certificate exists
    if [ ! -f "${MYSQL_SSL_CA}" ]; then
        log_error "CA certificate not found at ${MYSQL_SSL_CA}"
        return 1
    fi

    # Create CA trust directory if it doesn't exist
    if [ ! -d "${MYSQL_SSL_TRUST_DIR}" ]; then
        log_error "CA trust directory ${MYSQL_SSL_TRUST_DIR} does not exist"
        return 1
    fi

    # Clean directory with proper error handling
    find "${MYSQL_SSL_TRUST_DIR}" -type f -delete 2>/dev/null || {
        log_warn "Failed to clean CA trust directory, continuing anyway"
    }
    
    # Copy our CA certificate
    if ! cp "${MYSQL_SSL_CA}" "${MYSQL_SSL_TRUST_DIR}/"; then
        log_error "Failed to copy CA certificate to trust directory"
        return 1
    fi
    
    # Create hash symlinks
    if ! c_rehash "${MYSQL_SSL_TRUST_DIR}" 2>/dev/null; then
        log_error "Failed to create certificate hash links"
        return 1
    fi

    return 0
}

# Generate SSL certificates if needed
if ! generate_ssl_certificates; then
    log_error "Failed to generate SSL certificates"
    return 1
fi

# Initialize CA trust directory
if ! init_ca_trust; then
    log_error "Failed to initialize CA trust directory"
    return 1
fi

# Start MySQL with enhanced configuration and monitoring
start_mysql() {
    local ROLE=$1
    local SERVER_ID=$2
    local HOST=$3
    shift 3
    local MYSQL_ARGS=("$@")

    if [ "$CLUSTER_MODE" = "true" ]; then
        # In cluster mode, start as slave initially
        ROLE="slave"
        log_info "Starting MySQL initially as slave (waiting for ProxySQL topology)"
    else
        # In standalone mode, use standalone role
        ROLE="standalone"
        log_info "Starting MySQL in standalone mode"
    fi
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
    
    # State detection is now handled at a higher level
        
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

    # Initialize MySQL if needed
    if ! init_mysql; then
        log_error "MySQL initialization failed"
        return 1
    fi

    # Ensure plugin directory is clean
    rm -rf "${DATA_DIR}/plugin"/*
    
    # Ensure error log directory exists
    mkdir -p "$(dirname "${ERROR_LOG}")" 2>/dev/null || true
    touch "${ERROR_LOG}" 2>/dev/null || true
    
    # Start log monitoring in background
    monitor_log "${ERROR_LOG}" "${ERROR_MONITOR_PID}"
    
    # Kill any existing MySQL processes
    pkill mysqld || true
    
    # Wait for processes to die and files to be unlocked
    sleep 2
    
    # Remove any stale files
    rm -f "${RUN_DIR}/mysqld.pid"
    rm -f "${MYSQL_SOCKET}"
    
    # Start MySQL
    SSL_CERT_DIR="${MYSQL_SSL_DIR}" \
    SSL_CERT_FILE="${MYSQL_SSL_CA}" \
    mysqld \
        --user=mysql \
        --port="${MYSQL_PORT}" \
        --log-error="${ERROR_LOG}" \
        --skip-mysqlx \
        --datadir="${DATA_DIR}" \
        --pid-file="${RUN_DIR}/mysqld.pid" \
        --socket="${MYSQL_SOCKET}" \
        --ssl-ca="${MYSQL_SSL_CA}" \
        --ssl-cert="${MYSQL_SSL_CERT}" \
        --ssl-key="${MYSQL_SSL_KEY}" \
        --ssl-cipher="ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256" \
        --tls-version="TLSv1.2" &

    MYSQL_PID=$!

    # Wait for MySQL to be ready
    if ! wait_for_mysql $MYSQL_START_TIMEOUT "${MYSQL_ROOT_PASSWORD}"; then
        log_error "MySQL failed to start within timeout"
        kill $MYSQL_PID 2>/dev/null || true
        return 1
    fi

    # Check if MySQL process is still running
    if ! kill -0 $MYSQL_PID 2>/dev/null; then
        log_error "MySQL process died during startup"
        if [ -f "${ERROR_LOG}" ]; then
            log_error "Last 10 lines of error log:"
            tail -n 10 "${ERROR_LOG}" >&2
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
        
        # Filter initialization files based on cluster mode
        local init_files=()
        for f in /docker-entrypoint-initdb.d/*; do
            # Skip if not a file
            [ ! -f "$f" ] && continue
            
            # In non-cluster mode, skip replication user setup
            if [ "$CLUSTER_MODE" != "true" ] && [[ "$f" == *"create-repl-user.sql" ]]; then
                log_info "Skipping replication user setup in non-cluster mode: $f"
                continue
            fi
            
            init_files+=("$f")
        done
        
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
            
            if mysqladmin --socket="${MYSQL_SOCKET}" -u root -p"${MYSQL_ROOT_PASSWORD}" ping --silent >/dev/null 2>&1; then
                auth_success=1
                break
            fi
            
            auth_attempts=$((auth_attempts + 1))
        done
        
        if [ $auth_success -eq 0 ]; then
            log_error "Failed to authenticate with MySQL after multiple attempts"
            return 1
        fi
        
        for f in "${init_files[@]}"; do
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
