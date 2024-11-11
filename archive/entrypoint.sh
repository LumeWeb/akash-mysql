#!/bin/bash
set -eo pipefail
shopt -s nullglob

set -x

source ./paths.sh
source "${LIB_PATH}/core/logging.sh"
source "${LIB_PATH}/mysql-init.sh"
source "${LIB_PATH}/mysql-startup.sh"

# Main entrypoint logic
main() {
    # Environment setup
    CLUSTER_MODE=${CLUSTER_MODE:-false}
    HOST=${HOST:-localhost}
    PORT=${PORT:-3306}
    NODE_ID="${HOST}:${PORT}"

    # Check if command starts with an option
    if [ "${1:0:1}" = '-' ]; then
        set -- mysqld "$@"
    fi

    # Check for help flags
    for arg; do
        case "$arg" in
            -'?'|--help|--print-defaults|-V|--version)
                exec "$@"
                ;;
        esac
    done

    if [ "$1" = 'mysqld' ]; then
        # Get data directory
        DATADIR=$(mysqld --verbose --help --log-bin-index="$(mktemp -u)" 2>/dev/null | awk '$1 == "datadir" { print $2; exit }')

        # Initialize if needed
        if initialize_mysql "$DATADIR" "$MYSQL_ROOT_PASSWORD"; then
            log_info "Database initialized, starting MySQL..."
            if [ "$CLUSTER_MODE" = "true" ]; then
               exec "${LIB_PATH}/cluster-start.sh" "$@"
            else
               exec "${LIB_PATH}/standalone-start.sh" "$@"
            fi
        else
            log_info "Database exists, starting MySQL..."
            if [ "$CLUSTER_MODE" = "true" ]; then
               exec "${LIB_PATH}/cluster-start.sh" "$@"
            else
               exec "${LIB_PATH}/standalone-start.sh" "$@"
            fi
        fi

        return 0
    fi

    # If we got here, just execute the command
    exec "$@"
}

main "$@"
