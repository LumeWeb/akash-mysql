#!/bin/bash

# Prevent multiple inclusion
[ -n "${MYSQL_QUERY_ANALYZER_SOURCED}" ] && return 0
declare -g MYSQL_QUERY_ANALYZER_SOURCED=1

# Core dependencies only - load order matters
source "${LIB_PATH}/core/logging.sh"
source "${LIB_PATH}/core/constants.sh"
source "${LIB_PATH}/core/fd.sh"
source "${LIB_PATH}/mysql-role.sh"

# Analyze query plans and provide optimization suggestions
analyze_query_plans() {
    local query
    local count
    local latency 
    local rows_examined
    local rows_sent
    local sort_rows
    local no_index
    local no_good_index
    local explain_file
    local joins
    local tables
    local cache_size
    local column
    local stats
    
    while true; do
        # Get slow queries from performance schema
        mysql -N -e "
            SELECT 
                DIGEST_TEXT,
                COUNT_STAR,
                AVG_TIMER_WAIT/1000000000000 as avg_latency_sec,
                SUM_ROWS_EXAMINED,
                SUM_ROWS_SENT,
                SUM_SORT_ROWS,
                SUM_NO_INDEX_USED,
                SUM_NO_GOOD_INDEX_USED
            FROM performance_schema.events_statements_summary_by_digest
            WHERE LAST_SEEN >= NOW() - INTERVAL 1 HOUR
            AND AVG_TIMER_WAIT > 1000000000
            ORDER BY AVG_TIMER_WAIT DESC
            LIMIT 10
        " | while read -r query count latency rows_examined rows_sent sort_rows no_index no_good_index; do
            if [ "$no_index" -gt 0 ] || [ "$no_good_index" -gt 0 ]; then
                log_warn "Inefficient query detected:"
                log_info "Query: $query"
                log_info "Executions: $count, Avg Latency: ${latency}s"
                log_info "Rows examined: $rows_examined, Rows returned: $rows_sent"
                
                # Get and analyze EXPLAIN plan
                local explain_file
                local query_info_file
                explain_file="/var/log/mysql/explain_$(date +%s).json"
                query_info_file=$(mktemp)
                mysql -e "EXPLAIN FORMAT=JSON $query" > "$explain_file"
                
                # Enhanced query plan caching with adaptive sizing
                if [ "$count" -gt 100 ] && [ "$latency" -gt 1 ]; then
                    # Calculate optimal cache size based on query complexity
                    local joins
                    local tables
                    joins=$(echo "$query" | grep -o "JOIN" | wc -l)
                    tables=$(echo "$query" | grep -oP 'FROM\s+\K\w+|JOIN\s+\K\w+' | wc -l)
                    local cache_size
                    cache_size=$((16 * 1024 * 1024 * (joins + 1) * (tables + 1)))
                    
                    mysql -e "
                        SET GLOBAL query_cache_type = 1;
                        SET GLOBAL query_cache_size = $cache_size;
                        SET GLOBAL query_cache_limit = $((cache_size / 10));
                        SET GLOBAL query_cache_min_res_unit = 4096;
                        ANALYZE TABLE $(echo "$query" | grep -oP 'FROM \K\w+');
                    "
                    log_info "Enabled adaptive query cache (size: $((cache_size/1024/1024))MB)"
                fi
                
                # Analyze potential improvements
                if [ "$rows_examined" -gt "$((rows_sent * 10))" ]; then
                    log_warn "Query examining too many rows - consider adding indexes"
                    
                    # Suggest specific indexes based on WHERE/JOIN conditions
                    local tables=$(echo "$query" | grep -oP '(?:FROM|JOIN)\s+\K\w+')
                    for table in $tables; do
                        mysql -e "
                            SELECT 
                                COLUMN_NAME,
                                COUNT(*) as usage_count
                            FROM information_schema.STATISTICS
                            WHERE TABLE_NAME='$table'
                            GROUP BY COLUMN_NAME
                            HAVING usage_count < 2
                        " | while read column count; do
                            log_info "Consider index on $table($column) - low usage detected"
                        done
                    done
                fi
                
                if [ "$sort_rows" -gt 1000 ]; then
                    log_warn "Large sort operation detected - consider adding ORDER BY indexes"
                fi
            fi
        done
        
        sleep 300
    done &
}

