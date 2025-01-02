#!/bin/bash

# Prevent multiple inclusion
[ -n "${CORE_CONSTANTS_SOURCED}" ] && return 0
declare -g CORE_CONSTANTS_SOURCED=1

# MySQL timeouts and retry settings
declare -gr MYSQL_START_TIMEOUT=30
declare -gr MYSQL_MAX_RETRIES=5
declare -gr MYSQL_CONNECT_TIMEOUT=10
declare -gr MYSQL_DEFAULT_PASSWORD="MyN3wP4ssw0rd"

# File paths
declare -gr CONFIG_DIR="/etc/my.cnf.d"
declare -gr LOG_DIR="/var/log/mysql"
declare -gr DATA_ROOT="/var/lib/data"
declare -gr DATA_DIR="${DATA_ROOT}/mysql"
declare -gr MYSQL_FILES_DIR="${DATA_ROOT}/mysql-files"
declare -gr RUN_DIR="/var/run/mysqld"
declare -gr STATE_DIR="${DATA_ROOT}/state"
declare -gr BACKUP_STATE_DIR="${STATE_DIR}/backup"
declare -gr MYSQL_SOCKET="${MYSQL_SOCKET_PATH:-${RUN_DIR}/mysqld.sock}"

# Backup settings
declare -gr BACKUP_CONFIG_DIR="${STATE_DIR}/backup/config"
declare -gr BACKUP_KEY_DIR="${BACKUP_CONFIG_DIR}/keys"
declare -gr BACKUP_RETENTION_DAYS=7
declare -gr BACKUP_FULL_INTERVAL=86400    # 24 hours in seconds
declare -gr BACKUP_INCR_INTERVAL=21600    # 6 hours in seconds

# Backup configuration
declare -gr BACKUP_ENABLED="${BACKUP_ENABLED:-true}"

# Required S3 environment variables
declare -gr REQUIRED_S3_VARS=(
    "S3_ACCESS_KEY"
    "S3_SECRET_KEY" 
    "S3_ENDPOINT"
    "S3_BUCKET"
    "S3_PATH"
)

# Required backup environment variables
declare -gr REQUIRED_BACKUP_VARS=(
    "BACKUP_CONFIG_DIR"
    "BACKUP_RETENTION_DAYS"
    "BACKUP_FULL_INTERVAL"
    "BACKUP_INCR_INTERVAL"
    "MYSQL_ROOT_PASSWORD"
)

# S3 defaults
declare -gr S3_SSL="${S3_SSL:-false}"
declare -gr S3_PATH="${S3_PATH:-backups}"

# Recovery preferences
declare -gr RECOVER_FROM_BACKUP="${RECOVER_FROM_BACKUP:-true}"

# SSL configuration
declare -gr SSL_STATE_DIR="${STATE_DIR}/ssl"
declare -gr MYSQL_SSL_DIR="${SSL_STATE_DIR}"
declare -gr MYSQL_SSL_CA="${MYSQL_SSL_DIR}/ca-cert.pem"
declare -gr MYSQL_SSL_CERT="${MYSQL_SSL_DIR}/server-cert.pem"
declare -gr MYSQL_SSL_KEY="${MYSQL_SSL_DIR}/server-key.pem"
declare -gr MYSQL_SSL_TRUST_DIR="${STATE_DIR}/ca-trust"

# State directory structure
declare -gr LOCKS_DIR="${STATE_DIR}/locks"
declare -gr CONFIG_STATE_DIR="${STATE_DIR}/config"
declare -gr CRON_STATE_DIR="${STATE_DIR}/cron"
declare -gr ETCD_STATE_DIR="${STATE_DIR}/etcd"
declare -gr MONITOR_STATE_DIR="${STATE_DIR}/monitor"
declare -gr CRON_TAB_FILE="${CRON_STATE_DIR}/mysql-backup"

# Monitor PID files
declare -gr ERROR_MONITOR_PID="${MONITOR_STATE_DIR}/error_monitor.pid"
declare -gr BACKUP_MONITOR_PID="${MONITOR_STATE_DIR}/backup_monitor.pid"
declare -gr LEASE_MONITOR_PID="${MONITOR_STATE_DIR}/lease_monitor.pid"

# Log files
declare -gr ERROR_LOG="${LOG_DIR}/error.log"
declare -gr BACKUP_LOG="${LOG_DIR}/backup.log"
declare -gr LEASE_LOG="${LOG_DIR}/lease.log"
declare -gr INIT_ERROR_LOG="${LOG_DIR}/init-error.log"
declare -gr SLOW_QUERY_LOG="${LOG_DIR}/slow-query.log"

# Base paths for MySQL cluster coordination
declare -gr ETC_PREFIX=${ETC_PREFIX:-"/mysql"}  # Allow override via environment variable
declare -gr ETCD_BASE="${ETC_PREFIX}"
declare -gr ETCD_NODES="${ETCD_BASE}/nodes"
declare -gr ETCD_TOPOLOGY_PREFIX="${ETCD_BASE}/topology"
declare -gr ETCD_MASTER_KEY="${ETCD_TOPOLOGY_PREFIX}/master"
declare -gx ETCDCTL_USER
declare -gx ETCDCTL_API
