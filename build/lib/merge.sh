#!/bin/bash
# Astro Linux - External-tree merge engine (docs/08 §4)
# Sourced by build-inner.sh / rootfs-stage.sh, not executed directly.
#
# Every function here consumes the ORDERED LAYER LIST produced by
# build/lib/layers.py (exported as $LAYERS_JSON — a file holding the JSON
# array; see that module for the contract). The array is already in final
# merge order: element 0 is applied first (lowest precedence), the last
# element wins. Consumers walk it in order and NEVER re-sort.
#
# Layer object: {kind: core|tree|board|variant, name, path, priority}.
# Per-kind overlay/packages/hooks source paths (docs/08 §2 layout):
#   core/tree/board : <path>/overlay , <path>/packages.list , <path>/hooks/*.sh
#   variant         : <variant-file-without-.toml>/overlay (config only)
#
# STATUS (M4 phase 0): WIRED. merge_packages_list / merge_hooks / merge_overlays
# drive the live build — build-inner.sh writes the manifest from
# merge_packages_list, and the rootfs stage (rootfs.sh apply_overlays/run_hooks)
# delegates to merge_overlays/merge_hooks. merge_cports_collections is the
# authoritative detector; packages.sh:overlay_tree_cports consumes its plan and
# does the copy/relink. With no --external tree the layer list is
# [core, board(, variant)] and every one of these is byte-identical to the
# pre-phase-0 behavior (regression-tested), so current fleet CI stays green.

# Emit the layer paths of the given kinds, in array (merge) order.
#   _merge_layer_paths <layers_json_file> <kind> [<kind> ...]
_merge_layer_paths() {
    local layers_json="$1"; shift
    local sel="" k
    for k in "$@"; do
        sel="${sel:+${sel} or }.kind==\"${k}\""
    done
    jq -r ".[] | select(${sel}) | .path" "$layers_json"
}

