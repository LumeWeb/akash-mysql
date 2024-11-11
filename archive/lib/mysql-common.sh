#!/bin/bash

# Prevent multiple inclusion
[ -n "${MYSQL_COMMON_SOURCED}" ] && return 0
declare -g MYSQL_COMMON_SOURCED=1

# Core dependencies only - load order matters
source "${LIB_PATH}/core/logging.sh"
source "${LIB_PATH}/core/constants.sh"
source "${LIB_PATH}/core/fd.sh"
source "${LIB_PATH}/core/locks.sh"
source "${LIB_PATH}/core/mysql.sh"

# Initialize FD tracking
init_fd_tracker

# Feature modules - load after core
source "${LIB_PATH}/features/monitoring/table_monitor.sh"
source "${LIB_PATH}/mysql-query-analyzer.sh"

# Global variables for process management
declare -g MYSQL_PID=""
declare -g LEASE_KEEPALIVE_PID=""
declare -g ROLE_WATCH_PID=""
declare -g CURRENT_ROLE=""
declare -g LEASE_ID=""

# Logging function with timestamp and level
log() {
    local level=$1
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
}

# MySQL command retry wrapper with enhanced timeout and monitoring
mysql_retry() {
    local max_attempts=5
    local attempt=1
    local timeout=10
    local command="$*"
    local wait_time=1
    
    # Get query type and complexity for adaptive timeout
    local query_type
    query_type=$(echo "$command" | grep -oE '^(SELECT|INSERT|UPDATE|DELETE|CREATE|ALTER)')
    local joins=$(echo "$command" | grep -o "JOIN" | wc -l)
    local subqueries=$(echo "$command" | grep -o "SELECT" | wc -l)
    local complexity=$((joins + subqueries))
    local tables=$(echo "$command" | grep -oE 'FROM\s+\w+|JOIN\s+\w+' | wc -l)
    
    # Base timeout adjusted by complexity and table count
    case "${query_type^^}" in
        "SELECT") 
            query_timeout=$((300 + (complexity * 60) + (tables * 30))) ;; # Additional time per join/subquery/table
        "INSERT"|"UPDATE"|"DELETE") 
            query_timeout=$((180 + (complexity * 30) + (tables * 15))) ;; # Less additional time for writes
        "CREATE"|"ALTER") 
            query_timeout=$((900 + (complexity * 120))) ;; # More time for DDL
        *) 
            query_timeout=$((300 + (complexity * 60))) ;; # Default with complexity adjustment
    esac
    
    # Cap maximum timeout
    if [ $query_timeout -gt 3600 ]; then
        query_timeout=3600 # Max 1 hour
    fi
    
    # Get current system metrics
    local load=$(uptime | awk -F'load average:' '{ print $2 }' | awk -F, '{ print $1 }')
    local cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}')
    local io_wait=$(top -bn1 | grep "Cpu(s)" | awk '{print $10}')
    
    # Adaptive timeout based on system metrics
    if [ $(echo "$load > 5" | bc) -eq 1 ] || [ $(echo "$cpu_usage > 80" | bc) -eq 1 ]; then
        query_timeout=$((query_timeout / 2))
        log_warn "High system load ($load) or CPU usage ($cpu_usage%) - reducing query timeout to ${query_timeout}s"
    fi
    
    if [ $(echo "$io_wait > 20" | bc) -eq 1 ]; then
        query_timeout=$((query_timeout * 3 / 2))
        log_warn "High IO wait ($io_wait%) - increasing query timeout to ${query_timeout}s"
    fi
    
    # Enhanced query timeout calculation with table statistics
    local query_type
    local joins
    local subqueries
    query_type=$(echo "$command" | grep -oE '^(SELECT|INSERT|UPDATE|DELETE|CREATE|ALTER)')
    joins=$(echo "$command" | grep -o "JOIN" | wc -l)
    subqueries=$(echo "$command" | grep -o "SELECT" | wc -l)
    local complexity=$((joins + subqueries))
    
    # Get table sizes and index stats for better timeout calculation
    local total_rows=0
    local total_data_mb=0
    local index_ratio=0
    
    for table in $(echo "$command" | grep -oE 'FROM\s+(\w+)|JOIN\s+(\w+)' | awk '{print $2}'); do
        local stats
        stats=$(mysql -N -e "
            SELECT 
                table_rows,
                data_length/1024/1024,
                index_length/GREATEST(data_length,1)
            FROM information_schema.tables 
            WHERE table_schema = DATABASE() 
            AND table_name = '$table'")
        
        local rows=$(echo "$stats" | awk '{print $1}')
        local data_mb=$(echo "$stats" | awk '{print $2}')
        local idx_ratio=$(echo "$stats" | awk '{print $3}')
        
        total_rows=$((total_rows + rows))
        total_data_mb=$(echo "$total_data_mb + $data_mb" | bc)
        index_ratio=$(echo "($index_ratio + $idx_ratio)/2" | bc -l)
    done
    
    # Enhanced timeout calculation based on comprehensive analysis
    case "${query_type^^}" in
        "SELECT")
            # Calculate timeout based on table statistics and query complexity
            local size_factor=$(echo "sqrt($total_data_mb/100)" | bc)
            local index_penalty=$(echo "(2 - $index_ratio) * 2" | bc -l)
            local join_factor=$((joins * 2))
            local subquery_penalty=$((subqueries * 3))
            
            # Get table fragmentation info
            local fragmentation=$(mysql -N -e "
                SELECT AVG(stat_value) FROM mysql.innodb_index_stats 
                WHERE stat_name='size' 
                AND table_name IN ($(echo "$tables" | tr ' ' ','))
            ")
            
            # Adjust timeout based on all factors
            query_timeout=$(echo "300 + ($complexity * 60) + ($size_factor * $index_penalty * 30) + ($join_factor * 20) + ($subquery_penalty * 15) + ($fragmentation * 5)" | bc)
            
            # Add buffer for large result sets
            if [ "$total_rows" -gt 1000000 ]; then
                query_timeout=$(echo "$query_timeout * 1.5" | bc)
            fi
            ;;
        "INSERT"|"UPDATE"|"DELETE")
            # More time for large data modifications
            local size_factor=$(echo "sqrt($total_data_mb/100)" | bc)
            query_timeout=$(echo "180 + ($complexity * 30) + ($size_factor * 20)" | bc)
            ;;
        "CREATE"|"ALTER")
            # Scale with table size for DDL
            local size_factor=$(echo "sqrt($total_data_mb/100)" | bc)
            query_timeout=$(echo "900 + ($complexity * 120) + ($size_factor * 60)" | bc)
            ;;
        *)
            query_timeout=$((300 + (complexity * 60)))
            ;;
    esac
    
    # Cap maximum timeout
    if [ $query_timeout -gt 3600 ]; then
        query_timeout=3600 # Max 1 hour
    fi
    
    # Get current system metrics
    local load=$(uptime | awk -F'load average:' '{ print $2 }' | awk -F, '{ print $1 }')
    local cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}')
    local io_wait=$(top -bn1 | grep "Cpu(s)" | awk '{print $10}')
    
    # Adaptive timeout based on system metrics
    if [ $(echo "$load > 5" | bc) -eq 1 ] || [ $(echo "$cpu_usage > 80" | bc) -eq 1 ]; then
        query_timeout=$((query_timeout / 2))
        log_warn "High system load ($load) or CPU usage ($cpu_usage%) - reducing query timeout to ${query_timeout}s"
    fi
    
    if [ $(echo "$io_wait > 20" | bc) -eq 1 ]; then
        query_timeout=$((query_timeout * 3 / 2))
        log_warn "High IO wait ($io_wait%) - increasing query timeout to ${query_timeout}s"
    fi
    
    # Set query timeout and create temp file for query details
    local query_info_file
    local query_info_fd
    query_info_file=$(mktemp)
    exec {query_info_fd}>"$query_info_file"
    track_fd "$query_info_fd" "temp:query_analysis"
    trap "cleanup_fd $query_info_fd; rm -f $query_info_file" EXIT
    
    # Enhanced query optimization with intelligent cache management
    local query_complexity=$(echo "$command" | grep -oE '(JOIN|GROUP BY|ORDER BY|HAVING|UNION|DISTINCT)' | wc -l)
    local table_count=$(echo "$command" | grep -oE 'FROM\s+\w+|JOIN\s+\w+' | wc -l)
    local cache_size=$((64 * 1024 * 1024 * (query_complexity + 1)))
    
    # Get table sizes and modify cache based on data volume
    local total_data_size=0
    for table in $(echo "$command" | grep -oE 'FROM\s+(\w+)|JOIN\s+(\w+)' | awk '{print $2}'); do
        local size=$(mysql -N -e "
            SELECT (data_length + index_length) / 1024 / 1024 
            FROM information_schema.tables 
            WHERE table_schema = DATABASE() 
            AND table_name = '$table'")
        total_data_size=$((total_data_size + size))
    done
    
    # Adjust cache size based on table sizes
    if [ $total_data_size -gt 1000 ]; then  # If total size > 1GB
        cache_size=$((cache_size * 2))
    fi
    
    # Apply query rewrite optimizations
    local optimized_query=$(echo "$command" | sed -E '
        s/SELECT \*/SELECT /g;
        s/ORDER BY .+ LIMIT/ORDER BY ... LIMIT/g;
        s/GROUP BY .+ HAVING/GROUP BY ... HAVING/g;
    ')
    
    # Enable query plan caching
    mysql -e "
        SET SESSION optimizer_switch='condition_fanout_filter=on';
        SET SESSION optimizer_switch='derived_merge=on';
        SET SESSION optimizer_use_condition_selectivity=5;
        SET SESSION MAX_EXECUTION_TIME=$((query_timeout * (query_complexity + 1) * 1000));
        SET SESSION innodb_lock_wait_timeout=$((50 * (query_complexity + 1)));
        SET SESSION lock_wait_timeout=$((50 * (query_complexity + 1)));
        SET SESSION wait_timeout=300;
        SET SESSION query_cache_type=1;
        SET SESSION query_cache_size=$cache_size;
        SET SESSION query_cache_limit=$((cache_size / 10));
        SET SESSION query_cache_min_res_unit=4096;
        SET SESSION sort_buffer_size=$((16 * 1024 * 1024 * (query_complexity + 1)));
        SET SESSION join_buffer_size=$((16 * 1024 * 1024 * (query_complexity + 1)));
        SET SESSION tmp_table_size=$((64 * 1024 * 1024 * (query_complexity + 1)));
    "
    local query_timeout=300  # 5 minute max query time
    
    # Set query timeout and create temp file for query details with proper FD tracking and cleanup
    local query_info_file
    query_info_file=$(mktemp)
    local query_info_fd
    exec {query_info_fd}>"$query_info_file"
    track_mysql_fd "$query_info_fd" "temp" "query_analysis_${RANDOM}"
    trap "cleanup_fd $query_info_fd; rm -f $query_info_file" EXIT INT TERM HUP
    
    # Track any additional FDs opened by query analysis
    local explain_fd
    exec {explain_fd}>/dev/null
    track_mysql_fd "$explain_fd" "temp" "explain_${RANDOM}"
    trap "cleanup_fd $explain_fd" EXIT INT TERM HUP
    
    # Set query timeout and monitoring
    mysql -e "
        SET SESSION MAX_EXECUTION_TIME=$((query_timeout * 1000));
        SET SESSION innodb_lock_wait_timeout=50;
        SET SESSION lock_wait_timeout=50;
        SET SESSION wait_timeout=300;
    "

    while [ $attempt -le $max_attempts ]; do
        if timeout $timeout $command; then
            return 0
        fi
        local exit_code=$?
        case $exit_code in
            124) log "WARN" "MySQL command timed out after ${timeout}s (attempt $attempt/$max_attempts)" ;;
            1) log "WARN" "MySQL command failed - syntax error (attempt $attempt/$max_attempts)" 
               return 1 ;; # Don't retry syntax errors
            *) log "WARN" "MySQL command failed with exit code $exit_code (attempt $attempt/$max_attempts)" ;;
        esac
        
        # Exponential backoff with jitter
        wait_time=$(( wait_time * 2 + RANDOM % 2 ))
        log "INFO" "Waiting ${wait_time} seconds before retry..."
        sleep $wait_time
        attempt=$((attempt + 1))
    done

    log "ERROR" "MySQL command failed after $max_attempts attempts"
    return 1
}

