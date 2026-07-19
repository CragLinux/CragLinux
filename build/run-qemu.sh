#!/bin/bash
set -e

# Astro Linux - QEMU Test Launcher
#
# Two modes (docs/04 §7):
#
#   direct (default, dev fast path): -kernel boot of the built kernel with
#     a bare rootfs image as the whole virtio disk; root= injected here.
#
#   --image (M1 wave 2): boots the full A/B GPT image through the REAL
#     bootloader — U-Boot via -bios (qemu-aarch64 / qemu-armv7) or
#     OVMF+GRUB via pflash (qemu-x86_64). The bootloader picks the slot
#     per BOOT_ORDER/ORDER; the kernel mounts root=PARTLABEL=rootfs.<slot>.
#
# Usage:
#   ./build/run-qemu.sh <board> <variant> [--image] [--scratch[=+SIZE]]
#   ./build/run-qemu.sh qemu-aarch64 dev
#   ./build/run-qemu.sh qemu-x86_64 prod --image
#   ./build/run-qemu.sh qemu-armv7 prod --image --scratch=+1G
#
# --scratch (image mode): boot a throwaway qcow2 overlay instead of the
#   artifact itself, so the built image stays pristine (without it, a
#   --image boot writes bootloader env + /data changes INTO the artifact).
#   An optional =+SIZE grows the overlay disk, exercising the on-device
#   /data growth path (docs/02 §4). Used by test-boot-smoke.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

BOARD="${1:?Usage: $0 <board> <variant> [--image] [--scratch[=+SIZE]]}"
VARIANT="${2:?Usage: $0 <board> <variant> [--image] [--scratch[=+SIZE]]}"
shift 2
IMAGE_MODE=false
SCRATCH_MODE=false
SCRATCH_GROW=""
for arg in "$@"; do
    case "$arg" in
        --image) IMAGE_MODE=true ;;
        --scratch) SCRATCH_MODE=true ;;
        --scratch=*) SCRATCH_MODE=true; SCRATCH_GROW="${arg#--scratch=}" ;;
        *) echo "ERROR: unknown option: $arg"; exit 1 ;;
    esac
done

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
RAUC_BACKEND=$(echo "$CONFIG_JSON" | jq -r '.rauc.bootloader')

# QEMU settings (from [qemu] section or defaults)
QEMU_MACHINE=$(echo "$CONFIG_JSON" | jq -r '.qemu.machine // "virt"')
QEMU_CPU=$(echo "$CONFIG_JSON" | jq -r '.qemu.cpu // ""')
QEMU_MEMORY=$(echo "$CONFIG_JSON" | jq -r '.qemu.memory // "1G"')
QEMU_EXTRA=$(echo "$CONFIG_JSON" | jq -r '.qemu.extra_args // ""')
QEMU_FIRMWARE=$(echo "$CONFIG_JSON" | jq -r '.qemu.firmware // ""')

# Variant cmdline append + rootfs type (ext4 for dev, squashfs for prod)
ROOTFS_TYPE="ext4"
VARIANT_FILE="${BOARD_DIR}/variants/${VARIANT}.toml"
if [ -f "$VARIANT_FILE" ]; then
    VARIANT_JSON=$(python3 "${SCRIPT_DIR}/lib/config.py" variant "$VARIANT_FILE" --format=json)
    CMDLINE_APPEND=$(echo "$VARIANT_JSON" | jq -r '.kernel.cmdline_append // ""')
    if [ -n "$CMDLINE_APPEND" ]; then
        KERNEL_CMDLINE="${KERNEL_CMDLINE} ${CMDLINE_APPEND}"
    fi
    ROOTFS_TYPE=$(echo "$VARIANT_JSON" | jq -r '.rootfs.type // "ext4"')
fi

# Map arch to QEMU binary and kernel image
case "$BOARD_ARCH" in
    aarch64)
        QEMU_BIN="qemu-system-aarch64"
        KERNEL_IMAGE="arch/arm64/boot/Image"
        [ -z "$QEMU_CPU" ] && QEMU_CPU="cortex-a72"
        ;;
    armv7hf)
        # qemu-system-aarch64 runs 32-bit CPU models on -M virt; the
        # container ships no qemu-system-arm, so fall back transparently.
        if command -v qemu-system-arm &>/dev/null; then
            QEMU_BIN="qemu-system-arm"
        else
            QEMU_BIN="qemu-system-aarch64"
        fi
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

BUILD_OUTPUT="${PROJECT_ROOT}/build/state/images/${BOARD}-${VARIANT}"

QEMU_ARGS=(
    "$QEMU_BIN"
    -M "$QEMU_MACHINE"
    -cpu "$QEMU_CPU"
    -m "$QEMU_MEMORY"
    -nographic
)

