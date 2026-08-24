#!/bin/bash
set -e

# Crag Linux - Inner Build Logic
#
# This script runs INSIDE the container. It is called by build/crag-build.sh
# (the host entry point) and should not be invoked directly on the host.
#
# Usage: ./build/build-inner.sh <board> <variant> [--step=<step>] [--clean]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source shared libraries
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/packages.sh"
source "${SCRIPT_DIR}/lib/rootfs.sh"
source "${SCRIPT_DIR}/lib/merge.sh"
source "${SCRIPT_DIR}/lib/image.sh"
source "${SCRIPT_DIR}/lib/bundle.sh"

##############################################################################
# Parse arguments
##############################################################################

BOARD="$1"
VARIANT="$2"
shift 2 || die "Usage: $0 <board> <variant> [--step=<step>] [--clean]"

STEP=""
CLEAN=false
PACKAGES_MODE_CLI=""
# --external=PATH is REPEATABLE (docs/08 §4 multi-tree). Accumulated verbatim
# and passed through to layers.py; $CRAG_EXTERNAL (colon-separated) is honored
# there too.
EXTERNAL_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --step=*) STEP="${1#--step=}" ;;
        --packages-mode=*) PACKAGES_MODE_CLI="${1#--packages-mode=}" ;;
        --external=*) EXTERNAL_ARGS+=("$1") ;;
        --clean)  CLEAN=true ;;
    esac
    shift
done

if [ -n "$PACKAGES_MODE_CLI" ] && [ "$PACKAGES_MODE_CLI" != "binary" ] && [ "$PACKAGES_MODE_CLI" != "source" ]; then
    die "Invalid --packages-mode: ${PACKAGES_MODE_CLI} (expected binary|source)"
fi

##############################################################################
# Discover external trees + resolve the ordered layer list (docs/08 §2, §4)
#
# layers.py is THE single source of truth for merge order. It parses the
# --external list (+ $CRAG_EXTERNAL), version-gates each tree.toml, orders
# trees by priority, and resolves BOARD_DIR / VARIANT_FILE (either may live in
# a tree). The emitted JSON array (LAYERS_JSON, exported below) is what the
# merge engine (build/lib/merge.sh) consumes. With NO external trees this
# yields exactly the historical in-tree paths — the no-tree build is unchanged.
##############################################################################

require_command python3
require_command jq

LAYERS_ARR=$(python3 "${SCRIPT_DIR}/lib/layers.py" \
    --board "$BOARD" --variant "$VARIANT" "${EXTERNAL_ARGS[@]}") || \
    die "external-tree / layer resolution failed"

BOARD_DIR=$(echo "$LAYERS_ARR" | jq -r 'first(.[] | select(.kind=="board")).path')
VARIANT_FILE=$(echo "$LAYERS_ARR" | jq -r 'first(.[] | select(.kind=="variant")).path')
[ -n "$BOARD_DIR" ] && [ "$BOARD_DIR" != "null" ] && [ -f "${BOARD_DIR}/board.toml" ] || \
    die "Board not found: ${BOARD}"
[ -n "$VARIANT_FILE" ] && [ "$VARIANT_FILE" != "null" ] && [ -f "$VARIANT_FILE" ] || \
    die "Variant not found: ${VARIANT}"

##############################################################################
# Load and validate configs
##############################################################################

log_step "Loading configuration: ${BOARD}/${VARIANT}"

# Load board/variant config through the external-tree deep-merge (docs/08 §4):
# merge.py folds every tree layer's board.toml / variant .toml fragment (deep
# merge per table, scalars last-wins, lists replace except [packages].install
# which accumulates) then runs config.py's validate/apply_defaults/derive
# pipeline. With NO --external tree the fragment stack is the single resolved
# file, so the emitted JSON is byte-identical to `config.py board|variant`
# (regression-tested in build/lib/test_merge_board_variant.py) — the no-tree
# build is unchanged.
BOARD_CONFIG_JSON=$(python3 "${SCRIPT_DIR}/lib/merge.py" board \
    --board "$BOARD" --variant "$VARIANT" "${EXTERNAL_ARGS[@]}") || \
    die "board config merge failed"
export BOARD_CONFIG_JSON

VARIANT_CONFIG_JSON=$(python3 "${SCRIPT_DIR}/lib/merge.py" variant \
    --board "$BOARD" --variant "$VARIANT" "${EXTERNAL_ARGS[@]}") || \
    die "variant config merge failed"
export VARIANT_CONFIG_JSON

