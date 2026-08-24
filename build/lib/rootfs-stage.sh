#!/bin/bash
set -e

# Crag Linux - Rootfs stage runner
#
# Executed by build-inner.sh as a CHILD PROCESS (not sourced) so the whole
# stage can run inside a user namespace for the prod squashfs path:
#
#   dev  (ext4):     bash build/lib/rootfs-stage.sh
#   prod (squashfs): unshare -r bash build/lib/rootfs-stage.sh
#
# Under `unshare -r` the build uid maps to root, so apk runs WITHOUT
# --usermode and applies package-metadata ownership for real, hooks see a
# root-owned tree, and mksquashfs (run in the same namespace) records
# root-owned files — all without sudo (GAP §3.5 ownership item).
#
# All inputs arrive via exported environment (set by build-inner.sh):
#   PROJECT_ROOT BOARD VARIANT BOARD_ARCH BOARD_DIR
#   BOARD_CONFIG_JSON VARIANT_CONFIG_JSON ROOTFS_DIR ROOTFS_TYPE
#   MANIFEST_FILE PACKAGES_MODE BUILD_OUTPUT USERS_CREATE SERVICES_*
#   LAYERS_JSON (docs/08 §4 ordered layer list — consumed by the merge engine)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/common.sh"
source "${SCRIPT_DIR}/rootfs.sh"
source "${SCRIPT_DIR}/merge.sh"
source "${SCRIPT_DIR}/cragd.sh"

: "${PROJECT_ROOT:?rootfs-stage.sh must be launched by build-inner.sh}"
: "${ROOTFS_DIR:?}" "${BOARD:?}" "${VARIANT:?}" "${BOARD_ARCH:?}"
: "${BOARD_DIR:?}" "${MANIFEST_FILE:?}"

ROOTFS_TYPE="${ROOTFS_TYPE:-ext4}"

if [ "$ROOTFS_TYPE" = "squashfs" ] && [ "$(id -u)" -ne 0 ]; then
    die "squashfs rootfs assembly must run as root in a user namespace (unshare -r) for correct ownership"
fi

# Clean previous rootfs
if [ -d "$ROOTFS_DIR" ]; then
    log_info "Removing previous rootfs..."
    rm -rf "$ROOTFS_DIR"
fi

# Create rootfs from packages (source: local repo only;
# binary: local repo + Chimera's signed binary repo, docs/03 §1).
# apk/repo arch is the cbuild arch (armv7hf -> armv7), not the board arch.
create_rootfs "$ROOTFS_DIR" "${CBUILD_ARCH:-$(cbuild_arch_for "$BOARD_ARCH")}" "$MANIFEST_FILE" "${PACKAGES_MODE:-source}"

# Apply overlays across every layer, in merge order (docs/08 §4). The merge
# order + resolved paths live in $LAYERS_JSON; apply_overlays delegates to
# merge_overlays.
apply_overlays "$ROOTFS_DIR"

# Install kernel into rootfs
install_kernel_to_rootfs "$ROOTFS_DIR" "$BOARD" "$BOARD_ARCH" "$BOARD_CONFIG_JSON"

# RAUC system.conf + keyring (+ fw_env.config on uboot boards) — docs/05 §2
generate_rauc_config "$ROOTFS_DIR" "$BOARD_CONFIG_JSON"

# Baked cragd defaults for the firstboot oneshot — docs/06 §2, docs/07 §3
generate_crag_defaults "$ROOTFS_DIR" "$BOARD_CONFIG_JSON"

# dhcpcd fallback config + /etc/resolv.conf symlink — docs/07 §2, M3 phase 3
bake_network_defaults "$ROOTFS_DIR"

# build-epoch time floor + minimal chrony.conf — docs/07 §6, M3 phase 4
bake_time_defaults "$ROOTFS_DIR"

# Image identity for GET /system (system.zig prefers CRAG_* keys)
stamp_os_release "$ROOTFS_DIR" "$BOARD" "$VARIANT"

# Build + install the cragd/cragctl binary (docs/06, AD-012)
build_cragd "$BOARD_ARCH" "$ROOTFS_DIR"

# Run hooks, interleaved by numeric prefix across every layer (docs/08 §4).
run_hooks "$ROOTFS_DIR"

log_info "Rootfs assembled at: ${ROOTFS_DIR}"

# Prod path: pack into a read-only squashfs inside the same namespace
if [ "$ROOTFS_TYPE" = "squashfs" ]; then
    make_squashfs_image "$ROOTFS_DIR" "${BUILD_OUTPUT}/rootfs.squashfs" "$BOARD_CONFIG_JSON"
fi
