#!/bin/bash
# Astro Linux - Package list resolution and building
# Sourced by build-inner.sh, not executed directly.

# Resolve the merged package list from common + board + firmware + variant + kernel
# Output: writes merged list to stdout (one package per line, deduplicated)
resolve_package_list() {
    local board_dir="$1"
    local variant_config_json="$2"
    local external_dir="${3:-}"

    local packages=()

    # 1. Common base packages
    local common_list="${PROJECT_ROOT}/boards/common/packages.list"
    if [ -f "$common_list" ]; then
        while IFS= read -r line; do
            line="${line%%#*}"      # strip comments
            line="${line// /}"      # strip whitespace
            [ -n "$line" ] && packages+=("$line")
        done < "$common_list"
    fi

    # 2. Board packages
    local board_list="${board_dir}/packages.list"
    if [ -f "$board_list" ]; then
        while IFS= read -r line; do
            line="${line%%#*}"
            line="${line// /}"
            [ -n "$line" ] && packages+=("$line")
        done < "$board_list"
    fi

    # 3. Firmware packages (from board.toml)
    local firmware_pkgs
    firmware_pkgs=$(echo "$BOARD_CONFIG_JSON" | jq -r '.firmware.packages // [] | .[]' 2>/dev/null)
    if [ -n "$firmware_pkgs" ]; then
        while IFS= read -r pkg; do
            [ -n "$pkg" ] && packages+=("$pkg")
        done <<< "$firmware_pkgs"
    fi

    # 4. Variant packages
    local variant_pkgs
    variant_pkgs=$(echo "$variant_config_json" | jq -r '.packages.install // [] | .[]' 2>/dev/null)
    if [ -n "$variant_pkgs" ]; then
        while IFS= read -r pkg; do
            [ -n "$pkg" ] && packages+=("$pkg")
        done <<< "$variant_pkgs"
    fi

    # Note: kernel is built directly (not through cbuild), so not included here

    # Deduplicate while preserving order
    printf '%s\n' "${packages[@]}" | awk '!seen[$0]++'
}

# Resolve the subset of templates that must be built from source in binary
# packages-mode (docs/03 §1 "Binary consumption for dev builds"):
#   1. every template in the astro-cports/ collection,
#   2. every cports template shadowed/patched via build/patches/cports/
#      (derived from the template paths inside the patch files),
#   3. anything listed in boards/common/source-packages.list.
# Output: bare template names to stdout, one per line, deduplicated.
resolve_source_package_list() {
    local packages=()

    # 1. astro-cports collection templates (any collection subdir, e.g. main/)
    local tmpl
    for tmpl in "${PROJECT_ROOT}"/astro-cports/*/*/template.py; do
        [ -f "$tmpl" ] || continue
        packages+=("$(basename "$(dirname "$tmpl")")")
    done

    # 2. Templates touched by quilt-style cports patches: any path of the
    #    form (a|b)/<collection>/<template>/... inside the patch files
    local patch
    for patch in "${PROJECT_ROOT}"/build/patches/cports/*.patch; do
        [ -f "$patch" ] || continue
        while IFS= read -r pkg; do
            [ -n "$pkg" ] && packages+=("$pkg")
        done < <(grep -E '^(---|\+\+\+) [ab]/(main|user)/' "$patch" \
                 | sed -E 's#^(---|\+\+\+) [ab]/(main|user)/([^/]+)/.*#\3#' \
                 | sort -u)
    done

    # 3. Explicit overrides
    local source_list="${PROJECT_ROOT}/boards/common/source-packages.list"
    if [ -f "$source_list" ]; then
        local line
        while IFS= read -r line; do
            line="${line%%#*}"
            line="${line// /}"
            [ -n "$line" ] && packages+=("$line")
        done < "$source_list"
    fi

    [ ${#packages[@]} -eq 0 ] && return 0
    printf '%s\n' "${packages[@]}" | awk '!seen[$0]++'
}

# Enable cbuild's transparent ccache support (cports Usage.md "Ccache").
# The cache lives in cports/cbuild_cache/ccache (cbuild's cbuild_cache_path),
# which sits inside the /workspace bind mount, so it persists across container
# runs alongside the other build caches. Knob: set ASTRO_CCACHE=0 to disable
# (the config is rewritten idempotently on every packages run).
ensure_cbuild_ccache() {
    local cbuild_dir="${PROJECT_ROOT}/cports"
    local config="${cbuild_dir}/etc/config.ini"
    local want="${ASTRO_CCACHE:-1}"
    local value="yes"
    [ "$want" = "0" ] && value="no"

    python3 - "$config" "$value" <<'EOF'
import configparser
import sys

path, value = sys.argv[1], sys.argv[2]
cfg = configparser.ConfigParser()
cfg.read(path)
if not cfg.has_section("build"):
    cfg.add_section("build")
if cfg.get("build", "ccache", fallback=None) != value:
    cfg.set("build", "ccache", value)
    with open(path, "w") as f:
        cfg.write(f)
    print(f"cbuild ccache = {value} ({path})")
EOF
}

# Build packages via cbuild
build_packages() {
    local arch="$1"
    local manifest_file="$2"

    # cports is a Harbormaster-managed checkout at <repo-root>/cports
    local cbuild_dir="${PROJECT_ROOT}/cports"

    if [ ! -d "$cbuild_dir" ]; then
        die "cports checkout not found at ${cbuild_dir}.\n  cports is managed by Harbormaster; run 'hm sync --locked' to materialize it."
    fi

    # Check for apk-tools (required by cbuild)
    if ! command -v apk &>/dev/null; then
        die "apk-tools not found. cbuild has not been bootstrapped.\n  Run: ./build/astro-build.sh <board> <variant> --shell\n  Then inside the container: ./build/setup-cbuild.sh"
    fi

    # Source architecture profile
    local profile="${PROJECT_ROOT}/build/cbuild-profiles/${arch}.conf"
    if [ -f "$profile" ]; then
        source "$profile"
    fi

    # Persistent compiler cache for all cbuild invocations (see function doc)
    ensure_cbuild_ccache

    log_step "Building packages for ${arch}..."

    local failed=()
    while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue

        # astro-cports collection wiring into cbuild is a later task
        # (AD-001: cbuild collections); until then astro-cports templates
        # can be resolved but not built.
        if compgen -G "${PROJECT_ROOT}/astro-cports/*/${pkg}/template.py" > /dev/null; then
            log_warn "Package ${pkg} lives in astro-cports/ — collection build wiring is a later task (skipping)"
            continue
        fi

        # Check if package exists in cports
        if [ ! -d "${cbuild_dir}/main/${pkg}" ] && [ ! -d "${cbuild_dir}/user/${pkg}" ]; then
            log_warn "Package not found in cports: ${pkg} (skipping)"
            continue
        fi

        local repo="main"
        [ -d "${cbuild_dir}/user/${pkg}" ] && repo="user"

        log_info "Building: ${repo}/${pkg}"
        if ! (cd "$cbuild_dir" && ./cbuild -a "$arch" pkg "${repo}/${pkg}"); then
            log_error "Failed to build: ${pkg}"
            failed+=("$pkg")
        fi
    done < "$manifest_file"

    if [ ${#failed[@]} -gt 0 ]; then
        log_error "Failed packages: ${failed[*]}"
        return 1
    fi

    log_info "All packages built successfully"
}
