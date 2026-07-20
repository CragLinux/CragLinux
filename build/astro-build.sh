#!/bin/bash
set -e

# Astro Linux - Build System Entry Point
#
# This is the host-side entry point. It ensures the astro-builder container
# image exists and launches the real build logic inside the container.
#
# Usage:
#   ./build/astro-build.sh <board> <variant> [options]
#   ./build/astro-build.sh rpi4 dev
#   ./build/astro-build.sh --external=/path/to/products my-gateway production
#   ./build/astro-build.sh qemu-aarch64 dev --step=packages
#
# Options:
#   --external=<path>   Path to external board/package tree (like BR2_EXTERNAL)
#   --step=<step>       Run only a specific step: toolchain, kernel, bootloader,
#                       packages, rootfs, image, bundle
#   --packages-mode=<m> binary|source. binary: build only Astro-touched
#                       templates, install the rest from Chimera's signed
#                       binary repo (dev/PR default via variant TOML).
#                       source: build everything from the pinned cports
#                       (release/nightly). Default comes from the variant's
#                       [packages].mode (falls back to source).
#   --clean             Clean build artifacts before building
#   --shell             Drop into an interactive shell inside the container
#
# Environment variables:
#   ASTRO_EXTERNAL      Same as --external
#   CONTAINER_ENGINE    Override container engine (default: auto-detect podman/docker)
#   CONTAINER_IMAGE     Override image name (default: astro-builder)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

##############################################################################
# Parse arguments
##############################################################################

BOARD=""
VARIANT=""
EXTERNAL="${ASTRO_EXTERNAL:-}"
STEP=""
CLEAN=false
INTERACTIVE=false
PASSTHROUGH_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --external=*)
            EXTERNAL="${1#--external=}"
            ;;
        --step=*)
            STEP="${1#--step=}"
            PASSTHROUGH_ARGS+=("$1")
            ;;
        --packages-mode=*)
            PASSTHROUGH_ARGS+=("$1")
            ;;
        --clean)
            CLEAN=true
            PASSTHROUGH_ARGS+=("$1")
            ;;
        --shell)
            INTERACTIVE=true
            ;;
        --help|-h)
            head -32 "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
        *)
            if [ -z "$BOARD" ]; then
                BOARD="$1"
            elif [ -z "$VARIANT" ]; then
                VARIANT="$1"
            fi
            ;;
    esac
    shift
done

# Validate arguments (unless --shell mode)
if [ "$INTERACTIVE" = false ]; then
    if [ -z "$BOARD" ] || [ -z "$VARIANT" ]; then
        echo "Usage: $0 <board> <variant> [--external=<path>] [--step=<step>] [--clean]"
        echo ""
        echo "Available boards:"
        for d in "${PROJECT_ROOT}"/boards/*/board.toml; do
            [ -f "$d" ] || continue
            local_board="$(basename "$(dirname "$d")")"
            echo "  ${local_board}"
        done
        if [ -n "$EXTERNAL" ] && [ -d "${EXTERNAL}/boards" ]; then
            for d in "${EXTERNAL}"/boards/*/board.toml; do
                [ -f "$d" ] || continue
                local_board="$(basename "$(dirname "$d")")"
                echo "  ${local_board} (external)"
            done
        fi
        exit 1
    fi
fi

##############################################################################
# Container engine detection
##############################################################################

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

##############################################################################
# Build container image if needed
##############################################################################

if ! $ENGINE image exists "$IMAGE_NAME" 2>/dev/null; then
    echo "[INFO] Building container image: $IMAGE_NAME"
    $ENGINE build -t "$IMAGE_NAME" -f "${PROJECT_ROOT}/container/Containerfile" "${PROJECT_ROOT}/container/"
fi

##############################################################################
# Assemble container run arguments
##############################################################################

RUN_ARGS=(run --rm)

# Use --userns=keep-id with podman for correct file ownership
if [ "$ENGINE" = "podman" ]; then
    RUN_ARGS+=(--userns=keep-id)
fi

# cbuild uses bubblewrap (bwrap) for build isolation, which needs
# namespace capabilities inside the container
RUN_ARGS+=(--privileged)

# Interactive mode
if [ "$INTERACTIVE" = true ]; then
    RUN_ARGS+=(-it)
fi

# Bind-mount the project directory
# :Z relabels for SELinux (required on Fedora/RHEL)
RUN_ARGS+=(-v "${PROJECT_ROOT}:/workspace:Z")

# Bind-mount external tree if specified
if [ -n "$EXTERNAL" ]; then
    EXTERNAL="$(cd "$EXTERNAL" && pwd)"
    RUN_ARGS+=(-v "${EXTERNAL}:/external:Z")
    RUN_ARGS+=(-e "ASTRO_EXTERNAL=/external")
fi

##############################################################################
# Launch build inside container
##############################################################################

if [ "$INTERACTIVE" = true ]; then
    echo "[INFO] Launching interactive shell in astro-builder container"
    exec $ENGINE "${RUN_ARGS[@]}" "$IMAGE_NAME"
else
    echo "[INFO] Building ${BOARD}/${VARIANT} in container (engine: ${ENGINE})"
    INNER_CMD="./build/build-inner.sh ${BOARD} ${VARIANT} ${PASSTHROUGH_ARGS[*]}"
    exec $ENGINE "${RUN_ARGS[@]}" "$IMAGE_NAME" -c "$INNER_CMD"
fi