# Wait for MySQL to be ready with enhanced validation
wait_for_mysql() {
    local max_attempts=${MYSQL_START_TIMEOUT:-30}
    local attempt=1
    local timeout=5
    local connection_test="SELECT 1"
    local process_check="pgrep mysqld"

    while [ $attempt -le $max_attempts ]; do
        # First verify process is running
        if ! $process_check >/dev/null; then
            log "ERROR" "MySQL process is not running"
            return 1
        fi

        # Check socket file exists
        if [ ! -S "/var/run/mysqld/mysqld.sock" ]; then
            log "WARN" "MySQL socket file not found (attempt $attempt/$max_attempts)"
            sleep $((2 + attempt / 2))
            attempt=$((attempt + 1))
            continue
        fi

        # Check basic connectivity
        if timeout $timeout mysqladmin ping -h localhost --silent; then
            # Verify query execution and connection limits
            if echo "$connection_test" | timeout $timeout mysql -N 2>/dev/null; then
                # Verify max_connections not exceeded
                local max_conns=$(mysql -N -e "SHOW VARIABLES LIKE 'max_connections'" | awk '{print $2}')
                local current_conns=$(mysql -N -e "SHOW STATUS LIKE 'Threads_connected'" | awk '{print $2}')
                
                if [ $current_conns -gt $((max_conns * 90 / 100)) ]; then
                    log "WARN" "High connection usage: $current_conns/$max_conns"
                fi
                
                log "INFO" "MySQL is ready and accepting connections"
                return 0
            else
                log "WARN" "MySQL is running but not accepting queries yet"
            fi
        fi
        
        local exit_code=$?
        if [ $exit_code -eq 124 ]; then
            log "WARN" "MySQL ping timed out after ${timeout} seconds (attempt $attempt/$max_attempts)"
        else
            log "WARN" "MySQL ping failed with exit code $exit_code (attempt $attempt/$max_attempts)"
        fi
        
        sleep $((2 + attempt / 2))
        attempt=$((attempt + 1))
    done

    log "ERROR" "MySQL failed to start after $max_attempts attempts"
    return 1
}

