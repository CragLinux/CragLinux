# shellcheck shell=bash
# (sourced by build/lib/rootfs.sh run_hooks — not executed directly)
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

    # Platform services (always in the boot set, not variant-selectable):
    # boot-success is the docs/02 §5.1 milestone; it hard-depends on
    # cragd (M1: the health-check stub) and data-mount, so enabling it
    # by name activates the whole chain. Soft (waits-for) from 'boot', so
    # a failed health check surfaces as [FAILED] without blocking login.
    ln -sf "../boot-success" "${boot_d}/boot-success"
    log_info "Enabled platform service: boot-success (-> ../boot-success)"
    # dbus-daemon: system bus for rauc (and cragd at M3); the service
    # definition ships in the dbus package as "dbus-daemon".
    ln -sf "../../../usr/lib/dinit.d/dbus-daemon" "${boot_d}/dbus-daemon"
    log_info "Enabled platform service: dbus-daemon"
    # rauc-mark-good transitively activates bootenv-mount (depends-on)
    # and the rauc daemon (waits-for) — docs/05 §4.
    ln -sf "../rauc-mark-good" "${boot_d}/rauc-mark-good"
    log_info "Enabled platform service: rauc-mark-good"
    # watchdog: forces a reboot when boot-success is never reached, so
    # bootloader attempt counters advance (docs/05 §4; no-op off A/B)
    ln -sf "../crag-boot-watchdog" "${boot_d}/crag-boot-watchdog"
    log_info "Enabled platform service: crag-boot-watchdog"
    # firstboot: once per /data lifetime (docs/07 §3; no-op on direct boots)
    ln -sf "../firstboot" "${boot_d}/firstboot"
    log_info "Enabled platform service: firstboot"
    # chronyd: NTP client (docs/07 §6, M3 phase 4) — resolves to the
    # /etc/dinit.d shadow (minimal /etc/crag/chrony.conf). The packaged
    # 'chrony' waitsync boot gate ships enabled in chrony-dinit's own
    # boot.d but is neutralized by its /etc/dinit.d shadow (no 180 s
    # offline boot stall; see that file). crag-portal-redirect-{start,
    # stop} and crag-factory-reset are deliberately NOT enabled here:
    # they are on-demand root oneshots cragd dispatches over the dinit
    # control socket (docs/02 §7).
    ln -sf "../chronyd" "${boot_d}/chronyd"
    log_info "Enabled platform service: chronyd"

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
