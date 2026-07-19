#!/bin/bash
set -e

# Multi-Architecture Cross-Compilation Toolchain Builder
# Supports: ARMv7 hard-float, ARM64, x86_64, RISC-V 64
# Components: Clang 22, musl libc, libc++

##############################################################################
# Architecture Selection
##############################################################################

ARCH="${1:-armv7hf}"

case "$ARCH" in
    armv7hf|armv7)
        TARGET_TRIPLE="armv7-unknown-linux-musleabihf"
        TARGET_ARCH="arm"
        TARGET_CPU="cortex-a7"
        TARGET_MARCH="armv7-a"
        TARGET_FPU="neon-vfpv4"
        TARGET_FLOAT_ABI="hard"
        LINKER_EMULATION="armelf_linux_eabi"
        KERNEL_ARCH="arm"
        TOOLCHAIN_NAME="armv7hf-clang22-musl"
        ;;
    aarch64|arm64)
        TARGET_TRIPLE="aarch64-unknown-linux-musl"
        TARGET_ARCH="aarch64"
        TARGET_CPU="generic"
        TARGET_MARCH="armv8-a"
        TARGET_FPU=""
        TARGET_FLOAT_ABI=""
        LINKER_EMULATION="aarch64linux"
        KERNEL_ARCH="arm64"
        TOOLCHAIN_NAME="aarch64-clang22-musl"
        ;;
    x86_64|x64)
        TARGET_TRIPLE="x86_64-unknown-linux-musl"
        TARGET_ARCH="x86_64"
        TARGET_CPU="generic"
        TARGET_MARCH="x86-64"
        TARGET_FPU=""
        TARGET_FLOAT_ABI=""
        LINKER_EMULATION="elf_x86_64"
        KERNEL_ARCH="x86"
        TOOLCHAIN_NAME="x86_64-clang22-musl"
        ;;
    riscv64|rv64)
        TARGET_TRIPLE="riscv64-unknown-linux-musl"
        TARGET_ARCH="riscv64"
        TARGET_CPU="generic-rv64"
        TARGET_MARCH="rv64gc"
        TARGET_MABI="lp64d"
        TARGET_FPU=""
        TARGET_FLOAT_ABI=""
        LINKER_EMULATION="elf64lriscv"
        KERNEL_ARCH="riscv"
        TOOLCHAIN_NAME="riscv64-clang22-musl"
        ;;
    *)
        echo "Usage: $0 [armv7hf|aarch64|x86_64|riscv64]"
        echo ""
        echo "Supported architectures:"
        echo "  armv7hf  - ARMv7-A hard-float (32-bit ARM with NEON)"
        echo "  aarch64  - ARM64 (64-bit ARM)"
        echo "  x86_64   - x86-64 (64-bit Intel/AMD)"
        echo "  riscv64  - RISC-V 64-bit"
        echo ""
        exit 1
        ;;
esac

##############################################################################
# Configuration
##############################################################################

# Version configuration
#
# Alignment policy (docs/03 AD-002): the app SDK tracks the LLVM/musl
# versions used by the pinned cports checkout (.harbormaster.lock), not
# necessarily the newest upstream release — consistency with the distro
# toolchain beats novelty. Kernel headers track the LTS line the boards
# ship (boards/*/board.toml [kernel].version), latest patch release.
#
# Current pins (cports @ e3c9e1a0, 2026-07-15):
#   LLVM  22.1.7  = cports main/llvm        (upstream latest is 22.1.8)
#   musl  1.2.6   = cports main/musl        (upstream latest; includes the
#                   2025-02 iconv CVE fixes previously carried as patches)
#   Linux 6.12.95 = latest 6.12 LTS patch, matching the board kernels
LLVM_VERSION="22.1.7"
MUSL_VERSION="1.2.6"
LINUX_VERSION="6.12.95"

# Directory configuration
# This script lives in sdk/; all artifacts are rooted at the repo root
# (ASTRO_ROOT): toolchain/ and sources/ are gitignored caches, build
# outputs live under build/state/.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASTRO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${ASTRO_ROOT}/build/state/${ARCH}"
SRC_DIR="${ASTRO_ROOT}/sources"
SYSROOT="${ASTRO_ROOT}/build/state/${ARCH}/sysroot"
TOOLCHAIN_DIR="${ASTRO_ROOT}/toolchain"
BIN_DIR="${ASTRO_ROOT}/build/state/${ARCH}/bin"
PATCHES_DIR="${ASTRO_ROOT}/build/patches"

# Source patch definitions if available
if [ -f "${PATCHES_DIR}/patches.sh" ]; then
    source "${PATCHES_DIR}/patches.sh"
fi

# Parallel build jobs
JOBS=$(nproc)

