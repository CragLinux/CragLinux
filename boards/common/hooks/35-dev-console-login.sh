# shellcheck shell=bash
# (sourced by build/lib/rootfs.sh run_hooks — not executed directly)
#
# DEV variants only: unlock root for SERIAL-CONSOLE login (empty
# password). Hardware bring-up (M5) needs a shell on the UART before
# networking is up; the QEMU flows never exposed the gap because the
# harness only asserts the login prompt and drives the guest over ssh.
# The packaged shadow leaves root with an invalid hash ("x") and
# 10-create-users locks every variant user, so a dev image on real
# hardware was a brick from the console.
#
# Scope guards, both required to unlock:
#   * variant name not prod/production (mirror of 30-dev-ssh-key.sh)
#   * rootfs is NOT squashfs — a prod-SHAPED variant under any name
#     (e.g. an external tree's acme-prod) stays sealed (AD-004)
# Remote stays key-only either way: sshd's PermitEmptyPasswords
# defaults to no, so the empty password works on the console alone.

unlock_dev_console_root() {
    case "${VARIANT:-}" in
        prod|production) return 0 ;;
    esac
    [ "${ROOTFS_TYPE:-ext4}" = "squashfs" ] && return 0

    local shadow_f="${ROOTFS_DIR}/etc/shadow"
    [ -f "$shadow_f" ] || return 0

    local mode
    mode=$(stat -c %a "$shadow_f")
    chmod u+w "$shadow_f"
    # root:<anything>: -> root:: (empty password, console login allowed)
    sed -i 's/^root:[^:]*:/root::/' "$shadow_f"
    chmod "$mode" "$shadow_f"
    log_info "  Dev image: root console login unlocked (empty password; ssh stays key-only)"
}

unlock_dev_console_root
