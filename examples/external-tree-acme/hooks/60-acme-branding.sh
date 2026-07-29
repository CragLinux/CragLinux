# shellcheck shell=bash
# (sourced by build/lib/rootfs.sh run_hooks — not executed directly)
#
# ACME tree hook (docs/08 §2). Hooks from ALL layers interleave by
# numeric prefix (docs/08 §4): core 05/10/20/40 run before this 60,
# board hooks numbered higher run after. The documented hook env
# (docs/08 §8) provides ROOTFS_DIR, BOARD, VARIANT, ROOTFS_TYPE,
# PROJECT_ROOT and the log_* helpers.
#
# Effect: brand /etc/motd from the acme-branding package's config —
# a deliberately small, idempotent example of a tree hook.
if ! grep -q "ACME Gateway" "${ROOTFS_DIR}/etc/motd" 2>/dev/null; then
    {
        echo ""
        echo "ACME Gateway (${VARIANT}) — built from external-tree-acme"
        echo "docs/08 is the contract; this line came from hooks/60-acme-branding.sh"
    } >> "${ROOTFS_DIR}/etc/motd"
    log_info "  [acme] branded /etc/motd"
fi
