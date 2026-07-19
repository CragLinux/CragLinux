#!/bin/bash
set -e

# Astro Linux - Rootfs stage runner
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
#   PROJECT_ROOT BOARD VARIANT BOARD_ARCH BOARD_DIR EXTERNAL_DIR
#   BOARD_CONFIG_JSON VARIANT_CONFIG_JSON ROOTFS_DIR ROOTFS_TYPE
#   MANIFEST_FILE PACKAGES_MODE BUILD_OUTPUT USERS_CREATE SERVICES_*

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/common.sh"
source "${SCRIPT_DIR}/rootfs.sh"

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

# Apply overlays
apply_overlays "$ROOTFS_DIR" "$BOARD_DIR" "$VARIANT" "${EXTERNAL_DIR:-}"

# Install kernel into rootfs
install_kernel_to_rootfs "$ROOTFS_DIR" "$BOARD" "$BOARD_ARCH" "$BOARD_CONFIG_JSON"

# Run hooks
run_hooks "$ROOTFS_DIR" "$BOARD_DIR"

log_info "Rootfs assembled at: ${ROOTFS_DIR}"

# Prod path: pack into a read-only squashfs inside the same namespace
if [ "$ROOTFS_TYPE" = "squashfs" ]; then
    make_squashfs_image "$ROOTFS_DIR" "${BUILD_OUTPUT}/rootfs.squashfs" "$BOARD_CONFIG_JSON"
fi