# Extract key values for shell use
BOARD_NAME=$(echo "$BOARD_CONFIG_JSON" | jq -r '.board.name')
BOARD_ARCH=$(echo "$BOARD_CONFIG_JSON" | jq -r '.board.arch')
# cbuild/apk arch (armv7hf -> armv7; see cbuild_arch_for in lib/common.sh)
CBUILD_ARCH=$(cbuild_arch_for "$BOARD_ARCH")
export CBUILD_ARCH
VARIANT_NAME=$(echo "$VARIANT_CONFIG_JSON" | jq -r '.variant.name')
KERNEL_PACKAGE=$(echo "$BOARD_CONFIG_JSON" | jq -r '.kernel.package')
KERNEL_CMDLINE=$(echo "$BOARD_CONFIG_JSON" | jq -r '.kernel.cmdline')
BOOTLOADER_TYPE=$(echo "$BOARD_CONFIG_JSON" | jq -r '.bootloader.type')

# Variant kernel cmdline append
VARIANT_CMDLINE=$(echo "$VARIANT_CONFIG_JSON" | jq -r '.kernel.cmdline_append // ""')
if [ -n "$VARIANT_CMDLINE" ]; then
    KERNEL_CMDLINE="${KERNEL_CMDLINE} ${VARIANT_CMDLINE}"
fi

# Packages-mode: CLI flag > variant [packages].mode > "source" (docs/03 §1
# "Binary consumption for dev builds"). binary = build only Crag-touched
# templates, consume Chimera's signed binary repo for the rest; source =
# build the full manifest from the pinned cports (release/nightly path).
PACKAGES_MODE="${PACKAGES_MODE_CLI:-$(echo "$VARIANT_CONFIG_JSON" | jq -r '.packages.mode // "source"')}"
export PACKAGES_MODE

# Rootfs type (docs/02 §3 AD-004): ext4 for dev, squashfs for prod.
# config.py defaults it by variant id when the [rootfs] section is absent.
ROOTFS_TYPE=$(echo "$VARIANT_CONFIG_JSON" | jq -r '.rootfs.type // "ext4"')
export ROOTFS_TYPE

# Export for hooks
export BOARD BOARD_NAME BOARD_ARCH VARIANT VARIANT_NAME KERNEL_PACKAGE KERNEL_CMDLINE BOOTLOADER_TYPE
export PROJECT_ROOT BOARD_DIR

# Services (space-separated for hooks)
SERVICES_ENABLE=$(echo "$VARIANT_CONFIG_JSON" | jq -r '.services.enable // [] | join(" ")')
SERVICES_DISABLE=$(echo "$VARIANT_CONFIG_JSON" | jq -r '.services.disable // [] | join(" ")')
export SERVICES_ENABLE SERVICES_DISABLE

# Users (JSON array for hooks)
USERS_CREATE=$(echo "$VARIANT_CONFIG_JSON" | jq -c '.users.create // []')
export USERS_CREATE

# Build output directories (all build state lives under build/state/ — gitignored)
BUILD_OUTPUT="${PROJECT_ROOT}/build/state/images/${BOARD}-${VARIANT}"
ROOTFS_DIR="${BUILD_OUTPUT}/rootfs"
MANIFEST_FILE="${BUILD_OUTPUT}/packages.manifest"
# Binary packages-mode: the subset of templates built from source
SOURCE_MANIFEST_FILE="${BUILD_OUTPUT}/packages.source.manifest"
export BUILD_OUTPUT ROOTFS_DIR MANIFEST_FILE SOURCE_MANIFEST_FILE

echo ""
log_info "Crag Linux Build"
log_info "  Board:   ${BOARD_NAME} (${BOARD})"
log_info "  Variant: ${VARIANT_NAME} (${VARIANT})"
log_info "  Arch:    ${BOARD_ARCH}"
log_info "  Kernel:  ${KERNEL_PACKAGE}"
log_info "  Pkgs:    ${PACKAGES_MODE} packages-mode"
log_info "  Output:  ${BUILD_OUTPUT}"
echo ""

##############################################################################
# Clean if requested
##############################################################################

if [ "$CLEAN" = true ]; then
    log_step "Cleaning previous build artifacts..."
    rm -rf "$BUILD_OUTPUT"
fi

mkdir -p "$BUILD_OUTPUT"

# Persist the ordered layer list for the merge engine + stages (docs/08 §4).
# LAYERS_JSON is the file every merge.sh / merge.py consumer reads.
LAYERS_JSON="${BUILD_OUTPUT}/layers.json"
printf '%s\n' "$LAYERS_ARR" > "$LAYERS_JSON"
export LAYERS_JSON

##############################################################################
# Step: Toolchain
##############################################################################

should_run_step() {
    [ -z "$STEP" ] || [ "$STEP" = "$1" ]
}

