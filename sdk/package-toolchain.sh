#!/bin/bash
set -e

# Multi-Architecture Toolchain Packaging Script
# Creates a compressed squashfs archive of the complete toolchain

##############################################################################
# Configuration
##############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# This script lives in sdk/; toolchain artifacts are rooted at the repo root
ASTRO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Auto-detect architecture from existing toolchain files
# Look for *-toolchain.cmake files to determine what was built
if [ -f "${ASTRO_ROOT}/armv7hf-toolchain.cmake" ]; then
    ARCH="armv7hf"
    TOOLCHAIN_NAME="armv7hf-clang22-musl-toolchain"
elif [ -f "${ASTRO_ROOT}/aarch64-toolchain.cmake" ]; then
    ARCH="aarch64"
    TOOLCHAIN_NAME="aarch64-clang22-musl-toolchain"
elif [ -f "${ASTRO_ROOT}/x86_64-toolchain.cmake" ]; then
    ARCH="x86_64"
    TOOLCHAIN_NAME="x86_64-clang22-musl-toolchain"
elif [ -f "${ASTRO_ROOT}/riscv64-toolchain.cmake" ]; then
    ARCH="riscv64"
    TOOLCHAIN_NAME="riscv64-clang22-musl-toolchain"
else
    # Fallback to parameter or default
    ARCH="${1:-armv7hf}"
    TOOLCHAIN_NAME="${ARCH}-clang22-musl-toolchain"
fi

OUTPUT_DIR="${ASTRO_ROOT}/dist"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
VERSION="1.0.0"

# Component versions: read from build-toolchain.sh (single source of truth)
# so the packaged TOOLCHAIN_INFO.txt never drifts from what was built.
LLVM_VERSION="$(sed -n 's/^LLVM_VERSION="\(.*\)"/\1/p' "${SCRIPT_DIR}/build-toolchain.sh")"
MUSL_VERSION="$(sed -n 's/^MUSL_VERSION="\(.*\)"/\1/p' "${SCRIPT_DIR}/build-toolchain.sh")"
LINUX_VERSION="$(sed -n 's/^LINUX_VERSION="\(.*\)"/\1/p' "${SCRIPT_DIR}/build-toolchain.sh")"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

##############################################################################
# Helper Functions
##############################################################################

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

check_tools() {
    log_info "Checking required tools..."

    local missing=()

    for tool in mksquashfs zstd; do
        if ! command -v $tool &> /dev/null; then
            missing+=("$tool")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        log_error "Missing required tools: ${missing[*]}"
        echo "" >&2
        echo "Install on Fedora:" >&2
        echo "  sudo dnf install squashfs-tools zstd" >&2
        echo "" >&2
        echo "Install on Debian/Ubuntu:" >&2
        echo "  sudo apt install squashfs-tools zstd" >&2
        exit 1
    fi

    log_info "All required tools found"
}

display_size_info() {
    log_info "Toolchain size analysis:"
    echo "" >&2

    du -sh "${ASTRO_ROOT}/toolchain" 2>/dev/null && echo "  Native LLVM/Clang: $(du -sh ${ASTRO_ROOT}/toolchain | cut -f1)" >&2
    du -sh "${ASTRO_ROOT}/build/state/${ARCH}/sysroot" 2>/dev/null && echo "  Sysroot (musl + libc++): $(du -sh ${ASTRO_ROOT}/build/state/${ARCH}/sysroot | cut -f1)" >&2
    du -sh "${ASTRO_ROOT}/build/state/${ARCH}/bin" 2>/dev/null && echo "  Wrapper scripts: $(du -sh ${ASTRO_ROOT}/build/state/${ARCH}/bin | cut -f1)" >&2

    local total=$(du -sh "${ASTRO_ROOT}/toolchain" "${ASTRO_ROOT}/build/state/${ARCH}" 2>/dev/null | tail -1 | cut -f1)
    echo "" >&2
    echo "  Total uncompressed: $total" >&2
    echo "" >&2
}

##############################################################################
# Main Packaging Functions
##############################################################################

