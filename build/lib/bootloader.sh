#!/bin/bash
# Astro Linux - Bootloader build
# Sourced by build-inner.sh, not executed directly.
#
# U-Boot and ATF build support. Currently a stub — full implementation
# will be added in a future session.

build_bootloader() {
    local board="$1"
    local board_arch="$2"
    local board_dir="$3"
    local board_config_json="$4"

    local boot_type
    boot_type=$(echo "$board_config_json" | jq -r '.bootloader.type')

    case "$boot_type" in
        direct|rpi-boot|none)
            log_info "Bootloader type '${boot_type}' — no bootloader build needed"
            return 0
            ;;
        u-boot)
            log_warn "U-Boot build not yet implemented"
            log_warn "This will be added in a future session"
            log_warn "For QEMU testing, use bootloader.type = \"direct\" with -kernel boot"
            return 0
            ;;
        *)
            die "Unknown bootloader type: ${boot_type}"
            ;;
    esac
}
