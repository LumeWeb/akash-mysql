#!/bin/bash

# Handle file-based environment variables
process_env_file() {
    local var="$1"
    local fileVar="${var}_FILE"
    local def="${2:-}"
    
    if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
        echo >&2 "error: both $var and $fileVar are set (but are exclusive)"
        return 1
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

# Process all MySQL environment variables
setup_mysql_env() {
    # Process all environment variables
    process_env_file 'MYSQL_ROOT_PASSWORD'
    process_env_file 'MYSQL_DATABASE'
    process_env_file 'MYSQL_USER'
    process_env_file 'MYSQL_PASSWORD'
    process_env_file 'MYSQL_ROOT_HOST' '%'
    process_env_file 'MYSQL_REPL_USER'
    process_env_file 'MYSQL_REPL_PASSWORD'
    
    return 0
}

# Verify MySQL credentials
verify_mysql_env() {
    local cluster_mode=${1:-false}

    if [ -z "$MYSQL_ROOT_PASSWORD" ]; then
        echo "MYSQL_ROOT_PASSWORD must be set" >&2
        return 1
    fi

    # Only verify replication credentials in cluster mode
    if [ "$cluster_mode" = "true" ]; then
        if [ -z "$MYSQL_REPL_USER" ] || [ -z "$MYSQL_REPL_PASSWORD" ]; then
            echo "MYSQL_REPL_USER and MYSQL_REPL_PASSWORD must be set in cluster mode" >&2
            return 1
        fi
    fi

    return 0
}

# Validate node ID format
validate_node_id() {
    local node_id=$1
    if [[ ! $node_id =~ ^[a-zA-Z0-9_.-]+:[0-9]+$ ]]; then
        echo "Invalid node ID format. Expected format: host:port" >&2
        return 1
    fi
    return 0
}

# Verify required environment variables
verify_env() {
    # Process environment variables first
    setup_mysql_env
    
    if [ -z "$HOST" ] || [ -z "$PORT" ]; then
        echo "HOST and PORT must be set" >&2
        return 1
    fi

    if ! validate_node_id "$NODE_ID"; then
        return 1
    fi

    # Pass CLUSTER_MODE to verify_mysql_env
    verify_mysql_env "$CLUSTER_MODE"
    return $?
}
