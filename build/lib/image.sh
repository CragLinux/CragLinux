#!/bin/bash
# Astro Linux - A/B disk image assembly (M1 wave 2, docs/04 §2/§6, AD-007)
# Sourced by build-inner.sh, not executed directly.
#
# Builds the canonical 7-partition GPT image entirely UNPRIVILEGED:
# no sudo, no losetup, no kernel mounts. Layout math lives in
# build/lib/image_layout.py (pure/testable); partitions are populated as
# free-standing filesystem images (mkfs.vfat + mtools for vfat,
# mkfs.ext4 -d for ext4, the rootfs squashfs as-is) and dd'd into the
# sparse disk file at the computed offsets.
#
#   1  esp       vfat   bootloader (GRUB BOOTX64.EFI+grub.cfg / U-Boot boot.scr)
#   2  bootenv   vfat   grubenv / uboot.env (slot-selection state)
#   3  boot.A    vfat   kernel (+ dtb when the board names one)
#   4  rootfs.A  squashfs (prod) / ext4 (dev)
#   5  boot.B    vfat   identical to boot.A
#   6  rootfs.B  identical to rootfs.A
#   7  data      ext4   AD-005 skeleton, grown on first boot (M2)
#
# Outputs into ${BUILD_OUTPUT} (build/state/images/<board>-<variant>/):
#   astro-<board>-<version>.img       raw (kept for run-qemu.sh --image)
#   astro-<board>-<version>.img.zst   flashable artifact (docs/04 §6)
#   astro-<board>-<version>.qcow2     when [image].formats has qcow2
#   SHA256SUMS, manifest.json
#
# Globals from build-inner.sh: PROJECT_ROOT BOARD_CONFIG_JSON BUILD_OUTPUT
# ROOTFS_TYPE KERNEL_CMDLINE BOARD_ARCH BOARD_DIR BOOTLOADER_TYPE

# mkfs.vfat wrapper: creates $1 of size $2 bytes with label $3.
# SOURCE_DATE_EPOCH -> --invariant for deterministic volume IDs/timestamps.
make_vfat() {
    local img="$1" size="$2" label="$3"
    local flags=(-n "$label")
    # FAT32 needs ~33 MiB minimum; small partitions (bootenv) get FAT12/16
    if [ "$size" -ge $((36 * 1024 * 1024)) ]; then
        flags+=(-F 32)
    fi
    [ -n "${SOURCE_DATE_EPOCH:-}" ] && flags+=(--invariant)
    rm -f "$img"
    truncate -s "$size" "$img"
    mkfs.vfat "${flags[@]}" "$img" > /dev/null || die "mkfs.vfat failed for ${img}"
}

# mkfs.ext4 -d wrapper, run inside a user namespace when unprivileged so
# the populated tree is recorded root-owned (same trick as the prod
# rootfs stage; GAP §3.5).
make_ext4_from_dir() {
    local img="$1" size="$2" label="$3" srcdir="$4"
    rm -f "$img"
    truncate -s "$size" "$img"
    local mkfs=(mkfs.ext4 -q -F -L "$label" -E "root_owner=0:0" -d "$srcdir" "$img")
    if [ "$(id -u)" -ne 0 ]; then
        unshare -r "${mkfs[@]}" || die "mkfs.ext4 failed for ${img}"
    else
        "${mkfs[@]}" || die "mkfs.ext4 failed for ${img}"
    fi
}

# Substitute the image-time template variables (boot.script.in,
# grub.cfg.in): @CMDLINE@ @ROOTFLAGS@ @KERNEL_IMG@ @BOOTCMD@
render_boot_template() {
    local template="$1" out="$2" cmdline="$3" rootflags="$4" kernel_img="$5" bootcmd="$6"
    sed -e "s|@CMDLINE@|${cmdline}|g" \
        -e "s|@ROOTFLAGS@|${rootflags}|g" \
        -e "s|@KERNEL_IMG@|${kernel_img}|g" \
        -e "s|@BOOTCMD@|${bootcmd}|g" \
        "$template" > "$out"
}