# Monitor and auto-tune MySQL memory settings
monitor_mysql_memory() {
    while true; do
        local total_memory=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
        local free_memory=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
        local mysql_memory=$(pmap $(pgrep mysqld) | tail -n 1 | awk '/total/ {print $2}' | sed 's/K//')
        
        # Calculate memory percentages
        local memory_usage=$((mysql_memory * 100 / total_memory))
        local free_percent=$((free_memory * 100 / total_memory))
        
        if [ $memory_usage -gt 85 ]; then
            log "WARN" "High MySQL memory usage: ${memory_usage}%"
            
            # Reduce buffer pool if memory pressure is high
            if [ $free_percent -lt 10 ]; then
                local current_pool=$(mysql -N -e "SHOW VARIABLES LIKE 'innodb_buffer_pool_size'" | awk '{print $2}')
                local new_pool=$((current_pool * 90 / 100))
                mysql -e "SET GLOBAL innodb_buffer_pool_size = $new_pool"
                log "INFO" "Reduced buffer pool size to ${new_pool} bytes"
            fi
        fi
        
        sleep 60
    done
}

# Check MySQL health with enhanced monitoring
check_mysql_health() {
    local ping_timeout=${MYSQL_HEALTH_PING_TIMEOUT:-5}
    local query_timeout=${MYSQL_HEALTH_QUERY_TIMEOUT:-5}
    local errors=0
    
    # Enhanced deadlock detection with root cause analysis
    local deadlock_check=$(mysql -N -e "
        WITH RECURSIVE
        lock_chains AS (
            SELECT 
                w.requesting_trx_id,
                w.blocking_trx_id,
                t1.trx_query as waiting_query,
                t2.trx_query as blocking_query,
                t1.trx_rows_locked,
                t1.trx_rows_modified,
                t1.trx_started,
                1 as chain_depth,
                CONCAT(t1.trx_id) as chain_path
            FROM information_schema.innodb_lock_waits w
            JOIN information_schema.innodb_trx t1 ON w.requesting_trx_id = t1.trx_id
            JOIN information_schema.innodb_trx t2 ON w.blocking_trx_id = t2.trx_id
                
            UNION ALL
                
            SELECT 
                w.requesting_trx_id,
                w.blocking_trx_id,
                t1.trx_query,
                t2.trx_query,
                t1.trx_rows_locked,
                t1.trx_rows_modified,
                t1.trx_started,
                lc.chain_depth + 1,
                CONCAT(lc.chain_path, ' -> ', t1.trx_id)
            FROM lock_chains lc
            JOIN information_schema.innodb_lock_waits w ON lc.requesting_trx_id = w.blocking_trx_id
            JOIN information_schema.innodb_trx t1 ON w.requesting_trx_id = t1.trx_id
            JOIN information_schema.innodb_trx t2 ON w.blocking_trx_id = t2.trx_id
            WHERE lc.chain_depth < 5
        )
        SELECT 
            COUNT(DISTINCT requesting_trx_id) as deadlocks,
            MAX(chain_depth) as max_chain_depth,
            GROUP_CONCAT(DISTINCT chain_path) as deadlock_chains,
            COUNT(DISTINCT CASE WHEN TIMESTAMPDIFF(SECOND, trx_started, NOW()) > 10 THEN requesting_trx_id END) as long_running_locks
        FROM lock_chains;")
    
    local deadlocks=$(echo "$deadlock_check" | awk '{print $1}')
    local lock_waits=$(echo "$deadlock_check" | awk '{print $2}')
    local avg_lock_time=$(echo "$deadlock_check" | awk '{print $3}')
    
    if [ "$deadlocks" -gt 0 ] || [ "$lock_waits" -gt 10 ]; then
        log "WARN" "Detected $deadlocks deadlocks, $lock_waits lock waits, avg lock time: ${avg_lock_time}ms"
        mysql -e "
            SELECT 
                r.trx_id waiting_trx_id,
                r.trx_mysql_thread_id waiting_thread,
                r.trx_query waiting_query,
                b.trx_id blocking_trx_id,
                b.trx_mysql_thread_id blocking_thread,
                b.trx_query blocking_query
            FROM information_schema.innodb_lock_waits w
            JOIN information_schema.innodb_trx b ON b.trx_id = w.blocking_trx_id
            JOIN information_schema.innodb_trx r ON r.trx_id = w.requesting_trx_id;
        " > /var/log/mysql/deadlocks.log
        
        # Kill long-running blocking transactions if configured
        if [ "${MYSQL_AUTO_KILL_BLOCKERS:-false}" = "true" ]; then
            mysql -e "
                WITH RECURSIVE
                blocking_chain AS (
                    SELECT 
                        t1.trx_id,
                        t1.trx_mysql_thread_id,
                        t1.trx_query,
                        t1.trx_started,
                        t1.trx_rows_locked,
                        t1.trx_rows_modified,
                        1 as chain_depth
                    FROM information_schema.innodb_trx t1
                    JOIN information_schema.innodb_lock_waits w ON t1.trx_id = w.blocking_trx_id
                    WHERE (UNIX_TIMESTAMP() - UNIX_TIMESTAMP(trx_started)) > 300
                    
                    UNION ALL
                    
                    SELECT 
                        t2.trx_id,
                        t2.trx_mysql_thread_id,
                        t2.trx_query,
                        t2.trx_started,
                        t2.trx_rows_locked,
                        t2.trx_rows_modified,
                        bc.chain_depth + 1
                    FROM blocking_chain bc
                    JOIN information_schema.innodb_lock_waits w ON bc.trx_id = w.requesting_trx_id
                    JOIN information_schema.innodb_trx t2 ON t2.trx_id = w.blocking_trx_id
                    WHERE bc.chain_depth < 5
                )
                SELECT CONCAT('KILL ', trx_mysql_thread_id, ';') 
                FROM blocking_chain 
                WHERE chain_depth = (SELECT MAX(chain_depth) FROM blocking_chain)
                ORDER BY trx_rows_modified DESC, trx_rows_locked DESC
                LIMIT 1;" | mysql
            
            # Log killed transaction details
            echo "[$(date)] Killed blocking transaction chain" >> /var/log/mysql/deadlock_resolution.log
        fi
    fi
    
    # Check if MySQL is running and responsive
    if ! pgrep mysqld >/dev/null; then
        log "ERROR" "MySQL process is not running"
        return 1
    fi
    
    # Monitor query execution times
    local long_queries=$(mysql -N -e "
        SELECT COUNT(*) 
        FROM information_schema.processlist 
        WHERE TIME > 300 AND COMMAND != 'Sleep'")
    
    if [ "$long_queries" -gt 5 ]; then
        log "WARN" "Multiple long-running queries detected: $long_queries"
        mysql -e "
            SELECT ID, USER, HOST, DB, TIME, STATE, INFO 
            FROM information_schema.processlist 
            WHERE TIME > 300 AND COMMAND != 'Sleep'
            ORDER BY TIME DESC" >> /var/log/mysql/long_queries.log
    fi

    # Check if MySQL is responding with retry
    if ! mysql_retry "mysqladmin ping -h localhost --silent"; then
        log "ERROR" "MySQL is not responding to ping after retries"
        errors=$((errors + 1))
    fi

    # Check for read/write capability with retry and timeout monitoring
    if ! mysql_retry "mysql -e 'SELECT 1'"; then
        log "ERROR" "MySQL cannot execute queries after retries"
        errors=$((errors + 1))
    fi
    
    # Monitor for long-running queries
    mysql -N -e "
        SELECT ID, TIME, INFO 
        FROM information_schema.processlist 
        WHERE COMMAND != 'Sleep' 
        AND TIME > 300" | while read id time query; do
        log "WARN" "Long running query detected (${time}s): $query"
        if [ $time -gt 600 ]; then
            log "ERROR" "Query exceeded 10 minute timeout, killing: $id"
            mysql -e "KILL $id"
        fi
    done

    # Check for connection capacity
    local max_connections=$(mysql -N -e "SHOW VARIABLES LIKE 'max_connections'" | awk '{print $2}')
    local current_connections=$(mysql -N -e "SHOW STATUS LIKE 'Threads_connected'" | awk '{print $2}')
    local connection_ratio=$((current_connections * 100 / max_connections))
    
    if [ $connection_ratio -gt 90 ]; then
        log "WARN" "High connection usage: ${connection_ratio}% (${current_connections}/${max_connections})"
    fi

    if [ $errors -gt 0 ]; then
        return 1
    fi
    return 0
}

# Validate MySQL configuration
validate_mysql_config() {
    local config_file=$1
    
    if [ ! -f "$config_file" ]; then
        log "ERROR" "Configuration file not found: $config_file"
        return 1
    fi

    # Test configuration file
    if ! mysqld --verbose --help --log-bin-index="$(mktemp -u)" 2>/dev/null > /dev/null; then
        log "ERROR" "Invalid MySQL configuration in $config_file"
        return 1
    fi

    # Check for common misconfigurations
    local innodb_buffer_pool_size=$(my_print_defaults mysqld | grep innodb_buffer_pool_size | cut -d= -f2)
    local total_memory=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    
    if [ -n "$innodb_buffer_pool_size" ]; then
        # Convert to bytes for comparison
        local buffer_pool_bytes=$(numfmt --from=iec "$innodb_buffer_pool_size")
        if [ $buffer_pool_bytes -gt $((total_memory * 70 / 100)) ]; then
            log "WARN" "InnoDB buffer pool size exceeds 70% of system memory"
        fi
    fi

    return 0
}

# Wait for etcd to be ready with enhanced error handling
wait_for_etcd() {
    local max_attempts=30
    local attempt=1
    local timeout=5

    while [ $attempt -le $max_attempts ]; do
        if timeout $timeout etcdctl endpoint health >/dev/null 2>&1; then
            log_info "Successfully connected to etcd"
            return 0
        fi
        
        local exit_code=$?
        case $exit_code in
            124) log_warn "Etcd health check timed out (attempt $attempt/$max_attempts)" ;;
            *) log_warn "Etcd health check failed with code $exit_code (attempt $attempt/$max_attempts)" ;;
        esac

        sleep $((2 * attempt))  # Exponential backoff
        attempt=$((attempt + 1))
    done

    log_error "Failed to connect to etcd after $max_attempts attempts"
    return 1
}

