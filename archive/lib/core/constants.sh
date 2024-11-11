#!/bin/bash

# Prevent multiple inclusion
[ -n "${CORE_CONSTANTS_SOURCED}" ] && return 0
declare -g CORE_CONSTANTS_SOURCED=1


# Core system settings
declare -gr CORE_MIN_FD=1024
declare -gr CORE_MAX_FD=65535

# MySQL timeouts and retry settings
declare -gr MYSQL_START_TIMEOUT=30
declare -gr MYSQL_HEALTH_PING_TIMEOUT=5
declare -gr MYSQL_HEALTH_QUERY_TIMEOUT=5
declare -gr MYSQL_MAX_RETRIES=5
declare -gr MYSQL_CONNECT_TIMEOUT=10
declare -gr MYSQL_QUERY_TIMEOUT=300


# Connection pool settings
declare -gr MAX_CONNECTIONS_BASE=1000
declare -gr THREAD_POOL_SIZE_MULTIPLIER=2
declare -gr CONNECTION_TIMEOUT=5


# Source lock-related constants
source "${LIB_PATH}/core/locks.sh"

# Monitoring intervals (seconds)
declare -gr BUFFER_POOL_CHECK_INTERVAL=300
declare -gr CONNECTION_POOL_CHECK_INTERVAL=60
declare -gr QUERY_ANALYZER_INTERVAL=300
declare -gr HEALTH_CHECK_INTERVAL=60
declare -gr HEALTH_CHECK_TIMEOUT=5
declare -gr MAX_HEALTH_FAILURES=3
declare -gr METRICS_COLLECTION_INTERVAL=30

# File paths
declare -gr CONFIG_DIR="/etc/mysql/conf.d"
declare -gr MYSQL_LOG_DIR="/var/log/mysql"
declare -gr DATA_DIR="/var/lib/mysql"
declare -gr RUN_DIR="/var/run/mysqld"

# Configuration files
declare -gr OPTIMIZATIONS_CONFIG="${CONFIG_DIR}/optimizations.cnf"
declare -gr SERVER_CONFIG="${CONFIG_DIR}/server.cnf"
declare -gr REPLICATION_CONFIG="${CONFIG_DIR}/replication.cnf"

# MySQL settings
declare -gr MYSQL_REPLICATION_PORT=3306
declare -gr MYSQL_ADMIN_PORT=33062
declare -gr MYSQL_MAX_ALLOWED_PACKET="64M"
declare -gr MYSQL_INNODB_BUFFER_POOL_SIZE="1G"
declare -gr MYSQL_INNODB_LOG_FILE_SIZE="256M"
declare -gr MYSQL_QUERY_CACHE_SIZE="256M"
declare -gr MYSQL_MAX_CONNECTIONS=1000

# ETCD paths
declare -gr ETCD_BASE="/mysql"
declare -gr ETCD_NODES="$ETCD_BASE/nodes"
declare -gr ETCD_ROLES="$ETCD_BASE/roles"
declare -gr ETCD_TOPOLOGY_MASTER="$ETCD_TOPOLOGY/master"
declare -gr ETCD_LOCK_STARTUP="$ETCD_LOCKS/startup"
declare -gr ETCD_LOCK_MASTER="$ETCD_LOCKS/master"

