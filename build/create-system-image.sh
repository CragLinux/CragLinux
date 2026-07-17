#!/bin/bash
set -e

# Create Bootable System Image
# Generates a complete bootable image from built packages

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

usage() {
    cat << EOF
Usage: $0 <architecture> <device> [profile]

Create a bootable system image for embedded devices

Arguments:
    architecture    Target architecture (armv7hf, aarch64)
    device          Device configuration (generic, rpi)
    profile         System profile (minimal, base, full) [default: base]

Examples:
    $0 aarch64 rpi base           # Raspberry Pi image with base system
    $0 armv7hf generic minimal    # Generic ARM minimal image
    $0 aarch64 rpi full           # Full-featured Raspberry Pi image

Requirements:
    - sudo access for loop device manipulation
    - parted, mkfs.vfat, mkfs.ext4
    - Optional: qemu-img for qcow2 format

Output:
    Images are created in: build/state/images/<arch>/

EOF
    exit 1
}

# Parse arguments
ARCH="${1:-}"
DEVICE="${2:-}"
PROFILE="${3:-base}"

if [ -z "$ARCH" ] || [ -z "$DEVICE" ]; then
    usage
fi

# Normalize architecture
case "$ARCH" in
    armv7hf|armv7) ARCH="armv7hf" ;;
    aarch64|arm64) ARCH="aarch64" ;;
    *) log_error "Unsupported architecture: $ARCH"; exit 1 ;;
esac

# Configuration
IMAGE_DIR="${PROJECT_ROOT}/build/state/images/${ARCH}"
PKG_DIR="${PROJECT_ROOT}/build/state/${ARCH}/packages"
DEVICE_CONF="${PROJECT_ROOT}/build/cbuild-profiles/devices/${DEVICE}.conf"
IMAGE_NAME="${ARCH}-${DEVICE}-${PROFILE}"
IMAGE_FILE="${IMAGE_DIR}/${IMAGE_NAME}.img"
ROOTFS_TAR="${IMAGE_DIR}/${IMAGE_NAME}-rootfs.tar.gz"

# Default sizes (can be overridden by device config)
BOOT_SIZE=256  # MB
ROOT_SIZE=2048 # MB

verify_requirements() {
    log_info "Checking requirements..."

    local missing=()

    for tool in parted mkfs.vfat mkfs.ext4 losetup; do
        if ! command -v $tool &> /dev/null; then
            missing+=($tool)
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        log_error "Missing tools: ${missing[*]}"
        echo "Install on Fedora: sudo dnf install parted dosfstools e2fsprogs util-linux"
        echo "Install on Debian/Ubuntu: sudo apt install parted dosfstools e2fsprogs util-linux"
        exit 1
    fi

    if ! sudo -n true 2>/dev/null; then
        log_warn "This script requires sudo access"
        log_warn "You may be prompted for your password"
    fi

    if [ ! -f "$DEVICE_CONF" ]; then
        log_error "Device configuration not found: $DEVICE_CONF"
        log_error "Available devices: $(ls ${PROJECT_ROOT}/build/cbuild-profiles/devices/*.conf 2>/dev/null | xargs basename -s .conf | tr '\n' ' ')"
        exit 1
    fi

    log_info "Requirements met"
}

load_device_config() {
    log_info "Loading device configuration: $DEVICE"

    source "$DEVICE_CONF"

    # Override sizes if defined in device config
    BOOT_SIZE=${BOOT_PARTITION_SIZE:-256M}
    ROOT_SIZE=${ROOT_PARTITION_SIZE:-2G}

    # Convert sizes to MB if needed
    BOOT_SIZE=$(echo $BOOT_SIZE | sed 's/M$//')
    ROOT_SIZE=$(echo $ROOT_SIZE | sed 's/G$//')
    ROOT_SIZE=$((ROOT_SIZE * 1024))  # Convert GB to MB

    log_info "Device: ${DEVICE_NAME}"
    log_info "Architecture: ${DEVICE_ARCH}"
    log_info "Bootloader: ${BOOTLOADER}"
    log_info "Kernel: ${KERNEL_PACKAGE}"
}

create_image_file() {
    log_info "Creating disk image..."

    mkdir -p "$IMAGE_DIR"

    local total_size=$((BOOT_SIZE + ROOT_SIZE + 8))  # +8MB for GPT tables

    dd if=/dev/zero of="$IMAGE_FILE" bs=1M count=$total_size status=progress

    log_info "Image file created: $IMAGE_FILE (${total_size}MB)"
}

