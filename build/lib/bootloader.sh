#!/bin/bash
# Crag Linux - Bootloader build (M1 wave 2, docs/04 §3/§4)
# Sourced by build-inner.sh, not executed directly.
#
# Produces per-board bootloader artifacts under
#   build/state/<arch>/bootloader/<board>/
#
#   u-boot     -> u-boot.bin   (built from the pinned upstream release with
#                 the SDK clang cross wrappers; QEMU boards run it via
#                 qemu -bios)
#   grub-efi   -> BOOTX64.EFI  (grub2-mkimage from the container's
#                 x86_64-efi module tree; OVMF loads it from the ESP)
#   direct/rpi-boot/none -> no-op
#
# The boot *configuration* (boot.scr, grub.cfg, env defaults) is generated
# by the image stage — it depends on the variant cmdline and slot layout.

# Map board arch -> SDK cross-wrapper triple (sdk/build-toolchain.sh)
uboot_cross_triple() {
    case "$1" in
        aarch64) echo "aarch64-unknown-linux-musl" ;;
        armv7hf) echo "armv7-unknown-linux-musleabihf" ;;
        x86_64)  echo "x86_64-unknown-linux-musl" ;;
        riscv64) echo "riscv64-unknown-linux-musl" ;;
        *) die "Unsupported architecture for U-Boot build: $1" ;;
    esac
}

# Download + extract a pinned upstream U-Boot release into sources/.
# stdout = extracted source dir (logging must go to stderr).
download_uboot_source() {
    local version="$1"
    local src_dir="${PROJECT_ROOT}/sources"
    local tarball="u-boot-${version}.tar.bz2"
    local extract_dir="u-boot-${version}"

    mkdir -p "$src_dir"
    if [ ! -d "${src_dir}/${extract_dir}" ]; then
        if [ ! -f "${src_dir}/${tarball}" ]; then
            log_info "Downloading U-Boot ${version}..." >&2
            curl -fL -o "${src_dir}/${tarball}" \
                "https://ftp.denx.de/pub/u-boot/${tarball}" >&2
        fi
        log_info "Extracting U-Boot source..." >&2
        tar -xjf "${src_dir}/${tarball}" -C "$src_dir"
    else
        log_info "U-Boot source already exists: ${extract_dir}" >&2
    fi
    echo "${src_dir}/${extract_dir}"
}

