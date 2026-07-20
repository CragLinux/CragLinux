#!/bin/bash
set -e

# Build Base System using cbuild
# Builds a minimal or complete base system for embedded devices

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# cports is a Harbormaster-managed checkout at <repo-root>/cports
CBUILD_DIR="${PROJECT_ROOT}/cports"

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
Usage: $0 <architecture> [profile]

Build base system for specified architecture using Chimera cbuild

Arguments:
    architecture    Target architecture (armv7hf, aarch64)
    profile         System profile (minimal, base, full) [default: base]

System Profiles:
    minimal         Bare minimum (musl, chimerautils, dinit)
    base            Standard embedded (+ kernel, u-boot, networking)
    full            Feature-rich (+ utilities, development tools)

Examples:
    $0 aarch64                  # Build base system for ARM64
    $0 armv7hf minimal          # Build minimal system for ARMv7
    $0 aarch64 full             # Build full system for ARM64

Environment Variables:
    CBUILD_OPTS     Additional options to pass to cbuild
    SKIP_VERIFY     Skip toolchain verification (not recommended)

EOF
    exit 1
}

# Parse arguments
ARCH="${1:-}"
PROFILE="${2:-base}"

if [ -z "$ARCH" ]; then
    log_error "Architecture required"
    usage
fi

case "$ARCH" in
    armv7hf|armv7)
        ARCH="armv7hf"
        ;;
    aarch64|arm64)
        ARCH="aarch64"
        ;;
    *)
        log_error "Unsupported architecture: $ARCH"
        log_error "Supported: armv7hf, aarch64"
        exit 1
        ;;
esac

case "$PROFILE" in
    minimal|base|full)
        ;;
    *)
        log_error "Unknown profile: $PROFILE"
        log_error "Supported: minimal, base, full"
        exit 1
        ;;
esac

verify_cbuild() {
    log_info "Verifying cbuild installation..."

    if [ ! -f "${CBUILD_DIR}/cbuild" ]; then
        log_error "cbuild not found at ${CBUILD_DIR}/cbuild"
        log_error "cports is managed by Harbormaster; run 'hm sync --locked', then ./build/setup-cbuild.sh"
        exit 1
    fi

    if [ ! -f "${PROJECT_ROOT}/build/cbuild-profiles/${ARCH}.conf" ]; then
        log_error "Profile for ${ARCH} not found in build/cbuild-profiles/"
        exit 1
    fi

    log_info "cbuild found"
}

verify_toolchain() {
    log_info "Verifying cross-compilation toolchain for ${ARCH}..."

    local toolchain_file="${PROJECT_ROOT}/${ARCH}-toolchain.cmake"
    local bin_dir="${PROJECT_ROOT}/build/state/${ARCH}/bin"
    local sysroot="${PROJECT_ROOT}/build/state/${ARCH}/sysroot"

    if [ ! -f "$toolchain_file" ]; then
        log_error "Toolchain file not found: $toolchain_file"
        log_error "Build toolchain first: ./sdk/build-toolchain.sh ${ARCH}"
        exit 1
    fi

    if [ ! -d "$bin_dir" ]; then
        log_error "Toolchain bin directory not found: $bin_dir"
        log_error "Build toolchain first: ./sdk/build-toolchain.sh ${ARCH}"
        exit 1
    fi

    if [ ! -d "$sysroot" ]; then
        log_error "Sysroot not found: $sysroot"
        log_error "Build toolchain first: ./sdk/build-toolchain.sh ${ARCH}"
        exit 1
    fi

    log_info "Toolchain verified for ${ARCH}"
}

ensure_apk_in_path() {
    log_info "Checking for apk-tools..."

    # Check if apk is in PATH
    if command -v apk &> /dev/null; then
        log_info "apk-tools found: $(which apk)"
        # Set CBUILD_APK_PATH for cbuild to use
        export CBUILD_APK_PATH="$(which apk)"
        return 0
    fi

    # Check for locally built apk-tools
    local APK_INSTALL="${PROJECT_ROOT}/toolchain/apk"
    if [ -f "${APK_INSTALL}/usr/bin/apk" ]; then
        log_info "Using locally built apk-tools"
        # Set CBUILD_APK_PATH and LD_LIBRARY_PATH for cbuild
        export CBUILD_APK_PATH="${APK_INSTALL}/usr/bin/apk"
        export LD_LIBRARY_PATH="${APK_INSTALL}/usr/lib64:${APK_INSTALL}/usr/lib:${APK_INSTALL}/lib:${LD_LIBRARY_PATH}"
        log_info "Set CBUILD_APK_PATH=${CBUILD_APK_PATH}"
        log_info "Set LD_LIBRARY_PATH for libapk.so"
        return 0
    elif [ -f "${APK_INSTALL}/bin/apk" ]; then
        log_info "Using locally built apk-tools"
        export CBUILD_APK_PATH="${APK_INSTALL}/bin/apk"
        export LD_LIBRARY_PATH="${APK_INSTALL}/usr/lib64:${APK_INSTALL}/usr/lib:${APK_INSTALL}/lib:${LD_LIBRARY_PATH}"
        log_info "Set CBUILD_APK_PATH=${CBUILD_APK_PATH}"
        log_info "Set LD_LIBRARY_PATH for libapk.so"
        return 0
    fi

    log_error "apk-tools not found in PATH"
    log_error "Run setup script first: ./build/setup-cbuild.sh"
    exit 1
}

