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
