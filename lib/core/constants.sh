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
declare -gr DATA_DIR="/var/lib/mysql"
declare -gr RUN_DIR="/var/run/mysqld"
declare -gr MYSQL_SOCKET="${MYSQL_SOCKET_PATH:-${RUN_DIR}/mysqld.sock}"

# Backup settings
declare -gr BACKUP_CONFIG_DIR="${BACKUP_CONFIG_DIR:-/etc/mysql/backup}"
declare -gr BACKUP_KEY_DIR="${BACKUP_CONFIG_DIR}/keys"
declare -gr BACKUP_RETENTION_DAYS=7
declare -gr BACKUP_FULL_INTERVAL=86400    # 24 hours in seconds
declare -gr BACKUP_INCR_INTERVAL=21600    # 6 hours in seconds

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