partition_image() {
    log_info "Partitioning image..."

    # Create GPT partition table
    sudo parted "$IMAGE_FILE" --script mklabel gpt

    # Create boot partition (FAT32)
    sudo parted "$IMAGE_FILE" --script mkpart primary fat32 1MiB ${BOOT_SIZE}MiB
    sudo parted "$IMAGE_FILE" --script set 1 boot on

    # Create root partition (ext4)
    local root_start=$((BOOT_SIZE))
    local root_end=$((BOOT_SIZE + ROOT_SIZE))
    sudo parted "$IMAGE_FILE" --script mkpart primary ext4 ${root_start}MiB ${root_end}MiB

    log_info "Partitions created"
}

setup_loop_device() {
    log_info "Setting up loop device..."

    LOOP_DEV=$(sudo losetup -f --show -P "$IMAGE_FILE")
    log_info "Loop device: $LOOP_DEV"

    # Give kernel time to create partition devices
    sleep 1

    if [ ! -b "${LOOP_DEV}p1" ]; then
        log_error "Partition devices not created"
        sudo losetup -d "$LOOP_DEV"
        exit 1
    fi
}

format_partitions() {
    log_info "Formatting partitions..."

    # Format boot partition (FAT32)
    sudo mkfs.vfat -F 32 -n BOOT "${LOOP_DEV}p1"

    # Format root partition (ext4)
    sudo mkfs.ext4 -L rootfs "${LOOP_DEV}p2"

    log_info "Partitions formatted"
}

mount_partitions() {
    log_info "Mounting partitions..."

    MOUNT_ROOT=$(mktemp -d)
    MOUNT_BOOT="${MOUNT_ROOT}/boot"

    sudo mount "${LOOP_DEV}p2" "$MOUNT_ROOT"
    sudo mkdir -p "$MOUNT_BOOT"
    sudo mount "${LOOP_DEV}p1" "$MOUNT_BOOT"

    log_info "Mounted at: $MOUNT_ROOT"
}

install_base_system() {
    log_info "Installing base system..."

    # TODO: Extract built packages from $PKG_DIR
    # For now, create basic directory structure

    sudo mkdir -p "$MOUNT_ROOT"/{bin,boot,dev,etc,home,lib,mnt,opt,proc,root,run,sbin,srv,sys,tmp,usr,var}
    sudo mkdir -p "$MOUNT_ROOT"/usr/{bin,include,lib,libexec,sbin,share,src}
    sudo mkdir -p "$MOUNT_ROOT"/var/{cache,lib,local,lock,log,opt,run,spool,tmp}

    sudo chmod 1777 "$MOUNT_ROOT"/tmp
    sudo chmod 1777 "$MOUNT_ROOT"/var/tmp

    log_warn "Package extraction not yet implemented"
    log_warn "Manual package installation required using apk-tools"
}

install_kernel() {
    log_info "Installing kernel..."

    # TODO: Copy kernel from built packages
    # Kernel location: $PKG_DIR/<kernel-package>/boot/vmlinuz-*
    # DTBs location: $PKG_DIR/<kernel-package>/boot/dtbs/

    log_warn "Kernel installation not yet implemented"
    log_warn "Manually copy kernel and DTBs to boot partition"
}

install_bootloader() {
    log_info "Installing bootloader: ${BOOTLOADER}"

    case "$BOOTLOADER" in
        u-boot)
            install_uboot
            ;;
        systemd-boot)
            log_warn "systemd-boot not needed for Chimera (uses dinit)"
            ;;
        *)
            log_warn "Unknown bootloader: $BOOTLOADER"
            ;;
    esac
}

install_uboot() {
    log_info "Installing U-Boot..."

    # TODO: Copy U-Boot files from built packages
    # Write U-Boot to specific offset on disk (device-specific)

    log_warn "U-Boot installation not yet implemented"
    log_warn "Device-specific U-Boot installation required"
}

configure_system() {
    log_info "Configuring system..."

    # Create fstab
    sudo tee "$MOUNT_ROOT/etc/fstab" > /dev/null << EOF
# <file system> <mount point> <type> <options> <dump> <pass>
/dev/mmcblk0p2  /             ext4   defaults   0 1
/dev/mmcblk0p1  /boot         vfat   defaults   0 2
EOF

    # Set hostname
    echo "$DEVICE_NAME" | sudo tee "$MOUNT_ROOT/etc/hostname" > /dev/null

    # Basic hosts file
    sudo tee "$MOUNT_ROOT/etc/hosts" > /dev/null << EOF
127.0.0.1   localhost
127.0.1.1   $DEVICE_NAME
::1         localhost ip6-localhost ip6-loopback
EOF

    log_info "System configured"
}