get_package_list() {
    local profile=$1
    local packages=()

    case "$profile" in
        minimal)
            packages=(
                "linux-headers"
                "musl"
                "chimerautils"
                "dinit"
                "dinit-chimera"
                "base-bootstrap"
            )
            ;;
        base)
            packages=(
                "linux-headers"
                "musl"
                "chimerautils"
                "dinit"
                "dinit-chimera"
                "turnstile"
                "apk-tools"
                "linux-lts"
                "u-boot"
                "base-bootstrap"
                "base-full-minimal"
                "base-full-core"
            )
            ;;
        full)
            packages=(
                "linux-headers"
                "musl"
                "chimerautils"
                "dinit"
                "dinit-chimera"
                "turnstile"
                "apk-tools"
                "linux-lts"
                "u-boot"
                "base-full"
            )
            ;;
    esac

    echo "${packages[@]}"
}

build_package() {
    local pkg=$1

    log_info "Building package: $pkg for ${ARCH}"

    cd "${CBUILD_DIR}"

    # Source our profile for environment variables
    source "${PROJECT_ROOT}/build/cbuild-profiles/${ARCH}.conf"

    # Build with cbuild using cross-compilation (-a flag)
    # The -a flag tells cbuild to cross-compile for the target architecture
    if ./cbuild -a "${ARCH}" pkg "main/${pkg}" ${CBUILD_OPTS}; then
        log_info "Successfully built: $pkg"
        return 0
    else
        log_error "Failed to build: $pkg"
        return 1
    fi
}

create_package_list_file() {
    local profile=$1
    local list_file="${PROJECT_ROOT}/build/state/${ARCH}/${profile}-packages.txt"

    mkdir -p "$(dirname "$list_file")"

    log_info "Creating package list: $list_file"

    get_package_list "$profile" | tr ' ' '\n' > "$list_file"

    log_info "Package list created with $(wc -l < "$list_file") packages"
}

bootstrap_bldroot() {
    log_info "Bootstrapping cbuild build root..."

    cd "${CBUILD_DIR}"

    # Check if already bootstrapped
    # Note: The build root is for the HOST architecture (where builds run),
    # not the target architecture. Cross-compilation happens when building packages.
    local BLDROOT_CHECK="${CBUILD_DIR}/bldroot"
    if [ -f "$BLDROOT_CHECK/.cbuild_chroot_init" ]; then
        log_info "Build root already exists"
        return 0
    fi

    # Clean up any leftover partial bootstrap attempts
    log_info "Cleaning up any leftover bootstrap state..."
    rm -rf "${CBUILD_DIR}/bldroot-stage0" \
           "${CBUILD_DIR}/bldroot-stage1" \
           "${CBUILD_DIR}/bldroot-stage2" \
           "${CBUILD_DIR}/packages-stage0" \
           "${CBUILD_DIR}/packages-stage1" \
           "${CBUILD_DIR}/packages-stage2" \
           "${CBUILD_DIR}/pkgstage-stage0" \
           "${CBUILD_DIR}/pkgstage-stage1" \
           "${CBUILD_DIR}/pkgstage-stage2"

    log_info "Build root not found, running source-bootstrap..."
    log_warn "This will build the HOST build environment from source"
    log_warn "The build environment runs on your system (x86_64)"
    log_warn "Cross-compilation for ${ARCH} happens when building packages"
    log_warn "This may take 30-60 minutes depending on your system"
    echo ""
    echo "Bootstrap stages:"
    echo "  - Stage 0: Build basic runtime (musl, compiler-rt, libc++)"
    echo "  - Stage 1: Build core utilities and build tools"
    echo "  - Stage 2: Build full LLVM toolchain"
    echo "  - Stage 3: Finalize bldroot"
    echo ""

    # Ensure our LLVM toolchain is in PATH for bootstrap (needs lld, clang, etc.)
    local TOOLCHAIN_BIN="${PROJECT_ROOT}/toolchain/bin"
    if [ -d "$TOOLCHAIN_BIN" ]; then
        log_info "Adding LLVM toolchain to PATH for bootstrap"
        export PATH="${TOOLCHAIN_BIN}:$PATH"
    else
        log_warn "LLVM toolchain not found at ${TOOLCHAIN_BIN}"
        log_warn "Bootstrap will use system compiler if available"
    fi

    # Also add apk to PATH for cbuild (it needs it before CBUILD_APK_PATH is processed)
    if [ -n "$CBUILD_APK_PATH" ]; then
        local APK_BIN_DIR="$(dirname "$CBUILD_APK_PATH")"
        log_info "Adding apk-tools to PATH: $APK_BIN_DIR"
        export PATH="${APK_BIN_DIR}:$PATH"
    fi

    # Run source-bootstrap to build the HOST build environment from source
    # NOTE: We do NOT pass -a ${ARCH} here! The bootstrap builds the host
    # environment (x86_64) where the build tools run. Cross-compilation
    # happens later when we build packages with -a ${ARCH}.
    log_info "Starting bootstrap (this will show progress)..."
    log_info "Note: 'ERROR: Failed scanning shlib dependencies' warnings are expected and non-fatal"
    echo ""

    # Use stdbuf to disable buffering for real-time output
    stdbuf -oL -eL ./cbuild source-bootstrap 2>&1 | tee bootstrap.log
    local exit_code=$?

    echo ""

    # Check for known error patterns in the log
    if [ $exit_code -ne 0 ] || grep -qE "Indexing failed|A failure has occurred|Phase .* failed|ERROR:" bootstrap.log; then
        log_warn "Bootstrap may have encountered errors"

        if grep -q "Indexing failed" bootstrap.log; then
            log_warn "Repository indexing failed - this may be an apk-tools issue"
        fi

        if grep -q "A failure has occurred" bootstrap.log; then
            log_warn "Build failure detected during bootstrap"
            # Show the last failure message
            grep -A 5 "Phase .* failed" bootstrap.log | tail -6
        fi

        if grep -q "ERROR:" bootstrap.log; then
            log_warn "Errors detected in bootstrap log:"
            grep "ERROR:" bootstrap.log | tail -5
        fi
    fi

    # Check if bootstrap actually completed by looking for the final bldroot marker
    if [ ! -f "${CBUILD_DIR}/bldroot/.cbuild_chroot_init" ]; then
        log_error "Bootstrap did not complete - final build root not initialized"
        log_error "Only stage 0 was completed, but full bootstrap is required"
        log_error "Check ${CBUILD_DIR}/bootstrap.log for details"
        return 1
    fi

    log_info "Build root bootstrapped successfully"
}