# Track analyzer PID
declare -g QUERY_ANALYZER_PID=""

# Initialize query analysis with deadlock prevention
init_query_analyzer() {
    local role=${1:-standalone}
    log_info "Query analyzer handling role change to: $role..."
    
    # Kill existing analyzer if running
    if [ -n "$QUERY_ANALYZER_PID" ] && kill -0 $QUERY_ANALYZER_PID 2>/dev/null; then
        log_info "Stopping existing query analyzer (PID: $QUERY_ANALYZER_PID)"
        kill -TERM $QUERY_ANALYZER_PID
        wait $QUERY_ANALYZER_PID 2>/dev/null
        
        # Clean up any temporary files or state
        rm -f /tmp/query_analyzer.* 2>/dev/null
        rm -f /var/log/mysql/explain_*.json 2>/dev/null
        
        # Kill any long-running EXPLAIN or analysis queries
        mysql -e "
            KILL QUERY IF EXISTS (
                SELECT id FROM information_schema.processlist 
                WHERE command = 'Query'
                AND (info LIKE 'EXPLAIN%' OR info LIKE 'ANALYZE%')
            );
        " || true
        
        # Reset query analysis state and performance schema
        mysql -e "
            SET GLOBAL query_cache_size = 0;
            SET GLOBAL query_cache_type = 0;
            SET GLOBAL performance_schema_max_digest_length = 1024;
            SET GLOBAL performance_schema_max_sql_text_length = 1024;
            FLUSH STATUS;
            FLUSH TABLES;
            FLUSH OPTIMIZER_COSTS;
            FLUSH USER_RESOURCES;
        " || true
        
        # Reset query digest tables during transition
        mysql -e "TRUNCATE TABLE performance_schema.events_statements_summary_by_digest" || true
        
        # Clean up any in-progress analysis files
        rm -f /var/log/mysql/explain_*.json 2>/dev/null
        
        # Kill any long-running EXPLAIN or analysis queries
        mysql -e "
            KILL QUERY IF EXISTS (
                SELECT id FROM information_schema.processlist 
                WHERE command = 'Query'
                AND (info LIKE 'EXPLAIN%' OR info LIKE 'ANALYZE%')
            );
        " || true
        
        # Reset query analysis state and performance schema
        mysql -e "
            SET GLOBAL query_cache_size = 0;
            SET GLOBAL query_cache_type = 0;
            SET GLOBAL performance_schema_max_digest_length = 1024;
            SET GLOBAL performance_schema_max_sql_text_length = 1024;
            FLUSH STATUS;
            FLUSH TABLES;
            FLUSH OPTIMIZER_COSTS;
            FLUSH USER_RESOURCES;
        " || true
    fi

    # Wait briefly before starting to allow role transition to complete
    sleep 2

    # Wait briefly before starting to allow role transition to complete
    sleep 2
    
    # Only run analysis on master/standalone    
    if [ "$role" = "standalone" ] || [ "$role" = "master" ]; then
        # Wait briefly before starting to allow role transition to complete
        sleep 2
        
        # Reset query digest tables before starting
        mysql -e "TRUNCATE TABLE performance_schema.events_statements_summary_by_digest" || true
        
        analyze_query_plans &
        QUERY_ANALYZER_PID=$!
        log_info "Started query analyzer (PID: $QUERY_ANALYZER_PID)"
    else
        log_info "Query analysis disabled for slave nodes"
    fi
}

# Register for role changes
register_role_change_handler "query_analyzer" init_query_analyzer