create_squashfs() {
    log_info "Creating squashfs filesystem..."

    local squashfs_file="${OUTPUT_DIR}/${TOOLCHAIN_NAME}-${VERSION}.squashfs"

    # Create list of directories to include
    local include_items=(
        "toolchain"
        "build/state/${ARCH}"
        "${ARCH}-toolchain.cmake"
    )

    # Check which items exist
    local existing_items=()
    for item in "${include_items[@]}"; do
        if [ -e "${ASTRO_ROOT}/${item}" ]; then
            existing_items+=("${item}")
        fi
    done

    # Create temporary staging directory
    local staging_dir="${OUTPUT_DIR}/staging"
    mkdir -p "${staging_dir}"

    log_info "Copying files to staging directory..."
    for item in "${existing_items[@]}"; do
        cp -a "${ASTRO_ROOT}/${item}" "${staging_dir}/"
    done

    # Determine target triple from bin directory
    local TARGET_TRIPLE=""
    for compiler in "${ASTRO_ROOT}"/build/state/${ARCH}/bin/*-clang; do
        if [ -f "$compiler" ]; then
            TARGET_TRIPLE=$(basename "$compiler" | sed 's/-clang$//')
            break
        fi
    done

    # Create info file
    cat > "${staging_dir}/TOOLCHAIN_INFO.txt" << EOF
${ARCH^^} Cross-Compilation Toolchain
=============================================

Version: ${VERSION}
Build Date: $(date)
Architecture: ${ARCH}
Target Triple: ${TARGET_TRIPLE}

Components:
- LLVM/Clang: ${LLVM_VERSION}
- musl libc: ${MUSL_VERSION}
- libc++: LLVM ${LLVM_VERSION}
- Linux Headers: ${LINUX_VERSION}

Features:
- C17 and C++23 support
- Static linking by default
- LLVM toolchain (lld linker, compiler-rt, libc++)

Usage:
1. Extract or mount this archive
2. Use the wrapper scripts in bin/ directory
3. Or use ${ARCH}-toolchain.cmake with CMake

Example:
  ./bin/${TARGET_TRIPLE}-clang++ -std=c++23 -o app app.cpp

For more information, see README.md
EOF

    # Create squashfs with high compression
    log_info "Building squashfs (this may take a few minutes)..."
    mksquashfs "${staging_dir}" "${squashfs_file}" \
        -comp zstd \
        -Xcompression-level 19 \
        -noappend \
        -no-exports \
        -no-progress \
        -processors "$(nproc)" >&2

    # Clean up staging
    rm -rf "${staging_dir}"

    log_info "Squashfs created: ${squashfs_file}"
    echo "  Size: $(du -h ${squashfs_file} | cut -f1)" >&2

    echo "${squashfs_file}"
}

create_extraction_script() {
    local squashfs_file="$1"
    local extract_script="${OUTPUT_DIR}/extract-toolchain.sh"

    log_info "Creating extraction script..."

    cat > "${extract_script}" << 'EXTRACT_EOF'
#!/bin/bash
set -e

# Multi-Architecture Toolchain Extraction Script

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQUASHFS_FILE=""

# Find squashfs file
for file in "${SCRIPT_DIR}"/*.squashfs; do
    if [ -f "$file" ]; then
        SQUASHFS_FILE="$file"
        break
    fi
done

if [ -z "$SQUASHFS_FILE" ]; then
    echo "Error: No .squashfs file found in ${SCRIPT_DIR}"
    exit 1
fi

# Detect architecture from filename
ARCH=$(basename "${SQUASHFS_FILE}" | sed -E 's/^(armv7hf|aarch64|x86_64|riscv64)-.*/\1/')
EXTRACT_DIR="${PWD}/${ARCH}-toolchain"

# Allow custom extraction directory
if [ -n "$1" ]; then
    EXTRACT_DIR="$1"
fi

echo "=== ${ARCH^^} Toolchain Extraction ==="
echo ""
echo "Squashfs file: $(basename ${SQUASHFS_FILE})"
echo "Extract to: ${EXTRACT_DIR}"
echo ""

# Check if unsquashfs is available
if ! command -v unsquashfs &> /dev/null; then
    echo "Error: unsquashfs not found"
    echo ""
    echo "Install on Fedora:"
    echo "  sudo dnf install squashfs-tools"
    echo ""
    echo "Install on Debian/Ubuntu:"
    echo "  sudo apt install squashfs-tools"
    exit 1
fi

# Extract
echo "Extracting..."
mkdir -p "$(dirname ${EXTRACT_DIR})"
unsquashfs -f -d "${EXTRACT_DIR}" "${SQUASHFS_FILE}"

echo ""
echo "=== Extraction complete! ==="
echo ""
echo "Toolchain location: ${EXTRACT_DIR}"
echo ""

# Find the actual compiler triple
COMPILER=$(find "${EXTRACT_DIR}/build/state/${ARCH}/bin" -name '*-clang' -type f 2>/dev/null | head -n1)
if [ -n "$COMPILER" ]; then
    TRIPLE=$(basename "$COMPILER" | sed 's/-clang$//')
    echo "Quick start:"
    echo "  export PATH=\"${EXTRACT_DIR}/build/state/${ARCH}/bin:\$PATH\""
    echo "  ${TRIPLE}-clang++ -std=c++23 -o app app.cpp"
    echo ""
fi

# Find the CMake toolchain file
TOOLCHAIN_CMAKE=$(find "${EXTRACT_DIR}" -maxdepth 1 -name '*-toolchain.cmake' 2>/dev/null | head -n1)
if [ -n "$TOOLCHAIN_CMAKE" ]; then
    echo "With CMake:"
    echo "  cmake -DCMAKE_TOOLCHAIN_FILE=${TOOLCHAIN_CMAKE} .."
    echo ""
fi
EXTRACT_EOF

    chmod +x "${extract_script}"

    log_info "Extraction script created: ${extract_script}"
}

