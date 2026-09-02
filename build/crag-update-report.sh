#!/bin/bash
set -euo pipefail

# Crag Linux - cports update-currency report (host entry point).
#
# Sweeps the forked port tree with cbuild's update-check machinery and
# writes a JSON+Markdown report of packages with newer upstream releases,
# prioritized by shipped/Crag-owned so an agent (or a human) can work
# the list down. Owning the fork means owning version currency; this is
# the tool that makes that tractable (see cports/README.md "Why a fork").
#
# Runs inside crag-builder (cbuild + network live there).
#
# Usage:
#   ./build/crag-update-report.sh [--scope crag|shipped|all] [--jobs N]
#     crag    (default) only the Crag-maintained fork delta — fast
#     shipped  packages installed in some image — the security-currency set
#     all      the whole tree — the nightly full sweep

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ ! -f /run/.containerenv ] && [ ! -f /.dockerenv ]; then
    ENGINE="${CONTAINER_ENGINE:-$(command -v podman >/dev/null && echo podman || echo docker)}"
    IMAGE_NAME="${CONTAINER_IMAGE:-crag-builder}"
    exec "$ENGINE" run --rm --userns=keep-id --privileged \
        -v "${PROJECT_ROOT}:/workspace:Z" "$IMAGE_NAME" \
        -c "cd /workspace && ./build/crag-update-report.sh $*"
fi

# cbuild refuses every command (even the read-only update-check) without a
# signing key (cports/src/runner.py). Generate a throwaway dev key into
# cports/etc/{config.ini,keys} — both are covered by cports/.gitignore.
if ! grep -q '^key' "${PROJECT_ROOT}/cports/etc/config.ini" 2>/dev/null; then
    (cd "${PROJECT_ROOT}/cports" && ./cbuild keygen "cbuild-ci@localhost" 4096)
fi

python3 "${SCRIPT_DIR}/lib/update_report.py" "$@"