# Build architecture-specific compiler flags
build_arch_flags() {
    local flags="--target=${TARGET_TRIPLE} -march=${TARGET_MARCH}"

    # Add FPU flag if defined (ARMv7 only)
    if [ -n "$TARGET_FPU" ]; then
        flags="$flags -mfpu=${TARGET_FPU}"
    fi

    # Add float ABI if defined (ARMv7 only)
    if [ -n "$TARGET_FLOAT_ABI" ]; then
        flags="$flags -mfloat-abi=${TARGET_FLOAT_ABI}"
    fi

    # Add RISC-V ABI if defined
    if [ -n "$TARGET_MABI" ]; then
        flags="$flags -mabi=${TARGET_MABI}"
    fi

    echo "$flags"
}

# Get base architecture flags
ARCH_FLAGS=$(build_arch_flags)

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

##############################################################################
# Helper Functions
##############################################################################

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

##############################################################################
# Version Tracking Functions
##############################################################################

# Check if a component's version matches the expected version
# Returns 0 if version matches, 1 if mismatch or no version file
check_version() {
    local version_file="$1"
    local expected_version="$2"

    if [ -f "$version_file" ]; then
        local current_version
        current_version=$(cat "$version_file")
        if [ "$current_version" = "$expected_version" ]; then
            return 0
        fi
        log_warn "Version mismatch in $version_file: found $current_version, expected $expected_version"
        return 1
    fi
    return 1
}

# Write version to tracking file
write_version() {
    local version_file="$1"
    local version="$2"
    mkdir -p "$(dirname "$version_file")"
    echo "$version" > "$version_file"
}

