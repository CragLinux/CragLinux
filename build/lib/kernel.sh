#!/bin/bash
# Astro Linux - Kernel build
# Sourced by build-inner.sh, not executed directly.
#
# Downloads, patches, configures, and cross-compiles the Linux kernel
# using the project's Clang/LLVM toolchain.

# Map Astro arch to kernel ARCH and build targets
kernel_arch_map() {
    local board_arch="$1"
    case "$board_arch" in
        aarch64)
            KARCH="arm64"
            KERNEL_TARGETS="Image modules dtbs"
            KERNEL_IMAGE="arch/arm64/boot/Image"
            ;;
        armv7hf)
            KARCH="arm"
            KERNEL_TARGETS="zImage modules dtbs"
            KERNEL_IMAGE="arch/arm/boot/zImage"
            ;;
        x86_64)
            KARCH="x86_64"
            KERNEL_TARGETS="bzImage modules"
            KERNEL_IMAGE="arch/x86/boot/bzImage"
            ;;
        riscv64)
            KARCH="riscv"
            KERNEL_TARGETS="Image modules dtbs"
            KERNEL_IMAGE="arch/riscv/boot/Image"
            ;;
        *)
            die "Unsupported architecture for kernel build: $board_arch"
            ;;
    esac
}

# Download kernel source
# NOTE: this function's value is its stdout (captured with $(...) by
# build_kernel), so all logging must go to stderr (>&2).
download_kernel_source() {
    local version="$1"
    local source_type="$2"
    local git_repo="${3:-}"
    local git_ref="${4:-}"
    local board="${5:-}"

    local src_dir="${PROJECT_ROOT}/sources"
    mkdir -p "$src_dir"

    if [ "$source_type" = "upstream" ]; then
        local tarball="linux-${version}.tar.xz"
        local extract_dir="linux-${version}"
        local major_version="${version%%.*}"

        if [ ! -d "${src_dir}/${extract_dir}" ]; then
            if [ ! -f "${src_dir}/${tarball}" ]; then
                log_info "Downloading kernel ${version}..." >&2
                curl -L -o "${src_dir}/${tarball}" \
                    "https://cdn.kernel.org/pub/linux/kernel/v${major_version}.x/${tarball}"
            fi
            log_info "Extracting kernel source..." >&2
            tar -xJf "${src_dir}/${tarball}" -C "$src_dir"
        else
            log_info "Kernel source already exists: ${extract_dir}" >&2
        fi
        echo "${src_dir}/${extract_dir}"

    elif [ "$source_type" = "git" ]; then
        local clone_dir="linux-${board}-${git_ref}"
        if [ ! -d "${src_dir}/${clone_dir}" ]; then
            log_info "Cloning kernel from ${git_repo} (${git_ref})..." >&2
            git clone --depth 1 --branch "$git_ref" "$git_repo" "${src_dir}/${clone_dir}"
        else
            log_info "Kernel git source already exists: ${clone_dir}" >&2
        fi
        echo "${src_dir}/${clone_dir}"
    fi
}

