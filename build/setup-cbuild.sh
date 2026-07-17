#!/bin/bash
set -e

# Chimera cbuild Setup Script
# Installs dependencies and configures cbuild for cross-compilation
#
# NOTE (migration): the cports checkout is no longer vendored in this repo.
# It lives at <repo-root>/cports and is managed by Harbormaster:
# .harbormaster.toml declares the repo, the committed .harbormaster.lock
# pins the exact SHA, and `hm sync --locked` materializes it.
# The hm binary is expected on PATH or at <repo-root>/build/tools/hm
# (build it from the harbormaster repo: `go build -o build/tools/hm
# ./cmd/harbormaster`).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CPORTS_DIR="${PROJECT_ROOT}/cports"
PROFILES_DIR="${PROJECT_ROOT}/build/cbuild-profiles"

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

check_python_version() {
    log_info "Checking Python version..."

    if ! command -v python3 &> /dev/null; then
        log_error "Python 3 not found"
        exit 1
    fi

    PYTHON_VERSION=$(python3 --version | awk '{print $2}')
    PYTHON_MAJOR=$(echo $PYTHON_VERSION | cut -d. -f1)
    PYTHON_MINOR=$(echo $PYTHON_VERSION | cut -d. -f2)

    log_info "Found Python ${PYTHON_VERSION}"

    if [ "$PYTHON_MAJOR" -lt 3 ] || ([ "$PYTHON_MAJOR" -eq 3 ] && [ "$PYTHON_MINOR" -lt 12 ]); then
        log_error "Python 3.12+ required, found ${PYTHON_VERSION}"
        log_info "Install Python 3.12+ or use pyenv/conda"
        exit 1
    fi

    log_info "Python version OK (${PYTHON_VERSION})"
}