# Build U-Boot for a board: pinned release, board defconfig, plus every
# boards/<board>/uboot/*.fragment merged on top (env placement etc.).
build_uboot() {
    local board="$1"
    local board_arch="$2"
    local board_dir="$3"
    local board_config_json="$4"

    local version defconfig
    version=$(echo "$board_config_json" | jq -r '.bootloader.u_boot_version // ""')
    defconfig=$(echo "$board_config_json" | jq -r '.bootloader.u_boot_defconfig // ""')
    [ -n "$version" ] || die "bootloader.type=u-boot requires u_boot_version in board.toml"
    [ -n "$defconfig" ] || die "bootloader.type=u-boot requires u_boot_defconfig in board.toml"

    # Compiler selection (schema [bootloader].u_boot_compiler, default
    # clang): "gcc" uses the container's Fedora cross-gcc (U-Boot's
    # reference toolchain); "clang" uses the SDK wrappers. NOTE: clang/lld
    # U-Boot binaries currently HANG at self-relocation on qemu virt
    # (right after the DRAM: line, both 2025.10 and 2026.07, arm64) — the
    # QEMU boards pin u_boot_compiler = "gcc" until that is root-caused
    # (MIGRATION-NOTES §12).
    local compiler cross_prefix
    compiler=$(echo "$board_config_json" | jq -r '.bootloader.u_boot_compiler // "clang"')
    if [ "$compiler" = "gcc" ]; then
        case "$board_arch" in
            aarch64) cross_prefix="aarch64-linux-gnu-" ;;
            armv7hf) cross_prefix="arm-linux-gnu-" ;;
            *) die "no cross-gcc wired for arch ${board_arch} (u_boot_compiler=gcc)" ;;
        esac
        command -v "${cross_prefix}gcc" >/dev/null || \
            die "${cross_prefix}gcc not found — rebuild the crag-builder container (gcc-*-linux-gnu packages)"
    else
        local triple cross_bin
        triple=$(uboot_cross_triple "$board_arch")
        cross_bin="${PROJECT_ROOT}/build/state/${board_arch}/bin"
        [ -x "${cross_bin}/${triple}-gcc" ] || \
            die "SDK cross wrappers for ${board_arch} not found at ${cross_bin} — run: ./sdk/build-toolchain.sh ${board_arch}"
        cross_prefix="${cross_bin}/${triple}-"
    fi

    local build_dir="${PROJECT_ROOT}/build/state/${board_arch}/u-boot/${board}"
    local out_dir="${PROJECT_ROOT}/build/state/${board_arch}/bootloader/${board}"
    local version_marker="${build_dir}/.crag-uboot-version"

    # Fragment content is part of the staleness key: an edited
    # env.fragment must reconfigure + rebuild (found when the rpi4 mmc
    # device fix would otherwise have been silently skipped).
    local frag_hash="none"
    if ls "${board_dir}/uboot"/*.fragment >/dev/null 2>&1; then
        frag_hash=$(cat "${board_dir}/uboot"/*.fragment | sha256sum | cut -c1-16)
    fi
    local marker_want="${version}:${defconfig}:${compiler}:${frag_hash}"

    if [ -f "$version_marker" ] && [ "$(cat "$version_marker")" = "$marker_want" ] && \
       [ -f "${out_dir}/u-boot.bin" ]; then
        log_info "U-Boot ${version} (${defconfig}) already built for ${board}, skipping"
        return 0
    fi

    log_step "Building U-Boot ${version} for ${board} (${defconfig})..."

    local uboot_src
    uboot_src=$(download_uboot_source "$version")

    mkdir -p "$build_dir" "$out_dir"

    # U-Boot detects clang via `$(CC) --version`; the SDK wrappers already
    # pass --target/--sysroot/-fuse-ld=lld, and binutils names (ld,
    # objcopy, ...) resolve to the llvm tools via the wrapper symlinks.
    #
    # CLANG_FLAGS override: U-Boot's clang support assumes a parallel GNU
    # binutils install (-no-integrated-as + --prefix derived from
    # ${CROSS_COMPILE}elfedit) which the LLVM-only SDK does not have; a
    # command-line make variable beats the Makefile's := assignments, so
    # the integrated assembler is forced instead (same approach as the
    # kernel's LLVM_IAS=1).
    #
    # -Qunused-arguments: the wrappers always pass -rtlib/-fuse-ld, which
    # trip -Werror -Wunused-command-line-argument inside U-Boot's
    # cc-option probes — without it every probe fails and load-bearing
    # flags (arm32 -mno-movt, which keeps MOVW/MOVT relocs out of the
    # lld -pie link) are silently dropped.
    local make_args=(
        make -C "$uboot_src"
        O="$build_dir"
        CROSS_COMPILE="$cross_prefix"
        HOSTCC=gcc
        -j"${JOBS:-$(nproc)}"
    )
    # CLANG_FLAGS is only consulted by U-Boot when $(CC) is clang; harmless
    # under gcc, load-bearing under the SDK wrappers (see comment above).
    make_args+=(CLANG_FLAGS="-fintegrated-as -Qunused-arguments")

    "${make_args[@]}" "$defconfig"

    # Merge board U-Boot fragments (env-in-FAT placement etc., docs/04 §4)
    local frag merged=0
    for frag in "${board_dir}/uboot"/*.fragment; do
        [ -f "$frag" ] || continue
        log_info "  Merging U-Boot fragment: $(basename "$frag")"
        # Kconfig "last value wins": appending + olddefconfig applies the
        # fragment (same mechanism the kernel merge fallback uses).
        cat "$frag" >> "${build_dir}/.config"
        merged=$((merged + 1))
    done
    if [ "$merged" -gt 0 ]; then
        "${make_args[@]}" olddefconfig
        # A fragment option that silently fails to stick (missing deps)
        # would surface only at runtime — verify the load-bearing ones.
        local opt
        for opt in $(grep -hE '^CONFIG_[A-Z0-9_]+=' "${board_dir}/uboot"/*.fragment | cut -d= -f1); do
            grep -q "^${opt}=" "${build_dir}/.config" || \
                die "U-Boot fragment option ${opt} did not survive olddefconfig (missing Kconfig deps?)"
        done
    fi

    "${make_args[@]}"

    [ -f "${build_dir}/u-boot.bin" ] || die "U-Boot build produced no u-boot.bin"
    cp "${build_dir}/u-boot.bin" "${out_dir}/u-boot.bin"

    # Default environment as text: an env file (ENV_IS_IN_FAT) REPLACES the
    # built-in default env wholesale, so the image stage must seed
    # uboot.env with default-env + Crag's BOOT_* variables — not the
    # BOOT_* variables alone (which would lose bootcmd/kernel_addr_r/...).
    "${make_args[@]}" u-boot-initial-env
    cp "${build_dir}/u-boot-initial-env" "${out_dir}/u-boot-initial-env"

    echo "$marker_want" > "$version_marker"

    log_info "U-Boot built: ${out_dir}/u-boot.bin ($(du -h "${out_dir}/u-boot.bin" | cut -f1))"
}

# Build the GRUB EFI core image (AD-008). Modules are compiled into the
# core so the ESP needs no module tree; grub.cfg is read from the fixed
# prefix (hd0,gpt1)/EFI/BOOT — written there by the image stage.
build_grub_efi() {
    local board="$1"
    local board_arch="$2"

    [ "$board_arch" = "x86_64" ] || \
        die "grub-efi bootloader is only wired for x86_64 boards (got ${board_arch})"

    require_command grub2-mkimage

    local out_dir="${PROJECT_ROOT}/build/state/${board_arch}/bootloader/${board}"
    mkdir -p "$out_dir"

    if [ -f "${out_dir}/BOOTX64.EFI" ]; then
        log_info "GRUB EFI core image already built for ${board}, skipping"
        return 0
    fi

    log_step "Building GRUB EFI core image for ${board}..."

    # Module set for the AD-008 flow: GPT + FAT (boot partitions, bootenv),
    # env block load/save, scripting (normal), linux loader, serial console.
    grub2-mkimage \
        -O x86_64-efi \
        -o "${out_dir}/BOOTX64.EFI" \
        -p "/EFI/BOOT" \
        part_gpt fat ext2 search search_label normal configfile linux boot \
        loadenv test echo sleep serial terminal terminfo minicmd reboot halt \
        all_video efi_gop || die "grub2-mkimage failed"

    log_info "GRUB EFI image: ${out_dir}/BOOTX64.EFI ($(du -h "${out_dir}/BOOTX64.EFI" | cut -f1))"
}

build_bootloader() {
    local board="$1"
    local board_arch="$2"
    local board_dir="$3"
    local board_config_json="$4"

    local boot_type
    boot_type=$(echo "$board_config_json" | jq -r '.bootloader.type')

    case "$boot_type" in
        direct|none)
            log_info "Bootloader type '${boot_type}' — no bootloader build needed"
            return 0
            ;;
        rpi-boot)
            # RPi firmware boot chain (docs/04 §1): EEPROM -> start4.elf
            # -> u-boot.bin -> boot.scr. The firmware blobs come from the
            # rpi-boot apk (board packages.list) and the image stage
            # stages them onto the esp — the piece BUILT here is U-Boot,
            # exactly like the u-boot type (rpi_arm64_defconfig + the
            # board's uboot/*.fragment env config).
            build_uboot "$board" "$board_arch" "$board_dir" "$board_config_json"
            ;;
        u-boot)
            build_uboot "$board" "$board_arch" "$board_dir" "$board_config_json"
            ;;
        grub-efi)
            build_grub_efi "$board" "$board_arch"
            ;;
        *)
            die "Unknown bootloader type: ${boot_type}"
            ;;
    esac
}