# Apply kernel patches
patch_kernel_source() {
    local kernel_src="$1"
    local version="$2"
    local board_dir="$3"
    local apply_clang_patches="$4"

    local marker="${kernel_src}/.astro-patches-applied"
    if [ -f "$marker" ]; then
        log_info "Kernel patches already applied"
        return 0
    fi

    local major_minor="${version%.*}"  # e.g., 6.12.8 → 6.12
    local patch_count=0

    cd "$kernel_src"

    # 1. Common Clang patches
    if [ "$apply_clang_patches" = "true" ]; then
        local clang_patch_dir="${PROJECT_ROOT}/build/patches/kernel/${major_minor}"
        if [ -d "$clang_patch_dir" ]; then
            for patch_file in "$clang_patch_dir"/*.patch; do
                [ -f "$patch_file" ] || continue
                log_info "  Applying Clang patch: $(basename "$patch_file")"
                if patch -p1 -N --dry-run < "$patch_file" > /dev/null 2>&1; then
                    patch -p1 -N < "$patch_file"
                    patch_count=$((patch_count + 1))
                elif patch -p1 -R --dry-run < "$patch_file" > /dev/null 2>&1; then
                    log_info "    (already applied, skipping)"
                else
                    log_warn "    Failed to apply: $(basename "$patch_file") (continuing)"
                fi
            done
        else
            log_info "No common Clang patches for kernel ${major_minor}"
        fi
    fi

    # 2. Board-specific patches
    local board_patch_dir="${board_dir}/kernel/patches"
    if [ -d "$board_patch_dir" ]; then
        for patch_file in "$board_patch_dir"/*.patch; do
            [ -f "$patch_file" ] || continue
            log_info "  Applying board patch: $(basename "$patch_file")"
            if patch -p1 -N --dry-run < "$patch_file" > /dev/null 2>&1; then
                patch -p1 -N < "$patch_file"
                patch_count=$((patch_count + 1))
            elif patch -p1 -R --dry-run < "$patch_file" > /dev/null 2>&1; then
                log_info "    (already applied, skipping)"
            else
                log_warn "    Failed to apply: $(basename "$patch_file") (continuing)"
            fi
        done
    fi

    touch "$marker"
    log_info "Applied ${patch_count} kernel patch(es)"
    cd "$PROJECT_ROOT"
}

# Hash of everything that determines the generated .config: defconfig
# choice (and board defconfig content), every fragment's content in merge
# order, and the LTO mode. Stored in the skip markers so that editing a
# fragment (common or board) triggers reconfigure + rebuild instead of
# silently reusing a stale kernel (GAP-REPORT §4 item 11 — this bit both
# the x86_64 sysctl refresh and the armv7 cgroup fix).
kernel_config_hash() {
    local board_dir="$1"
    local defconfig_name="$2"
    local lto_setting="$3"
    local config_fragments_json="$4"
    local frag
    {
        echo "defconfig=${defconfig_name}"
        echo "lto=${lto_setting}"
        if [ -f "${board_dir}/kernel/defconfig" ]; then
            echo "== board-defconfig"
            cat "${board_dir}/kernel/defconfig"
        fi
        for frag in "${PROJECT_ROOT}/boards/common/kernel"/*.fragment \
                    "${board_dir}/kernel"/*.fragment; do
            if [ -f "$frag" ]; then
                echo "== ${frag}"
                cat "$frag"
            fi
        done
        echo "fragments_json=${config_fragments_json}"
    } | sha256sum | cut -c1-16
}

# Configure kernel
configure_kernel() {
    local kernel_src="$1"
    local build_dir="$2"
    local board_dir="$3"
    local defconfig_name="$4"
    local lto_setting="$5"
    local config_fragments_json="$6"

    # HOSTLD/HOSTAR: LLVM=1 defaults them to bare "ld.lld"/"llvm-ar",
    # which are not on PATH in the container — host tool builds (objtool
    # on x86_64) fail with exit 127 otherwise. Same absolute-path
    # treatment as the modules_install STRIP fix below.
    local make_env=(
        make -j${JOBS}
        O="${build_dir}"
        ARCH="${KARCH}"
        LLVM=1
        LLVM_IAS=1
        HOSTCC="${TOOLCHAIN_DIR}/bin/clang"
        HOSTCXX="${TOOLCHAIN_DIR}/bin/clang++"
        HOSTLD="${TOOLCHAIN_DIR}/bin/ld.lld"
        HOSTAR="${TOOLCHAIN_DIR}/bin/llvm-ar"
        CC="${TOOLCHAIN_DIR}/bin/clang"
        LD="${TOOLCHAIN_DIR}/bin/ld.lld"
        AR="${TOOLCHAIN_DIR}/bin/llvm-ar"
        NM="${TOOLCHAIN_DIR}/bin/llvm-nm"
        STRIP="${TOOLCHAIN_DIR}/bin/llvm-strip"
        OBJCOPY="${TOOLCHAIN_DIR}/bin/llvm-objcopy"
        OBJDUMP="${TOOLCHAIN_DIR}/bin/llvm-objdump"
        READELF="${TOOLCHAIN_DIR}/bin/llvm-readelf"
    )

    mkdir -p "$build_dir"

    # Skip reconfiguration only if the config inputs are unchanged
    local cfg_hash
    cfg_hash=$(kernel_config_hash "$board_dir" "$defconfig_name" "$lto_setting" "$config_fragments_json")
    if [ -f "${build_dir}/.config" ] && \
       [ "$(cat "${build_dir}/.astro-kernel-configured" 2>/dev/null)" = "$cfg_hash" ]; then
        log_info "Kernel already configured (inputs unchanged), skipping"
        return 0
    fi

    cd "$kernel_src"

    # Step 1: Base defconfig
    local board_defconfig="${board_dir}/kernel/defconfig"
    if [ -f "$board_defconfig" ]; then
        log_info "Using board-provided defconfig"
        cp "$board_defconfig" "${build_dir}/.config"
        "${make_env[@]}" olddefconfig
    else
        log_info "Using kernel defconfig: ${defconfig_name}"
        "${make_env[@]}" "$defconfig_name"
    fi

    # Step 2: Merge config fragments
    local fragments=()

    # Common fragments
    for frag in "${PROJECT_ROOT}/boards/common/kernel"/*.fragment; do
        [ -f "$frag" ] || continue
        fragments+=("$frag")
    done

    # Board-specific fragments
    for frag in "${board_dir}/kernel"/*.fragment; do
        [ -f "$frag" ] || continue
        fragments+=("$frag")
    done

    # Explicitly listed fragments from board.toml
    if [ -n "$config_fragments_json" ] && [ "$config_fragments_json" != "[]" ]; then
        local count
        count=$(echo "$config_fragments_json" | jq 'length')
        for i in $(seq 0 $((count - 1))); do
            local frag_name
            frag_name=$(echo "$config_fragments_json" | jq -r ".[$i]")
            local frag_path="${board_dir}/kernel/${frag_name}"
            if [ -f "$frag_path" ]; then
                fragments+=("$frag_path")
            else
                log_warn "Config fragment not found: ${frag_path}"
            fi
        done
    fi

    # Step 3: Generate LTO fragment
    local lto_frag="${build_dir}/.lto.fragment"
    case "$lto_setting" in
        thin)
            echo "CONFIG_LTO_CLANG_THIN=y" > "$lto_frag"
            echo "# CONFIG_LTO_CLANG_FULL is not set" >> "$lto_frag"
            echo "# CONFIG_LTO_NONE is not set" >> "$lto_frag"
            fragments+=("$lto_frag")
            ;;
        full)
            echo "# CONFIG_LTO_CLANG_THIN is not set" > "$lto_frag"
            echo "CONFIG_LTO_CLANG_FULL=y" >> "$lto_frag"
            echo "# CONFIG_LTO_NONE is not set" >> "$lto_frag"
            fragments+=("$lto_frag")
            ;;
        none)
            echo "# CONFIG_LTO_CLANG_THIN is not set" > "$lto_frag"
            echo "# CONFIG_LTO_CLANG_FULL is not set" >> "$lto_frag"
            echo "CONFIG_LTO_NONE=y" >> "$lto_frag"
            fragments+=("$lto_frag")
            ;;
    esac

    # Merge all fragments
    if [ ${#fragments[@]} -gt 0 ]; then
        log_info "Merging ${#fragments[@]} config fragment(s)..."
        local merge_script="${kernel_src}/scripts/kconfig/merge_config.sh"
        if [ -f "$merge_script" ]; then
            cd "$build_dir"
            ARCH="${KARCH}" "$merge_script" -m .config "${fragments[@]}"
            cd "$kernel_src"
        else
            # Fallback: cat fragments and run olddefconfig
            for frag in "${fragments[@]}"; do
                cat "$frag" >> "${build_dir}/.config"
            done
        fi
    fi

    # Step 4: Final resolve
    "${make_env[@]}" olddefconfig

    echo "$cfg_hash" > "${build_dir}/.astro-kernel-configured"
    log_info "Kernel configured"
    cd "$PROJECT_ROOT"
}

# Build the kernel
build_kernel() {
    local board="$1"
    local board_arch="$2"
    local board_dir="$3"
    local board_config_json="$4"

    log_step "Building kernel for ${board} (${board_arch})..."

    # Extract kernel config from JSON
    local version source defconfig lto clang_patches
    version=$(echo "$board_config_json" | jq -r '.kernel.version')
    source=$(echo "$board_config_json" | jq -r '.kernel.source // "upstream"')
    defconfig=$(echo "$board_config_json" | jq -r '.kernel.defconfig // "defconfig"')
    lto=$(echo "$board_config_json" | jq -r '.kernel.lto // "thin"')
    clang_patches=$(echo "$board_config_json" | jq -r '.kernel.clang_patches // true')
    local git_repo git_ref
    git_repo=$(echo "$board_config_json" | jq -r '.kernel.git_repo // ""')
    git_ref=$(echo "$board_config_json" | jq -r '.kernel.git_ref // ""')
    local config_fragments_json
    config_fragments_json=$(echo "$board_config_json" | jq -c '.kernel.config_fragments // []')

    # Ensure toolchain exists
    TOOLCHAIN_DIR="${PROJECT_ROOT}/toolchain"
    if [ ! -f "${TOOLCHAIN_DIR}/bin/clang" ]; then
        die "Clang toolchain not found at ${TOOLCHAIN_DIR}/bin/clang. Build it first: ./sdk/build-toolchain.sh <arch>"
    fi

    # Map architecture
    kernel_arch_map "$board_arch"

    # Build directory (per-board, since different boards may use different versions)
    local build_dir="${PROJECT_ROOT}/build/state/${board_arch}/kernel/${board}"
    local version_marker="${build_dir}/.kernel-version"

    # Skip only if version AND all config inputs (fragments/defconfig/lto)
    # are unchanged — the marker carries "version:config-hash"
    local cfg_hash
    cfg_hash=$(kernel_config_hash "$board_dir" "$defconfig" "$lto" "$config_fragments_json")
    if [ -f "$version_marker" ] && [ "$(cat "$version_marker")" = "${version}:${cfg_hash}" ] && \
       [ -f "${build_dir}/${KERNEL_IMAGE}" ]; then
        log_info "Kernel ${version} already built for ${board} (inputs unchanged), skipping"
        return 0
    fi

    # Download source
    local kernel_src
    kernel_src=$(download_kernel_source "$version" "$source" "$git_repo" "$git_ref" "$board")

    # Patch
    patch_kernel_source "$kernel_src" "$version" "$board_dir" "$clang_patches"

    # Configure
    configure_kernel "$kernel_src" "$build_dir" "$board_dir" "$defconfig" "$lto" "$config_fragments_json"

    # Build
    log_info "Compiling kernel ${version} (${KARCH})..."
    log_info "  Targets: ${KERNEL_TARGETS}"
    log_info "  LTO: ${lto}"

    local JOBS=${JOBS:-$(nproc)}

    cd "$kernel_src"
    make -j${JOBS} \
        O="${build_dir}" \
        ARCH="${KARCH}" \
        LLVM=1 \
        LLVM_IAS=1 \
        HOSTCC="${TOOLCHAIN_DIR}/bin/clang" \
        HOSTCXX="${TOOLCHAIN_DIR}/bin/clang++" \
        HOSTLD="${TOOLCHAIN_DIR}/bin/ld.lld" \
        HOSTAR="${TOOLCHAIN_DIR}/bin/llvm-ar" \
        CC="${TOOLCHAIN_DIR}/bin/clang" \
        LD="${TOOLCHAIN_DIR}/bin/ld.lld" \
        AR="${TOOLCHAIN_DIR}/bin/llvm-ar" \
        NM="${TOOLCHAIN_DIR}/bin/llvm-nm" \
        STRIP="${TOOLCHAIN_DIR}/bin/llvm-strip" \
        OBJCOPY="${TOOLCHAIN_DIR}/bin/llvm-objcopy" \
        OBJDUMP="${TOOLCHAIN_DIR}/bin/llvm-objdump" \
        READELF="${TOOLCHAIN_DIR}/bin/llvm-readelf" \
        ${KERNEL_TARGETS}

    # Install modules to staging area
    local modules_dir="${build_dir}/modules_install"
    rm -rf "$modules_dir"
    # STRIP must be the toolchain's llvm-strip by absolute path: LLVM=1 alone
    # makes Makefile.modinst call bare "llvm-strip", which is not on PATH in
    # the container (INSTALL_MOD_STRIP path, exit 127).
    make O="${build_dir}" \
        ARCH="${KARCH}" \
        LLVM=1 \
        STRIP="${TOOLCHAIN_DIR}/bin/llvm-strip" \
        INSTALL_MOD_PATH="$modules_dir" \
        INSTALL_MOD_STRIP=1 \
        modules_install

    # Write version marker
    echo "${version}:${cfg_hash}" > "$version_marker"

    cd "$PROJECT_ROOT"
    log_info "Kernel ${version} built successfully"
    log_info "  Image: ${build_dir}/${KERNEL_IMAGE}"
    log_info "  Modules: ${modules_dir}/lib/modules/"
}