# Lock management functions
acquire_lock() {
    local lock_key=$1
    local lock_value=$2
    local ttl=${3:-10}

    # Try to get a lease
    local lease_output
    lease_output=$(etcdctl lease grant $ttl 2>/dev/null)
    if [ $? -ne 0 ]; then
        echo "Failed to acquire lease" >&2
        return 1
    fi

    local lease_id=$(echo "$lease_output" | awk '{print $2}')

    # Try to acquire lock with lease
    if ! etcdctl put --lease=$lease_id "$lock_key" "$lock_value" --prev-kv 2>/dev/null; then
        echo "Failed to acquire lock" >&2
        etcdctl lease revoke $lease_id 2>/dev/null
        return 1
    fi

    echo $lease_id
    return 0
}

release_lock() {
    local lock_key=$1
    local lease_id=$2

    if [ -n "$lease_id" ]; then
        etcdctl lease revoke $lease_id 2>/dev/null || true
    fi
    etcdctl del "$lock_key" 2>/dev/null || true
}

# Register node in etcd with lease
register_node() {
    while true; do
        LEASE_ID=$(etcdctl lease grant 10 2>/dev/null | awk '{print $2}') && break
        echo "Waiting for valid etcd lease..."
        sleep 2
    done

    etcd_retry etcdctl put "$(get_node_path $NODE_ID)" "online" --lease=$LEASE_ID

    # Start lease keepalive in background
    etcd_retry etcdctl lease keep-alive $LEASE_ID &
    LEASE_KEEPALIVE_PID=$!

    return $?
}

