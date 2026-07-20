#!/bin/bash
# Astro Linux - Rootfs assembly
# Sourced by build-inner.sh, not executed directly.

# Create rootfs by installing packages via apk
#
# Packages-mode (docs/03 §1 "Binary consumption for dev builds"):
#   source — install everything from the local Astro-built repo, signatures
#            verified against the cbuild dev pubkey(s).
#   binary — install from the local repo AND Chimera's official binary repo;
#            the local repo is listed first, signatures are verified against
#            the pinned keys (build/keys/chimera/ + the cbuild dev key), and
#            locally-built manifest entries are version-pinned so a newer
#            Chimera package can never shadow an Astro-built/patched one.
# Either way installs are fully signature-verified (no --allow-untrusted)
# and any apk failure is a hard error (GAP §3.4/§3.5).
create_rootfs() {
    local rootfs_dir="$1"
    local arch="$2"
    local manifest_file="$3"
    local mode="${4:-${PACKAGES_MODE:-source}}"

    log_step "Creating rootfs at ${rootfs_dir} (${mode} packages-mode)..."

    mkdir -p "$rootfs_dir"

    # Determine package repository path
    # cbuild writes per-collection repos: packages/<collection>/<arch>/
    # apk expects the repo *base* in /etc/apk/repositories and appends /<arch>
    # ASTRO_LOCAL_REPO overrides the local repo base (e.g. a filtered CI copy).
    local pkg_repo_base="${ASTRO_LOCAL_REPO:-${PROJECT_ROOT}/cports/packages/main}"
    local pkg_repo="${pkg_repo_base}/${arch}"
    # Chimera's official binary repository (apk appends /<arch> itself);
    # layout per cports main/chimera-repo-main: <url>/current/main/<arch>/
    local chimera_repo="${ASTRO_CHIMERA_REPO:-https://repo.chimera-linux.org/current/main}"

    if [ "$mode" = "binary" ]; then
        create_rootfs_binary "$rootfs_dir" "$arch" "$manifest_file" \
                             "$pkg_repo_base" "$chimera_repo"
    else
        create_rootfs_source "$rootfs_dir" "$arch" "$manifest_file" \
                             "$pkg_repo_base"
    fi

    # Ensure basic directory structure exists regardless.
    # Skip entries that already exist — base-files ships some of these as
    # symlinks (e.g. var/lock -> ../run/lock, bin -> usr/bin) and mkdir -p
    # fails on dangling symlinks; never stomp the apk-installed layout.
    # data = mountpoint for the AD-005 mutable-state partition;
    # var/lib/seedrng = bind-mount target for the /data-backed rng seed
    # state (both consumed by boards/common/overlay .../data-mount.sh).
    local d
    for d in bin boot data dev etc home lib mnt opt proc root run sbin srv sys tmp usr var \
             usr/bin usr/include usr/lib usr/libexec usr/sbin usr/share usr/src \
             var/cache var/lib var/lib/seedrng var/local var/lock var/log var/opt var/run var/spool var/tmp \
             etc/dinit.d/boot.d; do
        [ -e "$rootfs_dir/$d" ] || [ -L "$rootfs_dir/$d" ] || mkdir -p "$rootfs_dir/$d"
    done
    chmod 1777 "$rootfs_dir"/tmp
    [ -d "$rootfs_dir"/var/tmp ] && chmod 1777 "$rootfs_dir"/var/tmp || true

    log_info "Rootfs base structure created"
}

