# shellcheck shell=bash
# (sourced by build/lib/rootfs.sh run_hooks — not executed directly)
# DEV variants only: install the committed dev SSH test key as root's
# authorized_keys (docs/02 §3: dev images are loudly unsealed; sshd is in
# the dev package set). This is what lets the AD-020 update/rollback test
# harness and (at M4) `astro deploy` drive a dev guest. sshd's default
# PermitRootLogin=prohibit-password means key-only root access.
# Prod variants: skipped — prod ships no SSH daemon and no interactive
# users (docs/02 §7).

install_dev_ssh_key() {
    case "${VARIANT:-}" in
        prod|production) return 0 ;;
    esac

    local pubkey="${PROJECT_ROOT}/keys/dev/ssh-test.pub"
    if [ ! -f "$pubkey" ]; then
        log_warn "dev SSH test key missing (${pubkey}) — run ./build/astro-keys.sh init-dev; skipping"
        return 0
    fi
    # Only meaningful when the image actually ships sshd
    if [ ! -f "${ROOTFS_DIR}/usr/bin/sshd" ] && [ ! -f "${ROOTFS_DIR}/usr/sbin/sshd" ]; then
        log_info "  no sshd in image, skipping dev SSH key"
        return 0
    fi

    mkdir -p "${ROOTFS_DIR}/root/.ssh"
    chmod 700 "${ROOTFS_DIR}/root" "${ROOTFS_DIR}/root/.ssh"
    cp "$pubkey" "${ROOTFS_DIR}/root/.ssh/authorized_keys"
    chmod 600 "${ROOTFS_DIR}/root/.ssh/authorized_keys"
    log_info "  Installed dev SSH test key (root authorized_keys)"
}

install_dev_ssh_key