check_dependencies() {
    log_info "Checking required dependencies..."

    local missing=()

    # Required tools for building
    for tool in git cmake meson ninja pkg-config make flex byacc m4 perl patch xz zstd; do
        if ! command -v $tool &> /dev/null; then
            missing+=($tool)
        fi
    done

    # Check for bwrap (bubblewrap)
    if ! command -v bwrap &> /dev/null; then
        missing+=(bubblewrap)
    fi

    # Check for bsdtar (from libarchive)
    if ! command -v bsdtar &> /dev/null; then
        missing+=(libarchive)
    fi

    if [ ${#missing[@]} -ne 0 ]; then
        log_error "Missing required dependencies: ${missing[*]}"
        echo ""
        echo "Install on Fedora:"
        echo "  sudo dnf install git cmake meson ninja-build pkgconf make flex byacc m4 perl bubblewrap patch xz zstd libarchive"
        echo ""
        echo "Install on Debian/Ubuntu:"
        echo "  sudo apt install git cmake meson ninja-build pkg-config make flex bison m4 perl bubblewrap patch xz-utils zstd libarchive-tools"
        echo ""
        exit 1
    fi

    log_info "All core dependencies found"
}

build_apk_tools() {
    log_info "Building apk-tools from source..."

    local APK_VERSION="3.0.5"  # Match version used by Chimera's cports
    local APK_DIR="${PROJECT_ROOT}/build/state/apk-tools"
    local APK_INSTALL="${PROJECT_ROOT}/toolchain/apk"

    # Check if already installed and correct version
    if [ -f "${APK_INSTALL}/bin/apk" ]; then
        local INSTALLED_VERSION=$(LD_LIBRARY_PATH="${APK_INSTALL}/lib" "${APK_INSTALL}/bin/apk" --version 2>&1 | grep -oP 'apk-tools \K[0-9.]+' || echo "unknown")
        if [[ "$INSTALLED_VERSION" == 3.* ]]; then
            log_info "apk-tools 3.x already installed at ${APK_INSTALL}/bin/apk"
            export PATH="${APK_INSTALL}/bin:$PATH"
            export LD_LIBRARY_PATH="${APK_INSTALL}/lib:${LD_LIBRARY_PATH}"
            return 0
        else
            log_warn "Found apk-tools $INSTALLED_VERSION, need 3.x - rebuilding..."
            rm -rf "${APK_INSTALL}"
        fi
    fi

    mkdir -p "${APK_DIR}"
    cd "${APK_DIR}"

    # Download apk-tools 3.x specific version tag
    if [ ! -d "apk-tools-v${APK_VERSION}" ]; then
        log_info "Cloning apk-tools ${APK_VERSION}..."
        git clone --depth 1 --branch "v${APK_VERSION}" \
            https://gitlab.alpinelinux.org/alpine/apk-tools.git "apk-tools-v${APK_VERSION}"
    else
        log_info "apk-tools ${APK_VERSION} already cloned"
    fi

    cd "apk-tools-v${APK_VERSION}"

    # Build using meson (apk-tools 3.x uses meson, not make)
    log_info "Compiling apk-tools 3.x with meson (this may take a few minutes)..."

    # Setup meson build (clean stale builds if needed)
    if [ -d "build" ] && [ ! -f "build/build.ninja" ]; then
        log_warn "Stale meson build directory found, cleaning..."
        rm -rf build
    fi

    if [ ! -d "build" ]; then
        meson setup build \
            --prefix=/usr \
            --sbindir=/usr/bin \
            -Dlua=disabled \
            -Dhelp=disabled \
            -Ddocs=disabled \
            -Dzstd=true \
            2>&1 | tee meson-setup.log
    fi

    # Build
    if meson compile -C build 2>&1 | tee build.log; then
        log_info "Installing apk-tools to ${APK_INSTALL}..."
        DESTDIR="${APK_INSTALL}" meson install -C build

        # Create symlinks for easier access
        mkdir -p "${APK_INSTALL}/bin"
        ln -sf ../usr/bin/apk "${APK_INSTALL}/bin/apk" 2>/dev/null || true

        # Add to PATH and LD_LIBRARY_PATH for current session (support both lib and lib64)
        export PATH="${APK_INSTALL}/bin:${APK_INSTALL}/usr/bin:$PATH"
        export LD_LIBRARY_PATH="${APK_INSTALL}/usr/lib64:${APK_INSTALL}/usr/lib:${LD_LIBRARY_PATH}"

        # Verify version
        local NEW_VERSION=$(LD_LIBRARY_PATH="${APK_INSTALL}/usr/lib64:${APK_INSTALL}/usr/lib" "${APK_INSTALL}/bin/apk" --version 2>&1 | head -1)
        log_info "apk-tools built successfully: $NEW_VERSION"
    else
        log_error "Failed to build apk-tools"
        log_error "Check ${APK_DIR}/apk-tools-v${APK_VERSION}/build.log for details"
        exit 1
    fi

    cd "${PROJECT_ROOT}"
}

check_or_build_apk() {
    log_info "Checking for apk-tools..."

    if command -v apk &> /dev/null; then
        local SYS_VERSION=$(apk --version 2>&1 | grep -oP 'apk-tools \K[0-9]+' | head -1 || echo "0")
        if [[ "$SYS_VERSION" -ge 3 ]]; then
            log_info "apk-tools 3.x found in system: $(which apk)"
            return 0
        else
            log_warn "System apk-tools is version $SYS_VERSION.x, need 3.x"
        fi
    fi

    # Check our local build
    local APK_INSTALL="${PROJECT_ROOT}/toolchain/apk"
    if [ -f "${APK_INSTALL}/bin/apk" ] || [ -f "${APK_INSTALL}/usr/bin/apk" ]; then
        # Check version (try both possible locations)
        local APK_BIN="${APK_INSTALL}/bin/apk"
        [ ! -f "$APK_BIN" ] && APK_BIN="${APK_INSTALL}/usr/bin/apk"

        local LOCAL_VERSION=$(LD_LIBRARY_PATH="${APK_INSTALL}/usr/lib64:${APK_INSTALL}/usr/lib:${APK_INSTALL}/lib" "$APK_BIN" --version 2>&1 | grep -oP 'apk-tools \K[0-9]+' | head -1 || echo "0")
        if [[ "$LOCAL_VERSION" -ge 3 ]]; then
            log_info "apk-tools 3.x found in local build: $APK_BIN"
            export PATH="${APK_INSTALL}/bin:${APK_INSTALL}/usr/bin:$PATH"
            export LD_LIBRARY_PATH="${APK_INSTALL}/usr/lib64:${APK_INSTALL}/usr/lib:${APK_INSTALL}/lib:${LD_LIBRARY_PATH}"
            return 0
        else
            log_warn "Local apk-tools is version $LOCAL_VERSION.x, need 3.x - rebuilding..."
        fi
    fi

    log_info "Building apk-tools 3.x from source..."
    build_apk_tools
}

# Locate the Harbormaster binary: prefer `hm` on PATH, fall back to the
# repo-local build at build/tools/hm. Prints the path on success.
find_hm() {
    if command -v hm &> /dev/null; then
        command -v hm
        return 0
    fi
    if [ -x "${PROJECT_ROOT}/build/tools/hm" ]; then
        echo "${PROJECT_ROOT}/build/tools/hm"
        return 0
    fi
    return 1
}

check_cports() {
    log_info "Checking for cports checkout..."

    # The cports tree is NOT cloned by this script. It is a companion repo
    # declared in .harbormaster.toml, pinned by .harbormaster.lock, and
    # materialized at ${PROJECT_ROOT}/cports by Harbormaster.
    if [ ! -d "${CPORTS_DIR}" ] || [ ! -f "${CPORTS_DIR}/cbuild" ]; then
        log_error "cports checkout not found at ${CPORTS_DIR}"
        log_error ""
        log_error "cports is managed by Harbormaster (AD-001/AD-003)."
        local HM_BIN
        if HM_BIN="$(find_hm)"; then
            log_error "Materialize it with:"
            log_error "  ${HM_BIN} sync --locked"
        else
            log_error "The 'hm' binary was not found on PATH or at"
            log_error "  ${PROJECT_ROOT}/build/tools/hm"
            log_error "Build it from the harbormaster repo:"
            log_error "  go build -o ${PROJECT_ROOT}/build/tools/hm ./cmd/harbormaster"
            log_error "then materialize cports with:"
            log_error "  ${PROJECT_ROOT}/build/tools/hm sync --locked"
        fi
        exit 1
    fi

    log_info "cports found at ${CPORTS_DIR}"
}

verify_profiles() {
    log_info "Verifying architecture profiles..."

    # Profiles are committed at build/cbuild-profiles/ (no longer generated here).
    # TODO(migration): per AD-002 these should be regenerated to point at the
    # bldroot toolchain; profile generation moves into the build stages later.
    local missing=0
    for profile in aarch64; do
        if [ ! -f "${PROFILES_DIR}/${profile}.conf" ]; then
            log_error "Missing profile: ${PROFILES_DIR}/${profile}.conf"
            missing=1
        fi
    done

    if [ $missing -ne 0 ]; then
        exit 1
    fi

    log_info "Profiles present in ${PROFILES_DIR}/"
    log_info "Device configs present in ${PROFILES_DIR}/devices/"
}

verify_cbuild() {
    log_info "Verifying cbuild installation..."

    if [ ! -f "${CPORTS_DIR}/cbuild" ]; then
        log_error "cbuild not found at ${CPORTS_DIR}/cbuild"
        exit 1
    fi

    log_info "cbuild verified successfully"
}

generate_signing_key() {
    log_info "Checking for package signing key..."

    local CONFIG_DIR="${HOME}/.config/cbuild"
    local CONFIG_FILE="${CONFIG_DIR}/config.ini"

    # Check if signing key is already configured
    if [ -f "$CONFIG_FILE" ] && grep -q "^\[signing\]" "$CONFIG_FILE" 2>/dev/null; then
        log_info "Signing key already configured"
        return 0
    fi

    log_info "Generating package signing key for cbuild..."

    mkdir -p "$CONFIG_DIR"

    # Ensure apk is in PATH and LD_LIBRARY_PATH for cbuild keygen
    local APK_INSTALL="${PROJECT_ROOT}/toolchain/apk"
    if [ -f "${APK_INSTALL}/bin/apk" ] || [ -f "${APK_INSTALL}/usr/bin/apk" ]; then
        export PATH="${APK_INSTALL}/bin:${APK_INSTALL}/usr/bin:$PATH"
        export LD_LIBRARY_PATH="${APK_INSTALL}/usr/lib64:${APK_INSTALL}/usr/lib:${APK_INSTALL}/lib:${LD_LIBRARY_PATH}"
    fi

    # Create a simple config if it doesn't exist
    if [ ! -f "$CONFIG_FILE" ]; then
        cat > "$CONFIG_FILE" << 'EOF'
[build]
jobs = 0

[host]
EOF
    fi

    # Generate key - must be in cports directory
    local CURRENT_DIR=$(pwd)
    cd "${CPORTS_DIR}"

    # Generate key - syntax: keygen <name> <keysize>
    if ./cbuild keygen "cbuild-dev@localhost" 4096 2>&1 | tee keygen.log; then
        log_info "Signing key generated successfully"
    else
        log_error "Failed to generate signing key"
        log_error "Check ${CPORTS_DIR}/keygen.log for details"
        cd "${CURRENT_DIR}"
        exit 1
    fi

    cd "${CURRENT_DIR}"
}

main() {
    echo -e "${BLUE}=== Chimera cbuild Setup ===${NC}"
    echo ""

    check_python_version
    check_dependencies
    check_or_build_apk
    check_cports
    verify_profiles
    verify_cbuild
    generate_signing_key

    echo ""
    echo -e "${GREEN}=== Setup Complete! ===${NC}"
    echo ""

    # Show apk-tools location if built locally
    local APK_INSTALL="${PROJECT_ROOT}/toolchain/apk"
    if [ -f "${APK_INSTALL}/bin/apk" ]; then
        echo "apk-tools installed to: ${APK_INSTALL}/bin/apk"
        echo "Add to your PATH: export PATH=\"${APK_INSTALL}/bin:\$PATH\""
        echo ""
    fi

    echo "Next steps:"
    echo "  1. Review architecture profiles in: build/cbuild-profiles/"
    echo "  2. Review device configs in: build/cbuild-profiles/devices/"
    echo "  3. Build a board: ./build/astro-build.sh <board> <variant>"
    echo ""
}

main "$@"
