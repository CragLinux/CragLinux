# Enable/disable dinit services based on variant config
# dinit uses symlinks in /etc/dinit.d/boot.d/

enable_services() {
    local boot_d="${ROOTFS_DIR}/etc/dinit.d/boot.d"
    mkdir -p "$boot_d"

    # Enable services
    if [ -n "${SERVICES_ENABLE:-}" ]; then
        for svc in $SERVICES_ENABLE; do
            if [ -f "${ROOTFS_DIR}/etc/dinit.d/${svc}" ] || \
               [ -f "${ROOTFS_DIR}/usr/lib/dinit.d/${svc}" ]; then
                ln -sf "../${svc}" "${boot_d}/${svc}"
                log_info "Enabled service: ${svc}"
            else
                log_warn "Service definition not found: ${svc} (will be enabled anyway)"
                ln -sf "../${svc}" "${boot_d}/${svc}"
            fi
        done
    fi

    # Disable services
    if [ -n "${SERVICES_DISABLE:-}" ]; then
        for svc in $SERVICES_DISABLE; do
            rm -f "${boot_d}/${svc}"
            log_info "Disabled service: ${svc}"
        done
    fi
}

enable_services
