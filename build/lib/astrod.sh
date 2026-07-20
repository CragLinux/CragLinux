#!/bin/bash
# Astro Linux - astrod build + install (docs/06, AD-012)
# Sourced by rootfs-stage.sh, not executed directly.
#
# Builds the astrod/astroctl multi-call binary with the container's pinned
# Zig (docs/06 §3: the container is the single source of truth for the Zig
# version) and installs it into the rootfs. This stage runs INSIDE the
# build container (rootfs-stage.sh is a build-inner.sh child), so zig is
# invoked directly — never through a nested container.

# docs/06 §3 budget, also asserted by the astrod-unit CI step.
ASTROD_MAX_SIZE=$((8 * 1024 * 1024))

# Map a board arch ([board].arch in board.toml) to a zig -Dtarget triple.
# musl ABI => fully static binaries with no extra flags (AD-012).
zig_target_for() {
    case "$1" in
        aarch64) echo "aarch64-linux-musl" ;;
        x86_64)  echo "x86_64-linux-musl" ;;
        armv7hf) echo "arm-linux-musleabihf" ;;
        *)       die "Unsupported architecture for astrod build: $1" ;;
    esac
}

# Build astrod (ReleaseSafe: release perf with safety checks on — the right
# trade for an always-on system daemon) and install /usr/bin/astrod plus
# the /usr/bin/astroctl multi-call symlink (dispatch is argv[0]-based).
build_astrod() {
    local board_arch="$1"
    local rootfs_dir="$2"

    local zig_target
    zig_target="$(zig_target_for "$board_arch")"
    local out_dir="${PROJECT_ROOT}/build/state/${board_arch}/astrod"
    # Per-arch cache: parallel per-board builds must not race in one cache.
    local cache_dir="${PROJECT_ROOT}/build/state/${board_arch}/astrod/zig-cache"

    log_step "Building astrod (${zig_target}, ReleaseSafe)"
    (cd "${PROJECT_ROOT}/astrod" && \
        zig build -Dtarget="${zig_target}" -Doptimize=ReleaseSafe \
            --cache-dir "${cache_dir}" --prefix "${out_dir}") \
        || die "astrod build failed for ${zig_target}"

    local bin="${out_dir}/bin/astrod"
    [ -f "$bin" ] || die "astrod binary missing after build: ${bin}"

    # Static-linkage guard: a dynamic binary would fail at boot on the
    # image (no matching loader) — fail the build, not the device.
    if readelf -lW "$bin" | grep -q INTERP; then
        die "astrod is dynamically linked (INTERP present) — expected a static musl binary"
    fi

    local size
    size=$(stat -c %s "$bin")
    if [ "$size" -gt "$ASTROD_MAX_SIZE" ]; then
        die "astrod binary exceeds the 8 MiB budget (docs/06 §3): ${size} bytes"
    fi

    install -D -m 0755 "$bin" "${rootfs_dir}/usr/bin/astrod"
    ln -sf astrod "${rootfs_dir}/usr/bin/astroctl"
    log_info "astrod installed: /usr/bin/astrod ($((size / 1024)) KiB) + astroctl symlink"
}
