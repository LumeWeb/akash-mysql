#!/bin/bash

# Required dependencies
source "${LIB_PATH}/core/logging.sh"
source "${LIB_PATH}/mysql-fd-tracker.sh"
source "${LIB_PATH}/etcd-paths.sh"

# Cleanup function for graceful shutdown
cleanup() {
    local exit_code=${1:-$?}
    log_info "Initiating cleanup... (exit code: $exit_code)"
    local cleanup_errors=0
    
    # Validate required variables
    if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
        log_error "MYSQL_ROOT_PASSWORD not set"
        cleanup_errors=$((cleanup_errors + 1))
    fi
    
    # Set cleanup flag to prevent new connections
    if [ -n "$MYSQL_PID" ] && kill -0 $MYSQL_PID 2>/dev/null; then
        mysql -e "SET GLOBAL offline_mode = ON;" || true
        
        # Wait for active transactions to complete
        local max_wait=30
        local waited=0
        while [ $waited -lt $max_wait ]; do
            local active_trans=$(mysql -N -e "SELECT COUNT(*) FROM information_schema.innodb_trx;")
            if [ "$active_trans" -eq 0 ]; then
                break
            fi
            sleep 1
            waited=$((waited + 1))
        done
    fi

    # Synchronize process shutdown
    {
        flock -w 30 200 || {
            log_error "Failed to acquire shutdown lock"
            return 1
        }
        
        # Stop role watching if active
        if [ -n "$ROLE_WATCH_PID" ] && kill -0 $ROLE_WATCH_PID 2>/dev/null; then
            kill $ROLE_WATCH_PID
            for i in {1..10}; do
                if ! kill -0 $ROLE_WATCH_PID 2>/dev/null; then
                    break
                fi
                sleep 1
            done
            kill -9 $ROLE_WATCH_PID 2>/dev/null || true
        fi
    } 200>/var/lock/mysql-shutdown.lock

    # Stop lease keepalive if active and cleanup FDs with validation
    if [ -n "$LEASE_KEEPALIVE_PID" ] && kill -0 $LEASE_KEEPALIVE_PID 2>/dev/null; then
        # First close FDs with proper error handling
        for fd in $(ls -1 /proc/$LEASE_KEEPALIVE_PID/fd 2>/dev/null); do
            if [ -e "/proc/$LEASE_KEEPALIVE_PID/fd/$fd" ]; then
                if [ -S "/proc/$LEASE_KEEPALIVE_PID/fd/$fd" ]; then
                    log_info "Cleaning up socket FD: $fd"
                    # Verify FD is still valid before closing
                    if [ -e "/proc/self/fd/$fd" ]; then
                        if ! eval "exec ${fd}>&-" 2>/dev/null; then
                            log_warn "Failed to close socket FD: $fd"
                            # Force close with direct syscall as last resort
                            python3 -c "import os; os.close($fd)" 2>/dev/null || true
                        fi
                    else
                        log_info "FD $fd already closed"
                    fi
                fi
            fi
        done
        
        # Then stop process
        kill $LEASE_KEEPALIVE_PID
        wait $LEASE_KEEPALIVE_PID 2>/dev/null
    fi

    # Remove node from etcd
    if [ -n "$LEASE_ID" ]; then
        etcdctl lease revoke $LEASE_ID || true
        etcdctl del "$(get_node_path $NODE_ID)" || true
    fi

    # Clean up any remaining FDs
    if [ -n "$CURRENT_ROLE" ]; then
        cleanup_orphaned_fds "$CURRENT_ROLE"
    fi

    # If we were master, remove master info
    if [ "$CURRENT_ROLE" = "master" ]; then
        etcdctl del "$ETCD_TOPOLOGY_MASTER" || true
    fi

    # Use flock with proper lock file cleanup
    (
        local lock_file="/var/lock/mysql-shutdown.lock"
        if [ -f "$lock_file" ] && [ ! -e "/proc/$(cat $lock_file 2>/dev/null)/fd/9" 2>/dev/null ]; then
            rm -f "$lock_file"
        fi
        
        if ! flock -n 9; then
            log_error "Could not acquire MySQL shutdown lock"
            cleanup_errors=$((cleanup_errors + 1))
            return 1
        fi
        echo $$ > "$lock_file"
        chmod 644 "$lock_file"
        
        trap 'rm -f "$lock_file"' EXIT
        
        # Atomic PID file read with proper locking and validation
        {
            flock -x -w 10 201 || {
                log_error "Failed to acquire PID file lock"
                return 1
            }
        
            local mysql_pid_file="/var/run/mysqld/mysqld.pid"
            local tmp_pid_file="/var/run/mysqld/mysqld.pid.tmp.$$"
            
            # Atomic read with validation
            if [ -f "$mysql_pid_file" ]; then
                cp -p "$mysql_pid_file" "$tmp_pid_file"
                if [ -f "$tmp_pid_file" ] && [ -s "$tmp_pid_file" ]; then
                    MYSQL_PID=$(cat "$tmp_pid_file")
                    if ! [[ "$MYSQL_PID" =~ ^[0-9]+$ ]]; then
                        log_error "Invalid PID format"
                        rm -f "$tmp_pid_file"
                        return 1
                    fi
                fi
                rm -f "$tmp_pid_file"
            fi
        } 201>/var/lock/mysql-pid.lock
        
        if [ -n "$MYSQL_PID" ] && kill -0 "$MYSQL_PID" 2>/dev/null; then
            log_info "Stopping MySQL gracefully..."

            # Prevent new connections and wait for existing ones
            mysql -e "SET GLOBAL offline_mode = ON;" || log_warn "Failed to set offline mode"

            # Wait for active connections to finish (max 30 seconds)
            local wait_count=0
            while [ $wait_count -lt 30 ]; do
                local active=$(mysql -N -e "SELECT COUNT(*) FROM information_schema.processlist WHERE command != 'Binlog Dump' AND user != 'system user'")
                if [ "$active" -eq 0 ]; then
                    break
                fi
                sleep 1
                wait_count=$((wait_count + 1))
            done

            # Use transaction to ensure atomic flush with proper error handling
            if ! mysql -e "START TRANSACTION; RESET QUERY CACHE; FLUSH TABLES WITH READ LOCK; COMMIT;"; then
                log_warn "Failed to flush caches cleanly"
            fi

            # Role-specific FD cleanup
            log_info "Running role-specific cleanup for role: $CURRENT_ROLE"

            # Clean up various types of leaked FDs based on role
            if [ "$CURRENT_ROLE" = "master" ]; then
                # Clean up binlog FDs
                for fd in $(lsof -p $$ | awk '/mysql-bin\./ {print $4}' | tr -d 'u'); do
                    log_info "Cleaning up binlog FD: $fd"
                    eval "exec ${fd}>&-" 2>/dev/null || true
                done
            elif [ "$CURRENT_ROLE" = "slave" ]; then
                # Clean up relay log FDs
                for fd in $(lsof -p $$ | awk '/relay-bin\./ {print $4}' | tr -d 'u'); do
                    log_info "Cleaning up relay log FD: $fd"
                    eval "exec ${fd}>&-" 2>/dev/null || true
                done
            fi

            # Common cleanup for all roles
            for fd in $(lsof -p $$ | awk '/SQL_CACHE|#sql/ {print $4}' | tr -d 'u'); do
                log_info "Cleaning up killed query FD: $fd"
                eval "exec ${fd}>&-" 2>/dev/null || true
            done

            # Shutdown with timeout
            if ! timeout 30 mysqladmin shutdown -u root -p"$MYSQL_ROOT_PASSWORD"; then
                log_error "Forced shutdown required"
                kill -9 $MYSQL_PID
            fi

            wait $MYSQL_PID 2>/dev/null
        fi
    )

    exit $exit_code
}