if should_run_step "toolchain"; then
    # Per-arch check: the LLVM toolchain is shared (toolchain/bin/clang),
    # but each board arch needs its own sysroot + compiler wrappers under
    # build/state/<arch>/bin (build-toolchain.sh skips the LLVM build when
    # it is already present, so a second arch only adds musl/compiler-rt/
    # libc++ — minutes, not hours).
    if ! ls "${PROJECT_ROOT}/build/state/${BOARD_ARCH}/bin/"*-clang &>/dev/null; then
        log_step "Toolchain for ${BOARD_ARCH} not found, building..."
        "${PROJECT_ROOT}/sdk/build-toolchain.sh" "$BOARD_ARCH"
    else
        log_info "Toolchain for ${BOARD_ARCH} already built, skipping"
    fi
fi

##############################################################################
# Step: Kernel
##############################################################################

if should_run_step "kernel"; then
    source "${SCRIPT_DIR}/lib/kernel.sh"
    build_kernel "$BOARD" "$BOARD_ARCH" "$BOARD_DIR" "$BOARD_CONFIG_JSON"
fi

##############################################################################
# Step: Bootloader
##############################################################################

if should_run_step "bootloader"; then
    source "${SCRIPT_DIR}/lib/bootloader.sh"
    build_bootloader "$BOARD" "$BOARD_ARCH" "$BOARD_DIR" "$BOARD_CONFIG_JSON"
fi

##############################################################################
# Step: Bootstrap cbuild (automatic, runs if needed before packages)
##############################################################################

if should_run_step "packages" || should_run_step "rootfs"; then
    # Ensure apk-tools is available
    local_apk="${PROJECT_ROOT}/toolchain/apk"
    if ! command -v apk &>/dev/null; then
        log_step "apk-tools not found, running setup..."
        "${PROJECT_ROOT}/build/setup-cbuild.sh"
    fi
    # Ensure apk is on PATH (setup-cbuild.sh sets it for its own session)
    if [ -f "${local_apk}/bin/apk" ] || [ -f "${local_apk}/usr/bin/apk" ]; then
        export PATH="${local_apk}/bin:${local_apk}/usr/bin:$PATH"
        export LD_LIBRARY_PATH="${local_apk}/usr/lib64:${local_apk}/usr/lib:${local_apk}/lib:${LD_LIBRARY_PATH:-}"
    fi

    # Ensure cbuild bldroot is bootstrapped (one-time, takes a while)
    # cbuild creates .cbuild_chroot_init when bootstrap completes successfully
    # cports is a Harbormaster-managed checkout at <repo-root>/cports (AD-001/AD-003)
    cbuild_dir="${PROJECT_ROOT}/cports"
    if [ -d "$cbuild_dir" ] && [ ! -f "${cbuild_dir}/bldroot/.cbuild_chroot_init" ]; then
        log_step "cbuild bldroot not bootstrapped, running bootstrap (this takes a while on first run)..."
        log_info "This builds cbuild's chroot environment for cross-compilation."
        log_info "Subsequent builds will skip this step."

        # Clean stale incomplete bldroot from a previous failed attempt
        if [ -d "${cbuild_dir}/bldroot" ]; then
            log_warn "Removing incomplete bldroot from previous attempt..."
            rm -rf "${cbuild_dir}/bldroot"
        fi

        (cd "$cbuild_dir" && ./cbuild bootstrap)
    fi
fi

##############################################################################
# Step: Packages
##############################################################################

