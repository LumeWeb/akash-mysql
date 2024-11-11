#!/bin/bash

# Prevent multiple inclusion
[ -n "${MYSQL_COMMON_SOURCED}" ] && return 0
declare -g MYSQL_COMMON_SOURCED=1

source "${LIB_PATH}/core/logging.sh"
source "${LIB_PATH}/core/constants.sh"

# Global variables for process management
declare -g MYSQL_PID=""
declare -g LEASE_KEEPALIVE_PID=""
declare -g HEALTH_UPDATE_PID=""

# Handle Docker secrets and environment variables
file_env() {
    local var="$1"
    local fileVar="${var}_FILE"
    local def="${2:-}"
    if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
        log_error "Both $var and $fileVar are set (but are exclusive)"
        exit 1
    fi
    local val="$def"
    if [ "${!var:-}" ]; then
        val="${!var}"
    elif [ "${!fileVar:-}" ]; then
        val="$(< "${!fileVar}")"
    fi
    export "$var"="$val"
    unset "$fileVar"
}

# MySQL command retry wrapper with default credentials
mysql_retry() {
    local max_attempts=${MYSQL_MAX_RETRIES:-5}
    local attempt=1
    local wait_time=1

    while [ $attempt -le $max_attempts ]; do
        if timeout "${MYSQL_CONNECT_TIMEOUT}" mysql -u"${MYSQL_REPL_USERNAME}" -p"${MYSQL_REPL_PASSWORD}" "$@"; then
            return 0
        fi
        log_warn "MySQL command failed (attempt $attempt/$max_attempts)"
        sleep $((wait_time * attempt))
        attempt=$((attempt + 1))
    done

    log_error "MySQL command failed after $max_attempts attempts"
    return 1
}

# MySQL command retry wrapper with explicit authentication
mysql_retry_auth() {
    local user="$1"
    local password="$2"
    shift 2

    local max_attempts=${MYSQL_MAX_RETRIES:-5}
    local attempt=1
    local wait_time=1

    while [ $attempt -le $max_attempts ]; do
        if timeout "${MYSQL_CONNECT_TIMEOUT}" mysql --defaults-extra-file=<(echo $'[client]\npassword='"$password") -u"$user" "$@"; then
            return 0
        fi
        log_warn "MySQL command failed (attempt $attempt/$max_attempts)"
        sleep $((wait_time * attempt))
        attempt=$((attempt + 1))
    done

    log_error "MySQL command failed after $max_attempts attempts"
    return 1
}

# Wait for MySQL to be ready with comprehensive checks
wait_for_mysql() {
    local timeout=${1:-$MYSQL_START_TIMEOUT}
    local counter=0
    local connection_success=0
    local root_pwd="$2"

    log_info "Waiting for MySQL to become ready..."

    while [ $counter -lt $timeout ]; do
        # Check socket file first
        if [ ! -S "$MYSQL_SOCKET" ]; then
            if [ $((counter % 5)) -eq 0 ]; then
                log_info "Waiting for MySQL socket file at $MYSQL_SOCKET"
            fi
            sleep 1
            counter=$((counter + 1))
            continue
        fi

        # Try ping with root user
        if mysqladmin -u root -p"${MYSQL_ROOT_PASSWORD}" ping -s >/dev/null 2>&1; then
            log_info "MySQL responding to ping"

            # During initial startup, try no-password first
            if mysql -u root --connect-timeout=5 -e "SELECT 1" >/dev/null 2>&1; then
                log_info "MySQL accepting SQL connections (initial no-password state)"
                connection_success=1
                break
            # Then try with password if provided
            elif [ -n "$root_pwd" ] && mysql -u root -p"$root_pwd" --connect-timeout=5 -e "SELECT 1" >/dev/null 2>&1; then
                log_info "MySQL accepting SQL connections (with password)"
                connection_success=1
                break
            fi

            log_warn "MySQL ping successful but SQL connection failed - will retry"
        fi

        if [ $((counter % 5)) -eq 0 ]; then
            log_info "Still waiting for MySQL... ($counter/$timeout seconds)"
        fi

        sleep 1
        counter=$((counter + 1))
    done

    if [ $connection_success -eq 0 ]; then
        log_error "MySQL failed to become ready within ${timeout} seconds"
        if [ -f "$LOG_DIR/error.log" ]; then
            log_error "Last 10 lines of error log:"
            tail -n 10 "$LOG_DIR/error.log" >&2
        fi
        return 1
    fi

    return 0
}

# Get current GTID position
get_gtid_position() {
    local gtid_position
    # Use -N for skip-column-names and grep to filter out warnings
    gtid_position=$(mysql_retry_auth "$MYSQL_REPL_USERNAME" "$MYSQL_REPL_PASSWORD" -N -s -e "SELECT @@GLOBAL.GTID_EXECUTED" 2>/dev/null | grep -v "Warning" | tr -d '\n')
    echo "${gtid_position:-""}"
}

# Comprehensive health check
check_mysql_health() {
    local errors=0
    local status_details=()

    # Check process
    if ! pgrep mysqld >/dev/null; then
        status_details+=("process:down")
        log_error "MySQL process not running"
        errors=$((errors + 1))
    else
        status_details+=("process:up")
    fi

    # Check connectivity
    if ! mysql_retry_auth root "${MYSQL_ROOT_PASSWORD}" mysqladmin ping -h localhost --silent >/dev/null 2>&1; then
        status_details+=("ping:failed")
        log_error "MySQL not responding to ping"
        errors=$((errors + 1))
    else
        status_details+=("ping:ok")
    fi

    # Check read capability
    if ! mysql_retry -e 'SELECT 1' >/dev/null 2>&1; then
        status_details+=("read:failed")
        log_error "MySQL cannot execute SELECT"
        errors=$((errors + 1))
    else
        status_details+=("read:ok")
    fi

    # Only check write capability if we're master
    if [ "$CURRENT_ROLE" = "master" ]; then
        if ! mysql_retry -e 'CREATE TABLE IF NOT EXISTS health_check (id INT); DROP TABLE health_check;' mysql >/dev/null 2>&1; then
            status_details+=("write:failed")
            log_error "MySQL cannot execute DDL"
            errors=$((errors + 1))
        else
            status_details+=("write:ok")
        fi
    else
        # For slaves, just mark write as skipped
        status_details+=("write:skipped")
    fi

    # Export status details for etcd update
    export HEALTH_STATUS_DETAILS=$(IFS=,; echo "${status_details[*]}")
    return $errors
}