#!/bin/bash
# Astro Linux - Disk image creation
# Sourced by build-inner.sh, not executed directly.
#
# TODO: Implement in a future session.
# This will handle:
#   - Creating raw disk images (dd)
#   - Partitioning (parted) per board.toml disk settings
#   - Formatting partitions (mkfs.vfat, mkfs.ext4)
#   - Loop device setup
#   - Copying rootfs to root partition
#   - Boot partition setup (kernel, DTBs, boot config)
#   - Bootloader installation (via board hooks)
#   - Compression (zstd) and checksums (sha256)

create_image() {
    local board_name="$1"
    local variant_name="$2"
    local rootfs_dir="$3"

    log_warn "Image creation not yet implemented"
    log_warn "Rootfs is available at: ${rootfs_dir}"
    log_warn "To create an image manually, see: build/create-system-image.sh"
}
