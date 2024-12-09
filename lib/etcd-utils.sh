#!/bin/bash

# Prevent multiple inclusion
[ -n "${ETCD_UTILS_SOURCED}" ] && return 0
declare -g ETCD_UTILS_SOURCED=1

source "${LIB_PATH}/core/logging.sh"

# Convert decimal lease ID to hex format
lease_id_to_hex() {
    local decimal_id=$1
    printf '%x' "$decimal_id"
}

# Convert hex lease ID to decimal format
lease_id_to_decimal() {
    local hex_id=$1
    printf '%d' "0x$hex_id"
}