if should_run_step "packages"; then
    log_step "Resolving package list..."

    # Additive-only merge across every layer (docs/08 §4): boards/common +
    # each tree's + the board's packages.list, then board.toml [firmware].packages
    # and variant [packages].install (which accumulates), deduped keeping first
    # occurrence. Reads $BOARD_CONFIG_JSON/$VARIANT_CONFIG_JSON from the env.
    # With no tree this is diff-identical to the former resolve_package_list.
    merge_packages_list "$LAYERS_JSON" > "$MANIFEST_FILE"

    log_info "Package manifest ($(wc -l < "$MANIFEST_FILE") packages):"
    while IFS= read -r pkg; do
        echo "    ${pkg}"
    done < "$MANIFEST_FILE"

    # In binary packages-mode only the Crag-owned fork templates are built
    # from source (build/cports-owned.list); everything else is installed
    # from Chimera's signed binary repo at rootfs time.
    BUILD_LIST_FILE="$MANIFEST_FILE"
    if [ "$PACKAGES_MODE" = "binary" ]; then
        log_step "Resolving source-build subset (binary packages-mode)..."
        # "new" fork packages (no Chimera equivalent) + source-packages.list
        # are always built. "mod" fork templates are built only when the
        # manifest lists them: the llvm cross patch is a no-op for native
        # profiles (and *removes* mlir/flang on cross), so building it for
        # hours on boards that never install it (x86_64 prod) buys nothing;
        # where a Chimera binary shadows a mod template anyway, the skew
        # report flags it loudly (build/lib/skew_check.py).
        {
            resolve_source_package_list
            resolve_owned_templates mod | grep -Fx -f "$MANIFEST_FILE" || true
        } | awk 'NF && !seen[$0]++' > "$SOURCE_MANIFEST_FILE"
        BUILD_LIST_FILE="$SOURCE_MANIFEST_FILE"
        if [ -s "$SOURCE_MANIFEST_FILE" ]; then
            log_info "Source-build subset ($(wc -l < "$SOURCE_MANIFEST_FILE") packages):"
            while IFS= read -r pkg; do
                echo "    ${pkg}"
            done < "$SOURCE_MANIFEST_FILE"
        else
            log_info "Source-build subset is empty — all packages come from binary repos"
        fi
    fi

    # Build packages via cbuild. The pinned cports checkout is prepared
    # (build/patches/cports + astro-cports shadow templates) before any
    # cbuild invocation and reset to the pristine pin afterwards — on
    # success AND on failure (GAP §3.1).
    if [ -d "${PROJECT_ROOT}/cports" ] && [ -f "${PROJECT_ROOT}/cports/cbuild" ]; then
        prepare_cports_tree
        # Reset the tree no matter how the stage ends (set -e exits and die
        # paths included); cleared + run explicitly on the success path.
        trap reset_cports_tree EXIT
        build_packages "$CBUILD_ARCH" "$BUILD_LIST_FILE"
        resolve_dependency_closure "$CBUILD_ARCH" "$MANIFEST_FILE" "$PACKAGES_MODE"
        trap - EXIT
        reset_cports_tree
    else
        log_warn "cports checkout not found at ${PROJECT_ROOT}/cports — skipping package build"
        log_warn "cports is managed by Harbormaster; run 'hm sync --locked' to materialize it"
        log_warn "Package manifest written to ${MANIFEST_FILE}"
    fi
fi

##############################################################################
# Step: Rootfs
##############################################################################

if should_run_step "rootfs"; then
    if [ ! -f "$MANIFEST_FILE" ]; then
        die "Package manifest not found: ${MANIFEST_FILE} (run --step=packages first)"
    fi

    # The stage runs as a child process (build/lib/rootfs-stage.sh) so the
    # prod squashfs path can be wrapped in a user namespace: with the build
    # uid mapped to root (unshare -r), apk installs WITHOUT --usermode and
    # applies real package-metadata ownership, and mksquashfs records
    # root-owned files — no sudo involved (GAP §3.5 ownership item).
    # The dev ext4 path is unchanged (plain unprivileged run; mkfs.ext4 -d
    # normalizes ownership to root at image-creation time).
    if [ "$ROOTFS_TYPE" = "squashfs" ] && [ "$(id -u)" -ne 0 ]; then
        log_step "Assembling prod rootfs in a user namespace (unshare -r)..."
        unshare -r bash "${SCRIPT_DIR}/lib/rootfs-stage.sh" || \
            die "rootfs stage failed (squashfs/userns path)"
    else
        bash "${SCRIPT_DIR}/lib/rootfs-stage.sh" || \
            die "rootfs stage failed"
    fi
fi

##############################################################################
# Step: Image
##############################################################################

if should_run_step "image"; then
    create_image "$BOARD" "$VARIANT" "$ROOTFS_DIR"
fi

##############################################################################
# Step: Bundle (docs/05 §3, AD-010)
##############################################################################

if should_run_step "bundle"; then
    create_bundle "$BOARD" "$VARIANT" "$ROOTFS_TYPE" "$BOARD_CONFIG_JSON"
fi

##############################################################################
# Step: SDK app sysroot (docs/03 §3 sdk stage — EXPLICIT ONLY)
##############################################################################
# Not part of a plain image build ("optional for image builds", docs/03
# §3): staged only via --step=sdk, after the image it derives from is
# built. Idempotent (content stamp), so re-runs are cheap.

if [ "$STEP" = "sdk" ]; then
    "${PROJECT_ROOT}/sdk/stage-sysroot.sh" "$BOARD" "$VARIANT"
fi

##############################################################################
# Done
##############################################################################

echo ""
log_info "Build complete: ${BOARD}/${VARIANT}"
log_info "  Manifest: ${MANIFEST_FILE}"
log_info "  Rootfs:   ${ROOTFS_DIR}"
