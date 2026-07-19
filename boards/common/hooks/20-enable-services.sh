# Enable/disable dinit services based on variant config.
#
# dinit-chimera layout (verified against the built rootfs): the 'boot'
# service declares "waits-for.d: /etc/dinit.d/boot.d" — entries there are
# activated by NAME (dinit resolves the service through its normal service
# dirs), so even a dangling symlink works. We still point the symlink at
# the actual service description like the packaged links do
# (/usr/lib/dinit.d/boot.d/<svc> -> ../<svc>): /etc-local services get
# ../<svc>, packaged services get ../../../usr/lib/dinit.d/<svc>.

enable_services() {
    local boot_d="${ROOTFS_DIR}/etc/dinit.d/boot.d"
    mkdir -p "$boot_d"

    # Enable services
    if [ -n "${SERVICES_ENABLE:-}" ]; then
        for svc in $SERVICES_ENABLE; do
            local target
            if [ -f "${ROOTFS_DIR}/etc/dinit.d/${svc}" ]; then
                target="../${svc}"
            elif [ -f "${ROOTFS_DIR}/usr/lib/dinit.d/${svc}" ]; then
                target="../../../usr/lib/dinit.d/${svc}"
            else
                log_warn "Service definition not found: ${svc} (enabling by name anyway)"
                target="../${svc}"
            fi
            ln -sf "$target" "${boot_d}/${svc}"
            log_info "Enabled service: ${svc} (-> ${target})"
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
