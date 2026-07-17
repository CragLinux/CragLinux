#!/bin/bash
# Astro Linux - Rootfs assembly
# Sourced by build-inner.sh, not executed directly.

# Create rootfs by installing packages via apk
#
# Packages-mode (docs/03 §1 "Binary consumption for dev builds"):
#   source — install everything from the local Astro-built repo (today's
#            release/nightly behavior, unchanged).
#   binary — install from the local repo AND Chimera's official binary repo;
#            the local repo is listed first, signatures are verified against
#            the pinned keys (build/keys/chimera/ + the cbuild dev key), and
#            locally-built manifest entries are version-pinned so a newer
#            Chimera package can never shadow an Astro-built/patched one.
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
    elif [ -d "$pkg_repo" ]; then
        # Try using apk to install packages from local repo
        if command -v apk &>/dev/null; then
            log_info "Installing packages via apk..."

            # Initialize apk database
            mkdir -p "${rootfs_dir}/etc/apk"
            echo "${pkg_repo_base}" > "${rootfs_dir}/etc/apk/repositories"

            # --usermode: apk-tools 3.x requires it to create/populate a DB as
            # non-root (the build container runs unprivileged, uid != 0)
            apk --root "$rootfs_dir" \
                --arch "$arch" \
                --allow-untrusted \
                --usermode \
                --initdb \
                add $(cat "$manifest_file") 2>&1 || {
                    log_warn "apk install failed, falling back to manual extraction"
                    extract_packages_manually "$rootfs_dir" "$pkg_repo" "$manifest_file"
                }
        else
            log_info "apk not found, extracting packages manually..."
            extract_packages_manually "$rootfs_dir" "$pkg_repo" "$manifest_file"
        fi
    else
        log_warn "Package repository not found at ${pkg_repo}"
        log_warn "Creating basic directory structure only"
    fi

    # Ensure basic directory structure exists regardless.
    # Skip entries that already exist — base-files ships some of these as
    # symlinks (e.g. var/lock -> ../run/lock, bin -> usr/bin) and mkdir -p
    # fails on dangling symlinks; never stomp the apk-installed layout.
    local d
    for d in bin boot dev etc home lib mnt opt proc root run sbin srv sys tmp usr var \
             usr/bin usr/include usr/lib usr/libexec usr/sbin usr/share usr/src \
             var/cache var/lib var/local var/lock var/log var/opt var/run var/spool var/tmp \
             etc/dinit.d/boot.d; do
        [ -e "$rootfs_dir/$d" ] || [ -L "$rootfs_dir/$d" ] || mkdir -p "$rootfs_dir/$d"
    done
    chmod 1777 "$rootfs_dir"/tmp
    [ -d "$rootfs_dir"/var/tmp ] && chmod 1777 "$rootfs_dir"/var/tmp || true

    log_info "Rootfs base structure created"
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
        --usermode \
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

# Fallback: extract .apk files manually (they are gzip'd tar archives)
extract_packages_manually() {
    local rootfs_dir="$1"
    local pkg_repo="$2"
    local manifest_file="$3"

    while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue

        # Find the .apk file (take the latest version)
        local apk_file
        apk_file=$(find "$pkg_repo" -name "${pkg}-*.apk" 2>/dev/null | sort -V | tail -1)

        if [ -n "$apk_file" ] && [ -f "$apk_file" ]; then
            log_info "  Extracting: $(basename "$apk_file")"
            tar -xzf "$apk_file" -C "$rootfs_dir" 2>/dev/null || true
        else
            log_warn "  Package not found: ${pkg}"
        fi
    done < "$manifest_file"
}

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

    log_step "Installing kernel into rootfs..."

    # Install kernel image
    mkdir -p "${rootfs_dir}/boot"
    cp "${kernel_build}/${KERNEL_IMAGE}" "${rootfs_dir}/boot/vmlinuz-${version}"
    log_info "  Installed kernel image: /boot/vmlinuz-${version}"

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

    # Install DTBs
    local dtbs_dir="${kernel_build}/arch/${KARCH}/boot/dts"
    if [ -d "$dtbs_dir" ]; then
        mkdir -p "${rootfs_dir}/boot/dtbs"
        find "$dtbs_dir" -name "*.dtb" -exec cp {} "${rootfs_dir}/boot/dtbs/" \; 2>/dev/null
        local dtb_count
        dtb_count=$(find "${rootfs_dir}/boot/dtbs" -name "*.dtb" 2>/dev/null | wc -l)
        log_info "  Installed ${dtb_count} device tree blob(s)"
    fi

    log_info "Kernel installation complete"
}