create_image() {
    local board_name="$1"
    local variant_name="$2"
    local rootfs_dir="$3"

    require_command sfdisk
    require_command mkfs.vfat
    require_command mcopy
    require_command mkfs.ext4
    require_command zstd
    require_command python3
    require_command jq

    local version="${ASTRO_VERSION:-0.0.0-dev}"
    local out_dir="${BUILD_OUTPUT}"
    local work="${out_dir}/image-work"
    local img="${out_dir}/astro-${board_name}-${version}.img"

    log_step "Assembling A/B disk image for ${board_name}/${variant_name} (${version})..."

    rm -rf "$work"
    mkdir -p "$work"

    ####################################################################
    # Layout (AD-007) — computed by the pure helper, consumed via jq
    ####################################################################
    local layout
    layout=$(echo "$BOARD_CONFIG_JSON" | python3 "${PROJECT_ROOT}/build/lib/image_layout.py") || \
        die "image_layout.py failed"
    echo "$layout" | jq -r '.sfdisk_script' > "${work}/sfdisk.script"

    local total_bytes
    total_bytes=$(echo "$layout" | jq -r '.total_bytes')

    part_attr() { # $1=partlabel $2=field
        echo "$layout" | jq -r ".partitions[] | select(.name == \"$1\") | .$2"
    }

    local esp_size bootenv_size boot_size rootfs_size data_size
    esp_size=$(part_attr esp size)
    bootenv_size=$(part_attr bootenv size)
    boot_size=$(part_attr "boot.A" size)
    rootfs_size=$(part_attr "rootfs.A" size)
    data_size=$(part_attr data size)

    ####################################################################
    # Kernel artifact
    ####################################################################
    source "${PROJECT_ROOT}/build/lib/kernel.sh"
    kernel_arch_map "$BOARD_ARCH"   # sets KERNEL_IMAGE (path) + KARCH
    local kernel_build="${PROJECT_ROOT}/build/state/${BOARD_ARCH}/kernel/${board_name}"
    local kernel_path="${kernel_build}/${KERNEL_IMAGE}"
    local kernel_img_name
    kernel_img_name=$(basename "$KERNEL_IMAGE")   # Image / zImage / bzImage
    [ -f "$kernel_path" ] || die "kernel image not found: ${kernel_path} (run --step=kernel first)"

    # Optional board DTB (real hardware boards; QEMU boards get their FDT
    # from the VMM/bootloader and set no [kernel].dtb)
    local dtb_name dtb_path=""
    dtb_name=$(echo "$BOARD_CONFIG_JSON" | jq -r '.kernel.dtb // ""')
    if [ -n "$dtb_name" ]; then
        dtb_path=$(find "${kernel_build}/arch/${KARCH}/boot/dts" -name "$dtb_name" | head -1)
        [ -n "$dtb_path" ] || die "board dtb ${dtb_name} not found in kernel build"
    fi

    ####################################################################
    # Root filesystem slot image (identical content for A and B)
    ####################################################################
    local rootfs_slot_img
    if [ "$ROOTFS_TYPE" = "squashfs" ]; then
        rootfs_slot_img="${out_dir}/rootfs.squashfs"
        [ -f "$rootfs_slot_img" ] || die "prod squashfs not found: ${rootfs_slot_img} (run --step=rootfs first)"
        local sq_bytes
        sq_bytes=$(stat -c %s "$rootfs_slot_img")
        [ "$sq_bytes" -le "$rootfs_size" ] || \
            die "squashfs (${sq_bytes} B) exceeds the rootfs slot (${rootfs_size} B) — also enforced by the rootfs stage"
    else
        # Dev variants map onto the same A/B layout with a rw ext4 of
        # exactly [partitions].rootfs_size in each rootfs slot (documented
        # in MIGRATION-NOTES §12): same partitioning, same PARTLABELs, so
        # RAUC/bootloader behavior is identical to prod.
        [ -d "$rootfs_dir" ] || die "rootfs dir not found: ${rootfs_dir} (run --step=rootfs first)"
        local tree_bytes
        tree_bytes=$(du -sb "$rootfs_dir" | cut -f1)
        # ext4 metadata overhead ~10%; refuse if the tree can't fit
        if [ "$tree_bytes" -gt $((rootfs_size * 9 / 10)) ]; then
            die "dev rootfs tree (${tree_bytes} B) does not fit the ${rootfs_size} B rootfs slot"
        fi
        rootfs_slot_img="${work}/rootfs.ext4"
        log_info "Building dev ext4 rootfs slot image (${rootfs_size} B)..."
        make_ext4_from_dir "$rootfs_slot_img" "$rootfs_size" "rootfs" "$rootfs_dir"
    fi

    ####################################################################
    # Boot slot image (kernel + optional dtb), shared by boot.A/boot.B
    ####################################################################
    log_info "Building boot slot image (${kernel_img_name})..."
    local boot_img="${work}/boot.vfat"
    make_vfat "$boot_img" "$boot_size" "ASTROBOOT"
    mcopy -i "$boot_img" "$kernel_path" "::/${kernel_img_name}" || die "mcopy kernel failed"
    if [ -n "$dtb_path" ]; then
        mmd -i "$boot_img" ::/dtbs
        mcopy -i "$boot_img" "$dtb_path" "::/dtbs/$(basename "$dtb_path")" || die "mcopy dtb failed"
    fi

    ####################################################################
    # Bootloader-specific ESP + bootenv content
    ####################################################################
    local rauc_backend rootflags
    rauc_backend=$(echo "$BOARD_CONFIG_JSON" | jq -r '.rauc.bootloader')
    [ "$ROOTFS_TYPE" = "squashfs" ] && rootflags="ro" || rootflags="rw"

    local esp_img="${work}/esp.vfat" bootenv_img="${work}/bootenv.vfat"
    make_vfat "$esp_img" "$esp_size" "ESP"
    make_vfat "$bootenv_img" "$bootenv_size" "BOOTENV"

    local bl_dir="${PROJECT_ROOT}/build/state/${BOARD_ARCH}/bootloader/${board_name}"

    case "$rauc_backend" in
        uboot)
            require_command mkimage
            require_command mkenvimage
            # boot.scr: slot-selection script (AD-009), read by U-Boot's
            # script bootmeth scanning the disk — first hit is the ESP.
            local mkimage_arch bootcmd
            case "$BOARD_ARCH" in
                aarch64) mkimage_arch="arm64"; bootcmd="booti" ;;
                armv7hf) mkimage_arch="arm";   bootcmd="bootz" ;;
                *) die "u-boot image assembly not wired for arch ${BOARD_ARCH}" ;;
            esac
            render_boot_template "${PROJECT_ROOT}/boards/common/uboot/boot.script.in" \
                "${work}/boot.cmd" "$KERNEL_CMDLINE" "$rootflags" "$kernel_img_name" "$bootcmd"
            mkimage -A "$mkimage_arch" -O linux -T script -C none \
                -n "Astro A/B boot" -d "${work}/boot.cmd" "${work}/boot.scr" > /dev/null || \
                die "mkimage boot.scr failed"
            mcopy -i "$esp_img" "${work}/boot.scr" ::/boot.scr

            # Initial env (BOOT_ORDER="A B", 3 tries each): mkenvimage blob
            # in a FAT file on bootenv — see boards/*/uboot/env.fragment
            # for why FAT instead of the AD-009 raw redundant env.
            # The env file replaces the built-in default env wholesale, so
            # it is seeded from the bootloader stage's u-boot-initial-env
            # (default env as text) plus the Astro BOOT_* variables.
            [ -f "${bl_dir}/u-boot-initial-env" ] || \
                die "u-boot-initial-env not found in ${bl_dir} (run --step=bootloader first)"
            {
                cat "${bl_dir}/u-boot-initial-env"
                grep -vE '^\s*(#|$)' "${PROJECT_ROOT}/boards/common/uboot/initial-env.in"
            } > "${work}/initial-env.txt"
            mkenvimage -s 0x10000 -o "${work}/uboot.env" "${work}/initial-env.txt" || \
                die "mkenvimage failed"
            mcopy -i "$bootenv_img" "${work}/uboot.env" ::/uboot.env
            ;;
        grub)
            require_command grub2-editenv
            [ -f "${bl_dir}/BOOTX64.EFI" ] || \
                die "GRUB EFI image not found: ${bl_dir}/BOOTX64.EFI (run --step=bootloader first)"
            render_boot_template "${PROJECT_ROOT}/boards/common/grub/grub.cfg.in" \
                "${work}/grub.cfg" "$KERNEL_CMDLINE" "$rootflags" "$kernel_img_name" ""
            mmd -i "$esp_img" ::/EFI ::/EFI/BOOT
            mcopy -i "$esp_img" "${bl_dir}/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI
            mcopy -i "$esp_img" "${work}/grub.cfg" ::/EFI/BOOT/grub.cfg

            # Initial grubenv (docs/04 §3): both slots OK, no tries burned
            grub2-editenv "${work}/grubenv" create
            grub2-editenv "${work}/grubenv" set \
                ORDER="A B" A_OK=1 B_OK=1 A_TRY=0 B_TRY=0
            mcopy -i "$bootenv_img" "${work}/grubenv" ::/grubenv
            ;;
        *)
            die "unknown rauc bootloader backend: ${rauc_backend}"
            ;;
    esac

    ####################################################################
    # /data partition (AD-005 §4.1 skeleton; grown on first boot — M2)
    ####################################################################
    log_info "Building data partition (${data_size} B)..."
    local data_skel="${work}/data-skel"
    mkdir -p "${data_skel}/config" \
             "${data_skel}/overlay/etc" "${data_skel}/overlay/.etc-work" \
             "${data_skel}/var/log" \
             "${data_skel}/apps" \
             "${data_skel}/keys/seedrng" \
             "${data_skel}/.astro"
    echo "1" > "${data_skel}/.astro/data-version"
    local data_img="${work}/data.ext4"
    make_ext4_from_dir "$data_img" "$data_size" "data" "$data_skel"

    ####################################################################
    # Assemble the sparse GPT disk
    ####################################################################
    log_step "Writing GPT + partitions into ${img}..."
    rm -f "$img"
    truncate -s "$total_bytes" "$img"
    sfdisk --quiet "$img" < "${work}/sfdisk.script" || die "sfdisk failed"

    # dd a partition image into the disk at its (MiB-aligned) offset
    write_part() { # $1=partlabel $2=source-image
        local offset
        offset=$(part_attr "$1" offset)
        dd if="$2" of="$img" bs=1M seek=$((offset / 1048576)) \
           conv=notrunc,sparse status=none || die "dd failed for ${1}"
    }

    write_part esp        "$esp_img"
    write_part bootenv    "$bootenv_img"
    write_part "boot.A"   "$boot_img"
    write_part "rootfs.A" "$rootfs_slot_img"
    write_part "boot.B"   "$boot_img"
    write_part "rootfs.B" "$rootfs_slot_img"
    write_part data       "$data_img"

    ####################################################################
    # Output formats + checksums + manifest (docs/04 §6)
    ####################################################################
    local formats
    formats=$(echo "$BOARD_CONFIG_JSON" | jq -r '.image.formats | join(" ")')

    if echo " $formats " | grep -q " qcow2 "; then
        require_command qemu-img
        log_info "Converting to qcow2..."
        qemu-img convert -f raw -O qcow2 "$img" "${img%.img}.qcow2" || \
            die "qemu-img convert failed"
    fi

    log_info "Compressing (zstd)..."
    zstd -q -T0 -f "$img" -o "${img}.zst" || die "zstd failed"

    local cports_pin
    cports_pin=$(git -C "${PROJECT_ROOT}/cports" rev-parse HEAD 2>/dev/null || echo unknown)
    local kernel_version
    kernel_version=$(echo "$BOARD_CONFIG_JSON" | jq -r '.kernel.version')

    (
        cd "$out_dir"
        rm -f SHA256SUMS
        sha256sum "$(basename "$img")" "$(basename "$img").zst" \
            $( [ -f "${img%.img}.qcow2" ] && basename "${img%.img}.qcow2" ) > SHA256SUMS
    )

    jq -n \
        --arg board "$board_name" \
        --arg variant "$variant_name" \
        --arg version "$version" \
        --arg arch "$BOARD_ARCH" \
        --arg kernel "$kernel_version" \
        --arg rootfs_type "$ROOTFS_TYPE" \
        --arg cports_pin "$cports_pin" \
        --arg rauc_compatible "$(echo "$BOARD_CONFIG_JSON" | jq -r '.rauc.compatible')" \
        --slurpfile sums <(jq -Rn '[inputs | split("  ") | {(.[1]): .[0]}] | add' < "${out_dir}/SHA256SUMS") \
        '{board: $board, variant: $variant, version: $version, arch: $arch,
          kernel: $kernel, rootfs_type: $rootfs_type, cports_pin: $cports_pin,
          rauc_compatible: $rauc_compatible, artifacts: $sums[0]}' \
        > "${out_dir}/manifest.json"

    log_info "Image artifacts:"
    log_info "  raw:    ${img}"
    log_info "  zst:    ${img}.zst ($(du -h "${img}.zst" | cut -f1))"
    [ -f "${img%.img}.qcow2" ] && log_info "  qcow2:  ${img%.img}.qcow2"
    log_info "  layout: $(echo "$layout" | jq -c '[.partitions[] | {name, offset, size}]')"
    log_info "  manifest: ${out_dir}/manifest.json"
}
