#!/bin/bash

source "${LIB_PATH}/mysql-logging.sh"

# Analyze and suggest indexes
analyze_indexes() {
    log_info "Starting index analysis..."
    
    # Find tables without primary keys
    mysql -N -e "
        SELECT TABLE_SCHEMA, TABLE_NAME 
        FROM information_schema.TABLES t
        WHERE TABLE_TYPE='BASE TABLE'
        AND TABLE_SCHEMA NOT IN ('mysql','information_schema','performance_schema')
        AND NOT EXISTS (
            SELECT 1 FROM information_schema.STATISTICS s 
            WHERE s.TABLE_SCHEMA=t.TABLE_SCHEMA 
            AND s.TABLE_NAME=t.TABLE_NAME 
            AND s.INDEX_NAME='PRIMARY'
        )
    " | while read schema table; do
        log_warn "Table without primary key: $schema.$table"
    done

    # Analyze queries that might benefit from indexes
    mysql -N -e "
        SELECT DIGEST_TEXT, COUNT_STAR, AVG_TIMER_WAIT,
               SUM_ROWS_EXAMINED, SUM_ROWS_SENT
        FROM performance_schema.events_statements_summary_by_digest
        WHERE SUM_ROWS_EXAMINED > SUM_ROWS_SENT * 10
        AND DIGEST_TEXT NOT LIKE '%INSERT%'
        AND DIGEST_TEXT NOT LIKE '%UPDATE%'
        AND DIGEST_TEXT NOT LIKE '%DELETE%'
        ORDER BY (SUM_ROWS_EXAMINED - SUM_ROWS_SENT) DESC
        LIMIT 10
    " | while read query count wait rows_examined rows_sent; do
        log_warn "Query examining too many rows:"
        log_info "Query: $query"
        log_info "Rows examined: $rows_examined, Rows returned: $rows_sent"
        
        # Extract table name from query and suggest columns for indexing
        table=$(echo "$query" | grep -oP "FROM \K\w+")
        if [ -n "$table" ]; then
            mysql -N -e "
                SELECT COLUMN_NAME 
                FROM information_schema.COLUMNS 
                WHERE TABLE_NAME='$table'
                AND COLUMN_NAME IN (
                    SELECT COLUMN_NAME 
                    FROM information_schema.STATISTICS 
                    WHERE TABLE_NAME='$table'
                    GROUP BY COLUMN_NAME 
                    HAVING COUNT(*) < 1
                )
            " | while read column; do
                log_info "Consider adding index on: $table($column)"
            done
        fi
    done
}

# Monitor and maintain indexes
monitor_indexes() {
    while true; do
        analyze_indexes
        
        # Enhanced index analysis
        mysql -N -e "
            SELECT 
                OBJECT_SCHEMA, 
                OBJECT_NAME, 
                INDEX_NAME,
                COUNT_STAR,
                COUNT_READ,
                COUNT_WRITE,
                COUNT_FETCH,
                SUM_TIMER_WAIT/1000000000 as total_latency_ms
            FROM performance_schema.table_io_waits_summary_by_index_usage
            WHERE INDEX_NAME IS NOT NULL
            AND COUNT_STAR = 0
            AND OBJECT_SCHEMA NOT IN ('mysql','performance_schema','information_schema')
            AND SUM_TIMER_WAIT > 0
        " | while read schema table index; do
            log_warn "Unused index detected: $schema.$table.$index"
            log_info "Consider dropping this index if not needed for constraints"
        done

        # Check for duplicate indexes
        mysql -N -e "
            SELECT t.TABLE_SCHEMA, t.TABLE_NAME, 
                   GROUP_CONCAT(INDEX_NAME) as indexes,
                   GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) as columns
            FROM information_schema.STATISTICS t
            GROUP BY TABLE_SCHEMA, TABLE_NAME, 
                     GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX)
            HAVING COUNT(*) > 1
        " | while read schema table indexes columns; do
            log_warn "Duplicate indexes found on $schema.$table"
            log_info "Indexes: $indexes"
            log_info "Columns: $columns"
        done

        sleep 86400  # Run once per day
    done &
}
