#!/bin/bash

# Prevent multiple inclusion
[ -n "${MYSQL_FD_TRACKER_SOURCED}" ] && return 0
MYSQL_FD_TRACKER_SOURCED=1

source "${LIB_PATH}/core/fd.sh"

# Track MySQL-specific file descriptors
declare -A MYSQL_FD_TYPES=(
    ["socket"]="MySQL socket connections"
    ["table"]="Table file handles"
    ["index"]="Index file handles"
    ["temp"]="Temporary files"
    ["binlog"]="Binary log files"
)

# Initialize MySQL FD tracking
init_mysql_fd_tracker() {
    local role=${1:-standalone}  # Default to standalone if no role provided
    # Start FD cleanup with role awareness
    cleanup_orphaned_fds "$role"
}

# Track MySQL file descriptor
track_mysql_fd() {
    local fd=$1
    local type=$2
    local description=$3
    
    if [[ ! "${MYSQL_FD_TYPES[$type]+isset}" ]]; then
        log_error "Invalid MySQL FD type: $type"
        return 1
    fi
    
    # Special handling for socket FDs with validation
    if [ "$type" = "socket" ]; then
        if [ ! -e "/proc/$$/fd/$fd" ]; then
            log_error "FD $fd does not exist"
            return 1
        fi
        if [ ! -S "/proc/$$/fd/$fd" ]; then
            log_error "FD $fd is not a socket"
            return 1
        fi
        # Enhanced socket validation
        if ! ss -p | grep -q "pid=$$/fd=$fd"; then
            log_error "Socket FD $fd is not connected"
            return 1
        fi
        
        # Check for half-closed sockets
        if ss -p | grep "pid=$$/fd=$fd" | grep -q "CLOSE-WAIT\|FIN-WAIT"; then
            log_error "Socket FD $fd is in inconsistent state"
            eval "exec ${fd}>&-" 2>/dev/null || true
            return 1
        fi
        
        log_info "Tracking MySQL socket FD: $fd"
    fi
    
    # Check for leaked FDs from aborted connections and queries
    if [ "$type" = "socket" ] || [ "$type" = "temp" ]; then
        # Check aborted connections with retry
        local max_attempts=3
        local attempt=1
        local aborted_count=0
        local aborted_queries=0
        
        while [ $attempt -le $max_attempts ]; do
            if aborted_count=$(mysql -N -e "SHOW GLOBAL STATUS LIKE 'Aborted_connects'" | awk '{print $2}') && \
               aborted_queries=$(mysql -N -e "SHOW GLOBAL STATUS LIKE 'Aborted_clients'" | awk '{print $2}'); then
                break
            fi
            sleep 1
            attempt=$((attempt + 1))
        done
        
        if [ "$aborted_count" -gt 0 ] || [ "$aborted_queries" -gt 0 ]; then
            log_warn "Detected $aborted_count aborted connections, $aborted_queries aborted queries" 
            
            # Clean up leaked FDs
            for proc_fd in /proc/$$/fd/*; do
                if [ -e "$proc_fd" ]; then
                    if [ -S "$proc_fd" ] || [ -f "$proc_fd" ]; then
                        if ! grep -q "$proc_fd" <(lsof -p $$ 2>/dev/null); then
                            log_warn "Found leaked FD: $proc_fd"
                            eval "exec ${proc_fd}>&-" 2>/dev/null || {
                                log_error "Failed to close leaked FD: $proc_fd"
                                # Force close with direct syscall
                                python3 -c "import os; os.close($proc_fd)" 2>/dev/null || true
                            }
                        fi
                    fi
                fi
            done
        fi
    fi
    
    track_fd "$fd" "mysql_${type}:${description}"
}

# Cleanup orphaned FDs from various sources
cleanup_orphaned_fds() {
    local role=${1:-standalone}
    while true; do
        # Check socket FDs from client connections
        local active_connections=$(mysql -N -e "SELECT id FROM information_schema.processlist")
        for fd in /proc/$$/fd/*; do
            if [ -S "$fd" ]; then
                local fd_num=$(basename "$fd")
                local is_orphaned=true
                
                for conn in $active_connections; do
                    if ss -p | grep -q "pid=$$/fd=$fd_num.*$conn"; then
                        is_orphaned=false
                        break
                    fi
                done
                
                if [ "$is_orphaned" = true ]; then
                    log_warn "Found orphaned socket FD: $fd_num"
                    eval "exec ${fd_num}>&-" 2>/dev/null || true
                fi
            fi
        done

        # Check for abandoned LOAD DATA INFILE FDs
        local load_data_fds=$(lsof -p $$ | grep -E '/tmp/ML-|/tmp/SQL')
        if [ -n "$load_data_fds" ]; then
            echo "$load_data_fds" | while read fd_info; do
                local fd_num
                fd_num=$(echo "$fd_info" | awk '{print $4}' | tr -d 'u')
                log_warn "Found abandoned LOAD DATA INFILE FD: $fd_num" 
                eval "exec ${fd_num}>&-" 2>/dev/null || true
            done
        fi


        # Only check temp tables on master/standalone to avoid replication issues
        if [ "$role" = "master" ] || [ "$role" = "standalone" ]; then
            # Check for temp table FDs from crashed operations
            local temp_fds=$(lsof -p $$ | grep -E '#sql.*\.ibd$|#sql.*\.frm$')
            if [ -n "$temp_fds" ]; then
                echo "$temp_fds" | while read fd_info; do
                    fd_num=$(echo "$fd_info" | awk '{print $4}' | tr -d 'u')
                    file_path=$(echo "$fd_info" | awk '{print $9}')
                    # Check if temp table is still in use
                    if ! mysql -N -e "SELECT * FROM information_schema.TABLES WHERE TABLE_NAME LIKE '#sql%'" | grep -q "$(basename "$file_path")"; then
                        log_warn "Found orphaned temp table FD: $fd_num"
                        eval "exec ${fd_num}>&-" 2>/dev/null || true
                    fi
                done
            fi
        fi

        # Role-specific query cache cleanup
        if [ "$role" = "master" ] || [ "$role" = "standalone" ]; then
            # Check for leaked query cache FDs
            local cache_fds=$(lsof -p $$ | grep -E 'query_cache|qc_[0-9]+\.bin')
            if [ -n "$cache_fds" ]; then
                echo "$cache_fds" | while read fd_info; do
                    local fd_num=$(echo "$fd_info" | awk '{print $4}' | tr -d 'u')
                    # Verify if query cache is still enabled
                    local cache_enabled=$(mysql -N -e "SHOW VARIABLES LIKE 'query_cache_type'" | awk '{print $2}')
                    if [ "$cache_enabled" = "OFF" ]; then
                        log_warn "Found leaked query cache FD: $fd_num"
                        eval "exec ${fd_num}>&-" 2>/dev/null || true
                    fi
                done
            fi
        fi

        # Role-specific replication FD cleanup
        if [ "$role" = "slave" ]; then
            # Check for leaked replication thread FDs
            local replica_fds=$(lsof -p $$ | grep -E 'relay-bin|master.info|relay-log.info')
            if [ -n "$replica_fds" ]; then
                # Verify if replication is actually running
                local slave_running=$(mysql -N -e "SHOW SLAVE STATUS\G" | grep "Slave_IO_Running: Yes")
                if [ -z "$slave_running" ]; then
                    echo "$replica_fds" | while read fd_info; do
                        local fd_num=$(echo "$fd_info" | awk '{print $4}' | tr -d 'u')
                        log_warn "Found leaked replication FD: $fd_num"
                        eval "exec ${fd_num}>&-" 2>/dev/null || true
                    done
                fi
            fi
        elif [ "$role" = "master" ]; then
            # Enhanced binlog FD cleanup for master with backup awareness
            local binlog_fds=$(lsof -p $$ | grep -E 'mysql-bin\.[0-9]+$')
            if [ -n "$binlog_fds" ]; then
                echo "$binlog_fds" | while read fd_info; do
                    local fd_num=$(echo "$fd_info" | awk '{print $4}' | tr -d 'u')
                    local binlog_file=$(echo "$fd_info" | awk '{print $9}')
                    
                    # Check if binlog is still needed by any slave
                    local needed_by_slave=0
                    while read slave_status; do
                        local slave_binlog=$(echo "$slave_status" | awk '{print $1}')
                        if [ "$(basename "$binlog_file")" = "$slave_binlog" ]; then
                            needed_by_slave=1
                            break
                        fi
                    done < <(mysql -N -e "SHOW SLAVE HOSTS" 2>/dev/null)
                    
                    # Check for active backup processes
                    local backup_active=0
                    if pgrep -f "xtrabackup|mariabackup|mysqlbackup" >/dev/null; then
                        backup_active=1
                        log_info "Backup in progress, preserving binlog FDs"
                    fi
                    
                    # Only clean up if not needed by slave or backup
                    if [ "$needed_by_slave" -eq 0 ] && [ "$backup_active" -eq 0 ] && \
                       ! mysql -N -e "SHOW BINARY LOGS" | grep -q "$(basename "$binlog_file")"; then
                        log_warn "Found leaked binlog FD: $fd_num (not needed by slave or backup)"
                        eval "exec ${fd_num}>&-" 2>/dev/null || true
                    fi
                done
            fi
            
            # Check for temporary binlog index FDs
            local binlog_index_fds=$(lsof -p $$ | grep -E 'mysql-bin\.index\.[0-9]+$')
            if [ -n "$binlog_index_fds" ]; then
                echo "$binlog_index_fds" | while read fd_info; do
                    local fd_num=$(echo "$fd_info" | awk '{print $4}' | tr -d 'u')
                    log_warn "Found temporary binlog index FD: $fd_num"
                    eval "exec ${fd_num}>&-" 2>/dev/null || true
                done
            fi
        fi

        # Check for FDs holding table locks from crashed connections
        local locked_tables=$(mysql -N -e "SELECT OBJECT_NAME FROM performance_schema.table_handles WHERE OWNER_THREAD_ID NOT IN (SELECT THREAD_ID FROM performance_schema.threads WHERE THREAD_ID=PROCESSLIST_ID)")
        if [ -n "$locked_tables" ]; then
            echo "$locked_tables" | while read table; do
                local lock_fds=$(lsof -p $$ | grep -E "${table}\.(frm|ibd)$")
                if [ -n "$lock_fds" ]; then
                    echo "$lock_fds" | while read fd_info; do
                        local fd_num=$(echo "$fd_info" | awk '{print $4}' | tr -d 'u')
                        log_error "Found FD holding lock on $table: $fd_num"
                        eval "exec ${fd_num}>&-" 2>/dev/null || true
                    done
                fi
            done
        fi

        # Role-specific temporary file cleanup for master/standalone
        if [ "$role" = "master" ] || [ "$role" = "standalone" ]; then
            # Clean up temporary files from LOAD DATA
            local load_temp_fds=$(lsof -p $$ | grep -E '/tmp/ML-|/var/lib/mysql-files/')
            if [ -n "$load_temp_fds" ]; then
                echo "$load_temp_fds" | while read fd_info; do
                    local fd_num
                    local file_path
                    fd_num=$(echo "$fd_info" | awk '{print $4}' | tr -d 'u')
                    file_path=$(echo "$fd_info" | awk '{print $9}')
                    # Check if file is still needed
                    if ! mysql -N -e "SHOW PROCESSLIST" | grep -q "LOAD DATA"; then
                        log_warn "Found leaked LOAD DATA temp file FD: $fd_num"
                        eval "exec ${fd_num}>&-" 2>/dev/null || true
                    fi
                done
            fi
        fi

        # Check for leaked prepared statement FDs
        local stmt_fds=$(lsof -p $$ | grep -E 'prepared-stmt-|stmt-registry')
        if [ -n "$stmt_fds" ]; then
            echo "$stmt_fds" | while read fd_info; do
                local fd_num=$(echo "$fd_info" | awk '{print $4}' | tr -d 'u')
                # Verify if statement is still in use
                if ! mysql -N -e "SHOW PROCESSLIST" | grep -q "Execute"; then
                    log_warn "Found leaked prepared statement FD: $fd_num"
                    eval "exec ${fd_num}>&-" 2>/dev/null || true
                fi
            done
        fi

        # Role-specific InnoDB cleanup for master/standalone
        if [ "$role" = "master" ] || [ "$role" = "standalone" ]; then
            # Check for ALTER TABLE FDs
            local alter_fds=$(lsof -p $$ | grep -E '#sql-.*\.ibd$')
            if [ -n "$alter_fds" ]; then
                echo "$alter_fds" | while read fd_info; do
                    local fd_num=$(echo "$fd_info" | awk '{print $4}' | tr -d 'u')
                    # Verify if ALTER is still running
                    if ! mysql -N -e "SHOW PROCESSLIST" | grep -q "ALTER TABLE"; then
                        log_warn "Found leaked ALTER TABLE FD: $fd_num"
                        eval "exec ${fd_num}>&-" 2>/dev/null || true
                    fi
                done
            fi

            # Check for undo log FDs
            local undo_fds=$(lsof -p $$ | grep -E 'undo[0-9]+$')
            if [ -n "$undo_fds" ]; then
                echo "$undo_fds" | while read fd_info; do
                    local fd_num=$(echo "$fd_info" | awk '{print $4}' | tr -d 'u')
                    local file_path=$(echo "$fd_info" | awk '{print $9}')
                    # Check if undo log is still needed
                    if ! mysql -N -e "SELECT COUNT(*) FROM information_schema.innodb_trx" | grep -q "^0$"; then
                        log_info "Active transactions found, preserving undo log FDs"
                        continue
                    fi
                    log_warn "Found potentially leaked undo log FD: $fd_num"
                    eval "exec ${fd_num}>&-" 2>/dev/null || true
                done
            fi
        fi

        # Role-specific InnoDB buffer pool cleanup for master/standalone
        if [ "$role" = "master" ] || [ "$role" = "standalone" ]; then
            # Check for buffer pool dump FDs
            local buffer_pool_fds=$(lsof -p $$ | grep -E 'ib_buffer_pool$')
            if [ -n "$buffer_pool_fds" ]; then
                echo "$buffer_pool_fds" | while read fd_info; do
                    local fd_num=$(echo "$fd_info" | awk '{print $4}' | tr -d 'u')
                    # Verify if dump is in progress
                    if ! mysql -N -e "SHOW ENGINE INNODB STATUS\G" | grep -q "buffer pool dump in progress"; then
                        log_warn "Found leaked buffer pool dump FD: $fd_num"
                        eval "exec ${fd_num}>&-" 2>/dev/null || true
                    fi
                done
            fi

            # Check for InnoDB log file FDs
            local log_fds=$(lsof -p $$ | grep -E 'ib_logfile[0-9]+$')
            if [ -n "$log_fds" ]; then
                echo "$log_fds" | while read fd_info; do
                    local fd_num=$(echo "$fd_info" | awk '{print $4}' | tr -d 'u')
                    local file_path=$(echo "$fd_info" | awk '{print $9}')
                    # Check if log file is still active
                    if ! mysql -N -e "SHOW ENGINE INNODB STATUS\G" | grep -q "$(basename "$file_path")"; then
                        log_warn "Found potentially leaked log file FD: $fd_num"
                        eval "exec ${fd_num}>&-" 2>/dev/null || true
                    fi
                done
            fi
        fi

        # Role-specific InnoDB purge and DDL cleanup for master/standalone
        if [ "$role" = "master" ] || [ "$role" = "standalone" ]; then
            # Check for purge thread FDs
            local purge_fds=$(lsof -p $$ | grep -E 'innodb_purge_[0-9]+')
            if [ -n "$purge_fds" ]; then
                echo "$purge_fds" | while read fd_info; do
                    local fd_num=$(echo "$fd_info" | awk '{print $4}' | tr -d 'u')
                    # Verify if purge is still running
                    if ! mysql -N -e "SHOW ENGINE INNODB STATUS\G" | grep -q "purge state: running"; then
                        log_warn "Found leaked purge thread FD: $fd_num"
                        eval "exec ${fd_num}>&-" 2>/dev/null || true
                    fi
                done
            fi

            # Check for online DDL FDs
            local ddl_fds=$(lsof -p $$ | grep -E '#sql-alter-.*\.(frm|ibd)$')
            if [ -n "$ddl_fds" ]; then
                echo "$ddl_fds" | while read fd_info; do
                    local fd_num=$(echo "$fd_info" | awk '{print $4}' | tr -d 'u')
                    local file_path=$(echo "$fd_info" | awk '{print $9}')
                    # Check if DDL is still running
                    if ! mysql -N -e "SELECT * FROM information_schema.INNODB_TRX WHERE trx_query LIKE 'ALTER%'" | grep -q .; then
                        log_warn "Found leaked online DDL FD: $fd_num for $file_path"
                        eval "exec ${fd_num}>&-" 2>/dev/null || true
                    fi
                done
            fi
        fi

        # Role-specific InnoDB change buffer and hash index cleanup for master/standalone
        if [ "$role" = "master" ] || [ "$role" = "standalone" ]; then
            # Check for change buffer FDs
            local change_buffer_fds=$(lsof -p $$ | grep -E 'ibuf[0-9]*')
            if [ -n "$change_buffer_fds" ]; then
                echo "$change_buffer_fds" | while read fd_info; do
                    local fd_num=$(echo "$fd_info" | awk '{print $4}' | tr -d 'u')
                    # Verify if change buffer is still active
                    if ! mysql -N -e "SHOW ENGINE INNODB STATUS\G" | grep -q "change buffer entries"; then
                        log_warn "Found leaked change buffer FD: $fd_num"
                        eval "exec ${fd_num}>&-" 2>/dev/null || true
                    fi
                done
            fi

            # Check for adaptive hash index FDs
            local hash_fds=$(lsof -p $$ | grep -E 'hash_index_[0-9]+')
            if [ -n "$hash_fds" ]; then
                echo "$hash_fds" | while read fd_info; do
                    local fd_num=$(echo "$fd_info" | awk '{print $4}' | tr -d 'u')
                    # Check if adaptive hash indexing is enabled
                    if ! mysql -N -e "SHOW VARIABLES LIKE 'innodb_adaptive_hash_index'" | grep -q "ON"; then
                        log_warn "Found leaked adaptive hash index FD: $fd_num"
                        eval "exec ${fd_num}>&-" 2>/dev/null || true
                    fi
                done
            fi
        fi

        # Role-specific InnoDB compression and encryption cleanup for master/standalone
        if [ "$role" = "master" ] || [ "$role" = "standalone" ]; then
            # Check for compression thread FDs
            local compress_fds=$(lsof -p $$ | grep -E 'ibtmp[0-9]*|\.cfp$')
            if [ -n "$compress_fds" ]; then
                echo "$compress_fds" | while read fd_info; do
                    local fd_num=$(echo "$fd_info" | awk '{print $4}' | tr -d 'u')
                    # Verify if compression is still active
                    if ! mysql -N -e "SHOW VARIABLES LIKE 'innodb_compression_level'" | grep -q "[1-9]"; then
                        log_warn "Found leaked compression FD: $fd_num"
                        eval "exec ${fd_num}>&-" 2>/dev/null || true
                    fi
                done
            fi

            # Check for encryption thread FDs
            local encrypt_fds=$(lsof -p $$ | grep -E '\.enc$|\.key$')
            if [ -n "$encrypt_fds" ]; then
                echo "$encrypt_fds" | while read fd_info; do
                    local fd_num=$(echo "$fd_info" | awk '{print $4}' | tr -d 'u')
                    # Check if encryption is enabled
                    if ! mysql -N -e "SHOW VARIABLES LIKE 'innodb_encrypt_tables'" | grep -q "ON"; then
                        log_warn "Found leaked encryption FD: $fd_num"
                        eval "exec ${fd_num}>&-" 2>/dev/null || true
                    fi
                done
            fi
        fi

        # Role-specific InnoDB doublewrite and redo log cleanup for master/standalone
        if [ "$role" = "master" ] || [ "$role" = "standalone" ]; then
            # Check for doublewrite buffer FDs
            local doublewrite_fds=$(lsof -p $$ | grep -E 'ib_doublewrite')
            if [ -n "$doublewrite_fds" ]; then
                echo "$doublewrite_fds" | while read fd_info; do
                    local fd_num=$(echo "$fd_info" | awk '{print $4}' | tr -d 'u')
                    # Verify if doublewrite buffer is enabled
                    if ! mysql -N -e "SHOW VARIABLES LIKE 'innodb_doublewrite'" | grep -q "ON"; then
                        log_warn "Found leaked doublewrite buffer FD: $fd_num"
                        eval "exec ${fd_num}>&-" 2>/dev/null || true
                    fi
                done
            fi

            # Check for redo log FDs
            local redo_fds=$(lsof -p $$ | grep -E 'ib_redo[0-9]+')
            if [ -n "$redo_fds" ]; then
                echo "$redo_fds" | while read fd_info; do
                    local fd_num=$(echo "$fd_info" | awk '{print $4}' | tr -d 'u')
                    # Check if redo logging is enabled
                    if ! mysql -N -e "SHOW VARIABLES LIKE 'innodb_redo_log_enabled'" | grep -q "ON"; then
                        log_warn "Found leaked redo log FD: $fd_num"
                        eval "exec ${fd_num}>&-" 2>/dev/null || true
                    fi
                done
            fi
        fi

        # Role-specific InnoDB read-ahead and prefetch cleanup for master/standalone
        if [ "$role" = "master" ] || [ "$role" = "standalone" ]; then
            # Check for read-ahead thread FDs
            local readahead_fds=$(lsof -p $$ | grep -E 'ib_readahead_[0-9]+')
            if [ -n "$readahead_fds" ]; then
                echo "$readahead_fds" | while read fd_info; do
                    local fd_num=$(echo "$fd_info" | awk '{print $4}' | tr -d 'u')
                    # Verify if read-ahead is enabled
                    if ! mysql -N -e "SHOW VARIABLES LIKE 'innodb_read_ahead_threshold'" | grep -q "[1-9]"; then
                        log_warn "Found leaked read-ahead FD: $fd_num"
                        eval "exec ${fd_num}>&-" 2>/dev/null || true
                    fi
                done
            fi

            # Check for prefetch thread FDs
            local prefetch_fds=$(lsof -p $$ | grep -E 'ib_prefetch_[0-9]+')
            if [ -n "$prefetch_fds" ]; then
                echo "$prefetch_fds" | while read fd_info; do
                    local fd_num=$(echo "$fd_info" | awk '{print $4}' | tr -d 'u')
                    # Check if prefetch is still active
                    if ! mysql -N -e "SHOW ENGINE INNODB STATUS\G" | grep -q "prefetch state: active"; then
                        log_warn "Found leaked prefetch FD: $fd_num"
                        eval "exec ${fd_num}>&-" 2>/dev/null || true
                    fi
                done
            fi
        fi

        # Role-specific InnoDB background thread cleanup for master/standalone
        if [ "$role" = "master" ] || [ "$role" = "standalone" ]; then
            # Check for background thread FDs
            local bg_thread_fds=$(lsof -p $$ | grep -E 'innodb_bg_[0-9]+|innodb_io_[0-9]+')
            if [ -n "$bg_thread_fds" ]; then
                echo "$bg_thread_fds" | while read fd_info; do
                    local fd_num=$(echo "$fd_info" | awk '{print $4}' | tr -d 'u')
                    # Verify if thread is still active
                    if ! mysql -N -e "SHOW ENGINE INNODB STATUS\G" | grep -q "background thread.*running"; then
                        log_warn "Found leaked background thread FD: $fd_num"
                        eval "exec ${fd_num}>&-" 2>/dev/null || true
                    fi
                done
            fi
        fi

        # Role-specific InnoDB merge and sort cleanup for master/standalone
        if [ "$role" = "master" ] || [ "$role" = "standalone" ]; then
            # Check for merge thread FDs
            local merge_fds=$(lsof -p $$ | grep -E 'ib_merge_[0-9]+|merge_temp_[0-9]+')
            if [ -n "$merge_fds" ]; then
                echo "$merge_fds" | while read fd_info; do
                    local fd_num=$(echo "$fd_info" | awk '{print $4}' | tr -d 'u')
                    # Verify if merge operation is still active
                    if ! mysql -N -e "SHOW ENGINE INNODB STATUS\G" | grep -q "merge.*running"; then
                        log_warn "Found leaked merge thread FD: $fd_num"
                        eval "exec ${fd_num}>&-" 2>/dev/null || true
                    fi
                done
            fi

            # Check for sort thread FDs
            local sort_fds=$(lsof -p $$ | grep -E 'ib_sort_[0-9]+|sort_temp_[0-9]+')
            if [ -n "$sort_fds" ]; then
                echo "$sort_fds" | while read fd_info; do
                    local fd_num=$(echo "$fd_info" | awk '{print $4}' | tr -d 'u')
                    # Verify if sort operation is still active
                    if ! mysql -N -e "SHOW ENGINE INNODB STATUS\G" | grep -q "sort.*running"; then
                        log_warn "Found leaked sort thread FD: $fd_num"
                        eval "exec ${fd_num}>&-" 2>/dev/null || true
                    fi
                done
            fi
        fi

        # Role-specific InnoDB page tracking cleanup for master/standalone
        if [ "$role" = "master" ] || [ "$role" = "standalone" ]; then
            # Check for page tracking thread FDs
            local tracking_fds=$(lsof -p $$ | grep -E 'ib_page_track\.[0-9]+|ib_modified_pages\.[0-9]+')
            if [ -n "$tracking_fds" ]; then
                echo "$tracking_fds" | while read fd_info; do
                    local fd_num=$(echo "$fd_info" | awk '{print $4}' | tr -d 'u')
                    # Verify if page tracking is still active
                    if ! mysql -N -e "SHOW ENGINE INNODB STATUS\G" | grep -q "page tracking active"; then
                        log_warn "Found leaked page tracking FD: $fd_num"
                        eval "exec ${fd_num}>&-" 2>/dev/null || true
                    fi
                done
            fi

            # Check for monitoring thread FDs
            local monitor_fds=$(lsof -p $$ | grep -E 'ib_monitor_[0-9]+|innodb_monitor\.[0-9]+')
            if [ -n "$monitor_fds" ]; then
                echo "$monitor_fds" | while read fd_info; do
                    local fd_num=$(echo "$fd_info" | awk '{print $4}' | tr -d 'u')
                    # Verify if monitoring thread is still active
                    if ! mysql -N -e "SHOW ENGINE INNODB STATUS\G" | grep -q "monitor thread.*running"; then
                        log_warn "Found leaked monitor thread FD: $fd_num"
                        eval "exec ${fd_num}>&-" 2>/dev/null || true
                    fi
                done
            fi
        fi

        # Role-specific InnoDB temporary tablespace cleanup for master/standalone
        if [ "$role" = "master" ] || [ "$role" = "standalone" ]; then
            # Check for temporary tablespace FDs
            local temp_tablespace_fds=$(lsof -p $$ | grep -E 'ibtmp[0-9]+$')
            if [ -n "$temp_tablespace_fds" ]; then
                echo "$temp_tablespace_fds" | while read fd_info; do
                    local fd_num=$(echo "$fd_info" | awk '{print $4}' | tr -d 'u')
                    # Verify if temp tablespace is still needed
                    if ! mysql -N -e "SELECT COUNT(*) FROM information_schema.INNODB_TEMP_TABLE_INFO" | grep -q "[1-9]"; then
                        log_warn "Found leaked temporary tablespace FD: $fd_num"
                        eval "exec ${fd_num}>&-" 2>/dev/null || true
                    fi
                done
            fi
        fi

        # Role-specific InnoDB buffer pool resize cleanup for master/standalone
        if [ "$role" = "master" ] || [ "$role" = "standalone" ]; then
            # Check for buffer pool resize operation FDs
            local resize_fds=$(lsof -p $$ | grep -E 'ib_buffer_pool\.[0-9]+$')
            if [ -n "$resize_fds" ]; then
                echo "$resize_fds" | while read fd_info; do
                    local fd_num=$(echo "$fd_info" | awk '{print $4}' | tr -d 'u')
                    # Verify if resize operation is still active
                    if ! mysql -N -e "SHOW ENGINE INNODB STATUS\G" | grep -q "buffer pool resize in progress"; then
                        log_warn "Found leaked buffer pool resize FD: $fd_num"
                        eval "exec ${fd_num}>&-" 2>/dev/null || true
                    fi
                done
            fi
        fi

        # Role-specific InnoDB fulltext index cleanup for master/standalone
        if [ "$role" = "master" ] || [ "$role" = "standalone" ]; then
            # Check for fulltext index thread FDs
            local fulltext_fds=$(lsof -p $$ | grep -E 'ft_index\.[0-9]+|fts_[0-9]+\.doc_id')
            if [ -n "$fulltext_fds" ]; then
                echo "$fulltext_fds" | while read fd_info; do
                    local fd_num=$(echo "$fd_info" | awk '{print $4}' | tr -d 'u')
                    # Verify if fulltext indexing is still active
                    if ! mysql -N -e "SELECT COUNT(*) FROM information_schema.INNODB_FT_CONFIG" | grep -q "[1-9]"; then
                        log_warn "Found leaked fulltext index FD: $fd_num"
                        eval "exec ${fd_num}>&-" 2>/dev/null || true
                    fi
                done
            fi

            # Check for online DDL log thread FDs
            local ddl_log_fds=$(lsof -p $$ | grep -E 'ddl_log\.[0-9]+|online_log\.[0-9]+')
            if [ -n "$ddl_log_fds" ]; then
                echo "$ddl_log_fds" | while read fd_info; do
                    local fd_num=$(echo "$fd_info" | awk '{print $4}' | tr -d 'u')
                    # Verify if online DDL is still active
                    if ! mysql -N -e "SELECT COUNT(*) FROM information_schema.INNODB_TRX WHERE trx_query LIKE 'ALTER%'" | grep -q "[1-9]"; then
                        log_warn "Found leaked online DDL log FD: $fd_num"
                        eval "exec ${fd_num}>&-" 2>/dev/null || true
                    fi
                done
            fi

            # Check for encryption thread FDs
            local encrypt_thread_fds=$(lsof -p $$ | grep -E 'innodb_encrypt_thread\.[0-9]+|innodb_master_key\.[0-9]+')
            if [ -n "$encrypt_thread_fds" ]; then
                echo "$encrypt_thread_fds" | while read fd_info; do
                    local fd_num=$(echo "$fd_info" | awk '{print $4}' | tr -d 'u')
                    # Verify if encryption threads are still active
                    if ! mysql -N -e "SHOW VARIABLES LIKE 'innodb_encrypt_tables'" | grep -q "ON"; then
                        log_warn "Found leaked encryption thread FD: $fd_num"
                        eval "exec ${fd_num}>&-" 2>/dev/null || true
                    fi
                done
            fi

            # Check for buffer pool thread FDs
            local buffer_thread_fds=$(lsof -p $$ | grep -E 'innodb_buffer_pool_[0-9]+|buf_dump_thread\.[0-9]+')
            if [ -n "$buffer_thread_fds" ]; then
                echo "$buffer_thread_fds" | while read fd_info; do
                    local fd_num=$(echo "$fd_info" | awk '{print $4}' | tr -d 'u')
                    # Verify if buffer pool threads are still active
                    if ! mysql -N -e "SHOW ENGINE INNODB STATUS\G" | grep -q "buffer pool thread.*running"; then
                        log_warn "Found leaked buffer pool thread FD: $fd_num"
                        eval "exec ${fd_num}>&-" 2>/dev/null || true
                    fi
                done
            fi

            # Check for page cleaner thread FDs
            local cleaner_thread_fds=$(lsof -p $$ | grep -E 'innodb_page_cleaner_[0-9]+|page_cleaner\.[0-9]+')
            if [ -n "$cleaner_thread_fds" ]; then
                echo "$cleaner_thread_fds" | while read fd_info; do
                    local fd_num=$(echo "$fd_info" | awk '{print $4}' | tr -d 'u')
                    # Verify if page cleaner threads are still active
                    if ! mysql -N -e "SHOW ENGINE INNODB STATUS\G" | grep -q "page_cleaner.*running"; then
                        log_warn "Found leaked page cleaner thread FD: $fd_num"
                        eval "exec ${fd_num}>&-" 2>/dev/null || true
                    fi
                done
            fi

            # Check for statistics thread FDs
            local stats_thread_fds=$(lsof -p $$ | grep -E 'innodb_stats_thread_[0-9]+|stats_background\.[0-9]+')
            if [ -n "$stats_thread_fds" ]; then
                echo "$stats_thread_fds" | while read fd_info; do
                    local fd_num=$(echo "$fd_info" | awk '{print $4}' | tr -d 'u')
                    # Verify if stats threads are still active
                    if ! mysql -N -e "SHOW ENGINE INNODB STATUS\G" | grep -q "stats_thread.*running"; then
                        log_warn "Found leaked statistics thread FD: $fd_num"
                        eval "exec ${fd_num}>&-" 2>/dev/null || true
                    fi
                done
            fi

            # Check for metadata thread FDs
            local metadata_thread_fds=$(lsof -p $$ | grep -E 'innodb_dict_[0-9]+|dict_background\.[0-9]+')
            if [ -n "$metadata_thread_fds" ]; then
                echo "$metadata_thread_fds" | while read fd_info; do
                    local fd_num=$(echo "$fd_info" | awk '{print $4}' | tr -d 'u')
                    # Verify if metadata threads are still active
                    if ! mysql -N -e "SHOW ENGINE INNODB STATUS\G" | grep -q "dict_stats.*running"; then
                        log_warn "Found leaked metadata thread FD: $fd_num"
                        eval "exec ${fd_num}>&-" 2>/dev/null || true
                    fi
                done
            fi

            # Check for statistics thread FDs
            local stats_thread_fds=$(lsof -p $$ | grep -E 'innodb_stats_thread_[0-9]+|stats_background\.[0-9]+')
            if [ -n "$stats_thread_fds" ]; then
                echo "$stats_thread_fds" | while read fd_info; do
                    local fd_num=$(echo "$fd_info" | awk '{print $4}' | tr -d 'u')
                    # Verify if stats threads are still active
                    if ! mysql -N -e "SHOW ENGINE INNODB STATUS\G" | grep -q "stats_thread.*running"; then
                        log_warn "Found leaked statistics thread FD: $fd_num"
                        eval "exec ${fd_num}>&-" 2>/dev/null || true
                    fi
                done
            fi

            # Check for metadata thread FDs
            local metadata_thread_fds=$(lsof -p $$ | grep -E 'innodb_dict_[0-9]+|dict_background\.[0-9]+')
            if [ -n "$metadata_thread_fds" ]; then
                echo "$metadata_thread_fds" | while read fd_info; do
                    local fd_num=$(echo "$fd_info" | awk '{print $4}' | tr -d 'u')
                    # Verify if metadata threads are still active
                    if ! mysql -N -e "SHOW ENGINE INNODB STATUS\G" | grep -q "dict_stats.*running"; then
                        log_warn "Found leaked metadata thread FD: $fd_num"
                        eval "exec ${fd_num}>&-" 2>/dev/null || true
                    fi
                done
            fi
        fi

        # Role-specific InnoDB statistics and metadata cleanup for master/standalone
        if [ "$role" = "master" ] || [ "$role" = "standalone" ]; then
            # Check for statistics thread FDs
            local stats_fds=$(lsof -p $$ | grep -E 'innodb_stats\.[0-9]+|innodb_index_stats\.[0-9]+')
            if [ -n "$stats_fds" ]; then
                echo "$stats_fds" | while read fd_info; do
                    local fd_num=$(echo "$fd_info" | awk '{print $4}' | tr -d 'u')
                    # Verify if stats thread is still active
                    if ! mysql -N -e "SHOW ENGINE INNODB STATUS\G" | grep -q "statistics collection.*running"; then
                        log_warn "Found leaked statistics thread FD: $fd_num"
                        eval "exec ${fd_num}>&-" 2>/dev/null || true
                    fi
                done
            fi

            # Check for metadata thread FDs
            local metadata_fds=$(lsof -p $$ | grep -E 'innodb_table_stats|innodb_index_stats|innodb_ddl_log')
            if [ -n "$metadata_fds" ]; then
                echo "$metadata_fds" | while read fd_info; do
                    local fd_num=$(echo "$fd_info" | awk '{print $4}' | tr -d 'u')
                    # Verify if metadata operations are still active
                    if ! mysql -N -e "SELECT COUNT(*) FROM information_schema.INNODB_TRX WHERE trx_query LIKE '%innodb_%stats%'" | grep -q "[1-9]"; then
                        log_warn "Found leaked metadata thread FD: $fd_num"
                        eval "exec ${fd_num}>&-" 2>/dev/null || true
                    fi
                done
            fi
        fi

        # Role-specific InnoDB temporary tablespace cleanup for master/standalone
        if [ "$role" = "master" ] || [ "$role" = "standalone" ]; then
            # Check for temporary tablespace FDs
            local temp_tablespace_fds=$(lsof -p $$ | grep -E 'ibtmp[0-9]+$')
            if [ -n "$temp_tablespace_fds" ]; then
                echo "$temp_tablespace_fds" | while read fd_info; do
                    local fd_num=$(echo "$fd_info" | awk '{print $4}' | tr -d 'u')
                    # Verify if temp tablespace is still needed
                    if ! mysql -N -e "SELECT COUNT(*) FROM information_schema.INNODB_TEMP_TABLE_INFO" | grep -q "[1-9]"; then
                        log_warn "Found leaked temporary tablespace FD: $fd_num"
                        eval "exec ${fd_num}>&-" 2>/dev/null || true
                    fi
                done
            fi
        fi

        # Check for orphaned FDs from interrupted InnoDB operations
        local innodb_fds=$(lsof -p $$ | grep -E '\.ibd$' | grep -v "ibdata")
        if [ -n "$innodb_fds" ]; then
            echo "$innodb_fds" | while read fd_info; do
                local fd_num
                local file_path
                fd_num=$(echo "$fd_info" | awk '{print $4}' | tr -d 'u')
                file_path=$(echo "$fd_info" | awk '{print $9}')
                # Verify if table is in use
                local table_name
                table_name=$(basename "$file_path" .ibd)
                if ! mysql -N -e "SELECT * FROM information_schema.INNODB_TABLES WHERE NAME LIKE '%$table_name'" | grep -q .; then
                    log_error "Found orphaned InnoDB FD: $fd_num for $file_path"
                    eval "exec ${fd_num}>&-" 2>/dev/null || true
                fi
            done
        fi

        # Check for stuck FDs from partial writes
        local partial_fds=$(lsof -p $$ | grep -E '\.(frm|ibd|MYD|MYI)$' | grep -i "deleted")
        if [ -n "$partial_fds" ]; then
            echo "$partial_fds" | while read fd_info; do
                local fd_num=$(echo "$fd_info" | awk '{print $4}' | tr -d 'u')
                log_error "Found stuck partial write FD: $fd_num"
                # Force sync before closing to prevent corruption
                sync
                eval "exec ${fd_num}>&-" 2>/dev/null || true
            done
        fi

        sleep 60
    done &
}

# Initialize on source
init_mysql_fd_tracker
