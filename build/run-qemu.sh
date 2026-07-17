#!/bin/bash
set -e

# Astro Linux - QEMU Test Launcher
#
# Boots a built kernel + rootfs in QEMU for testing.
# Reads board.toml for QEMU machine/cpu settings.
#
# Usage:
#   ./build/run-qemu.sh <board> <variant>
#   ./build/run-qemu.sh qemu-aarch64 dev

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

BOARD="${1:?Usage: $0 <board> <variant>}"
VARIANT="${2:?Usage: $0 <board> <variant>}"

# Load config
BOARD_DIR="${PROJECT_ROOT}/boards/${BOARD}"
if [ ! -f "${BOARD_DIR}/board.toml" ]; then
    echo "ERROR: Board not found: ${BOARD}"
    exit 1
fi

# Parse board config
CONFIG_JSON=$(python3 "${SCRIPT_DIR}/lib/config.py" board "${BOARD_DIR}/board.toml" --format=json)

BOARD_ARCH=$(echo "$CONFIG_JSON" | jq -r '.board.arch')
KERNEL_VERSION=$(echo "$CONFIG_JSON" | jq -r '.kernel.version')
KERNEL_CMDLINE=$(echo "$CONFIG_JSON" | jq -r '.kernel.cmdline')

# QEMU settings (from [qemu] section or defaults)
QEMU_MACHINE=$(echo "$CONFIG_JSON" | jq -r '.qemu.machine // "virt"')
QEMU_CPU=$(echo "$CONFIG_JSON" | jq -r '.qemu.cpu // ""')
QEMU_MEMORY=$(echo "$CONFIG_JSON" | jq -r '.qemu.memory // "1G"')
QEMU_EXTRA=$(echo "$CONFIG_JSON" | jq -r '.qemu.extra_args // ""')

# Variant cmdline append
VARIANT_FILE="${BOARD_DIR}/variants/${VARIANT}.toml"
if [ -f "$VARIANT_FILE" ]; then
    VARIANT_JSON=$(python3 "${SCRIPT_DIR}/lib/config.py" variant "$VARIANT_FILE" --format=json)
    CMDLINE_APPEND=$(echo "$VARIANT_JSON" | jq -r '.kernel.cmdline_append // ""')
    if [ -n "$CMDLINE_APPEND" ]; then
        KERNEL_CMDLINE="${KERNEL_CMDLINE} ${CMDLINE_APPEND}"
    fi
fi

# Map arch to QEMU binary and kernel image
case "$BOARD_ARCH" in
    aarch64)
        QEMU_BIN="qemu-system-aarch64"
        KERNEL_IMAGE="arch/arm64/boot/Image"
        [ -z "$QEMU_CPU" ] && QEMU_CPU="cortex-a72"
        ;;
    armv7hf)
        QEMU_BIN="qemu-system-arm"
        KERNEL_IMAGE="arch/arm/boot/zImage"
        [ -z "$QEMU_CPU" ] && QEMU_CPU="cortex-a15"
        ;;
    x86_64)
        QEMU_BIN="qemu-system-x86_64"
        KERNEL_IMAGE="arch/x86/boot/bzImage"
        [ -z "$QEMU_CPU" ] && QEMU_CPU="qemu64"
        ;;
    riscv64)
        QEMU_BIN="qemu-system-riscv64"
        KERNEL_IMAGE="arch/riscv/boot/Image"
        [ -z "$QEMU_CPU" ] && QEMU_CPU="rv64"
        ;;
    *)
        echo "ERROR: Unsupported architecture: ${BOARD_ARCH}"
        exit 1
        ;;
esac

# Check for QEMU binary
if ! command -v "$QEMU_BIN" &>/dev/null; then
    echo "ERROR: ${QEMU_BIN} not found."
    echo "Install: sudo dnf install qemu-system-aarch64  (or equivalent)"
    exit 1
fi

# Kernel image path
KERNEL_PATH="${PROJECT_ROOT}/build/state/${BOARD_ARCH}/kernel/${BOARD}/${KERNEL_IMAGE}"
if [ ! -f "$KERNEL_PATH" ]; then
    echo "ERROR: Kernel image not found: ${KERNEL_PATH}"
    echo "Build the kernel first: ./build/astro-build.sh ${BOARD} ${VARIANT} --step=kernel"
    exit 1
fi

# Rootfs path — look for an ext4 image or create one from rootfs directory
ROOTFS_DIR="${PROJECT_ROOT}/build/state/images/${BOARD}-${VARIANT}/rootfs"
ROOTFS_IMG="${PROJECT_ROOT}/build/state/images/${BOARD}-${VARIANT}/rootfs.ext4"

if [ ! -f "$ROOTFS_IMG" ] && [ -d "$ROOTFS_DIR" ]; then
    echo "[INFO] Creating ext4 rootfs image from ${ROOTFS_DIR}..."
    # Calculate size (rootfs + 50% headroom, minimum 256M)
    local_size=$(du -sm "$ROOTFS_DIR" 2>/dev/null | awk '{print $1}')
    local_size=${local_size:-256}
    img_size=$(( (local_size * 3 / 2) > 256 ? (local_size * 3 / 2) : 256 ))
    dd if=/dev/zero of="$ROOTFS_IMG" bs=1M count=${img_size} status=none
    mkfs.ext4 -q -d "$ROOTFS_DIR" "$ROOTFS_IMG"
    echo "[INFO] Created ${img_size}M rootfs image"
elif [ ! -f "$ROOTFS_IMG" ]; then
    echo "ERROR: No rootfs found. Build it first:"
    echo "  ./build/astro-build.sh ${BOARD} ${VARIANT} --step=rootfs"
    exit 1
fi

# Build QEMU command
QEMU_ARGS=(
    "$QEMU_BIN"
    -M "$QEMU_MACHINE"
    -cpu "$QEMU_CPU"
    -m "$QEMU_MEMORY"
    -kernel "$KERNEL_PATH"
    -append "$KERNEL_CMDLINE"
    -drive "file=${ROOTFS_IMG},format=raw,if=virtio"
    -nographic
)

# Add extra args from board.toml
if [ -n "$QEMU_EXTRA" ]; then
    # shellcheck disable=SC2206
    QEMU_ARGS+=($QEMU_EXTRA)
fi

echo "[INFO] Launching QEMU:"
echo "  Board:   ${BOARD}"
echo "  Variant: ${VARIANT}"
echo "  Kernel:  ${KERNEL_PATH}"
echo "  Rootfs:  ${ROOTFS_IMG}"
echo "  Cmdline: ${KERNEL_CMDLINE}"
echo "  Machine: ${QEMU_MACHINE} (${QEMU_CPU}, ${QEMU_MEMORY})"
echo ""
echo "  Press Ctrl-A X to exit QEMU"
echo ""

exec "${QEMU_ARGS[@]}"
