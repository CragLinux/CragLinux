#!/bin/bash
set -e

# Container-based build wrapper for Astro Linux toolchain
#
# Usage: ./container/build-in-container.sh [armv7hf|aarch64|x86_64|riscv64]
#
# Environment variables:
#   CONTAINER_ENGINE  - Override container engine (default: auto-detect podman/docker)
#   CONTAINER_IMAGE   - Override image name (default: astro-builder)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARCH="${1:-armv7hf}"

# Validate architecture argument
case "$ARCH" in
    armv7hf|armv7|aarch64|arm64|x86_64|x64|riscv64|rv64) ;;
    *)
        echo "Usage: $0 [armv7hf|aarch64|x86_64|riscv64]"
        exit 1
        ;;
esac

# Auto-detect container engine (prefer podman)
ENGINE="${CONTAINER_ENGINE:-}"
if [ -z "$ENGINE" ]; then
    if command -v podman &>/dev/null; then
        ENGINE="podman"
    elif command -v docker &>/dev/null; then
        ENGINE="docker"
    else
        echo "ERROR: Neither podman nor docker found."
        echo "Install podman:"
        echo "  Fedora: sudo dnf install podman"
        echo "  Ubuntu: sudo apt install podman"
        echo "  macOS:  brew install podman"
        exit 1
    fi
fi

IMAGE_NAME="${CONTAINER_IMAGE:-astro-builder}"

# Build container image if it doesn't exist
if ! $ENGINE image exists "$IMAGE_NAME" 2>/dev/null; then
    echo "[INFO] Building container image: $IMAGE_NAME"
    $ENGINE build -t "$IMAGE_NAME" -f "${SCRIPT_DIR}/Containerfile" "${SCRIPT_DIR}"
fi

# Build the run arguments
RUN_ARGS=(run --rm)

# Use --userns=keep-id with podman so files are owned by the host user
if [ "$ENGINE" = "podman" ]; then
    RUN_ARGS+=(--userns=keep-id)
fi

# Bind-mount the project directory
# :Z relabels for SELinux (required on Fedora/RHEL, harmless elsewhere)
RUN_ARGS+=(-v "${PROJECT_DIR}:/workspace:Z")

echo "[INFO] Building ${ARCH} toolchain in container (engine: ${ENGINE})"
echo "[INFO] Build outputs will appear in ${PROJECT_DIR}/toolchain/ and ${PROJECT_DIR}/build/state/${ARCH}/"
exec $ENGINE "${RUN_ARGS[@]}" "$IMAGE_NAME" -c "./sdk/build-toolchain.sh ${ARCH}"