# Check version and clean build artifacts if mismatch
check_and_clean_llvm() {
    local version_file="${TOOLCHAIN_DIR}/.llvm-version"
    if [ -d "${TOOLCHAIN_DIR}" ] && [ -f "${TOOLCHAIN_DIR}/bin/clang" ]; then
        if ! check_version "$version_file" "$LLVM_VERSION"; then
            log_warn "Cleaning LLVM toolchain due to version change..."
            rm -rf "${TOOLCHAIN_DIR}"
            # Also clean architecture-specific LLVM build dirs
            rm -rf "${ASTRO_ROOT}/build/state"/*/llvm-native
        fi
    fi
}

check_and_clean_compiler_rt() {
    local version_file="${BUILD_DIR}/.compiler-rt-version"
    if ! check_version "$version_file" "$LLVM_VERSION"; then
        if [ -d "${BUILD_DIR}/compiler-rt-builtins" ]; then
            log_warn "Cleaning compiler-rt (builtins + crt) due to LLVM version change..."
            rm -rf "${BUILD_DIR}/compiler-rt-builtins"
            rm -rf "${SYSROOT}/lib/linux"
            rm -rf "${TOOLCHAIN_DIR}/lib/clang/${LLVM_VERSION%%.*}/lib/${TARGET_TRIPLE}"
        fi
    fi
}

check_and_clean_libcxx() {
    local version_file="${BUILD_DIR}/.libcxx-version"
    if ! check_version "$version_file" "$LLVM_VERSION"; then
        if [ -d "${BUILD_DIR}/runtimes" ]; then
            log_warn "Cleaning libc++ due to LLVM version change..."
            rm -rf "${BUILD_DIR}/runtimes"
            rm -f "${SYSROOT}/lib/libc++.a"
            rm -f "${SYSROOT}/lib/libc++abi.a"
            rm -f "${SYSROOT}/lib/libunwind.a"
            rm -rf "${SYSROOT}/include/c++"
        fi
    fi
}

check_and_clean_musl() {
    local version_file="${BUILD_DIR}/.musl-version"
    if ! check_version "$version_file" "$MUSL_VERSION"; then
        if [ -d "${BUILD_DIR}/musl" ]; then
            log_warn "Cleaning musl due to version change..."
            rm -rf "${BUILD_DIR}/musl"
            rm -f "${SYSROOT}/lib/libc.a"
            rm -f "${SYSROOT}/lib/crt"*.o
        fi
    fi
}

check_and_clean_kernel_headers() {
    local version_file="${BUILD_DIR}/.kernel-headers-version"
    if ! check_version "$version_file" "$LINUX_VERSION"; then
        if [ -f "${SYSROOT}/include/linux/version.h" ]; then
            log_warn "Cleaning kernel headers due to version change..."
            rm -rf "${SYSROOT}/include/linux"
            rm -rf "${SYSROOT}/include/asm"
            rm -rf "${SYSROOT}/include/asm-generic"
            rm -rf "${BUILD_DIR}/kernel-headers-obj"
        fi
    fi
}

##############################################################################
# Patch Application Functions
##############################################################################

# Apply patches to a source directory
# Usage: apply_patches <source_dir> <patch_array_name> <marker_file>
apply_patches() {
    local source_dir="$1"
    local -n patches_array="$2"
    local marker_file="$3"

    # Skip if no patches defined
    if [ ${#patches_array[@]} -eq 0 ]; then
        return 0
    fi

    # Skip if patches already applied
    if [ -f "$marker_file" ]; then
        log_info "Patches already applied (marker: $marker_file)"
        return 0
    fi

    log_info "Applying ${#patches_array[@]} patch(es) to $source_dir..."

    cd "$source_dir"

    for patch in "${patches_array[@]}"; do
        local patch_file="${PATCHES_DIR}/${patch}"
        if [ -f "$patch_file" ]; then
            log_info "  Applying: $patch"
            if ! patch -p1 -N --dry-run < "$patch_file" > /dev/null 2>&1; then
                # Check if already applied
                if patch -p1 -R --dry-run < "$patch_file" > /dev/null 2>&1; then
                    log_info "    (already applied, skipping)"
                    continue
                else
                    log_error "  Failed to apply patch: $patch"
                    exit 1
                fi
            fi
            patch -p1 -N < "$patch_file"
        else
            log_error "Patch file not found: $patch_file"
            exit 1
        fi
    done

    # Create marker file to indicate patches were applied
    touch "$marker_file"
    log_info "All patches applied successfully"
}

# Apply all source patches
apply_source_patches() {
    log_info "Checking for source patches..."

    # Apply musl patches
    if [ -n "${MUSL_PATCHES+x}" ] && [ ${#MUSL_PATCHES[@]} -gt 0 ]; then
        apply_patches "${SRC_DIR}/musl-${MUSL_VERSION}" MUSL_PATCHES "${SRC_DIR}/musl-${MUSL_VERSION}/.patches-applied"
    fi

    # Apply LLVM patches
    if [ -n "${LLVM_PATCHES+x}" ] && [ ${#LLVM_PATCHES[@]} -gt 0 ]; then
        apply_patches "${SRC_DIR}/llvm-project" LLVM_PATCHES "${SRC_DIR}/llvm-project/.patches-applied"
    fi

    # Apply Linux kernel patches
    if [ -n "${LINUX_PATCHES+x}" ] && [ ${#LINUX_PATCHES[@]} -gt 0 ]; then
        apply_patches "${SRC_DIR}/linux-${LINUX_VERSION}" LINUX_PATCHES "${SRC_DIR}/linux-${LINUX_VERSION}/.patches-applied"
    fi
}

check_prerequisites() {
    log_info "Checking prerequisites..."

    local missing_deps=()

    for cmd in cmake ninja git curl tar patch; do
        if ! command -v $cmd &> /dev/null; then
            missing_deps+=($cmd)
        fi
    done

    if [ ${#missing_deps[@]} -ne 0 ]; then
        log_error "Missing dependencies: ${missing_deps[*]}"
        log_error "Please install: sudo dnf install cmake ninja-build git curl tar python3"
        exit 1
    fi

    log_info "All prerequisites satisfied"
}

create_directories() {
    log_info "Creating directory structure..."
    mkdir -p "${SRC_DIR}" "${BUILD_DIR}" "${SYSROOT}" "${TOOLCHAIN_DIR}"
    mkdir -p "${SYSROOT}"/{lib,include,bin}
}

##############################################################################
# Download Sources
##############################################################################

download_sources() {
    log_info "Downloading sources..."

    cd "${SRC_DIR}"

    # Download LLVM Project
    if [ ! -d "llvm-project" ]; then
        log_info "Downloading LLVM ${LLVM_VERSION}..."
        git clone --depth 1 --branch "llvmorg-${LLVM_VERSION}" \
            https://github.com/llvm/llvm-project.git
    else
        log_info "LLVM source already exists"
		cd llvm-project
		git fetch origin tag "llvmorg-${LLVM_VERSION}"
		git checkout "llvmorg-${LLVM_VERSION}"
		cd ..
    fi

    # Download musl
    if [ ! -f "musl-${MUSL_VERSION}.tar.gz" ]; then
        log_info "Downloading musl ${MUSL_VERSION}..."
        curl -LO "https://musl.libc.org/releases/musl-${MUSL_VERSION}.tar.gz"
        tar -xzf "musl-${MUSL_VERSION}.tar.gz"
    else
        log_info "musl source already exists"
    fi

    # Download Linux kernel headers
    if [ ! -f "linux-${LINUX_VERSION}.tar.xz" ]; then
        log_info "Downloading Linux kernel headers ${LINUX_VERSION}..."
        local major_version=$(echo ${LINUX_VERSION} | cut -d. -f1)
        curl -LO "https://cdn.kernel.org/pub/linux/kernel/v${major_version}.x/linux-${LINUX_VERSION}.tar.xz"
        tar -xJf "linux-${LINUX_VERSION}.tar.xz"
    else
        log_info "Linux kernel headers source already exists"
    fi
}

##############################################################################
# Build LLVM/Clang (Native Bootstrap Compiler)
##############################################################################

build_llvm_native() {
    log_info "Building native LLVM/Clang ${LLVM_VERSION}..."

    local build_dir="${BUILD_DIR}/llvm-native"
    mkdir -p "${build_dir}"
    cd "${build_dir}"

    if [ -f "${TOOLCHAIN_DIR}/bin/clang" ]; then
        log_info "Native LLVM already built, skipping..."
        return 0
    fi

    cmake -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${TOOLCHAIN_DIR}" \
        -DLLVM_ENABLE_PROJECTS="clang;lld;compiler-rt" \
        -DLLVM_ENABLE_RUNTIMES="libcxx;libcxxabi;libunwind" \
        -DLLVM_TARGETS_TO_BUILD="ARM;AArch64;X86" \
        -DLLVM_INSTALL_TOOLCHAIN_ONLY=ON \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_EXAMPLES=OFF \
        -DLLVM_INCLUDE_BENCHMARKS=OFF \
        "${SRC_DIR}/llvm-project/llvm"

    ninja -j${JOBS}
    ninja install

    # Record the version we just built
    write_version "${TOOLCHAIN_DIR}/.llvm-version" "$LLVM_VERSION"

    log_info "Native LLVM/Clang build complete"
}

##############################################################################
# Build musl libc
##############################################################################

build_musl() {
    log_info "Building musl libc for ${TARGET_TRIPLE}..."

    local build_dir="${BUILD_DIR}/musl"
    mkdir -p "${build_dir}"
    cd "${build_dir}"

    if [ -f "${SYSROOT}/lib/libc.a" ]; then
        log_info "musl already built, skipping..."
        return 0
    fi

    # Architecture-specific flags
    local CFLAGS="${ARCH_FLAGS} -O2"

    "${SRC_DIR}/musl-${MUSL_VERSION}/configure" \
        --prefix="${SYSROOT}" \
        --target="${TARGET_TRIPLE}" \
        CC="${TOOLCHAIN_DIR}/bin/clang" \
        AR="${TOOLCHAIN_DIR}/bin/llvm-ar" \
        RANLIB="${TOOLCHAIN_DIR}/bin/llvm-ranlib" \
        CFLAGS="${CFLAGS}" \
        --disable-shared

    make -j${JOBS} \
        AR="${TOOLCHAIN_DIR}/bin/llvm-ar" \
        RANLIB="${TOOLCHAIN_DIR}/bin/llvm-ranlib"
    make install \
        AR="${TOOLCHAIN_DIR}/bin/llvm-ar" \
        RANLIB="${TOOLCHAIN_DIR}/bin/llvm-ranlib"

    # Create necessary symlinks
    cd "${SYSROOT}/lib"
    ln -sf libc.a libm.a
    ln -sf libc.a libpthread.a
    ln -sf libc.a librt.a
    ln -sf libc.a libdl.a

    # Record the version we just built
    write_version "${BUILD_DIR}/.musl-version" "$MUSL_VERSION"

    log_info "musl libc build complete"
}

##############################################################################
# Install Linux Kernel Headers
##############################################################################

install_kernel_headers() {
    log_info "Installing Linux kernel headers..."

    if [ -f "${SYSROOT}/include/linux/version.h" ]; then
        log_info "Kernel headers already installed, skipping..."
        return 0
    fi

    # ARCH is parameterized per target (KERNEL_ARCH set in the arch case
    # block above: arm64 for aarch64, x86 for x86_64, arm for armv7hf,
    # riscv for riscv64). Header version tracks the board kernels'
    # LTS line (docs/03-build-system.md §3 fix list, items 2 and 4).
    #
    # O= keeps all generated state out of the shared sources/linux-* tree:
    # the kernel stage builds from the same extracted tree with its own O=
    # and Kbuild refuses to run in a dirtied source tree (GAP fix #2 was a
    # one-time 'make mrproper'; this is the root-cause fix — the tree stays
    # pristine).
    local hdr_obj="${BUILD_DIR}/kernel-headers-obj"
    mkdir -p "${hdr_obj}"
    make -C "${SRC_DIR}/linux-${LINUX_VERSION}" \
        ARCH="${KERNEL_ARCH}" \
        O="${hdr_obj}" \
        INSTALL_HDR_PATH="${SYSROOT}" \
        headers_install

    # Record the version we just installed
    write_version "${BUILD_DIR}/.kernel-headers-version" "$LINUX_VERSION"

    log_info "Kernel headers installation complete"
}

##############################################################################
# Build compiler-rt builtins
##############################################################################

build_compiler_rt() {
    log_info "Building compiler-rt builtins for ${TARGET_TRIPLE}..."

    # Determine compiler-rt architecture suffix
    local COMPILER_RT_ARCH
    case "$ARCH" in
        armv7hf|armv7)
            COMPILER_RT_ARCH="armhf"
            ;;
        aarch64|arm64)
            COMPILER_RT_ARCH="aarch64"
            ;;
        x86_64|x64)
            COMPILER_RT_ARCH="x86_64"
            ;;
        riscv64|rv64)
            COMPILER_RT_ARCH="riscv64"
            ;;
    esac

    local build_dir="${BUILD_DIR}/compiler-rt-builtins"
    mkdir -p "${build_dir}"
    cd "${build_dir}"

    if [ -f "${SYSROOT}/lib/linux/libclang_rt.builtins-${COMPILER_RT_ARCH}.a" ] && \
       [ -f "${TOOLCHAIN_DIR}/lib/clang/${LLVM_VERSION%%.*}/lib/${TARGET_TRIPLE}/clang_rt.crtbegin.o" ]; then
        log_info "compiler-rt builtins + crt already built, skipping..."
        return 0
    fi

    # Compiler flags for cross-compilation
    # Use ARM mode (not Thumb) for better compatibility with assembly files on ARM architectures
    local EXTRA_FLAGS=""
    if [ "$TARGET_ARCH" = "arm" ]; then
        EXTRA_FLAGS="-marm"
    fi
    local CMAKE_C_FLAGS="${ARCH_FLAGS} ${EXTRA_FLAGS}"
    local CMAKE_CXX_FLAGS="${CMAKE_C_FLAGS}"
    local CMAKE_ASM_FLAGS="${CMAKE_C_FLAGS}"

    # Build only builtins library directly
    cmake -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${SYSROOT}" \
        -DCMAKE_C_COMPILER="${TOOLCHAIN_DIR}/bin/clang" \
        -DCMAKE_CXX_COMPILER="${TOOLCHAIN_DIR}/bin/clang++" \
        -DCMAKE_ASM_COMPILER="${TOOLCHAIN_DIR}/bin/clang" \
        -DCMAKE_C_COMPILER_TARGET="${TARGET_TRIPLE}" \
        -DCMAKE_CXX_COMPILER_TARGET="${TARGET_TRIPLE}" \
        -DCMAKE_ASM_COMPILER_TARGET="${TARGET_TRIPLE}" \
        -DCMAKE_AR="${TOOLCHAIN_DIR}/bin/llvm-ar" \
        -DCMAKE_NM="${TOOLCHAIN_DIR}/bin/llvm-nm" \
        -DCMAKE_RANLIB="${TOOLCHAIN_DIR}/bin/llvm-ranlib" \
        -DCMAKE_C_FLAGS="${CMAKE_C_FLAGS}" \
        -DCMAKE_CXX_FLAGS="${CMAKE_CXX_FLAGS}" \
        -DCMAKE_ASM_FLAGS="${CMAKE_ASM_FLAGS}" \
        -DCMAKE_SYSTEM_NAME=Linux \
        -DCMAKE_SYSTEM_PROCESSOR=${TARGET_ARCH} \
        -DCMAKE_SYSROOT="${SYSROOT}" \
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
        -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
        -DCOMPILER_RT_OS_DIR="linux" \
        -DCOMPILER_RT_BUILD_CRT=ON \
        -DCOMPILER_RT_INSTALL_PATH="${SYSROOT}/lib/clang/${LLVM_VERSION%%.*}" \
        "${SRC_DIR}/llvm-project/compiler-rt/lib/builtins"

    ninja -j${JOBS}

    # Install to both sysroot (for linking) and toolchain (for clang's implicit -rtlib=compiler-rt)
    local sysroot_dir="${SYSROOT}/lib/linux"
    local toolchain_rt_dir="${TOOLCHAIN_DIR}/lib/clang/${LLVM_VERSION%%.*}/lib/${TARGET_TRIPLE}"

    mkdir -p "${sysroot_dir}"
    mkdir -p "${toolchain_rt_dir}"

    cp lib/linux/libclang_rt.builtins-${COMPILER_RT_ARCH}.a "${sysroot_dir}/"
    cp lib/linux/libclang_rt.builtins-${COMPILER_RT_ARCH}.a "${toolchain_rt_dir}/libclang_rt.builtins.a"

    # crt begin/end objects (COMPILER_RT_BUILD_CRT=ON above): required for
    # -static linking — the clang driver with -rtlib=compiler-rt looks for
    # clang_rt.crtbegin.o/clang_rt.crtend.o in the per-triple resource dir
    # (GAP §3.6: '-static' previously failed with 'cannot open crtbeginT.o').
    local crt
    for crt in crtbegin crtend; do
        if [ ! -f "lib/linux/clang_rt.${crt}-${COMPILER_RT_ARCH}.o" ]; then
            log_error "compiler-rt did not produce clang_rt.${crt}-${COMPILER_RT_ARCH}.o (COMPILER_RT_BUILD_CRT)"
            exit 1
        fi
        cp "lib/linux/clang_rt.${crt}-${COMPILER_RT_ARCH}.o" "${sysroot_dir}/"
        cp "lib/linux/clang_rt.${crt}-${COMPILER_RT_ARCH}.o" "${toolchain_rt_dir}/clang_rt.${crt}.o"
    done

    # Record the version we just built
    write_version "${BUILD_DIR}/.compiler-rt-version" "$LLVM_VERSION"

    log_info "compiler-rt builtins build complete"
}

##############################################################################
# Build C++ Runtime Libraries
##############################################################################

build_libcxx() {
    log_info "Building libc++ and libc++abi for ${TARGET_TRIPLE}..."

    local build_dir="${BUILD_DIR}/runtimes"
    mkdir -p "${build_dir}"
    cd "${build_dir}"

    if [ -f "${SYSROOT}/lib/libc++.a" ]; then
        log_info "libc++ already built, skipping..."
        return 0
    fi

    # Compiler and linker flags
    # Use -marm for better compatibility with assembly files on ARM architectures
    local EXTRA_FLAGS=""
    if [ "$TARGET_ARCH" = "arm" ]; then
        EXTRA_FLAGS="-marm"
    fi
    local CMAKE_C_FLAGS="${ARCH_FLAGS} ${EXTRA_FLAGS}"
    local CMAKE_CXX_FLAGS="${CMAKE_C_FLAGS}"
    local CMAKE_ASM_FLAGS="${CMAKE_C_FLAGS}"
    local CMAKE_EXE_LINKER_FLAGS="-fuse-ld=lld -rtlib=compiler-rt"

    cmake -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${SYSROOT}" \
        -DCMAKE_C_COMPILER="${TOOLCHAIN_DIR}/bin/clang" \
        -DCMAKE_CXX_COMPILER="${TOOLCHAIN_DIR}/bin/clang++" \
        -DCMAKE_ASM_COMPILER="${TOOLCHAIN_DIR}/bin/clang" \
        -DCMAKE_C_COMPILER_TARGET="${TARGET_TRIPLE}" \
        -DCMAKE_CXX_COMPILER_TARGET="${TARGET_TRIPLE}" \
        -DCMAKE_ASM_COMPILER_TARGET="${TARGET_TRIPLE}" \
        -DCMAKE_AR="${TOOLCHAIN_DIR}/bin/llvm-ar" \
        -DCMAKE_NM="${TOOLCHAIN_DIR}/bin/llvm-nm" \
        -DCMAKE_RANLIB="${TOOLCHAIN_DIR}/bin/llvm-ranlib" \
        -DCMAKE_C_FLAGS="${CMAKE_C_FLAGS}" \
        -DCMAKE_CXX_FLAGS="${CMAKE_CXX_FLAGS}" \
        -DCMAKE_ASM_FLAGS="${CMAKE_ASM_FLAGS}" \
        -DCMAKE_EXE_LINKER_FLAGS="${CMAKE_EXE_LINKER_FLAGS}" \
        -DCMAKE_SYSROOT="${SYSROOT}" \
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
        -DLLVM_ENABLE_RUNTIMES="libcxx;libcxxabi;libunwind" \
        -DLIBCXX_ENABLE_SHARED=OFF \
        -DLIBCXX_ENABLE_STATIC=ON \
        -DLIBCXX_USE_COMPILER_RT=ON \
        -DLIBCXX_HAS_MUSL_LIBC=ON \
        -DLIBCXX_CXX_ABI=libcxxabi \
        -DLIBCXXABI_ENABLE_SHARED=OFF \
        -DLIBCXXABI_ENABLE_STATIC=ON \
        -DLIBCXXABI_USE_COMPILER_RT=ON \
        -DLIBCXXABI_USE_LLVM_UNWINDER=ON \
        -DLIBUNWIND_ENABLE_SHARED=OFF \
        -DLIBUNWIND_ENABLE_STATIC=ON \
        "${SRC_DIR}/llvm-project/runtimes"

    ninja -j${JOBS}
    ninja install

    # Create symlink for __config_site so toolchain's libc++ headers can find it
    local config_site_dir="${TOOLCHAIN_DIR}/include/c++/v1"
    if [ -f "${SYSROOT}/include/c++/v1/__config_site" ]; then
        ln -sf "${SYSROOT}/include/c++/v1/__config_site" "${config_site_dir}/__config_site"
        log_info "Created __config_site symlink in toolchain headers"
    fi

    # Record the version we just built
    write_version "${BUILD_DIR}/.libcxx-version" "$LLVM_VERSION"

    log_info "libc++ runtime libraries build complete"
}

##############################################################################
# Create Toolchain Wrapper Scripts
##############################################################################

create_wrappers() {
    log_info "Creating toolchain wrapper scripts..."

    mkdir -p "${BIN_DIR}"

    # Create C compiler wrapper
    # Note: wrapper is in build/state/<arch>/bin, needs to go up 4 levels to project root
    cat > "${BIN_DIR}/${TARGET_TRIPLE}-clang" << EOF
#!/bin/bash
SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && cd ../../../.. && pwd)"
TOOLCHAIN_DIR="\${SCRIPT_DIR}/toolchain"
SYSROOT="\${SCRIPT_DIR}/build/state/${ARCH}/sysroot"

exec "\${TOOLCHAIN_DIR}/bin/clang" \\
    ${ARCH_FLAGS} \\
    --sysroot="\${SYSROOT}" \\
    -rtlib=compiler-rt \\
    -fuse-ld=lld \\
    "\$@"
EOF

    # Create C++ compiler wrapper
    # Note: wrapper is in build/state/<arch>/bin, needs to go up 4 levels to project root
    cat > "${BIN_DIR}/${TARGET_TRIPLE}-clang++" << EOF
#!/bin/bash
SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && cd ../../../.. && pwd)"
TOOLCHAIN_DIR="\${SCRIPT_DIR}/toolchain"
SYSROOT="\${SCRIPT_DIR}/build/state/${ARCH}/sysroot"

exec "\${TOOLCHAIN_DIR}/bin/clang++" \\
    ${ARCH_FLAGS} \\
    --sysroot="\${SYSROOT}" \\
    -rtlib=compiler-rt \\
    -stdlib=libc++ \\
    -unwindlib=libunwind \\
    -fuse-ld=lld \\
    "\$@"
EOF

    chmod +x "${BIN_DIR}/${TARGET_TRIPLE}-clang"
    chmod +x "${BIN_DIR}/${TARGET_TRIPLE}-clang++"

    # Create symlinks for common tool names
    ln -sf "${TARGET_TRIPLE}-clang" "${BIN_DIR}/${TARGET_TRIPLE}-gcc"
    ln -sf "${TARGET_TRIPLE}-clang++" "${BIN_DIR}/${TARGET_TRIPLE}-g++"
    ln -sf "${TOOLCHAIN_DIR}/bin/llvm-ar" "${BIN_DIR}/${TARGET_TRIPLE}-ar"
    ln -sf "${TOOLCHAIN_DIR}/bin/llvm-ranlib" "${BIN_DIR}/${TARGET_TRIPLE}-ranlib"
    ln -sf "${TOOLCHAIN_DIR}/bin/llvm-nm" "${BIN_DIR}/${TARGET_TRIPLE}-nm"
    ln -sf "${TOOLCHAIN_DIR}/bin/llvm-objcopy" "${BIN_DIR}/${TARGET_TRIPLE}-objcopy"
    ln -sf "${TOOLCHAIN_DIR}/bin/llvm-objdump" "${BIN_DIR}/${TARGET_TRIPLE}-objdump"
    ln -sf "${TOOLCHAIN_DIR}/bin/llvm-strip" "${BIN_DIR}/${TARGET_TRIPLE}-strip"
    ln -sf "${TOOLCHAIN_DIR}/bin/ld.lld" "${BIN_DIR}/${TARGET_TRIPLE}-ld"
    # readelf: used by U-Boot's checkarmreloc target (M1 wave 2 bootloader
    # stage) and generally expected next to the other binutils names.
    # The LLVM install ships no llvm-readelf binary — it is llvm-readobj
    # switching on argv[0] (a *readelf* name selects GNU output style).
    ln -sf llvm-readobj "${TOOLCHAIN_DIR}/bin/llvm-readelf"
    ln -sf "${TOOLCHAIN_DIR}/bin/llvm-readelf" "${BIN_DIR}/${TARGET_TRIPLE}-readelf"

    log_info "Wrapper scripts created in ${BIN_DIR}"
}

##############################################################################
# Create CMake Toolchain File
##############################################################################

create_cmake_toolchain() {
    log_info "Creating CMake toolchain file..."

    cat > "${ASTRO_ROOT}/${ARCH}-toolchain.cmake" << EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR ${TARGET_ARCH})

set(triple ${TARGET_TRIPLE})

set(CMAKE_C_COMPILER \${CMAKE_CURRENT_LIST_DIR}/build/state/${ARCH}/bin/\${triple}-clang)
set(CMAKE_CXX_COMPILER \${CMAKE_CURRENT_LIST_DIR}/build/state/${ARCH}/bin/\${triple}-clang++)

# Use LLVM tools
set(CMAKE_AR \${CMAKE_CURRENT_LIST_DIR}/toolchain/bin/llvm-ar)
set(CMAKE_RANLIB \${CMAKE_CURRENT_LIST_DIR}/toolchain/bin/llvm-ranlib)
set(CMAKE_LINKER \${CMAKE_CURRENT_LIST_DIR}/toolchain/bin/ld.lld)

set(CMAKE_SYSROOT \${CMAKE_CURRENT_LIST_DIR}/build/state/${ARCH}/sysroot)

set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

set(CMAKE_C_FLAGS_INIT "-march=${TARGET_MARCH}$([ -n "$TARGET_FPU" ] && echo " -mfpu=${TARGET_FPU}")$([ -n "$TARGET_FLOAT_ABI" ] && echo " -mfloat-abi=${TARGET_FLOAT_ABI}")$([ -n "$TARGET_MABI" ] && echo " -mabi=${TARGET_MABI}")")
set(CMAKE_CXX_FLAGS_INIT "-march=${TARGET_MARCH}$([ -n "$TARGET_FPU" ] && echo " -mfpu=${TARGET_FPU}")$([ -n "$TARGET_FLOAT_ABI" ] && echo " -mfloat-abi=${TARGET_FLOAT_ABI}")$([ -n "$TARGET_MABI" ] && echo " -mabi=${TARGET_MABI}")")

# Use lld linker and set proper linker flags
# -nostartfiles tells clang not to use GCC's crt files
# We use musl's crt files from the sysroot instead
# -Wl,-m sets the linker emulation mode for the target architecture
# Link order: crt1.o -> user code -> libc++ -> libc++abi -> libunwind -> libc -> crtn.o
set(CMAKE_EXE_LINKER_FLAGS_INIT "-fuse-ld=lld -rtlib=compiler-rt -static -nostartfiles \${CMAKE_CURRENT_LIST_DIR}/build/state/${ARCH}/sysroot/lib/crt1.o \${CMAKE_CURRENT_LIST_DIR}/build/state/${ARCH}/sysroot/lib/crti.o \${CMAKE_CURRENT_LIST_DIR}/build/state/${ARCH}/sysroot/lib/crtn.o -Wl,-m,${LINKER_EMULATION} -lc++ -lc++abi -lunwind")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-fuse-ld=lld -rtlib=compiler-rt -lc++ -lc++abi")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "-fuse-ld=lld -rtlib=compiler-rt -lc++ -lc++abi")

# Tell CMake we can compile and link
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
EOF

    log_info "CMake toolchain file created: ${ASTRO_ROOT}/${ARCH}-toolchain.cmake"
}

##############################################################################
# Create Test Programs
##############################################################################

create_test_programs() {
    log_info "Creating test programs..."

    local test_dir="${BUILD_DIR}/tests"
    mkdir -p "${test_dir}"

    # C test program
    cat > "${test_dir}/test.c" << 'EOF'
#include <stdio.h>
#include <math.h>

int main() {
    printf("Hello from ARMv7 C!\n");
    printf("sqrt(2.0) = %f\n", sqrt(2.0));
    return 0;
}
EOF

    # C++ test program
    cat > "${test_dir}/test.cpp" << 'EOF'
#include <iostream>
#include <vector>
#include <algorithm>
#include <cmath>

int main() {
    std::cout << "Hello from ARMv7 C++!" << std::endl;

    std::vector<int> numbers = {5, 2, 8, 1, 9};
    std::sort(numbers.begin(), numbers.end());

    std::cout << "Sorted numbers: ";
    for (int n : numbers) {
        std::cout << n << " ";
    }
    std::cout << std::endl;

    std::cout << "sqrt(2.0) = " << std::sqrt(2.0) << std::endl;

    return 0;
}
EOF

    log_info "Test programs created in ${test_dir}"
}

##############################################################################
# Display Usage Information
##############################################################################

display_usage() {
    echo ""
    echo -e "${GREEN}============================================================================="
    echo -e "${ARCH^^} Cross-Compilation Toolchain Build Complete!"
    echo -e "=============================================================================${NC}"
    echo ""
    echo "Target: ${TARGET_TRIPLE}"
    echo "Toolchain location: ${TOOLCHAIN_DIR}"
    echo "Sysroot location: ${SYSROOT}"
    echo "Wrapper scripts: ${BIN_DIR}"
    echo ""
    echo -e "${YELLOW}Usage:${NC}"
    echo ""
    echo "1. Compile C code:"
    echo "   ${BIN_DIR}/${TARGET_TRIPLE}-clang -o output test.c"
    echo ""
    echo "2. Compile C++ code:"
    echo "   ${BIN_DIR}/${TARGET_TRIPLE}-clang++ -o output test.cpp"
    echo ""
    echo "3. Use with CMake:"
    echo "   cmake -DCMAKE_TOOLCHAIN_FILE=${ASTRO_ROOT}/${ARCH}-toolchain.cmake .."
    echo ""
    echo "4. Add to PATH:"
    echo "   export PATH=\"${BIN_DIR}:\$PATH\""
    echo ""
    echo -e "${YELLOW}Test the toolchain:${NC}"
    echo "   cd ${BUILD_DIR}/tests"
    echo "   ${BIN_DIR}/${TARGET_TRIPLE}-clang -o test_c test.c"
    echo "   ${BIN_DIR}/${TARGET_TRIPLE}-clang++ -o test_cpp test.cpp"
    echo ""
    echo -e "${YELLOW}Compiler flags already configured:${NC}"
    echo "   - Target: ${TARGET_TRIPLE}"
    echo "   - CPU: ${TARGET_CPU}"
    [ -n "$TARGET_FPU" ] && echo "   - FPU: ${TARGET_FPU}"
    [ -n "$TARGET_FLOAT_ABI" ] && echo "   - Float ABI: ${TARGET_FLOAT_ABI}"
    [ -n "$TARGET_MABI" ] && echo "   - ABI: ${TARGET_MABI}"
    echo "   - C library: musl"
    echo "   - C++ library: libc++"
    echo "   - Runtime: compiler-rt"
    echo ""
    echo -e "${GREEN}==============================================================================${NC}"
    echo ""
}

##############################################################################
# Main Build Process
##############################################################################

main() {
    log_info "Starting ${ARCH^^} Cross-Compilation Toolchain Build"
    log_info "Target: ${TARGET_TRIPLE}"
    log_info "LLVM Version: ${LLVM_VERSION}"
    log_info "musl Version: ${MUSL_VERSION}"
    log_info "Linux Headers Version: ${LINUX_VERSION}"
    echo

    check_prerequisites
    create_directories

    # Check for version changes and clean stale builds
    log_info "Checking for version changes..."
    check_and_clean_llvm
    check_and_clean_musl
    check_and_clean_kernel_headers
    check_and_clean_compiler_rt
    check_and_clean_libcxx

    download_sources
    apply_source_patches
    build_llvm_native
    build_musl
    install_kernel_headers
    build_compiler_rt
    build_libcxx
    create_wrappers
    create_cmake_toolchain
    create_test_programs
    display_usage

    log_info "Build process completed successfully!"
}

# Run main function
main "$@"