# Process MySQL database initialization
setup_mysql_database() {
    local SOCKET="$1"
    local mysql=( mysql --protocol=socket -uroot -hlocalhost --socket="${SOCKET}" )

    if [ ! -z "$MYSQL_ROOT_PASSWORD" ]; then
        mysql+=( -p"${MYSQL_ROOT_PASSWORD}" )
    fi

    # Wait for MySQL to be ready
    for i in {120..0}; do
        if echo 'SELECT 1' | "${mysql[@]}" &> /dev/null; then
            break
        fi
        echo 'MySQL init process in progress...'
        sleep 1
    done

    if [ "$i" = 0 ]; then
        echo >&2 'MySQL init process failed.'
        return 1
    fi

    # Setup timezone info
    if [ -z "$MYSQL_INITDB_SKIP_TZINFO" ]; then
        (
            echo "SET @@SESSION.SQL_LOG_BIN = off;"
            mysql_tzinfo_to_sql /usr/share/zoneinfo | sed 's/Local time zone must be set--see zic manual page/FCTY/'
        ) | "${mysql[@]}" mysql
    fi

    # Handle root password and host
    if [ ! -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
        MYSQL_ROOT_PASSWORD="$(pwmake 128)"
        echo "GENERATED ROOT PASSWORD: $MYSQL_ROOT_PASSWORD"
    fi

    # Setup root access and permissions
    "${mysql[@]}" <<-EOSQL
        SET @@SESSION.SQL_LOG_BIN=0;
        DELETE FROM mysql.user WHERE user NOT IN ('mysql.sys', 'mysqlxsys', 'mysql.infoschema', 'mysql.session', 'root') OR host NOT IN ('localhost') ;
        ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' ;
        GRANT ALL ON *.* TO 'root'@'localhost' WITH GRANT OPTION ;
        CREATE USER 'root'@'${MYSQL_ROOT_HOST}' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' ;
        GRANT ALL ON *.* TO 'root'@'${MYSQL_ROOT_HOST}' WITH GRANT OPTION ;
        DROP DATABASE IF EXISTS test ;
        FLUSH PRIVILEGES ;
EOSQL

    # Create initial database if specified
    if [ "$MYSQL_DATABASE" ]; then
        echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` ;" | "${mysql[@]}"
    fi

    # Create user if specified
    if [ "$MYSQL_USER" -a "$MYSQL_PASSWORD" ]; then
        echo "CREATE USER '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD' ;" | "${mysql[@]}"
        if [ "$MYSQL_DATABASE" ]; then
            echo "GRANT ALL ON \`$MYSQL_DATABASE\`.* TO '$MYSQL_USER'@'%' ;" | "${mysql[@]}"
        fi
        echo 'FLUSH PRIVILEGES ;' | "${mysql[@]}"
    fi

    # Process initialization files
    for f in /docker-entrypoint-initdb.d/*; do
        process_init_file "$f" "${mysql[@]}"
    done

    # Handle one-time password if specified
    if [ ! -z "$MYSQL_ONETIME_PASSWORD" ]; then
        "${mysql[@]}" <<-EOSQL
            ALTER USER 'root'@'%' PASSWORD EXPIRE;
EOSQL
    fi

    return 0
}

# Helper function for initialization scripts
process_init_file() {
    local f="$1"; shift
    local mysql=( "$@" )

    case "$f" in
        *.sh)     echo "$0: running $f"; . "$f" ;;
        *.sql)    echo "$0: running $f"; "${mysql[@]}" < "$f"; echo ;;
        *.sql.gz) echo "$0: running $f"; gunzip -c "$f" | "${mysql[@]}"; echo ;;
        *)        echo "$0: ignoring $f" ;;
    esac
    echo
}