create_boot_config() {
    log_info "Creating boot configuration..."

    if [ "$BOOTLOADER" = "u-boot" ]; then
        # Create boot.cmd for U-Boot
        sudo tee "$MOUNT_BOOT/boot.cmd" > /dev/null << EOF
# U-Boot boot script
setenv bootargs "${KERNEL_CMDLINE}"
load mmc 0:1 \${kernel_addr_r} /vmlinuz
load mmc 0:1 \${fdt_addr_r} /dtbs/${DTB_FILE}
bootz \${kernel_addr_r} - \${fdt_addr_r}
EOF

        # Compile boot.cmd to boot.scr (requires mkimage)
        if command -v mkimage &> /dev/null; then
            sudo mkimage -A arm -O linux -T script -C none -a 0 -e 0 -n "Boot Script" \
                -d "$MOUNT_BOOT/boot.cmd" "$MOUNT_BOOT/boot.scr"
            log_info "U-Boot boot script created"
        else
            log_warn "mkimage not found, boot.scr not created"
            log_warn "Install u-boot-tools package"
        fi
    fi
}

cleanup() {
    log_info "Cleaning up..."

    if [ -n "$MOUNT_ROOT" ] && mountpoint -q "$MOUNT_ROOT/boot" 2>/dev/null; then
        sudo umount "$MOUNT_BOOT"
    fi

    if [ -n "$MOUNT_ROOT" ] && mountpoint -q "$MOUNT_ROOT" 2>/dev/null; then
        sudo umount "$MOUNT_ROOT"
        rmdir "$MOUNT_ROOT" 2>/dev/null || true
    fi

    if [ -n "$LOOP_DEV" ] && [ -b "$LOOP_DEV" ]; then
        sudo losetup -d "$LOOP_DEV"
    fi

    log_info "Cleanup complete"
}

create_rootfs_tarball() {
    log_info "Creating rootfs tarball..."

    # Create compressed tarball of root filesystem
    sudo tar czf "$ROOTFS_TAR" -C "$MOUNT_ROOT" .

    log_info "Rootfs tarball created: $ROOTFS_TAR"
}

compress_image() {
    log_info "Compressing image..."

    # Compress the raw image
    if command -v zstd &> /dev/null; then
        zstd -19 -T0 "$IMAGE_FILE" -o "${IMAGE_FILE}.zst"
        log_info "Compressed image: ${IMAGE_FILE}.zst"
    elif command -v gzip &> /dev/null; then
        gzip -k -9 "$IMAGE_FILE"
        log_info "Compressed image: ${IMAGE_FILE}.gz"
    else
        log_warn "No compression tool found (zstd or gzip)"
    fi
}

generate_checksums() {
    log_info "Generating checksums..."

    cd "$IMAGE_DIR"

    sha256sum "$(basename $IMAGE_FILE)" > "${IMAGE_NAME}.sha256"

    if [ -f "$ROOTFS_TAR" ]; then
        sha256sum "$(basename $ROOTFS_TAR)" >> "${IMAGE_NAME}.sha256"
    fi

    log_info "Checksums created: ${IMAGE_NAME}.sha256"
}

show_summary() {
    echo ""
    echo -e "${GREEN}=== Image Creation Complete ===${NC}"
    echo ""
    echo "Image: $IMAGE_FILE"
    echo "Rootfs: $ROOTFS_TAR"
    echo "Checksums: ${IMAGE_DIR}/${IMAGE_NAME}.sha256"
    echo ""
    echo "Flash to SD card:"
    echo "  sudo dd if=$IMAGE_FILE of=/dev/sdX bs=4M status=progress"
    echo ""
    echo "Test with QEMU:"
    if [ "$ARCH" = "aarch64" ]; then
        echo "  qemu-system-aarch64 -M virt -cpu cortex-a57 -m 1G \\"
        echo "    -kernel <kernel> -drive file=$IMAGE_FILE,format=raw \\"
        echo "    -nographic"
    else
        echo "  qemu-system-arm -M virt -cpu cortex-a15 -m 1G \\"
        echo "    -kernel <kernel> -drive file=$IMAGE_FILE,format=raw \\"
        echo "    -nographic"
    fi
    echo ""
}

main() {
    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        usage
    fi

    echo -e "${BLUE}=== Creating System Image ===${NC}"
    echo "Architecture: $ARCH"
    echo "Device: $DEVICE"
    echo "Profile: $PROFILE"
    echo ""

    # Set trap for cleanup
    trap cleanup EXIT

    verify_requirements
    load_device_config
    create_image_file
    partition_image
    setup_loop_device
    format_partitions
    mount_partitions
    install_base_system
    configure_system
    install_kernel
    install_bootloader
    create_boot_config
    create_rootfs_tarball
    cleanup
    compress_image
    generate_checksums
    show_summary
}

main "$@"
