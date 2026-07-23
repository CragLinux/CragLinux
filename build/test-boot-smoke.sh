#!/bin/bash
set -euo pipefail

# Astro Linux - boot-smoke test stage (docs/03 §5, docs/11 M1; GAP §4
# item 8: the hand-run QEMU boots, promoted to an asserting test).
#
# Boots the built full A/B image through the real bootloader on a
# throwaway scratch overlay grown by +1G (which also exercises the
# on-device /data growth path), watches the serial console, and asserts:
#
#   1. dinit reaches the boot-success milestone      ([  OK  ] boot-success)
#   2. a login prompt appears                        (login:)
#   3. no service failed                             (zero [FAILED] lines)
#   4. /data growth ran                              (data-mount: growing)
#
# Exits early as soon as 1+2 are seen (no fixed-sleep CI padding); the
# timeout only bounds a hung boot. Serial log is kept at
# build/state/logs/boot-smoke-<board>-<variant>.log and a junit XML at
# build/state/test-results/boot-smoke-<board>-<variant>.xml.
#
# Runs on the host (wraps itself into the astro-builder container, where
# QEMU lives) or directly inside the container. Harness plumbing lives in
# build/lib/testlib.sh.
#
# Usage:
#   ./build/test-boot-smoke.sh <board> <variant> [--timeout=SECONDS]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/testlib.sh"

BOARD="${1:?Usage: $0 <board> <variant> [--timeout=SECONDS]}"
VARIANT="${2:?Usage: $0 <board> <variant> [--timeout=SECONDS]}"
shift 2
TIMEOUT=240
for arg in "$@"; do
    case "$arg" in
        --timeout=*) TIMEOUT="${arg#--timeout=}" ;;
        *) echo "ERROR: unknown option: $arg"; exit 1 ;;
    esac
done

tl_containerize "build/test-boot-smoke.sh" "$BOARD" "$VARIANT" "--timeout=${TIMEOUT}"

##############################################################################
# Container side: boot, watch, assert
##############################################################################
tl_init "boot-smoke-${BOARD}-${VARIANT}" "$BOARD" "$VARIANT"
# The single case already bakes board+variant into its name.
TL_CASE_SUFFIX=""

case_begin "boot-smoke-${BOARD}-${VARIANT}"
tl_start_qemu

# Poll the serial log; exit the watch as soon as the boot verdict is in.
# Event-driven: the loop leaves the moment success (1+2), a fatal line,
# QEMU death, or the timeout arrives — never a fixed sleep.
while :; do
    if grep -aq 'boot-success' "$SERIAL_LOG" && grep -aq 'login:' "$SERIAL_LOG"; then
        break
    fi
    # dinit gave up / kernel panicked / QEMU died -> no point waiting
    if grep -aqE 'Kernel panic|dinit: boot failed' "$SERIAL_LOG"; then
        break
    fi
    kill -0 "$QEMU_PID" 2>/dev/null || break
    if [ "$(elapsed)" -ge "$TIMEOUT" ]; then
        break
    fi
    sleep 2
done
tl_stop_qemu

# Give the log its final flush, then assert
grep -aq '\[  OK  \] boot-success' "$SERIAL_LOG" || \
    fail "boot-success milestone not reached"
grep -aq 'login:' "$SERIAL_LOG" || \
    fail "no login prompt on serial console"
N_FAILED=$(grep -ac '\[FAILED\]' "$SERIAL_LOG" || :)
[ "${N_FAILED:-0}" -eq 0 ] || \
    fail "${N_FAILED} service(s) FAILED: $(grep -a '\[FAILED\]' "$SERIAL_LOG" | sed 's/.*\[FAILED\] //' | tr '\n' ' ')"
grep -aq 'data-mount: growing' "$SERIAL_LOG" || \
    fail "/data growth did not run on the +1G scratch disk"
case_end

tl_finish "boot-smoke"