if [ "$IMAGE_MODE" = true ]; then
    ##########################################################################
    # Full-image boot through the real bootloader (docs/04 §1/§7)
    ##########################################################################
    # Prefer qcow2 (exercises the converted artifact), fall back to raw.
    IMAGE_FILE=$(ls -t "${BUILD_OUTPUT}"/astro-"${BOARD}"-*.qcow2 2>/dev/null | head -1 || true)
    IMAGE_FORMAT="qcow2"
    if [ -z "$IMAGE_FILE" ]; then
        IMAGE_FILE=$(ls -t "${BUILD_OUTPUT}"/astro-"${BOARD}"-*.img 2>/dev/null | head -1 || true)
        IMAGE_FORMAT="raw"
    fi
    if [ -z "$IMAGE_FILE" ]; then
        echo "ERROR: no image found in ${BUILD_OUTPUT}. Build it first:"
        echo "  ./build/astro-build.sh ${BOARD} ${VARIANT}"
        exit 1
    fi

    case "$RAUC_BACKEND" in
        uboot)
            UBOOT_BIN="${PROJECT_ROOT}/build/state/${BOARD_ARCH}/bootloader/${BOARD}/u-boot.bin"
            if [ ! -f "$UBOOT_BIN" ]; then
                echo "ERROR: u-boot.bin not found: ${UBOOT_BIN}"
                echo "  ./build/astro-build.sh ${BOARD} ${VARIANT} --step=bootloader"
                exit 1
            fi
            QEMU_ARGS+=(-bios "$UBOOT_BIN")
            ;;
        grub)
            if [ -z "$QEMU_FIRMWARE" ] || [ ! -f "$QEMU_FIRMWARE" ]; then
                echo "ERROR: EFI firmware not found ([qemu].firmware = '${QEMU_FIRMWARE}')"
                exit 1
            fi
            # Writable NVRAM scratch copy next to the image
            OVMF_VARS_SRC="$(dirname "$QEMU_FIRMWARE")/OVMF_VARS.fd"
            OVMF_VARS="${BUILD_OUTPUT}/OVMF_VARS.fd"
            [ -f "$OVMF_VARS" ] || cp "$OVMF_VARS_SRC" "$OVMF_VARS"
            QEMU_ARGS+=(
                -drive "if=pflash,format=raw,readonly=on,file=${QEMU_FIRMWARE}"
                -drive "if=pflash,format=raw,file=${OVMF_VARS}"
            )
            ;;
        *)
            echo "ERROR: unsupported rauc bootloader backend for --image: ${RAUC_BACKEND}"
            exit 1
            ;;
    esac

    if [ "$SCRATCH_MODE" = true ]; then
        SCRATCH_IMG="${BUILD_OUTPUT}/scratch.qcow2"
        rm -f "$SCRATCH_IMG"
        qemu-img create -q -f qcow2 -b "$IMAGE_FILE" -F "$IMAGE_FORMAT" "$SCRATCH_IMG"
        if [ -n "$SCRATCH_GROW" ]; then
            qemu-img resize -q "$SCRATCH_IMG" "$SCRATCH_GROW"
        fi
        IMAGE_FILE="$SCRATCH_IMG"
        IMAGE_FORMAT="qcow2"
    fi
    QEMU_ARGS+=(-drive "file=${IMAGE_FILE},format=${IMAGE_FORMAT},if=virtio")
    BOOT_DESC="full image via ${RAUC_BACKEND} (${IMAGE_FILE})"
else
    ##########################################################################
    # Direct kernel boot (dev fast path)
    ##########################################################################
    KERNEL_PATH="${PROJECT_ROOT}/build/state/${BOARD_ARCH}/kernel/${BOARD}/${KERNEL_IMAGE}"
    if [ ! -f "$KERNEL_PATH" ]; then
        echo "ERROR: Kernel image not found: ${KERNEL_PATH}"
        echo "Build the kernel first: ./build/astro-build.sh ${BOARD} ${VARIANT} --step=kernel"
        exit 1
    fi

    # Rootfs image + direct-boot root= injection.
    #
    # Board cmdlines carry no root= (the image stage owns root=PARTLABEL=...
    # per A/B slot — docs/03 §6, enforced by the schema validator). This
    # direct-boot developer flow attaches a bare filesystem image as the whole
    # virtio disk, so root= is injected HERE, per rootfs type:
    #   ext4 (dev):      root=/dev/vda rw
    #   squashfs (prod): root=/dev/vda rootfstype=squashfs ro
    ROOTFS_DIR="${BUILD_OUTPUT}/rootfs"

    if [ "$ROOTFS_TYPE" = "squashfs" ]; then
        ROOTFS_IMG="${BUILD_OUTPUT}/rootfs.squashfs"
        if [ ! -f "$ROOTFS_IMG" ]; then
            echo "ERROR: No squashfs rootfs found at ${ROOTFS_IMG}. Build it first:"
            echo "  ./build/astro-build.sh ${BOARD} ${VARIANT} --step=rootfs"
            exit 1
        fi
        KERNEL_CMDLINE="${KERNEL_CMDLINE} root=/dev/vda rootfstype=squashfs ro"
    else
        ROOTFS_IMG="${BUILD_OUTPUT}/rootfs.ext4"
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
        KERNEL_CMDLINE="${KERNEL_CMDLINE} root=/dev/vda rw"
    fi

    QEMU_ARGS+=(
        -kernel "$KERNEL_PATH"
        -append "$KERNEL_CMDLINE"
        -drive "file=${ROOTFS_IMG},format=raw,if=virtio"
    )
    BOOT_DESC="direct kernel boot (${ROOTFS_IMG})"
fi

# Add extra args from board.toml
if [ -n "$QEMU_EXTRA" ]; then
    # shellcheck disable=SC2206
    QEMU_ARGS+=($QEMU_EXTRA)
fi

echo "[INFO] Launching QEMU:"
echo "  Board:   ${BOARD}"
echo "  Variant: ${VARIANT}"
echo "  Boot:    ${BOOT_DESC}"
if [ "$IMAGE_MODE" = false ]; then
    echo "  Cmdline: ${KERNEL_CMDLINE}"
fi
echo "  Machine: ${QEMU_MACHINE} (${QEMU_CPU}, ${QEMU_MEMORY})"
echo ""
echo "  Press Ctrl-A X to exit QEMU"
echo ""

exec "${QEMU_ARGS[@]}"