create_mount_script() {
    local squashfs_file="$1"
    local mount_script="${OUTPUT_DIR}/mount-toolchain.sh"

    log_info "Creating mount script..."

    cat > "${mount_script}" << 'MOUNT_EOF'
#!/bin/bash

# Multi-Architecture Toolchain Mount Script
# Mounts the squashfs filesystem without extracting

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQUASHFS_FILE=""

# Find squashfs file
for file in "${SCRIPT_DIR}"/*.squashfs; do
    if [ -f "$file" ]; then
        SQUASHFS_FILE="$file"
        break
    fi
done

if [ -z "$SQUASHFS_FILE" ]; then
    echo "Error: No .squashfs file found in ${SCRIPT_DIR}"
    exit 1
fi

# Detect architecture from filename
ARCH=$(basename "${SQUASHFS_FILE}" | sed -E 's/^(armv7hf|aarch64|x86_64|riscv64)-.*/\1/')
MOUNT_POINT="${PWD}/${ARCH}-toolchain-mount"

# Allow custom mount point
if [ -n "$1" ]; then
    MOUNT_POINT="$1"
fi

echo "=== ${ARCH^^} Toolchain Mount ==="
echo ""
echo "Squashfs file: $(basename ${SQUASHFS_FILE})"
echo "Mount point: ${MOUNT_POINT}"
echo ""

# Create mount point
mkdir -p "${MOUNT_POINT}"

# Check if already mounted
if mountpoint -q "${MOUNT_POINT}"; then
    echo "Already mounted at ${MOUNT_POINT}"
    echo ""
    echo "To unmount:"
    echo "  sudo umount ${MOUNT_POINT}"
    exit 0
fi

# Mount
echo "Mounting (requires sudo)..."
sudo mount -t squashfs -o loop,ro "${SQUASHFS_FILE}" "${MOUNT_POINT}"

echo ""
echo "=== Mounted successfully! ==="
echo ""
echo "Toolchain location: ${MOUNT_POINT}"
echo ""

# Find the actual compiler triple
COMPILER=$(find "${MOUNT_POINT}/build/state/${ARCH}/bin" -name '*-clang' -type f 2>/dev/null | head -n1)
if [ -n "$COMPILER" ]; then
    TRIPLE=$(basename "$COMPILER" | sed 's/-clang$//')
    echo "Quick start:"
    echo "  export PATH=\"${MOUNT_POINT}/build/state/${ARCH}/bin:\$PATH\""
    echo "  ${TRIPLE}-clang++ -std=c++23 -o app app.cpp"
    echo ""
fi

echo "To unmount when done:"
echo "  sudo umount ${MOUNT_POINT}"
echo ""
MOUNT_EOF

    chmod +x "${mount_script}"

    log_info "Mount script created: ${mount_script}"
}

