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
    # shellcheck disable=SC2046  # apk_user_flags/manifest expansion: deliberate word splitting
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
    # shellcheck disable=SC2046  # apk_user_flags: deliberate word splitting
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

# Apply overlays across every layer, in merge order (docs/08 §4).
#
# Layer-driven successor to the former single-external overlay walk: the
# authoritative merge order — boards/common -> external trees (ascending
# tree.toml priority) -> board -> variant — lives in the ordered layer list
# resolved by build/lib/layers.py and persisted at $LAYERS_JSON. The actual
# file-by-file, last-writer-wins application (with per-file override
# provenance logging and the phase-1 code/config fence seam) is
# merge_overlays() in build/lib/merge.sh, which this delegates to;
# process_templates() (below) runs there afterwards.
#
# The resolved board dir and variant file are carried by $LAYERS_JSON, so this
# takes only the rootfs dir. With NO external trees the layer list is exactly
# [core, board, variant], so the overlay result is byte-for-byte what the old
# common->board->variant rsync produced (verified: no overlay ships empty or
# non-0755 dirs, and the lone symlink is copied with cp -a).
apply_overlays() {
    local rootfs_dir="$1"
    local layers_json="${LAYERS_JSON:?apply_overlays requires \$LAYERS_JSON (exported by build-inner.sh)}"

    merge_overlays "$layers_json" "$rootfs_dir"
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

# Run hook scripts from every layer, interleaved by numeric prefix (docs/08 §4).
#
# The hook set and its execution order come from the merged layer list: hooks
# from boards/common, external trees, and the board are interleaved by their
# numeric filename prefix ACROSS all layers (10-core.sh, 30-treeA.sh,
# 60-treeB.sh, 90-board.sh run in numeric order regardless of which layer
# contributed them; a tie on the number falls back to merge order). That
# ordering lives in merge_hooks() (build/lib/merge.sh), which reads
# $LAYERS_JSON; run_hooks is the consumer that sources each path in the
# printed order.
#
# With NO external trees the layer list is [core, board] for hooks and the
# board's own hooks are numbered above every common hook (50+ vs 00-30), so
# the interleave collapses to "all common hooks then the board hook" — exactly
# the historical order. The board layer's hooks come from $LAYERS_JSON.
run_hooks() {
    local rootfs_dir="$1"
    local layers_json="${LAYERS_JSON:?run_hooks requires \$LAYERS_JSON (exported by build-inner.sh)}"

    log_step "Running hooks..."

    # Documented hook environment (docs/08 §8 stability contract).
    export ROOTFS_DIR="$rootfs_dir"

    local hook count=0 label
    while IFS= read -r hook; do
        [ -f "$hook" ] || continue
        # Label as "<layer-dir>/hooks/<file>" for readable provenance in the log.
        label="$(basename "$(dirname "$(dirname "$hook")")")/hooks/$(basename "$hook")"
        log_info "  Running: ${label}"
        # shellcheck disable=SC1090  # hook path resolved at runtime from the layer list
        source "$hook"
        count=$((count + 1))
    done < <(merge_hooks "$layers_json")

    log_info "Hooks complete (${count} hook(s))"
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

##############################################################################
# Baked astrod defaults (docs/06 §2, docs/07 §3; M3)
#
# /etc/astro/astro-defaults.json is the IMAGE's contribution to the
# desired-state store: the firstboot oneshot copies it to
# /data/config/astro.json on the first boot of a data lifetime, and
# astrod migrates forward from there. Values come from the board TOML
# [api] section (AD-025: lan_exposure defaults off). Shaped here (jq
# exists in the build container; the image has no jq).
##############################################################################

# Stamp image identity into os-release: astrod's system info prefers
# ASTRO_BOARD/ASTRO_VARIANT/ASTRO_RELEASE over the generic keys, so
# GET /system reports the real board/variant instead of "unknown".
# ASTRO_RELEASE mirrors the image/bundle version (ASTRO_VERSION, the same
# source image.sh/bundle.sh use) so API clients and RAUC agree on it.
#
# The canonical document is /usr/lib/os-release, NOT /etc/os-release:
# base-files ships a tmpfiles `L+ /etc/os-release -> ../usr/lib/os-release`
# that force-recreates the symlink in the /etc overlay every boot, so a
# regular file baked at /etc/os-release silently vanishes at runtime (found
# by in-guest validation — the old common-overlay copy there was never
# actually served). The Astro document therefore lives in the common
# overlay at usr/lib/os-release and is stamped here.
stamp_os_release() {
    local rootfs_dir="$1" board="$2" variant="$3"
    local osr="${rootfs_dir}/usr/lib/os-release"
    [ -f "$osr" ] || { log_warn "no /usr/lib/os-release to stamp"; return 0; }

    sed -i '/^ASTRO_/d' "$osr"
    {
        echo "ASTRO_BOARD=${board}"
        echo "ASTRO_VARIANT=${variant}"
        echo "ASTRO_RELEASE=${ASTRO_VERSION:-0.0.0-dev}"
    } >> "$osr"
    log_info "os-release stamped: ASTRO_BOARD=${board} ASTRO_VARIANT=${variant} ASTRO_RELEASE=${ASTRO_VERSION:-0.0.0-dev}"

    # The pre-login banner (agetty /etc/issue) still said "Chimera"
    # (first-metal-boot polish note). Same trap family as os-release:
    # base-files' tmpfiles has `C /etc/issue <- /usr/share/base-files/
    # issue`, so a factory-reset /etc wipe would resurrect whatever the
    # package copy says — stamp BOTH the baked /etc/issue and the
    # tmpfiles source. agetty escapes: \r kernel release, \n hostname,
    # \l tty line.
    local issue_text="Astro ${ASTRO_VERSION:-0.0.0-dev} (\\n) (\\l) — kernel \\r"
    printf '%s\n\n' "$issue_text" > "${rootfs_dir}/etc/issue"
    if [ -f "${rootfs_dir}/usr/share/base-files/issue" ]; then
        printf '%s\n\n' "$issue_text" > "${rootfs_dir}/usr/share/base-files/issue"
    fi
    log_info "issue banner stamped: Astro ${ASTRO_VERSION:-0.0.0-dev}"
}

# Baked network defaults (docs/07 §2 rendering model; M3 phase 3).
#
# 1. /etc/astro/dhcpcd-fallback.conf — the config dhcpcd runs on BEFORE
#    astrod has ever rendered one: tmpfiles pre-creates
#    /run/astro/net/dhcpcd.conf as a symlink here (see the dhcpcd shadow
#    service in the common overlay for the whole bootstrap story). It
#    mirrors the pre-phase-3 behavior — plain DHCP on wired interfaces —
#    minus the resolv.conf hook, which is astrod's job now.
# 2. /etc/resolv.conf -> /run/astro-resolv/resolv.conf — astrod renders
#    the
#    target (ONE writer, docs/07 §2). This replaces whatever any package
#    left at /etc/resolv.conf. TRAP (the os-release lesson, §15 of
#    MIGRATION-NOTES): the resolvconf metapackage (dependency of dhcpcd
#    AND iwd) ships tmpfiles `L+ /etc/resolv.conf -> ../run/resolvconf/
#    resolv.conf` which force-recreates the symlink in the /etc overlay
#    every boot — a baked symlink alone would silently vanish at runtime.
#    The common overlay therefore ALSO ships /etc/tmpfiles.d/resolv.conf
#    (same basename = full override per tmpfiles.d(5)) pointing at the
#    Astro target; keep the two in sync.
bake_network_defaults() {
    local rootfs_dir="$1"

    mkdir -p "${rootfs_dir}/etc/astro"
    cat > "${rootfs_dir}/etc/astro/dhcpcd-fallback.conf" << 'EOF'
# Astro dhcpcd FALLBACK config (baked at image build; read-only).
#
# Served through the /run/astro/net/dhcpcd.conf bootstrap symlink until
# astrod's first render replaces it (docs/07 §2; see the dhcpcd dinit
# service for the mechanism). Keep this minimal and board-agnostic:
# plain DHCP on wired interfaces only — wifi association is iwd's job
# and does not exist before astrod has rendered a profile anyway.
allowinterfaces eth*
# DNS is astrod's: the lease hook exports DHCP-learned resolvers to
# /run/astro/net/leases/ and astrod alone writes the resolv target
# (/run/astro-resolv/resolv.conf).
nohook resolv.conf
# Group astrod may connect to /run/dhcpcd/sock so unprivileged astrod
# can send the rebind command after its first render (dhcpcd-10.3.2
# control.c chowns the socket to this group at startup). Must match the
# rendered config or the first-boot socket stays root-only until a
# dhcpcd restart.
controlgroup astrod
EOF
    log_info "network defaults baked: /etc/astro/dhcpcd-fallback.conf"

    # /run/astro-resolv, NOT /run/astro: the API-socket dir is 0750
    # astrod:astro-api and every user's libc resolver must read this
    # file (chronyd as _chrony found it unreadable live — M3 phase 4).
    ln -sfn /run/astro-resolv/resolv.conf "${rootfs_dir}/etc/resolv.conf"
    log_info "network defaults baked: /etc/resolv.conf -> /run/astro-resolv/resolv.conf"
}

# Time defaults (docs/07 §6, M3 phase 4).
#
# 1. /etc/astro/build-epoch — the image's build timestamp as decimal
#    unix seconds: SOURCE_DATE_EPOCH when the build pins one (the same
#    variable the squashfs stage clamps timestamps with), else the
#    assembly wall clock. This is the TLS chicken-and-egg floor for
#    battery-less boards booting in 1970: firstboot (root) steps the
#    clock up to max(build-epoch, /data/.astro/last-known-time), and
#    astrod re-checks at every startup + gates its own https installs
#    on synced-or-past-floor (astrod/src/timekeep.zig).
# 2. /etc/astro/chrony.conf — the minimal config the chronyd dinit
#    shadow runs with (-f): pool + makestep + rtcsync. No driftfile
#    (/var/lib is on the RO rootfs; drift tracking gets a /data home
#    only if a product asks). rtcsync IS required despite most boards
#    lacking a battery RTC: chronyd only clears the kernel's STA_UNSYNC
#    flag (sys_linux.c SYS_Linux_SetSync, guarded by the rtcsync
#    directive) when it is set — without it astrod's adjtimex-based
#    time.synced can never become true even with a selected NTP source
#    (found live: chronyc tracking synced, GET /system stuck false).
#    The side effect (kernel copies system time to the RTC every 11
#    min) is a no-op without an RTC driver.
bake_time_defaults() {
    local rootfs_dir="$1"
    local epoch="${SOURCE_DATE_EPOCH:-$(date +%s)}"

    mkdir -p "${rootfs_dir}/etc/astro"
    printf '%s\n' "$epoch" > "${rootfs_dir}/etc/astro/build-epoch"

    cat > "${rootfs_dir}/etc/astro/chrony.conf" << 'EOF'
# Astro minimal chrony config (baked at image build; docs/07 §6).
# Read by the /etc/dinit.d/chronyd shadow via -f. Products layer their
# own servers through the /etc overlay if the default pool is wrong for
# their deployment.
pool pool.ntp.org iburst
# Always step, never slew, when the clock is off by >1 s — appliances
# care about being right now, not about monotonic wall-clock aesthetics
# (the -1 means "on any correction", not just the first).
makestep 1.0 -1
# Clear the kernel STA_UNSYNC flag once synced — this is what feeds
# astrod's time.synced (adjtimex, docs/07 §6); chronyd only touches the
# flag when rtcsync is enabled. Harmless without an RTC driver.
rtcsync
EOF
    log_info "time defaults baked: /etc/astro/build-epoch=${epoch} + /etc/astro/chrony.conf"
}

generate_astro_defaults() {
    local rootfs_dir="$1"
    local board_config_json="$2"

    mkdir -p "${rootfs_dir}/etc/astro"
    echo "$board_config_json" | jq '{
        schema: 1,
        system: { provisioning: "factory" },
        api: {
            wifi:            (.api.wifi // true),
            ap_provisioning: (.api.ap_provisioning // true),
            mdns:            (.api.mdns // true),
            lan_exposure:    (.api.lan_exposure // false)
        }
    }' > "${rootfs_dir}/etc/astro/astro-defaults.json"

    log_info "astrod defaults baked: /etc/astro/astro-defaults.json"
}
