#!/bin/bash

# Prevent multiple inclusion
[ -n "${TABLE_MONITOR_SOURCED}" ] && return 0
declare -g TABLE_MONITOR_SOURCED=1

# Core dependencies only
source "${LIB_PATH}/core/logging.sh"
source "${LIB_PATH}/mysql-role.sh"

# Monitor for table issues and optimize queries
# Track monitor PIDs
declare -g TABLE_MONITOR_PID=""

# Register for role changes
register_role_change_handler "table_monitor" monitor_table_health

monitor_table_health() {
    local role=$1
    
    log_info "Table monitor handling role change to: $role"
    
    # Kill existing monitor if running
    if [ -n "$TABLE_MONITOR_PID" ] && kill -0 $TABLE_MONITOR_PID 2>/dev/null; then
        log_info "Stopping existing table monitor (PID: $TABLE_MONITOR_PID)"
        kill -TERM $TABLE_MONITOR_PID
        wait $TABLE_MONITOR_PID 2>/dev/null
        
        # Clean up any in-progress monitoring files
        rm -f /var/log/mysql/monitor_*.log 2>/dev/null
        
        # Safely reset monitoring state
        mysql -e "
            SET GLOBAL slow_query_log = 0;
            SET GLOBAL long_query_time = 10;
        " || true
        
        # Clean up any in-progress monitoring files
        rm -f /var/log/mysql/monitor_*.log 2>/dev/null
    fi

    # Only run monitoring on master/standalone
    if [ "$role" != "master" ] && [ "$role" != "standalone" ]; then
        log_info "Table monitoring disabled - not master/standalone"
        return 0
    fi

    # Wait briefly before starting to allow role transition to complete
    sleep 2

    (while true; do
        # Check table health and kill long running queries
        mysql -N -e "
            SELECT ID, USER, HOST, DB, TIME, STATE, INFO 
            FROM information_schema.processlist 
            WHERE TIME > 300 AND COMMAND != 'Sleep'
        " | while read id user host db time state info; do
            log_warn "Long running query detected - ID: $id, Time: $time, User: $user"
            log_info "Query: $info"
            
            if [ $time -gt 600 ]; then
                log_warn "Long running query detected (${time}s) - ID: $id"
                
                # Enhanced progress monitoring
                local progress1=$(mysql -N -e "SHOW PROCESSLIST" | grep $id | awk '{print $6}')
                local rows1=$(mysql -N -e "SHOW STATUS LIKE 'Handler_read_rnd_next'" | awk '{print $2}')
                sleep 5
                local progress2=$(mysql -N -e "SHOW PROCESSLIST" | grep $id | awk '{print $6}')
                local rows2=$(mysql -N -e "SHOW STATUS LIKE 'Handler_read_rnd_next'" | awk '{print $2}')
            
                local rows_processed=$((rows2 - rows1))
            
                if [ "$progress1" = "$progress2" ] || [ $rows_processed -lt 100 ]; then
                    log_warn "Query appears stuck, killing: $id"
                    mysql -e "KILL $id"
                fi
            fi
        done

        # Check table health
        mysql -N -e "SHOW TABLE STATUS" | while read line; do
            if echo "$line" | grep -q "corrupt\|crash"; then
                local table=$(echo "$line" | awk '{print $1}')
                auto_recover "$line" "$table"
            fi
        done

        # Monitor for deadlocks
        mysql -N -e "
            SELECT COUNT(*) 
            FROM information_schema.innodb_trx t1
            JOIN information_schema.innodb_lock_waits w ON t1.trx_id = w.requesting_trx_id
            WHERE t1.trx_state = 'LOCK WAIT'
        " | while read deadlocks; do
            if [ "$deadlocks" -gt 0 ]; then
                log_warn "Deadlocks detected: $deadlocks"
                mysql -e "SHOW ENGINE INNODB STATUS\G" > "/var/log/mysql/deadlock_status.log"
            fi
        done

        sleep ${HEALTH_CHECK_INTERVAL:-3600}
    done) &

    TABLE_MONITOR_PID=$!
}

# Automated recovery for common issues
auto_recover() {
    local error=$1
    local table=$2
    
    case "$error" in
        *"corrupt"*)
            log_warn "Attempting to repair corrupt table: $table"
            mysqlcheck --repair --auto-repair "$table"
            ;;
        *"crashed"*)
            log_warn "Attempting to recover crashed table: $table"
            mysql -e "REPAIR TABLE $table QUICK;"
            ;;
        *"temporary"*)
            log_warn "Cleaning up temporary tables"
            find /var/lib/mysql -name '*tmp*' -type f -delete
            ;;
    esac
}
