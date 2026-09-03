#!/bin/bash
# Crag Linux - cragd build + install (docs/06, AD-012)
# Sourced by rootfs-stage.sh, not executed directly.
#
# Builds the cragd/cragctl multi-call binary with the container's pinned
# Zig (docs/06 §3: the container is the single source of truth for the Zig
# version) and installs it into the rootfs. This stage runs INSIDE the
# build container (rootfs-stage.sh is a build-inner.sh child), so zig is
# invoked directly — never through a nested container.

# docs/06 §3 budget, also asserted by the cragd-unit CI step.
CRAGD_MAX_SIZE=$((8 * 1024 * 1024))

# Map a board arch ([board].arch in board.toml) to a zig -Dtarget triple.
# musl ABI => fully static binaries with no extra flags (AD-012).
zig_target_for() {
    case "$1" in
        aarch64) echo "aarch64-linux-musl" ;;
        x86_64)  echo "x86_64-linux-musl" ;;
        armv7hf) echo "arm-linux-musleabihf" ;;
        *)       die "Unsupported architecture for cragd build: $1" ;;
    esac
}

# Map a board arch to the cports package repo arch (packages/main/<arch>/).
apk_arch_for() {
    case "$1" in
        aarch64) echo "aarch64" ;;
        x86_64)  echo "x86_64" ;;
        armv7hf) echo "armv7" ;;
        *)       die "Unsupported architecture for cragd deps: $1" ;;
    esac
}

# Resolve a runnable apk-tools 3 binary. Inside the build container the
# packages stage puts toolchain/apk on PATH (build-inner.sh); other entry
# points (crag-ci.sh cragd-unit) reach here without that export, so fall
# back to the checked-out toolchain explicitly. Echoes a command prefix.
resolve_apk() {
    if command -v apk &>/dev/null; then
        echo "apk"
        return 0
    fi
    local local_apk="${PROJECT_ROOT}/toolchain/apk"
    local bin
    for bin in "${local_apk}/bin/apk" "${local_apk}/usr/bin/apk"; do
        if [ -x "$bin" ]; then
            # LD_LIBRARY_PATH for libapk.so, same dirs build-inner.sh exports.
            echo "env LD_LIBRARY_PATH=${local_apk}/usr/lib64:${local_apk}/usr/lib:${local_apk}/lib ${bin}"
            return 0
        fi
    done
    die "apk-tools not found (PATH or ${local_apk}) — run ./build/setup-cbuild.sh"
}

# Extract the basu sd-bus headers + static library for one target arch into
# build/state/<board_arch>/cragd-deps/ (cragd/build.zig -Dbasu-prefix).
# The apks are apk-tools 3 ADB archives (NOT gzip tars), so extraction goes
# through 'apk extract'. Layout after extraction:
#   <deps>/usr/include/basu/sd-bus.h (+ sd-bus-protocol.h, sd-id128.h, ...)
#   <deps>/usr/lib/libbasu.a         (ELF archive; the port sets !lto —
#                                     LTO bitcode members break zig's linker)
# Idempotent: a stamp file records the exact apk filenames; re-extraction
# happens only when the package set changes (e.g. a pkgrel bump).
extract_cragd_deps() {
    local board_arch="$1"
    local apk_arch
    apk_arch="$(apk_arch_for "$board_arch")"
    local repo="${PROJECT_ROOT}/cports/packages/main/${apk_arch}"
    local deps_dir="${PROJECT_ROOT}/build/state/${board_arch}/cragd-deps"

    # Newest pkgver-r<rel> wins (version sort handles r9 -> r10 correctly).
    local devel_apk static_apk
    devel_apk="$(ls "${repo}"/basu-devel-[0-9]*.apk 2>/dev/null | sort -V | tail -1)"
    static_apk="$(ls "${repo}"/basu-devel-static-*.apk 2>/dev/null | sort -V | tail -1)"
    [ -n "$devel_apk" ] && [ -n "$static_apk" ] || \
        die "basu-devel apks not found in ${repo} — build the basu port first (main/basu in the cports fork)"

    local stamp="${deps_dir}/.stamp"
    local want="$(basename "$devel_apk") $(basename "$static_apk")"
    if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$want" ]; then
        return 0
    fi

    log_step "Extracting basu headers + static lib (${apk_arch}) -> ${deps_dir}"
    local apk_cmd
    apk_cmd="$(resolve_apk)"
    rm -rf "$deps_dir"
    mkdir -p "$deps_dir"
    # --allow-untrusted: local repo, integrity is the repo checksum's job.
    $apk_cmd extract --destination "$deps_dir" --allow-untrusted \
        "$devel_apk" "$static_apk" \
        || die "apk extract failed for basu (${apk_arch})"

    [ -f "${deps_dir}/usr/include/basu/sd-bus.h" ] || \
        die "basu extraction incomplete: missing usr/include/basu/sd-bus.h in ${deps_dir}"
    [ -f "${deps_dir}/usr/lib/libbasu.a" ] || \
        die "basu extraction incomplete: missing usr/lib/libbasu.a in ${deps_dir}"
    echo "$want" > "$stamp"
}

# Build cragd (ReleaseSafe: release perf with safety checks on — the right
# trade for an always-on system daemon) and install /usr/bin/cragd plus
# the /usr/bin/cragctl multi-call symlink (dispatch is argv[0]-based).
build_cragd() {
    local board_arch="$1"
    local rootfs_dir="$2"

    local zig_target
    zig_target="$(zig_target_for "$board_arch")"
    local out_dir="${PROJECT_ROOT}/build/state/${board_arch}/cragd"
    # Per-arch cache: parallel per-board builds must not race in one cache.
    local cache_dir="${PROJECT_ROOT}/build/state/${board_arch}/cragd/zig-cache"

    # basu sd-bus headers + static lib for this target arch (src/bus.zig).
    extract_cragd_deps "$board_arch"
    local deps_dir="${PROJECT_ROOT}/build/state/${board_arch}/cragd-deps"

    log_step "Building cragd (${zig_target}, ReleaseSafe)"
    (cd "${PROJECT_ROOT}/cragd" && \
        zig build -Dtarget="${zig_target}" -Doptimize=ReleaseSafe \
            -Dbasu-prefix="${deps_dir}" \
            --cache-dir "${cache_dir}" --prefix "${out_dir}") \
        || die "cragd build failed for ${zig_target}"

    local bin="${out_dir}/bin/cragd"
    [ -f "$bin" ] || die "cragd binary missing after build: ${bin}"

    # Static-linkage guard: a dynamic binary would fail at boot on the
    # image (no matching loader) — fail the build, not the device.
    if readelf -lW "$bin" | grep -q INTERP; then
        die "cragd is dynamically linked (INTERP present) — expected a static musl binary"
    fi

    local size
    size=$(stat -c %s "$bin")
    if [ "$size" -gt "$CRAGD_MAX_SIZE" ]; then
        die "cragd binary exceeds the 8 MiB budget (docs/06 §3): ${size} bytes"
    fi

    install -D -m 0755 "$bin" "${rootfs_dir}/usr/bin/cragd"
    ln -sf cragd "${rootfs_dir}/usr/bin/cragctl"
    log_info "cragd installed: /usr/bin/cragd ($((size / 1024)) KiB) + cragctl symlink"
}
