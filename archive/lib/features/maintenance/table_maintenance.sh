#!/bin/bash

# Prevent multiple inclusion
[ -n "${TABLE_MAINTENANCE_SOURCED}" ] && return 0
declare -g TABLE_MAINTENANCE_SOURCED=1

# Core dependencies only
source "${LIB_PATH}/core/logging.sh"
source "${LIB_PATH}/core/constants.sh"

# Schedule regular table optimization
# Track maintenance PIDs
declare -g MAINTENANCE_PID=""

# Register for role changes
register_role_change_handler "table_maintenance" schedule_table_maintenance

schedule_table_maintenance() {
    local role=$1
    
    log_info "Table maintenance handling role change to: $role"
    
    # Kill existing maintenance if running
    if [ -n "$MAINTENANCE_PID" ] && kill -0 $MAINTENANCE_PID 2>/dev/null; then
        log_info "Stopping existing maintenance process (PID: $MAINTENANCE_PID)"
        kill -TERM $MAINTENANCE_PID
        wait $MAINTENANCE_PID 2>/dev/null
        
        # Safely stop long-running maintenance queries
        mysql -e "
            KILL QUERY IF EXISTS (
                SELECT id FROM information_schema.processlist 
                WHERE command = 'Query'
                AND TIME > 3600  -- Only kill if running > 1 hour
                AND (info LIKE 'OPTIMIZE%' OR info LIKE 'ANALYZE%')
            )
        " || true
    fi
    
    # Exit if not in correct role
    if [ "$role" != "standalone" ] && [ "$role" != "master" ]; then
        log_info "Table maintenance disabled - not master/standalone (current role: $role)"
        return 0
    }

    # Wait briefly before starting to allow role transition to complete
    sleep 2
    
    (while true; do
        log_info "Starting scheduled table maintenance (role: $role)"
        
        # Get list of tables that need optimization
        mysql -N -e "
            SELECT CONCAT(table_schema, '.', table_name)
            FROM information_schema.tables 
            WHERE table_schema NOT IN ('mysql', 'information_schema', 'performance_schema')
            AND (data_free > 0 OR table_rows > 100000)" | while read table; do
            
            log_info "Optimizing table: $table"
            mysql -e "OPTIMIZE TABLE $table" || log_error "Failed to optimize table: $table"
            
            sleep 2
        done

        sleep 86400
    done &
}
#!/bin/bash

# Prevent multiple inclusion
[ -n "${MYSQL_MAINTENANCE_SOURCED}" ] && return 0
declare -g MYSQL_MAINTENANCE_SOURCED=1

# Core dependencies only
source "${LIB_PATH}/core/logging.sh"
source "${LIB_PATH}/core/constants.sh"

# Initialize maintenance functions
init_maintenance() {
    # Start monitoring and maintenance
    source "${LIB_PATH}/features/monitoring/table_monitor.sh"
    source "${LIB_PATH}/features/maintenance/table_maintenance.sh"
}
