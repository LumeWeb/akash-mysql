#!/bin/bash
set -e

source "${LIB_PATH}/mysql-common.sh"
source "${LIB_PATH}/mysql-startup.sh"

# Source cleanup functions
source "${LIB_PATH}/cleanup-functions.sh"
# Preserve existing traps
trap 'err=$?; cleanup; exit $err' SIGTERM SIGINT EXIT

log_info "Starting MySQL in standalone mode..."

# Set role for this instance
ROLE="standalone"



# Start MySQL in standalone mode
if ! start_mysql "$ROLE" 1 "$@"; then
    log_error "Failed to start MySQL server"
    exit 1
fi

log_info "MySQL is running in standalone mode"
log_info "Port: ${PORT}"

# Create or update root password if needed
if [ -n "$MYSQL_ROOT_PASSWORD" ]; then
    mysql -u root << EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
FLUSH PRIVILEGES;
EOF
fi

# Create additional users if specified
if [ -n "$MYSQL_USER" ] && [ -n "$MYSQL_PASSWORD" ]; then
    mysql -u root -p"$MYSQL_ROOT_PASSWORD" << EOF
CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO '${MYSQL_USER}'@'%';
FLUSH PRIVILEGES;
EOF
fi

# Create initial database if specified
if [ -n "$MYSQL_DATABASE" ]; then
    mysql -u root -p"$MYSQL_ROOT_PASSWORD" << EOF
CREATE DATABASE IF NOT EXISTS \`${MYSQL_DATABASE}\`;
EOF
fi

# Wait for MySQL process
wait $MYSQL_PID
