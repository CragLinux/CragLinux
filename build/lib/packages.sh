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

# Astro-owned fork templates of a given class ("new" or "mod") from
# build/cports-owned.list. "new" = not in Chimera's binary repo (always
# source-built); "mod" = we differ from upstream (source-built only when
# an image installs it). One name per line.
resolve_owned_templates() {
    local class="$1" owned="${PROJECT_ROOT}/build/cports-owned.list"
    [ -f "$owned" ] || return 0
    local name kind
    while read -r name kind _; do
        case "$name" in ''|\#*) continue ;; esac
        [ "$kind" = "$class" ] && echo "$name"
    done < "$owned"
}

# Templates that must be built from source in binary packages-mode
# UNCONDITIONALLY (docs/03 §1): the fork's NEW packages (Chimera's repo
# has no equivalent) plus boards/common/source-packages.list overrides.
# "mod" templates are handled separately in build-inner.sh (built only
# when the manifest lists them). Output: bare names, deduplicated.
resolve_source_package_list() {
    local packages=() line
    while IFS= read -r line; do packages+=("$line"); done < <(resolve_owned_templates new)

    local source_list="${PROJECT_ROOT}/boards/common/source-packages.list"
    if [ -f "$source_list" ]; then
        while IFS= read -r line; do
            line="${line%%#*}"; line="${line// /}"
            [ -n "$line" ] && packages+=("$line")
        done < "$source_list"
    fi

    [ ${#packages[@]} -eq 0 ] && return 0
    printf '%s\n' "${packages[@]}" | awk 'NF && !seen[$0]++'
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

##############################################################################
# cports tree preparation / reset (GAP §3.1)
#
# The pinned cports checkout is treated as immutable input: before any cbuild
# invocation the packages stage applies every build/patches/cports/*.patch
# and overlays the astro-cports/ shadow templates onto it; after the stage
# finishes (success OR failure) the tree is reset to the pristine pin.
#
# Why overlay-copy instead of a separate cbuild collection: cbuild has no
# out-of-tree collection support — template categories are subdirectories of
# the cports checkout itself ([build] categories in etc/config.ini, default
# "main user"), and symlinked category/template dirs are defeated by
# sanitize_pkgname()'s Path.resolve() (the resolved parent dir name becomes
# the category, and name-based lookups always go through paths.distdir()).
# Copying astro-cports/<cat>/<pkg> over cports/<cat>/<pkg> gives exact
# shadowing semantics (the upstream template is gone for the duration of the
# stage) and the reset restores the pin.
##############################################################################

prepare_cports_tree() {
    local cbuild_dir="${PROJECT_ROOT}/cports"
    [ -d "${cbuild_dir}/.git" ] || \
        die "cports checkout not found (or not a git checkout) at ${cbuild_dir}.\n  cports is Astro's fork, managed by Harbormaster; run 'hm sync --locked' to materialize it."

    # Astro's patches/overrides/new packages now live IN the fork (see
    # cports/README.md). Nothing to overlay at build time. The escape
    # hatch below still applies any locally-dropped patch/shadow so an
    # experiment doesn't require a fork commit; normally there are none.
    log_step "Preparing cports tree (fork; local escape-hatch overlays if any)..."

    local patch applied=0
    for patch in "${PROJECT_ROOT}"/build/patches/cports/*.patch; do
        [ -f "$patch" ] || continue
        if git -C "$cbuild_dir" apply --check "$patch" 2>/dev/null; then
            git -C "$cbuild_dir" apply "$patch" || die "git apply failed for ${patch}"
            log_info "  local PATCH applied: $(basename "$patch")"
            applied=$((applied + 1))
        fi
    done

    local tmpl pkg cat shadows=0
    for tmpl in "${PROJECT_ROOT}"/astro-cports/*/*/template.py; do
        [ -f "$tmpl" ] || continue
        pkg="$(basename "$(dirname "$tmpl")")"
        cat="$(basename "$(dirname "$(dirname "$tmpl")")")"
        log_info "  local SHADOW: astro-cports/${cat}/${pkg}"
        mkdir -p "${cbuild_dir}/${cat}/${pkg}"
        rsync -a --delete "${PROJECT_ROOT}/astro-cports/${cat}/${pkg}/" \
                          "${cbuild_dir}/${cat}/${pkg}/"
        shadows=$((shadows + 1))
    done
    if [ "$shadows" -gt 0 ]; then
        (cd "$cbuild_dir" && ./cbuild relink-subpkgs > /dev/null 2>&1) || \
            log_warn "cbuild relink-subpkgs failed (continuing)"
    fi

    if [ "$applied" -eq 0 ] && [ "$shadows" -eq 0 ]; then
        log_info "cports fork tree used as-is (no local overlays)"
    else
        log_info "cports tree prepared: ${applied} local patch(es), ${shadows} local shadow(s)"
    fi
}

reset_cports_tree() {
    local cbuild_dir="${PROJECT_ROOT}/cports"
    [ -d "${cbuild_dir}/.git" ] || return 0

    # Restore the fork tree to its committed HEAD (undoes any escape-hatch
    # overlay + cbuild's in-place edits). NOT -x: cports/.gitignore covers
    # bldroot*, cbuild_cache, packages*, pkgstage*, sources*, etc/keys and
    # etc/config.ini, so build state, distfiles and signing keys survive.
    log_step "Resetting cports fork tree to its committed HEAD..."
    git -C "$cbuild_dir" checkout -- . || log_warn "git checkout in cports failed"
    git -C "$cbuild_dir" clean -fd -e keygen.log | sed 's/^/  /' || \
        log_warn "git clean in cports failed"
    log_info "cports fork tree reset"
}

##############################################################################
# Distfile fetch resilience (GAP §3.3)
#
# gitlab.alpinelinux.org (and potentially other hosts) sits behind Anubis,
# which answers cbuild's Python-urllib fetcher with HTTP 418; plain curl with
# its default UA passes. On a cbuild failure that looks like a distfile
# fetch error, we resolve the template's source URLs + sha256 via
# './cbuild dump', download with curl -L into cports/sources/<name>-<ver>/,
# verify checksums, and re-run the build exactly once. cbuild itself skips
# fetching any distfile that is already present with a good checksum.
##############################################################################

# Build one template via cbuild, with the bounded fetch-retry described above.
# Output is streamed AND captured to build/state/logs/cbuild-<tmpl>-<arch>.log.
cbuild_pkg() {
    local arch="$1" tmpl="$2"
    local cbuild_dir="${PROJECT_ROOT}/cports"
    local logs_dir="${PROJECT_ROOT}/build/state/logs"
    mkdir -p "$logs_dir"
    local logf="${logs_dir}/cbuild-${tmpl//\//-}-${arch}.log"
    local rc=0

    log_info "Building: ${tmpl} (log: ${logf})"
    (cd "$cbuild_dir" && ./cbuild -a "$arch" pkg "$tmpl" 2>&1 | tee "$logf"
     exit "${PIPESTATUS[0]}") || rc=$?
    [ "$rc" -eq 0 ] && return 0

    # Fetch failure? (cbuild: "error fetching '<f>' (<url>): <err>" then
    # "failed to fetch N sources"). The failing template is often a
    # DEPENDENCY built inside the same invocation (e.g. readline while
    # building dinit-chimera — savannah's cgit answers urllib with 400),
    # so the curl fallback fetches the distfiles of every template that
    # reported a fetch error, not just ${tmpl} (M1 wave 2).
    if grep -qE "failed to fetch [0-9]+ sources|error fetching '" "$logf"; then
        log_warn "Distfile fetch failure under ${tmpl} — retrying once via curl (Anubis/cgit workaround, GAP §3.3)"
        # "<name>-<pkgver>-r<rel>: ERROR: failed to fetch" -> template name
        # (pkgver and rel never contain dashes, same rule as
        # local_repo_version in rootfs.sh)
        local failed_tmpls fetch_ok=true t base
        failed_tmpls=$(grep -oE '=> [A-Za-z0-9._+-]+: ERROR: failed to fetch' "$logf" \
            | sed -E 's/^=> //; s/: ERROR: failed to fetch$//; s/-[^-]+-r[0-9]+$//' | sort -u)
        [ -n "$failed_tmpls" ] || failed_tmpls="${tmpl##*/}"
        for t in $failed_tmpls; do
            base="$t"
            [ -d "${cbuild_dir}/main/${t}" ] && base="main/${t}"
            [ -d "${cbuild_dir}/user/${t}" ] && base="user/${t}"
            log_info "  curl-fetching distfiles for ${base}"
            if ! (cd "$cbuild_dir" && ./cbuild -a "$arch" dump "$base" 2>/dev/null) \
                 | python3 "${PROJECT_ROOT}/build/lib/fetch_distfiles.py" "$cbuild_dir"; then
                log_error "Manual distfile fetch failed for ${base}"
                fetch_ok=false
            fi
        done
        if [ "$fetch_ok" = true ]; then
            log_info "Manual distfile fetch OK — re-running cbuild for ${tmpl}"
            rc=0
            (cd "$cbuild_dir" && ./cbuild -a "$arch" pkg "$tmpl" 2>&1 | tee -a "$logf"
             exit "${PIPESTATUS[0]}") || rc=$?
            [ "$rc" -eq 0 ] && return 0
        fi
    fi

    log_error "cbuild failed for ${tmpl} (rc=${rc}), see ${logf}"
    return "$rc"
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

        # Check if package exists in cports (after prepare_cports_tree the
        # astro-cports shadow templates are present in the tree as well).
        # Names without a template dir (subpackages like dhcpcd-dinit,
        # virtual providers, ...) are resolved by the closure pass instead.
        if [ ! -d "${cbuild_dir}/main/${pkg}" ] && [ ! -d "${cbuild_dir}/user/${pkg}" ]; then
            log_info "No template dir for '${pkg}' — deferred to closure resolution"
            continue
        fi

        local repo="main"
        [ -d "${cbuild_dir}/user/${pkg}" ] && repo="user"

        if ! cbuild_pkg "$arch" "${repo}/${pkg}"; then
            failed+=("$pkg")
        fi
    done < "$manifest_file"

    if [ ${#failed[@]} -gt 0 ]; then
        log_error "Failed packages: ${failed[*]}"
        return 1
    fi

    log_info "All listed packages built successfully"
}

##############################################################################
# Dependency-closure resolution (GAP §3.4)
#
# After the listed templates are built, the repo must be able to satisfy the
# *runtime* closure of the full manifest. Each round:
#   1. regenerate the signed local index ('./cbuild index' → apk mkndx
#      --sign-key; NOTE: raw 'apk mkndx' without keys exits 127 silently,
#      see MIGRATION-NOTES — cbuild's wrapper always signs with the dev key)
#   2. dry-run the manifest install (apk --simulate) against the local repo
#      (+ Chimera's binary repo in binary packages-mode)
#   3. parse unsatisfied deps (name / so: / pc: / cmd:), map them to cports
#      templates (template dirs, subpackage decorators, and the Chimera
#      index as a provider->origin oracle) and build the missing templates
# ...until convergence, capped at 10 rounds.
##############################################################################

# Refresh + sign the local repo index.
#
# The old index is deleted first: 'cbuild index' passes the existing
# Packages.adb to 'apk mkndx --index' as a cache, and mkndx then KEEPS
# entries for .apk files that no longer exist on disk (observed: removed
# packages still resolved in the closure dry-run). Rebuilding from scratch
# hashes every package (a few seconds) and yields a truthful index.
refresh_local_index() {
    local arch="$1"
    local cbuild_dir="${PROJECT_ROOT}/cports"
    # NOTE: deliberately not ASTRO_LOCAL_REPO — 'cbuild index' only manages
    # the repos under cports/packages; an override repo (filtered CI copy)
    # brings its own index and is left untouched.
    local repo="${cbuild_dir}/packages/main/${arch}"
    [ -d "$repo" ] || { log_warn "no local repo dir at ${repo} yet"; return 0; }
    log_info "Regenerating signed local repo index from scratch (cbuild index)..."
    # APKINDEX.tar.gz is a hardlink to Packages.adb (cbuild compat link).
    # Without the old index present, cbuild's mkndx wrapper builds a fresh
    # one from the .apk files actually on disk. The repo path must be given
    # explicitly — bare './cbuild index' discovers repos BY their existing
    # index files and would skip the repo entirely after this rm.
    rm -f "${repo}/Packages.adb" "${repo}/APKINDEX.tar.gz"
    (cd "$cbuild_dir" && ./cbuild -a "$arch" index packages/main) || \
        die "cbuild index failed — local repo index unusable"
}

# Fetch (cached) Chimera Packages.adb and adbdump it for the mapping oracle.
# Best-effort: prints the dump path, or nothing when unavailable.
chimera_index_dump() {
    local arch="$1"
    local chimera_repo="${ASTRO_CHIMERA_REPO:-https://repo.chimera-linux.org/current/main}"
    local cache_dir="${PROJECT_ROOT}/build/state/cache"
    mkdir -p "$cache_dir"
    local ndx="${cache_dir}/chimera-Packages-${arch}.adb"
    local dump="${cache_dir}/chimera-Packages-${arch}.txt"

    if [ ! -f "$dump" ] || [ ! -f "$ndx" ]; then
        curl -sfL -o "$ndx" "${chimera_repo}/${arch}/Packages.adb" 2>/dev/null || true
    fi
    if [ -f "$ndx" ] && { [ ! -f "$dump" ] || [ "$ndx" -nt "$dump" ]; }; then
        apk adbdump "$ndx" > "$dump" 2>/dev/null || rm -f "$dump"
    fi
    [ -f "$dump" ] && echo "$dump"
    return 0
}

# Resolve the runtime dependency closure of the manifest.
#   $1 = arch, $2 = manifest file, $3 = packages-mode (source|binary)
resolve_dependency_closure() {
    local arch="$1" manifest_file="$2" mode="$3"
    local cbuild_dir="${PROJECT_ROOT}/cports"
    local logs_dir="${PROJECT_ROOT}/build/state/logs"
    local pkg_repo_base="${ASTRO_LOCAL_REPO:-${cbuild_dir}/packages/main}"
    local chimera_repo="${ASTRO_CHIMERA_REPO:-https://repo.chimera-linux.org/current/main}"
    mkdir -p "$logs_dir"

    log_step "Resolving runtime dependency closure (${mode} packages-mode)..."

    # Scratch apk root + trusted keys for the dry-run
    local work
    work=$(mktemp -d "${PROJECT_ROOT}/build/state/closure.XXXXXX")
    mkdir -p "${work}/keys" "${work}/root"
    local key have_key=false
    for key in "${cbuild_dir}"/etc/keys/*.pub; do
        [ -f "$key" ] && cp "$key" "${work}/keys/" && have_key=true
    done
    [ "$have_key" = true ] || { rm -rf "$work"; die "no cbuild dev pubkeys in cports/etc/keys — cannot verify the local repo index"; }
    if [ "$mode" = "binary" ]; then
        for key in "${PROJECT_ROOT}"/build/keys/chimera/*.pub; do
            [ -f "$key" ] && cp "$key" "${work}/keys/"
        done
    fi

    {
        echo "v3 ${pkg_repo_base}"
        if [ "$mode" = "binary" ]; then
            echo "v3 ${chimera_repo}"
        fi
    } > "${work}/repositories"

    # The mapping oracle (used for so:/pc:/cmd: and subpackage names).
    local oracle
    oracle=$(chimera_index_dump "$arch")
    [ -n "$oracle" ] || log_warn "Chimera index unavailable — closure mapping falls back to template-tree search only"

    local round rc=0 built_any
    local -A attempted=()
    for round in $(seq 1 10); do
        refresh_local_index "$arch"

        # apk needs an initialized db even for --simulate
        rm -rf "${work}/root"; mkdir -p "${work}/root"
        apk --root "${work}/root" --arch "$arch" --keys-dir "${work}/keys" \
            --repositories-file "${work}/repositories" \
            --usermode --initdb add >/dev/null 2>&1 || true

        local errf="${logs_dir}/closure-round${round}-${arch}.log"
        rc=0
        # shellcheck disable=SC2046
        apk --root "${work}/root" --arch "$arch" --keys-dir "${work}/keys" \
            --repositories-file "${work}/repositories" \
            --usermode --simulate add $(grep -v '^[[:space:]]*$' "$manifest_file") \
            > "$errf" 2>&1 || rc=$?

        if [ "$rc" -eq 0 ]; then
            log_info "Dependency closure converged after ${round} round(s)"
            rm -rf "$work"
            return 0
        fi

        log_info "Closure round ${round}: unsatisfied dependencies (${errf}):"
        grep -E "no such package|required by" "$errf" | sed 's/^/    /' || sed 's/^/    /' "$errf"

        # Map unsatisfied deps to templates
        local mapf="${logs_dir}/closure-round${round}-${arch}.templates"
        if ! python3 "${PROJECT_ROOT}/build/lib/closure_map.py" \
                --errors "$errf" --cports "$cbuild_dir" \
                ${oracle:+--index-dump "$oracle"} > "$mapf"; then
            log_error "Could not map any unsatisfied dependency to a cports template:"
            sed 's/^/    /' "$mapf" >&2 || true
            rm -rf "$work"
            die "dependency closure unresolvable (round ${round}) — see ${errf}"
        fi

        built_any=false
        local tmpl
        while IFS= read -r tmpl; do
            [ -z "$tmpl" ] && continue
            if [ -n "${attempted[$tmpl]:-}" ]; then
                log_warn "Template ${tmpl} was already built this run but deps are still unsatisfied"
                continue
            fi
            attempted[$tmpl]=1
            if ! cbuild_pkg "$arch" "$tmpl"; then
                rm -rf "$work"
                die "closure build failed for ${tmpl}"
            fi
            built_any=true
        done < "$mapf"

        if [ "$built_any" = false ]; then
            rm -rf "$work"
            die "dependency closure made no progress in round ${round} — unresolved deps in ${errf}"
        fi
    done

    rm -rf "$work"
    die "dependency closure did not converge after 10 rounds — see ${logs_dir}/closure-round*-${arch}.log"
}
