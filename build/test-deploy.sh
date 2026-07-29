#!/bin/bash
set -euo pipefail

# Astro Linux - AD-026 sideload-loop test (docs/08 §6, M4 phase 3).
#
# Proves the developer deploy loop end-to-end against a RUNNING
# dev-variant QEMU with the acme reference app aboard:
#
#   1. sysroot     the image-derived app sysroot stages (sdk/
#                  stage-sysroot.sh) and the app SDK environment
#                  compiles acme-sensord.c (docs/08 §6 step 1)
#   2. binary      astro-deploy --binary pushes an SDK-rebuilt daemon
#                  carrying a marker, restarts it, and the marker
#                  appears in the service log; drift is recorded
#   3. package     astro-deploy --pkg reinstalls the built apk over
#                  the sideload (drift healed, apk owns the files)
#
# PRECONDITIONS (the CI steps build these first; locally run):
#   ./build/astro-build.sh <board> dev --external=examples/external-tree-acme
#   ./sdk/build-toolchain.sh <arch>        (once per arch)
#
# Usage:
#   ./build/test-deploy.sh <board> [--timeout=SECONDS]
#
# Runs on the host (wraps itself into the astro-builder container) or
# directly inside it. junit + serial log land in build/state/ like the
# other suites.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"    # cbuild_arch_for
source "${SCRIPT_DIR}/lib/testlib.sh"

BOARD="${1:?Usage: $0 <board> [--timeout=SECONDS]}"
VARIANT="dev"
TIMEOUT=180
for arg in "${@:2}"; do
    case "$arg" in
        --timeout=*) TIMEOUT="${arg#--timeout=}" ;;
        *) echo "ERROR: unknown option: $arg"; exit 1 ;;
    esac
done

tl_containerize "build/test-deploy.sh" "$BOARD" "--timeout=${TIMEOUT}"

##############################################################################
# Container side
##############################################################################
tl_init "deploy-${BOARD}" "$BOARD" "$VARIANT"

# Preconditions, with actionable messages.
[ -f "${TL_OUT}/rootfs/usr/lib/dinit.d/acme-sensord" ] || {
    echo "ERROR: ${BOARD}/${VARIANT} image lacks acme-sensord — build it with the tree first:"
    echo "  ./build/astro-build.sh ${BOARD} ${VARIANT} --external=examples/external-tree-acme"
    exit 1
}
BOARD_ARCH=$(python3 "${PROJECT_ROOT}/build/lib/config.py" board \
    "${PROJECT_ROOT}/boards/${BOARD}/board.toml" --format=json | \
    python3 -c 'import json,sys; print(json.load(sys.stdin)["board"]["arch"])')
ls "${PROJECT_ROOT}/build/state/${BOARD_ARCH}/bin/"*-clang >/dev/null 2>&1 || {
    echo "ERROR: SDK toolchain for ${BOARD_ARCH} not built — run: ./sdk/build-toolchain.sh ${BOARD_ARCH}"
    exit 1
}

SSH_PORT=$(( 20000 + RANDOM % 10000 ))
tl_ssh_init

##############################################################################
# case 1: app sysroot stages + the app SDK compiles the reference app
##############################################################################
case_begin "sysroot-${BOARD}"
if "${PROJECT_ROOT}/sdk/stage-sysroot.sh" "$BOARD" "$VARIANT" > "${TL_LOG_DIR}/deploy-sysroot-${BOARD}.log" 2>&1; then
    # shellcheck disable=SC1091
    . "${TL_OUT}/sdk/environment"
    MARKED_SRC="${TL_LOG_DIR}/acme-sensord-marked.c"
    MARKED_BIN="${TL_LOG_DIR}/acme-sensord-marked-${BOARD}"
    sed 's/starting (data_dir=/starting DEPLOY-MARKER-42 (data_dir=/' \
        "${PROJECT_ROOT}/examples/external-tree-acme/cports/main/acme-sensord/files/acme-sensord.c" \
        > "$MARKED_SRC"
    "$CC" -std=c99 -Wall -Wextra -Werror "$MARKED_SRC" -o "$MARKED_BIN" \
        || fail "app SDK compile failed (see above)"
else
    fail "stage-sysroot.sh failed (${TL_LOG_DIR}/deploy-sysroot-${BOARD}.log)"
fi
case_end

##############################################################################
# boot the dev image
##############################################################################
tl_start_qemu --ssh-port="$SSH_PORT"
case_begin "boot-${BOARD}"
tl_wait_ssh "deploy target boot" || fail "SSH never came up"
case_end

##############################################################################
# case 2: binary-mode deploy (< 5 s contract, marker lands in the log)
##############################################################################
case_begin "binary-deploy-${BOARD}"
if [ -z "$CURRENT_FAIL" ] && [ -f "${MARKED_BIN:-/nonexistent}" ]; then
    T0=$(tl_now)
    if "${PROJECT_ROOT}/sdk/astro-deploy.sh" acme-sensord \
        --binary "$MARKED_BIN" --to "127.0.0.1:${SSH_PORT}" --no-log; then
        DEPLOY_S=$(( $(tl_now) - T0 ))
        echo "binary deploy round-trip: ${DEPLOY_S}s"
        # The docs/08 §6 target is < 5 s on QEMU; scaled for slow boards.
        [ "$DEPLOY_S" -le "$(tl_scale 10)" ] || \
            fail "deploy round-trip ${DEPLOY_S}s exceeds $(tl_scale 10)s"
        tl_wait_for "marker in service log" 15 \
            "${SSH[@]}" "grep -q DEPLOY-MARKER-42 /var/log/acme-sensord.log" \
            || fail "DEPLOY-MARKER-42 never appeared in /var/log/acme-sensord.log"
        "${SSH[@]}" "grep -q 'binary /usr/bin/acme-sensord' /etc/astro/deploy-drift" \
            || fail "no drift record on the device"
    else
        fail "astro-deploy --binary failed"
    fi
else
    fail "skipped: no marked binary from case 1"
fi
case_end

##############################################################################
# case 3: package-mode deploy restores the packaged binary
##############################################################################
case_begin "package-deploy-${BOARD}"
CBUILD_ARCH=$(cbuild_arch_for "$BOARD_ARCH")
APK=$(find "${PROJECT_ROOT}/cports/packages/main/${CBUILD_ARCH}" -maxdepth 1 \
    -name 'acme-sensord-[0-9]*.apk' 2>/dev/null | sort -V | tail -1)
if [ -n "$APK" ]; then
    if "${PROJECT_ROOT}/sdk/astro-deploy.sh" acme-sensord \
        --pkg "$APK" --to "127.0.0.1:${SSH_PORT}" --no-log; then
        # The packaged (marker-less) daemon is running again: the most
        # recent start line in the log must carry no deploy marker.
        tl_wait_for "packaged daemon restarted" 15 \
            "${SSH[@]}" "grep 'starting' /var/log/acme-sensord.log | tail -1 | grep -qv DEPLOY-MARKER" \
            || fail "latest daemon start still carries the sideload marker"
        "${SSH[@]}" "apk query acme-sensord >/dev/null 2>&1 || apk list --installed 2>/dev/null | grep -q acme-sensord" \
            || fail "apk no longer owns acme-sensord after package deploy"
    else
        fail "astro-deploy --pkg failed"
    fi
else
    fail "no acme-sensord apk in cports/packages/main/${CBUILD_ARCH} (build the tree image first)"
fi
case_end

tl_finish "deploy"