##############################################################################
# merge_packages_list <layers_json> -> stdout
#
# Contract (docs/08 §4, packages.list = ADDITIVE ONLY): concatenate, in merge
# order, boards/common/packages.list + every tree's packages.list + the board's
# packages.list, then append board.toml [firmware].packages and variant
# [packages].install (which ACCUMULATES). Deduplicate preserving first
# occurrence. There is NO removal syntax — masking a base package is forbidden
# (docs/08 §4; use the docs/02 §2 tiers to ship less). Output: one package per
# line, deduplicated.
#
# Reads $BOARD_CONFIG_JSON / $VARIANT_CONFIG_JSON from the environment for the
# firmware + variant contributions (both exported by build-inner.sh). This is
# the layer-driven successor to packages.sh:resolve_package_list.
##############################################################################
merge_packages_list() {
    local layers_json="${1:-$LAYERS_JSON}"
    local -a pkgs=()
    local lpath line f

    while IFS= read -r lpath; do
        f="${lpath}/packages.list"
        [ -f "$f" ] || continue
        while IFS= read -r line; do
            line="${line%%#*}"      # strip comments
            line="${line// /}"      # strip whitespace
            [ -n "$line" ] && pkgs+=("$line")
        done < "$f"
    done < <(_merge_layer_paths "$layers_json" core tree board)

    if [ -n "${BOARD_CONFIG_JSON:-}" ]; then
        while IFS= read -r line; do
            [ -n "$line" ] && pkgs+=("$line")
        done < <(echo "$BOARD_CONFIG_JSON" | jq -r '.firmware.packages // [] | .[]')
    fi
    if [ -n "${VARIANT_CONFIG_JSON:-}" ]; then
        while IFS= read -r line; do
            [ -n "$line" ] && pkgs+=("$line")
        done < <(echo "$VARIANT_CONFIG_JSON" | jq -r '.packages.install // [] | .[]')
    fi

    [ ${#pkgs[@]} -eq 0 ] && return 0
    printf '%s\n' "${pkgs[@]}" | awk 'NF && !seen[$0]++'
}

##############################################################################
# merge_hooks <layers_json> -> stdout (ordered hook file paths, one per line)
#
# Contract (docs/08 §4, hooks): hooks from ALL layers are interleaved by their
# numeric filename prefix across layers (10-core.sh, 60-acme.sh, 90-board.sh
# run in numeric order regardless of which layer contributed them); a tie on
# the number falls back to layer (array) order. Non-numeric prefixes sort last
# (bucket 99999). The caller sources the paths in the printed order.
##############################################################################
merge_hooks() {
    local layers_json="${1:-$LAYERS_JSON}"
    local lpath hook base num idx=0

    while IFS= read -r lpath; do
        if [ -d "${lpath}/hooks" ]; then
            for hook in "${lpath}/hooks"/*.sh; do
                [ -f "$hook" ] || continue
                base="$(basename "$hook")"
                num="${base%%-*}"
                case "$num" in
                    ''|*[!0-9]*) num=99999 ;;
                esac
                # <numeric-prefix>\t<layer-index>\t<path>; stable-sort on the
                # first two numeric keys, then strip them.
                printf '%05d\t%05d\t%s\n' "$((10#$num))" "$idx" "$hook"
            done
        fi
        idx=$((idx + 1))
    done < <(_merge_layer_paths "$layers_json" core tree board) \
        | sort -s -k1,1n -k2,2n \
        | cut -f3-
}

##############################################################################
# THE CODE/CONFIG FENCE (docs/08 §3, AD-017)
#
# Apps ship as apk packages; overlays are NON-EXECUTABLE CONFIGURATION ONLY.
# The fence is MECHANICAL, not honor-system: merge_overlays calls fence_check
# on EVERY incoming overlay file (from EVERY layer — core, tree, board,
# variant) and the build DIES if that file would install executable code via
# the overlay path. Two independent rejection rules:
#
#   (1) PATH  — a file landing under usr/bin/ or usr/sbin/ is ALWAYS rejected;
#       a file under usr/lib/ is rejected UNLESS it sits in a known,
#       non-executable data/config/hook directory (FENCE_USR_LIB_ALLOW below).
#       usr/lib/os-release is the one allowed exact file.
#   (2) ELF   — a regular file whose first four bytes are the ELF magic
#       (7f 45 4c 46) is rejected ANYWHERE in the overlay, whatever its path.
#
# Symlinks are PATH-checked (rule 1) but never ELF-probed (rule 2 would read
# the link target's bytes): the code a symlink points at must itself live in
# an allowed location to have passed the fence in its own right.
#
# MERGED-USR: this image is merged-/usr (base-files ships bin -> usr/bin,
# sbin -> usr/sbin, lib -> usr/lib as symlinks; see rootfs.sh). An overlay
# dropping "bin/evil" therefore lands at "usr/bin/evil" on the live system and
# would EVADE a fence that only matched the "usr/" spelling. Rule 1 closes this
# by canonicalizing a leading bin/, sbin/, lib/ (and lib64/) segment to its
# usr/ form BEFORE the path test, so both spellings of the same directory are
# fenced identically. This is enforcement of the exact AD-017 rule, not a new
# fenced location. (usr/local/** and opt/** are other executable-capable dirs
# outside AD-017's enumeration — see the FOLLOWUP note in the audit if that
# ever needs tightening.)
#
# FENCE_USR_LIB_ALLOW — the allowed usr/lib data/config/hook subtrees. Each
# entry X permits "usr/lib/X" and "usr/lib/X/**". These are distro MECHANISM
# directories (dinit service TEXT files, tmpfiles/sysctl/modules-load/udev
# rules, firmware blobs, os-release drop-ins, the astro platform-script dir,
# the dhcpcd hook dir), NOT places an app drops a binary. Keep this list
# TIGHT and documented — every entry widens the fence.
#
# AUDIT (M4 phase 1): every existing Astro overlay (boards/common/overlay and
# each boards/*/overlay) passes this fence. The one non-obvious entry is
# `dhcpcd-hooks`: boards/common ships usr/lib/dhcpcd-hooks/60-astro-lease, a
# SYMLINK into the allowed usr/lib/astro/dhcpcd-hook.sh. dhcpcd only sources
# hooks from its compiled-in hook dir (usr/lib/dhcpcd-hooks), so the wiring
# legitimately must live under usr/lib — it is a platform mechanism dir, not
# app code (the actual script is in the allowlisted usr/lib/astro/). This is
# recorded as a real audit finding, not a silent carve-out.
#
# Full audit result (M4 phase 1 harden pass): 34 overlay entries across
# boards/common/overlay (the only populated overlay tree; boards/*/overlay are
# empty). ALL pass. Zero ELF files anywhere. Notable entries verified:
#   - usr/lib/astro/*.sh                -> allowed (astro platform-script dir)
#   - usr/lib/dinit.d/* (via etc + usr) -> dinit service TEXT, allowed
#   - usr/lib/{tmpfiles.d,os-release}   -> allowed data/config
#   - usr/lib/dhcpcd-hooks/60-astro-lease -> SYMLINK, allowlisted dir (above)
#   - usr/libexec/astro/mark-good       -> #!/bin/sh TEXT, and usr/libexec is
#                                          NOT a fenced path (AD-017 fences
#                                          usr/{bin,sbin,lib} only); passes.
# FOLLOWUP (surfaced, NOT actioned here — outside AD-017's enumeration): the
# fence does not cover usr/local/{bin,sbin,lib}/** or opt/** (executable-capable
# but not merged-/usr aliases of the fenced dirs). No overlay uses them today.
# If a future tree tries to, the integrate agent should decide whether AD-017's
# path set grows; left as a documented gap rather than a silent expansion.
##############################################################################
FENCE_ELF_MAGIC=$'\x7fELF'
FENCE_USR_LIB_ALLOW=(
    astro           # usr/lib/astro/**         platform helper scripts (docs/02 §7)
    dinit.d         # usr/lib/dinit.d/**       dinit service TEXT files (allowed, §3)
    tmpfiles.d      # usr/lib/tmpfiles.d/**    systemd-tmpfiles config
    sysctl.d        # usr/lib/sysctl.d/**      kernel sysctl config
    modules-load.d  # usr/lib/modules-load.d/** module autoload lists
    os-release.d    # usr/lib/os-release.d/**  os-release drop-ins
    udev/rules.d    # usr/lib/udev/rules.d/**  udev rules (text)
    firmware        # usr/lib/firmware/**      device firmware blobs (data)
    dhcpcd-hooks    # usr/lib/dhcpcd-hooks/**  dhcpcd lease hook dir (see AUDIT above)
)

# _fence_die <dest_relpath> <layer_name> <why>
# Emit the precise AD-017 error (file + layer + reason + the fix) and exit.
_fence_die() {
    die "code/config fence (AD-017, docs/08 §3): overlay layer '${2}' file '${1}' — ${3}.
       Fix: ship it as an apk TEMPLATE in the tree's cports/ collection
       (docs/08 §3, AD-017) so it installs into the image's apk world;
       overlays are restricted to non-executable configuration."
}

# fence_check <incoming_file_abs> <dest_relpath> <layer_name>
# Dies (exit 1) if <dest_relpath>/<incoming_file_abs> violates AD-017.
# <dest_relpath> is relative to the rootfs (no leading slash), e.g.
# "usr/bin/foo" or "etc/acme/x.conf". Returns 0 on a passing file.
fence_check() {
    local file="$1" rel="$2" layer="$3"

    # ---- rule 1: fenced install paths ---------------------------------------
    # Canonicalize merged-/usr aliases to their usr/ spelling first, so bin/,
    # sbin/, lib/, lib64/ are fenced identically to usr/bin, usr/sbin, usr/lib
    # (they ARE those dirs on this image — see MERGED-USR note above). The
    # ORIGINAL rel is what we report to the operator; canon drives the test.
    local canon="$rel"
    case "$rel" in
        bin/*|sbin/*|lib/*) canon="usr/${rel}" ;;
        lib64/*)            canon="usr/lib/${rel#lib64/}" ;;
    esac
    case "$canon" in
        usr/bin/*|usr/sbin/*)
            _fence_die "$rel" "$layer" \
                "overlay files may not install under (usr/)bin or (usr/)sbin — executable path"
            ;;
        usr/lib/os-release)
            : ;;  # the one allowed exact file
        usr/lib/*)
            # Prefix match is /-anchored so usr/lib/astro/ is allowed but a
            # sibling like usr/lib/astro-evil/ (which shares the "astro" prefix
            # but is a DIFFERENT dir) is NOT: entry must equal $sub exactly, or
            # be a full leading path segment (entry + "/").
            local sub="${canon#usr/lib/}" allowed="" entry
            for entry in "${FENCE_USR_LIB_ALLOW[@]}"; do
                if [ "$sub" = "$entry" ] || [ "${sub#"${entry}"/}" != "$sub" ]; then
                    allowed=1; break
                fi
            done
            [ -n "$allowed" ] || _fence_die "$rel" "$layer" \
                "(usr/)lib is fenced; not in a known data/config dir (allowed subtrees: ${FENCE_USR_LIB_ALLOW[*]}; plus the exact file usr/lib/os-release)"
            ;;
    esac

    # ---- rule 2: no ELF binaries anywhere -----------------------------------
    # Regular files only: skip symlinks (a link's first bytes are the target's,
    # and that target is fence-checked in its own, allowed, location) and skip
    # anything that is not a plain file (dirs/fifos/devices never reach here
    # from find's -type f/-l, but guard anyway). LC_ALL=C keeps the 4-byte read
    # byte-exact regardless of the caller's locale; the ELF magic contains no
    # NUL/newline so command substitution preserves it verbatim.
    if [ ! -L "$file" ] && [ -f "$file" ]; then
        local magic
        magic=$(LC_ALL=C head -c4 "$file" 2>/dev/null)
        if [ "$magic" = "$FENCE_ELF_MAGIC" ]; then
            _fence_die "$rel" "$layer" \
                "file is an ELF binary (magic 7f 45 4c 46); apps ship as apk, never as overlay files"
        fi
    fi
}

##############################################################################
# merge_overlays <layers_json> <rootfs_dir>
#
# Contract (docs/08 §4, overlays): apply each layer's overlay tree in merge
# order, file-level LAST-WRITER-WINS, and LOG every override with provenance
# ("overlay: <tree>/etc/foo overrides <prev>/etc/foo"). Overlays are config
# only (docs/08 §3 AD-017) — the code/config fence is enforced at the marked
# seam by the M4 phase-1 agent.
#
# Reference implementation: copies each overlay file individually so a prior
# owner can be detected for provenance. process_templates() (rootfs.sh) runs
# afterwards, unchanged. This is the layer-driven successor to
# rootfs.sh:apply_overlays.
##############################################################################
merge_overlays() {
    local layers_json="${1:-$LAYERS_JSON}"
    local rootfs_dir="$2"
    local layer kind name path src f rel prev
    declare -A _ov_owner=()

    log_step "Merging overlays (${layers_json})..."

    while IFS= read -r layer; do
        kind=$(jq -r '.kind' <<< "$layer")
        name=$(jq -r '.name' <<< "$layer")
        path=$(jq -r '.path' <<< "$layer")
        case "$kind" in
            core|tree|board) src="${path}/overlay" ;;
            variant)         src="${path%.toml}/overlay" ;;
            *)               continue ;;
        esac
        [ -d "$src" ] || continue
        log_info "  overlay layer: ${name} (${src})"

        while IFS= read -r -d '' f; do
            rel="${f#"$src"/}"

            # ---- CODE/CONFIG FENCE (docs/08 §3, AD-017) --------------------
            # Per-incoming-file, EVERY layer. Dies the build if this overlay
            # file would install executable code (fenced path or ELF). See
            # fence_check + FENCE_USR_LIB_ALLOW above.
            fence_check "$f" "$rel" "$name"

            prev="${_ov_owner[$rel]:-}"
            [ -n "$prev" ] && \
                log_info "  overlay: ${name}/${rel} overrides ${prev}/${rel}"
            mkdir -p "${rootfs_dir}/$(dirname "$rel")"
            cp -a "$f" "${rootfs_dir}/${rel}"
            _ov_owner[$rel]="$name"
        done < <(find "$src" \( -type f -o -type l \) -print0)
    done < <(jq -c '.[]' "$layers_json")

    process_templates "$rootfs_dir"
    log_info "Overlays merged"
}

##############################################################################
# merge_cports_collections <layers_json> <cports_dir>
#
# Contract (docs/08 §4, cports collections + docs/03 §1 AD-027 fork model):
# every tree's cports/ is an ADDITIONAL cbuild collection layered on the fork.
# Precedence: fork (base) is shadowed by tree collections in ASCENDING priority
# (higher-priority tree wins). Rules:
#   * a tree template that shadows a same-NAME fork template is ALLOWED but must
#     be build-flagged LOUDLY (log_warn).
#   * two trees providing the same template name is a HARD ERROR unless the two
#     template.py files are byte-identical.
# cbuild has no out-of-tree collection support (see packages.sh header): the
# real wiring copies <tree>/cports/<cat>/<pkg> over cports/<cat>/<pkg> exactly
# like prepare_cports_tree(), then relinks subpkgs, and the reset restores the
# pin. This function ships as DETECTION ONLY (the contract-critical part) and
# prints the resolved shadow plan; the copy/relink + reset wiring is a TODO for
# the M4 packages fill agent.
#
# Output (stdout): one line per resolved shadow, "<cat>/<pkg>\t<tree-name>", in
# apply order (ascending tree priority — later lines win). Nonzero exit on a
# hard conflict.
##############################################################################
merge_cports_collections() {
    local layers_json="${1:-$LAYERS_JSON}"
    local cports_dir="$2"
    local layer name path tmpl cat pkg key
    declare -A _cp_owner=() _cp_src=()
    local rc=0

    # Tree layers only, in array order (already ascending priority).
    while IFS= read -r layer; do
        name=$(jq -r '.name' <<< "$layer")
        path=$(jq -r '.path' <<< "$layer")
        [ -d "${path}/cports" ] || continue
        for tmpl in "${path}"/cports/*/*/template.py; do
            [ -f "$tmpl" ] || continue
            pkg="$(basename "$(dirname "$tmpl")")"
            cat="$(basename "$(dirname "$(dirname "$tmpl")")")"
            key="${cat}/${pkg}"

            # Two trees, same template name -> hard error unless byte-identical.
            if [ -n "${_cp_owner[$key]:-}" ]; then
                if cmp -s "${_cp_src[$key]}" "$tmpl"; then
                    log_warn "cports: '${key}' provided identically by '${_cp_owner[$key]}' and '${name}' — using higher-priority '${name}'"
                else
                    log_error "cports: template '${key}' provided by BOTH '${_cp_owner[$key]}' and '${name}' with differing contents — hard error (docs/08 §4)"
                    rc=1
                fi
            elif [ -n "$cports_dir" ] && [ -f "${cports_dir}/${key}/template.py" ]; then
                # Shadowing a same-name fork template: allowed, flag loudly.
                log_warn "cports: tree '${name}' template '${key}' SHADOWS the fork's template (docs/08 §4) — allowed, flagged"
            fi

            _cp_owner[$key]="$name"
            _cp_src[$key]="$tmpl"
            printf '%s\t%s\n' "$key" "$name"
        done
    done < <(jq -c '.[] | select(.kind=="tree")' "$layers_json")

    # TODO(M4 packages fill agent): copy each resolved <tree>/cports/<cat>/<pkg>
    # over ${cports_dir}/<cat>/<pkg> (rsync -a --delete, like
    # packages.sh:prepare_cports_tree), run './cbuild relink-subpkgs', and
    # restore the pin in reset_cports_tree afterwards.
    return "$rc"
}