build_system() {
    local profile=$1

    echo -e "${BLUE}=== Building ${PROFILE} system for ${ARCH} ===${NC}"
    echo ""

    # Bootstrap build root if needed
    bootstrap_bldroot || return 1

    # shellcheck disable=SC2207  # package list is whitespace-separated by contract
    local packages=($(get_package_list "$profile"))
    local total=${#packages[@]}
    local current=0
    local failed=()

    # Critical base packages that must succeed
    local critical_packages=("linux-headers" "musl" "base-bootstrap")

    log_info "Building ${total} packages for ${ARCH} (${PROFILE} profile)"
    echo ""

    for pkg in "${packages[@]}"; do
        current=$((current + 1))
        echo ""
        echo -e "${BLUE}[${current}/${total}] Building ${pkg}${NC}"
        echo ""

        if ! build_package "$pkg"; then
            failed+=("$pkg")

            # Check if this is a critical package
            local is_critical=0
            for critical_pkg in "${critical_packages[@]}"; do
                if [ "$pkg" = "$critical_pkg" ]; then
                    is_critical=1
                    break
                fi
            done

            if [ $is_critical -eq 1 ]; then
                echo ""
                log_error "Critical package '$pkg' failed to build"
                log_error "Cannot continue without this package"
                log_error "Check cbuild logs for details"
                return 1
            else
                log_warn "Failed to build ${pkg}, continuing..."
            fi
        fi
    done

    echo ""
    echo -e "${BLUE}=== Build Summary ===${NC}"
    echo ""
    echo "Total packages: ${total}"
    echo "Successful: $((total - ${#failed[@]}))"
    echo "Failed: ${#failed[@]}"

    if [ ${#failed[@]} -gt 0 ]; then
        echo ""
        log_warn "Failed packages:"
        for pkg in "${failed[@]}"; do
            echo "  - $pkg"
        done
        echo ""
        log_warn "Some non-critical packages failed to build"
        return 0  # Don't fail if only non-critical packages failed
    else
        echo ""
        log_info "All packages built successfully!"
        return 0
    fi
}

show_next_steps() {
    echo ""
    echo -e "${GREEN}=== Build Complete ===${NC}"
    echo ""
    echo "Built packages are located in:"
    echo "  ${PROJECT_ROOT}/build/state/${ARCH}/packages/"
    echo ""
    echo "Next steps:"
    echo "  1. Build a full image: ./build/astro-build.sh <board> <variant>"
    echo ""
    echo "  2. Or build additional packages:"
    echo "     cd ${CBUILD_DIR}"
    echo "     ./cbuild -a ${ARCH} pkg main/<package-name>"
    echo ""
}

main() {
    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        usage
    fi

    verify_cbuild
    ensure_apk_in_path

    if [ -z "$SKIP_VERIFY" ]; then
        verify_toolchain
    fi

    create_package_list_file "$PROFILE"

    if build_system "$PROFILE"; then
        show_next_steps
        exit 0
    else
        log_error "Build failed or incomplete"
        log_info "Check cbuild logs for details"
        exit 1
    fi
}

main "$@"
