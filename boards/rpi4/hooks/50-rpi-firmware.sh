# shellcheck shell=bash
# (sourced by build/lib/rootfs.sh run_hooks — not executed directly)
# Install Raspberry Pi boot firmware to boot partition
# This hook handles the RPi-specific boot setup

install_rpi_boot() {
    if [ -z "${BOOT_DIR:-}" ]; then
        log_warn "BOOT_DIR not set, skipping RPi firmware install"
        return 0
    fi

    log_info "Installing Raspberry Pi boot firmware..."

    # Copy firmware files if they exist in the rootfs
    if [ -d "${ROOTFS_DIR}/boot" ]; then
        # RPi firmware blobs
        for f in bootcode.bin start.elf start4.elf fixup.dat fixup4.dat; do
            if [ -f "${ROOTFS_DIR}/boot/${f}" ]; then
                cp "${ROOTFS_DIR}/boot/${f}" "${BOOT_DIR}/"
                log_info "  Copied ${f}"
            fi
        done

        # Kernel image
        for f in "${ROOTFS_DIR}"/boot/vmlinuz-*; do
            if [ -f "$f" ]; then
                cp "$f" "${BOOT_DIR}/kernel8.img"
                log_info "  Copied kernel as kernel8.img"
                break
            fi
        done

        # Device tree blobs
        if [ -d "${ROOTFS_DIR}/boot/dtbs" ]; then
            cp -r "${ROOTFS_DIR}/boot/dtbs/"* "${BOOT_DIR}/" 2>/dev/null || true
            log_info "  Copied device tree blobs"
        fi
    fi

    # Create config.txt
    cat > "${BOOT_DIR}/config.txt" << 'RPIEOF'
# Astro Linux - Raspberry Pi 4 boot configuration
arm_64bit=1
kernel=kernel8.img
disable_overscan=1
dtparam=audio=on

[pi4]
max_framebuffers=2
arm_boost=1

[all]
enable_uart=1
RPIEOF

    # Create cmdline.txt from kernel cmdline
    echo "${KERNEL_CMDLINE}" > "${BOOT_DIR}/cmdline.txt"

    log_info "RPi boot firmware installation complete"
}

install_rpi_boot
