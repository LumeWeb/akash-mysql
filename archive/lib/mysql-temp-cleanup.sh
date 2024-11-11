#!/bin/bash

source "${LIB_PATH}/mysql-logging.sh"

# Cleanup temporary tables and resources
cleanup_temp_tables() {
    while true; do
        # Get list of temp tables
        local temp_tables=$(mysql -N -e "
            SELECT TABLE_SCHEMA, TABLE_NAME 
            FROM information_schema.TABLES 
            WHERE TABLE_NAME LIKE '#sql%'
            OR TABLE_NAME LIKE 'tmp%'")
            
        if [ -n "$temp_tables" ]; then
            log_warn "Found temporary tables:"
            echo "$temp_tables" | while read schema table; do
                log_info "Analyzing temp table: $schema.$table"
                
                # Check table age
                local create_time=$(mysql -N -e "
                    SELECT CREATE_TIME 
                    FROM information_schema.TABLES 
                    WHERE TABLE_SCHEMA='$schema' 
                    AND TABLE_NAME='$table'")
                    
                local age=$(($(date +%s) - $(date -d "$create_time" +%s)))
                
                if [ $age -gt 3600 ]; then # Older than 1 hour
                    log_warn "Dropping old temp table: $schema.$table (age: ${age}s)"
                    mysql -e "DROP TABLE IF EXISTS \`$schema\`.\`$table\`"
                fi
            done
        fi
        
        # Cleanup temp files
        find /var/lib/mysql -name "*#sql*" -type f -mmin +60 -delete
        
        sleep 1800 # Run every 30 minutes
    done &
}

# Initialize temp cleanup
init_temp_cleanup() {
    log_info "Initializing temporary table cleanup..."
    cleanup_temp_tables
}
