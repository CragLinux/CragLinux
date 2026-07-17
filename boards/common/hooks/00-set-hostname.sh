# Set hostname from board and variant names
# Runs inside rootfs assembly

set_hostname() {
    local hostname
    hostname=$(echo "${BOARD_NAME}-${VARIANT_NAME}" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    echo "$hostname" > "${ROOTFS_DIR}/etc/hostname"
    log_info "Set hostname: $hostname"
}

set_hostname
