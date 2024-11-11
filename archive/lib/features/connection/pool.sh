#!/bin/bash

# Prevent multiple inclusion
[ -n "${CONNECTION_POOL_SOURCED}" ] && return 0
declare -g CONNECTION_POOL_SOURCED=1

# Core dependencies only
source "${LIB_PATH}/core/logging.sh"
source "${LIB_PATH}/core/constants.sh"
source "${LIB_PATH}/core/fd.sh"

# Register for role changes
register_role_change_handler "connection_pool" handle_pool_role_change

# Handle role changes for connection pool
handle_pool_role_change() {
    local new_role=$1
    
    log_info "Connection pool handling role change to: $new_role"
    
    # Wait for existing transactions to complete
    local max_wait=30
    local waited=0
    while [ $waited -lt $max_wait ]; do
        local active_trans=$(mysql -N -e "SELECT COUNT(*) FROM information_schema.innodb_trx")
        if [ "$active_trans" -eq 0 ]; then
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done

    # Adjust pool settings based on role
    case "$new_role" in
        "master"|"standalone")
            mysql -e "
                SET GLOBAL max_connections = 1000;
                SET GLOBAL max_user_connections = 100;
                SET GLOBAL max_connect_errors = 1000;
            "
            ;;
        "slave")
            mysql -e "
                SET GLOBAL max_connections = 500;
                SET GLOBAL max_user_connections = 50;
                SET GLOBAL max_connect_errors = 100;
            "
            ;;
    esac

    return 0
}

# Initialize connection pool monitoring with rate limiting and retry logic
init_connection_pool() {
    local retries=3
    local retry_delay=5
    local attempt=1
    
    while [ $attempt -le $retries ]; do
        if mysql_retry "mysql -e \"
            SET GLOBAL max_connect_errors = 1000;
            SET GLOBAL max_connections_per_hour = 3600;
            SET GLOBAL max_user_connections = 100;
            SET GLOBAL connect_timeout = 5;
            SET GLOBAL thread_pool_size = $(($(nproc) * 2));
            SET GLOBAL thread_pool_idle_timeout = 60;
            SET GLOBAL thread_pool_stall_limit = 100;
            SET GLOBAL thread_handling = 'pool-of-threads';\""; then
            
            log_info "Connection pool configured successfully"
            monitor_connection_pool &
            return 0
        fi
        
        log_warn "Failed to configure connection pool (attempt $attempt/$retries)"
        sleep $((retry_delay * attempt))
        attempt=$((attempt + 1))
    done
    
    log_error "Failed to configure connection pool after $retries attempts"
    return 1
}

# Monitor and manage connection pool
monitor_connection_pool() {
    while true; do
        # Get current connection stats
        local stats
        stats=$(mysql -N -e "
            SELECT VARIABLE_VALUE 
            FROM performance_schema.global_status 
            WHERE VARIABLE_NAME IN (
                'Threads_connected',
                'Threads_running',
                'Connection_errors_max_connections',
                'Aborted_connects'
            );")
        
        local connected=$(echo "$stats" | sed -n '1p')
        local running=$(echo "$stats" | sed -n '2p')
        local max_conn_errors=$(echo "$stats" | sed -n '3p')
        local aborted=$(echo "$stats" | sed -n '4p')
        
        # Get max_connections setting
        local max_connections=$(mysql -N -e "SHOW VARIABLES LIKE 'max_connections'" | awk '{print $2}')
        
        # Calculate usage percentages
        local conn_usage=$((connected * 100 / max_connections))
        
        # Adjust pool size based on usage
        if [ $conn_usage -gt 80 ]; then
            log_warn "High connection usage ($conn_usage%). Increasing max_connections"
            mysql -e "SET GLOBAL max_connections = $((max_connections * 120 / 100))"
        fi

        # Check for connection errors
        if [ $max_conn_errors -gt 0 ] || [ $aborted -gt 0 ]; then
            log_warn "Connection errors detected: $max_conn_errors max_connections errors, $aborted aborted"
            
            # Reset error counters if needed
            if [ $max_conn_errors -gt 1000 ]; then
                mysql -e "FLUSH HOSTS;"
                log_info "Reset connection error counters"
            fi
        fi
        
        sleep 60
    done
}
