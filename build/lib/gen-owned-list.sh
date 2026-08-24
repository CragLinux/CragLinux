#!/bin/bash
set -euo pipefail
# Regenerate build/cports-owned.list from the fork delta. Needs the FULL
# fork history (not a shallow CI checkout); run it after every re-pin.
#
# new = template added by Crag (not in Chimera's repo) -> always source-built
# mod = template Crag modified (exists upstream, differs) -> source-built
#       only when an image installs it (binary packages-mode)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CP="${ROOT}/cports"
FORK_POINT="$(cat "${ROOT}/build/cports-fork-point")"
OUT="${ROOT}/build/cports-owned.list"

{
    echo "# Templates Crag maintains in the cports fork (fork delta vs the"
    echo "# fork point in build/cports-fork-point). Second field:"
    echo "#   new = not in Chimera's repo -> always built from source"
    echo "#   mod = exists upstream, we differ -> source-built only when installed"
    echo "# Regenerate with build/lib/gen-owned-list.sh after every re-pin"
    echo "# (needs full fork history, not a shallow CI checkout)."
    git -C "$CP" diff --name-status "${FORK_POINT}..HEAD" \
        | grep 'template\.py$' \
        | while IFS=$'\t' read -r st path; do
            pkg=$(printf '%s' "$path" | sed -n 's#^\(main\|user\)/\([^/]*\)/template\.py$#\2#p')
            [ -z "$pkg" ] && continue
            case "$st" in
                A) echo "$pkg new" ;;
                M) echo "$pkg mod" ;;
            esac
        done | sort -u
} > "$OUT"

echo "wrote $OUT ($(grep -vc '^#' "$OUT") templates)"