# Source packages-mode install: everything comes from the local Astro-built
# repo, with full signature verification against the cbuild dev pubkey(s)
# (GAP §3.4 follow-through: no --allow-untrusted anywhere). Any apk failure
# is a hard error — the old manual-extraction fallback was dead code with
# apk-tools 3.x ADB packages and silently produced an empty rootfs
# (GAP §3.5); it has been removed.
create_rootfs_source() {
    local rootfs_dir="$1"
    local arch="$2"
    local manifest_file="$3"
    local pkg_repo_base="$4"
    local pkg_repo="${pkg_repo_base}/${arch}"

    command -v apk &>/dev/null || die "apk-tools not found — cannot assemble rootfs"
    [ -d "$pkg_repo" ] || die "package repository not found at ${pkg_repo} — run --step=packages first"

    # Trusted keys: the cbuild dev pubkey(s) that signed the local repo index,
    # installed into the rootfs' own /etc/apk/keys (also used via --keys-dir).
    log_info "Installing local repository signing keys..."
    mkdir -p "${rootfs_dir}/etc/apk/keys"
    local key found_key=false
    for key in "${PROJECT_ROOT}"/cports/etc/keys/*.pub; do
        [ -f "$key" ] || continue
        cp "$key" "${rootfs_dir}/etc/apk/keys/"
        found_key=true
    done
    [ "$found_key" = true ] || \
        die "no cbuild dev pubkeys in ${PROJECT_ROOT}/cports/etc/keys — cannot verify the local repo"

    mkdir -p "${rootfs_dir}/etc/apk"
    echo "v3 ${pkg_repo_base}" > "${rootfs_dir}/etc/apk/repositories"

    log_info "Installing packages via apk (signatures verified)..."
    apk --root "$rootfs_dir" \
        --arch "$arch" \
        --keys-dir etc/apk/keys \
        $(apk_user_flags) \
        --initdb \
        add $(cat "$manifest_file") 2>&1 || \
        die "apk install failed in source packages-mode (see log above)"
}

# --usermode: apk-tools 3.x requires it to create/populate a DB as non-root
# (the build container runs unprivileged, uid != 0). It also makes apk skip
# chown entirely, so every file ends up owned by the build uid — fine for
# the dev ext4 path (mkfs.ext4 -d normalizes to root), wrong for the prod
# squashfs. The prod path therefore runs the whole rootfs stage under
# `unshare -r` (see build-inner.sh): euid is 0 inside the user namespace,
# apk runs in real root mode and applies the ownership recorded in package
# metadata, and mksquashfs records those uids. No flag needed then.
apk_user_flags() {
    [ "$(id -u)" -eq 0 ] || echo "--usermode"
}

# Binary packages-mode install: local Astro repo (first, wins version ties)
# + Chimera's signed binary repo, full signature verification (no
# --allow-untrusted), deterministic local precedence via version pins.
create_rootfs_binary() {
    local rootfs_dir="$1"
    local arch="$2"
    local manifest_file="$3"
    local pkg_repo_base="$4"
    local chimera_repo="$5"
    local pkg_repo="${pkg_repo_base}/${arch}"

    command -v apk &>/dev/null || die "binary packages-mode requires apk-tools"

    # Trusted keys, written into the rootfs' own /etc/apk/keys (also the
    # default keys dir apk uses relative to --root):
    #  - build/keys/chimera/: Chimera's repo pubkeys, pinned in this repo
    #    (provenance: the hm-locked cports checkout — see the README there)
    #  - cports/etc/keys/*.pub: the cbuild dev key(s) that signed the local repo
    log_info "Installing pinned repository keys..."
    mkdir -p "${rootfs_dir}/etc/apk/keys"
    local key found_chimera_key=false
    for key in "${PROJECT_ROOT}"/build/keys/chimera/*.pub; do
        [ -f "$key" ] || continue
        cp "$key" "${rootfs_dir}/etc/apk/keys/"
        found_chimera_key=true
    done
    [ "$found_chimera_key" = true ] || \
        die "No pinned Chimera keys in ${PROJECT_ROOT}/build/keys/chimera/ — refusing to TOFU a remote repo"
    for key in "${PROJECT_ROOT}"/cports/etc/keys/*.pub; do
        [ -f "$key" ] || continue
        cp "$key" "${rootfs_dir}/etc/apk/keys/"
    done

    # Repository list: local Astro repo first — on equal versions apk-tools 3.x
    # prefers the lowest-indexed repository (solver "prefer lowest available
    # repository" tiebreak), so Astro-built packages win over identical
    # Chimera versions. A *newer* Chimera version would still win, which is
    # why locally-built manifest entries get exact version pins below and the
    # skew report flags every divergence afterwards.
    mkdir -p "${rootfs_dir}/etc/apk"
    {
        if [ -d "$pkg_repo" ]; then
            echo "v3 ${pkg_repo_base}"
        fi
        echo "v3 ${chimera_repo}"
    } > "${rootfs_dir}/etc/apk/repositories"
    log_info "Repositories (in precedence order):"
    sed 's/^/    /' "${rootfs_dir}/etc/apk/repositories"

    # Version-pin manifest entries that exist in the local repo so the local
    # (possibly patched) build is selected deterministically.
    local install_args=() pkg local_ver
    while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue
        local_ver=$(local_repo_version "$pkg_repo" "$pkg")
        if [ -n "$local_ver" ]; then
            install_args+=("${pkg}=${local_ver}")
        else
            install_args+=("$pkg")
        fi
    done < "$manifest_file"

    log_info "Installing ${#install_args[@]} packages via apk (verified signatures)..."
    apk --root "$rootfs_dir" \
        --arch "$arch" \
        --keys-dir etc/apk/keys \
        $(apk_user_flags) \
        --initdb \
        add "${install_args[@]}" 2>&1 || \
        die "apk install failed in binary packages-mode (see log above)"

    # Version-skew guard (warn-only): binary mode mixes Chimera-current
    # binaries with the pinned cports templates; report every divergence.
    binary_skew_report "$rootfs_dir" "$arch" "$pkg_repo" "$chimera_repo"
}

# Newest version of $2 present in the local repo dir $1 (by filename;
# apk names are <name>-<pkgver>-r<rel>.apk and pkgver never contains dashes).
local_repo_version() {
    local pkg_repo="$1" pkg="$2"
    local f
    f=$(find "$pkg_repo" -maxdepth 1 -name "${pkg}-[0-9]*.apk" 2>/dev/null | sort -V | tail -1)
    [ -z "$f" ] && return 0
    f="$(basename "$f" .apk)"
    # strip "<name>-": version-rel is the last two dash-separated fields
    echo "$f" | awk -F- -v name="$pkg" '{
        ver = $(NF-1) "-" $NF
        if (substr($0, 1, length(name) + 1) == name "-") print ver
    }'
}

# Warn (never fail) when installed package versions diverge from the pinned
# cports templates — i.e. Chimera-current has moved past our pin for packages
# we do not build. Release/nightly source builds cannot skew by construction.
# Report: build/state/logs/skew-report-<board>-<variant>.log
binary_skew_report() {
    local rootfs_dir="$1"
    local arch="$2"
    local pkg_repo="$3"
    local chimera_repo="$4"

    local logs_dir="${PROJECT_ROOT}/build/state/logs"
    # BUILD_OUTPUT basename is "<board>-<variant>" (set by build-inner.sh)
    local report="${logs_dir}/skew-report-$(basename "${BUILD_OUTPUT:-unknown}").log"
    mkdir -p "$logs_dir"

    log_step "Checking version skew vs pinned cports templates..."

    # Chimera index for provenance attribution (best-effort)
    local chimera_dump="" cache_dir="${PROJECT_ROOT}/build/state/cache"
    mkdir -p "$cache_dir"
    local chimera_ndx="${cache_dir}/chimera-Packages-${arch}.adb"
    if curl -sfL -o "$chimera_ndx" "${chimera_repo}/${arch}/Packages.adb" 2>/dev/null; then
        chimera_dump="${cache_dir}/chimera-Packages-${arch}.txt"
        apk adbdump "$chimera_ndx" > "$chimera_dump" 2>/dev/null || chimera_dump=""
    fi

    local local_dump=""
    if [ -f "${pkg_repo}/Packages.adb" ]; then
        local_dump="${cache_dir}/local-Packages-${arch}.txt"
        apk adbdump "${pkg_repo}/Packages.adb" > "$local_dump" 2>/dev/null || local_dump=""
    fi

    python3 "${PROJECT_ROOT}/build/lib/skew_check.py" \
        --installed "${rootfs_dir}/lib/apk/db/installed" \
        --cports "${PROJECT_ROOT}/cports" \
        ${SOURCE_MANIFEST_FILE:+--source-manifest "$SOURCE_MANIFEST_FILE"} \
        ${local_dump:+--local-dump "$local_dump"} \
        ${chimera_dump:+--chimera-dump "$chimera_dump"} \
        --out "$report" || log_warn "skew check itself failed (non-fatal)"

    log_info "Skew report: ${report}"
}

# NOTE: the former extract_packages_manually() fallback was removed
# (GAP §3.5): apk-tools 3.x packages are ADB, not gzip tarballs, so
# 'tar -xzf' extracted nothing and the build "passed" with an empty rootfs.
# apk install failures are hard errors now.

# Apply overlay directories in order
apply_overlays() {
    local rootfs_dir="$1"
    local board_dir="$2"
    local variant_name="$3"
    local external_dir="${4:-}"

    log_step "Applying overlays..."

    # 1. Common overlay
    local common_overlay="${PROJECT_ROOT}/boards/common/overlay"
    if [ -d "$common_overlay" ]; then
        log_info "  Applying common overlay"
        rsync -a "$common_overlay/" "$rootfs_dir/"
    fi

    # 2. External global overlay (if set)
    if [ -n "$external_dir" ] && [ -d "${external_dir}/overlay" ]; then
        log_info "  Applying external global overlay"
        rsync -a "${external_dir}/overlay/" "$rootfs_dir/"
    fi

    # 3. Board overlay
    if [ -d "${board_dir}/overlay" ]; then
        log_info "  Applying board overlay"
        rsync -a "${board_dir}/overlay/" "$rootfs_dir/"
    fi

    # 4. Variant overlay (if exists)
    local variant_overlay="${board_dir}/variants/${variant_name}/overlay"
    if [ -d "$variant_overlay" ]; then
        log_info "  Applying variant overlay"
        rsync -a "$variant_overlay/" "$rootfs_dir/"
    fi

    # Process .template files
    process_templates "$rootfs_dir"

    log_info "Overlays applied"
}

# Process files ending in .template with envsubst
process_templates() {
    local rootfs_dir="$1"

    local templates
    templates=$(find "$rootfs_dir" -name "*.template" 2>/dev/null)

    if [ -n "$templates" ]; then
        while IFS= read -r template; do
            local target="${template%.template}"
            envsubst < "$template" > "$target"
            rm -f "$template"
            log_info "  Processed template: ${target#${rootfs_dir}}"
        done <<< "$templates"
    fi
}

# Run hook scripts from common and board directories
run_hooks() {
    local rootfs_dir="$1"
    local board_dir="$2"

    log_step "Running hooks..."

    # Export rootfs dir for hooks
    export ROOTFS_DIR="$rootfs_dir"

    # 1. Common hooks
    local common_hooks="${PROJECT_ROOT}/boards/common/hooks"
    if [ -d "$common_hooks" ]; then
        for hook in "$common_hooks"/*.sh; do
            [ -f "$hook" ] || continue
            log_info "  Running: common/$(basename "$hook")"
            source "$hook"
        done
    fi

    # 2. Board hooks
    if [ -d "${board_dir}/hooks" ]; then
        for hook in "${board_dir}/hooks"/*.sh; do
            [ -f "$hook" ] || continue
            log_info "  Running: $(basename "$(dirname "$board_dir")")/$(basename "$hook")"
            source "$hook"
        done
    fi

    log_info "Hooks complete"
}

# Install kernel image, modules, and DTBs into rootfs
install_kernel_to_rootfs() {
    local rootfs_dir="$1"
    local board="$2"
    local board_arch="$3"
    local board_config_json="$4"

    local version
    version=$(echo "$board_config_json" | jq -r '.kernel.version')

    # Determine kernel image path
    source "${PROJECT_ROOT}/build/lib/kernel.sh"
    kernel_arch_map "$board_arch"

    local kernel_build="${PROJECT_ROOT}/build/state/${board_arch}/kernel/${board}"

    if [ ! -f "${kernel_build}/${KERNEL_IMAGE}" ]; then
        log_warn "Kernel image not found at ${kernel_build}/${KERNEL_IMAGE}"
        log_warn "Run --step=kernel first"
        return 0
    fi

    log_step "Installing kernel modules into rootfs..."

    # NOTE (docs/02 §6, M1 wave 2): the kernel image and DTBs are NOT part
    # of the rootfs — the image stage installs them into the per-slot boot
    # partitions (boot.A/boot.B) from the kernel build dir, and direct QEMU
    # boots load the kernel straight from build/state/. Only the modules
    # live in the rootfs.

    # Install modules
    local modules_src="${kernel_build}/modules_install/lib/modules"
    if [ -d "$modules_src" ]; then
        mkdir -p "${rootfs_dir}/lib/modules"
        cp -a "$modules_src"/* "${rootfs_dir}/lib/modules/"
        log_info "  Installed kernel modules"

        # Run depmod
        local mod_version
        mod_version=$(ls "${rootfs_dir}/lib/modules/" | head -1)
        if [ -n "$mod_version" ] && command -v depmod &>/dev/null; then
            depmod -b "${rootfs_dir}" "$mod_version" 2>/dev/null || true
            log_info "  Generated module dependencies"
        fi
    fi

    # (DTBs go into the per-slot boot partitions at image time, not here.)

    log_info "Kernel module installation complete"
}

# Convert a [partitions] size string ("64M", "1G", "512K") to bytes
size_to_bytes() {
    local size="$1" num="${1%[KMG]}"
    case "$size" in
        *K) echo $((num * 1024)) ;;
        *M) echo $((num * 1024 * 1024)) ;;
        *G) echo $((num * 1024 * 1024 * 1024)) ;;
        *)  echo "$num" ;;
    esac
}

# Pack the assembled rootfs into a read-only squashfs (prod path, AD-004).
#
# Must run inside the same user namespace as the apk install (unshare -r,
# see build-inner.sh): the build uid maps to 0 there, so mksquashfs records
# root ownership for everything apk installed as "root", and any uids apk
# set from package metadata are preserved as-is.
#
# Reproducibility: -noappend for a fresh image; when SOURCE_DATE_EPOCH is
# set (docs/03 §7 — full plumbing is a later item, the env var is honored
# now) all file timestamps and the superblock mkfs time are clamped to it.
make_squashfs_image() {
    local rootfs_dir="$1"
    local out_img="$2"
    local board_config_json="$3"

    require_command mksquashfs

    log_step "Creating squashfs rootfs image..."

    local flags=(-comp zstd -noappend)
    if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
        flags+=(-mkfs-time "$SOURCE_DATE_EPOCH" -all-time "$SOURCE_DATE_EPOCH")
        log_info "  SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH} (clamping timestamps)"
    fi

    rm -f "$out_img"
    mksquashfs "$rootfs_dir" "$out_img" "${flags[@]}" || \
        die "mksquashfs failed"

    # The squashfs must fit the per-slot rootfs partition (docs/03 §6:
    # "build fails if squashfs exceeds it").
    local limit_str limit_bytes actual_bytes
    limit_str=$(echo "$board_config_json" | jq -r '.partitions.rootfs_size // "512M"')
    limit_bytes=$(size_to_bytes "$limit_str")
    actual_bytes=$(stat -c %s "$out_img")
    if [ "$actual_bytes" -gt "$limit_bytes" ]; then
        die "squashfs (${actual_bytes} bytes) exceeds [partitions].rootfs_size = ${limit_str} (${limit_bytes} bytes)"
    fi
    log_info "Squashfs rootfs: ${out_img} ($(du -h "$out_img" | cut -f1), limit ${limit_str})"
}

##############################################################################
# RAUC configuration (docs/05 §2; M2)
#
# Generated per board at rootfs assembly — not a package — so the values
# come straight from the board TOML ([rauc] section) and the AD-007
# partition layout. Three artifacts:
#
#   /etc/rauc/system.conf   slots, backend, statusfile on /data,
#                           bundle-formats=verity (AD-010)
#   /etc/rauc/keyring.pem   device keyring — the DEV CA for now; release
#                           images get the prod CA chain when the release
#                           pipeline lands (docs/05 §6, docs/10)
#   /etc/fw_env.config      uboot boards only: points libubootenv at the
#                           env-in-FAT file on the mounted bootenv
#                           partition (AD-009 deviation, MIGRATION-NOTES
#                           §12) — mounted at /run/astro/bootenv by the
#                           bootenv-mount service
##############################################################################

generate_rauc_config() {
    local rootfs_dir="$1"
    local board_config_json="$2"

    local compatible backend
    compatible=$(echo "$board_config_json" | jq -r '.rauc.compatible')
    backend=$(echo "$board_config_json" | jq -r '.rauc.bootloader')

    log_step "Generating RAUC configuration (compatible=${compatible}, bootloader=${backend})..."

    mkdir -p "${rootfs_dir}/etc/rauc"

    {
        echo "# Generated by the Astro rootfs stage (docs/05 §2) — do not edit on-device;"
        echo "# board values live in boards/<board>/board.toml [rauc]."
        echo "[system]"
        echo "compatible=${compatible}"
        echo "bootloader=${backend}"
        if [ "$backend" = "grub" ]; then
            # bootenv is a vfat partition carrying the grubenv FILE (docs/04
            # §3); mounted by bootenv-mount before rauc needs it
            echo "grubenv=/run/astro/bootenv/grubenv"
        fi
        echo "statusfile=/data/.astro/rauc.status"
        echo "bundle-formats=verity"
        echo ""
        echo "[keyring]"
        echo "path=/etc/rauc/keyring.pem"
        echo ""
        echo "[slot.boot.0]"
        echo "device=/dev/disk/by-partlabel/boot.A"
        echo "type=vfat"
        echo "parent=rootfs.0"
        echo ""
        echo "[slot.rootfs.0]"
        echo "device=/dev/disk/by-partlabel/rootfs.A"
        echo "type=raw"
        echo "bootname=A"
        echo ""
        echo "[slot.boot.1]"
        echo "device=/dev/disk/by-partlabel/boot.B"
        echo "type=vfat"
        echo "parent=rootfs.1"
        echo ""
        echo "[slot.rootfs.1]"
        echo "device=/dev/disk/by-partlabel/rootfs.B"
        echo "type=raw"
        echo "bootname=B"
    } > "${rootfs_dir}/etc/rauc/system.conf"

    # Device keyring: dev CA (loudly fake, keys/dev/README.md). Run
    # ./build/astro-keys.sh init-dev if missing.
    local dev_ca="${PROJECT_ROOT}/keys/dev/rauc-ca.pem"
    [ -f "$dev_ca" ] || die "dev RAUC CA not found: ${dev_ca}\n  Run: ./build/astro-keys.sh init-dev"
    cp "$dev_ca" "${rootfs_dir}/etc/rauc/keyring.pem"

    if [ "$backend" = "uboot" ]; then
        # env-in-FAT single copy; size must match CONFIG_ENV_SIZE in the
        # board's uboot env fragment (default 0x10000)
        local env_size
        env_size=$(grep -h '^CONFIG_ENV_SIZE=' "${BOARD_DIR}/uboot/"*.fragment 2>/dev/null | head -1 | cut -d= -f2)
        env_size="${env_size:-0x10000}"
        {
            echo "# Generated by the Astro rootfs stage. libubootenv config: the U-Boot"
            echo "# environment is a FAT file on the bootenv partition (AD-009 deviation,"
            echo "# MIGRATION-NOTES §12), mounted at /run/astro/bootenv by bootenv-mount."
            echo "/run/astro/bootenv/uboot.env 0x0000 ${env_size}"
        } > "${rootfs_dir}/etc/fw_env.config"
    fi

    log_info "RAUC config: system.conf + keyring.pem$([ "$backend" = uboot ] && echo ' + fw_env.config')"
}