create_readme() {
    local readme="${OUTPUT_DIR}/README.txt"

    cat > "${readme}" << 'README_EOF'
Multi-Architecture Cross-Compilation Toolchain Distribution
===========================================================

This package contains a complete cross-compilation toolchain using
Clang 21, musl libc, and LLVM libc++.

Contents:
---------
- *-clang22-musl-toolchain-*.squashfs : Compressed toolchain
- extract-toolchain.sh                : Extraction script
- mount-toolchain.sh                  : Mount script (no extraction)
- README.txt                          : This file

Quick Start (Extract):
---------------------
./extract-toolchain.sh [optional-target-dir]

This will extract the toolchain to a directory (default: ./<arch>-toolchain)

Quick Start (Mount - No Extraction):
-----------------------------------
./mount-toolchain.sh [optional-mount-point]

This mounts the squashfs filesystem read-only without extracting.
Requires sudo for mounting. Use 'sudo umount <mount-point>' to unmount.

Usage:
------
After extraction or mounting:

1. Direct usage:
   /path/to/toolchain/bin/<triple>-clang -o app app.c
   /path/to/toolchain/bin/<triple>-clang++ -std=c++23 -o app app.cpp

2. Add to PATH:
   export PATH="/path/to/toolchain/bin:$PATH"
   <triple>-clang++ -o app app.cpp

3. With CMake:
   cmake -DCMAKE_TOOLCHAIN_FILE=/path/to/toolchain/<arch>-toolchain.cmake ..

Common Features:
---------------
- C17 and C++23 support
- Static linking by default
- LLVM toolchain (lld linker, compiler-rt, libc++)
- musl C library
- LLVM libc++ standard library

Supported Architectures:
-----------------------
- armv7hf  : ARMv7-A hard-float (Raspberry Pi 2/3, BeagleBone Black)
- aarch64  : ARM64 (Raspberry Pi 3/4/5 64-bit, modern ARM servers)
- x86_64   : x86-64 (Intel/AMD 64-bit)
- riscv64  : RISC-V 64-bit

For more information, see TOOLCHAIN_INFO.txt inside the archive.
README_EOF

    log_info "README created: ${readme}"
}

create_checksum() {
    local squashfs_file="$1"

    log_info "Creating checksums..."

    cd "${OUTPUT_DIR}"

    # SHA256
    sha256sum "$(basename ${squashfs_file})" > "$(basename ${squashfs_file}).sha256"

    log_info "Checksum file created: $(basename ${squashfs_file}).sha256"
}

##############################################################################
# Main
##############################################################################

main() {
    echo -e "${BLUE}=== ARMv7 Toolchain Packaging ===${NC}" >&2
    echo "" >&2

    check_tools

    # Create output directory
    mkdir -p "${OUTPUT_DIR}"

    # Display size info
    display_size_info

    # Create squashfs
    squashfs_file=$(create_squashfs)

    # Create helper scripts
    create_extraction_script "${squashfs_file}"
    create_mount_script "${squashfs_file}"
    create_readme
    create_checksum "${squashfs_file}"

    echo "" >&2
    echo -e "${GREEN}=== Packaging Complete! ===${NC}" >&2
    echo "" >&2
    echo "Output directory: ${OUTPUT_DIR}" >&2
    echo "" >&2
    echo "Files created:" >&2
    ls -lh "${OUTPUT_DIR}" | tail -n +2 | awk '{printf "  %-50s %10s\n", $9, $5}' >&2
    echo "" >&2
    echo "Distribution package:" >&2
    echo "  $(basename ${squashfs_file})" >&2
    echo "" >&2
    echo "To distribute:" >&2
    echo "  1. Share the entire ${OUTPUT_DIR} directory, or" >&2
    echo "  2. Share just the .squashfs file with extract-toolchain.sh" >&2
    echo "" >&2
}

main "$@"
