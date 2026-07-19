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
# QEMU lives) or directly inside the container.
#
# Usage:
#   ./build/test-boot-smoke.sh <board> <variant> [--timeout=SECONDS]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

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

##############################################################################
# Host side: re-exec inside the build container (it has QEMU + firmware).
# The serial log must be redirected INSIDE the container — redirecting the
# podman invocation itself loses the stream (MIGRATION-NOTES §12).
##############################################################################
if [ ! -f /run/.containerenv ] && [ ! -f /.dockerenv ]; then
    ENGINE="${CONTAINER_ENGINE:-$(command -v podman >/dev/null && echo podman || echo docker)}"
    IMAGE_NAME="${CONTAINER_IMAGE:-astro-builder}"
    exec "$ENGINE" run --rm --userns=keep-id --privileged \
        -v "${PROJECT_ROOT}:/workspace:Z" "$IMAGE_NAME" \
        -c "cd /workspace && ./build/test-boot-smoke.sh ${BOARD} ${VARIANT} --timeout=${TIMEOUT}"
fi

##############################################################################
# Container side: boot, watch, assert
##############################################################################
LOG_DIR="${PROJECT_ROOT}/build/state/logs"
RESULT_DIR="${PROJECT_ROOT}/build/state/test-results"
mkdir -p "$LOG_DIR" "$RESULT_DIR"
SERIAL_LOG="${LOG_DIR}/boot-smoke-${BOARD}-${VARIANT}.log"
JUNIT_XML="${RESULT_DIR}/boot-smoke-${BOARD}-${VARIANT}.xml"
: > "$SERIAL_LOG"

START_TS=$(date +%s)

"${SCRIPT_DIR}/run-qemu.sh" "$BOARD" "$VARIANT" --image --scratch=+1G \
    > "$SERIAL_LOG" 2>&1 &
QEMU_PID=$!

# Poll the serial log; exit the watch as soon as the boot verdict is in.
BOOT_OK=false
while :; do
    if grep -aq 'boot-success' "$SERIAL_LOG" && grep -aq 'login:' "$SERIAL_LOG"; then
        BOOT_OK=true
        break
    fi
    # dinit gave up / kernel panicked / QEMU died -> no point waiting
    if grep -aqE 'Kernel panic|dinit: boot failed' "$SERIAL_LOG"; then
        break
    fi
    kill -0 "$QEMU_PID" 2>/dev/null || break
    if [ $(( $(date +%s) - START_TS )) -ge "$TIMEOUT" ]; then
        break
    fi
    sleep 2
done
kill "$QEMU_PID" 2>/dev/null || :
wait "$QEMU_PID" 2>/dev/null || :
ELAPSED=$(( $(date +%s) - START_TS ))

# Give the log its final flush, then assert
FAILURES=()
grep -aq '\[  OK  \] boot-success' "$SERIAL_LOG" || \
    FAILURES+=("boot-success milestone not reached")
grep -aq 'login:' "$SERIAL_LOG" || \
    FAILURES+=("no login prompt on serial console")
N_FAILED=$(grep -ac '\[FAILED\]' "$SERIAL_LOG" || :)
[ "${N_FAILED:-0}" -eq 0 ] || \
    FAILURES+=("${N_FAILED} service(s) FAILED: $(grep -a '\[FAILED\]' "$SERIAL_LOG" | sed 's/.*\[FAILED\] //' | tr '\n' ' ')")
grep -aq 'data-mount: growing' "$SERIAL_LOG" || \
    FAILURES+=("/data growth did not run on the +1G scratch disk")

# junit report (docs/03 §5)
xml_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
{
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo "<testsuite name=\"boot-smoke\" tests=\"1\" failures=\"${#FAILURES[@]}\" time=\"${ELAPSED}\">"
    echo "  <testcase name=\"boot-smoke-${BOARD}-${VARIANT}\" time=\"${ELAPSED}\">"
    for f in "${FAILURES[@]:+${FAILURES[@]}}"; do
        echo "    <failure message=\"$(printf '%s' "$f" | xml_escape)\"/>"
    done
    echo "  </testcase>"
    echo "</testsuite>"
} > "$JUNIT_XML"

echo ""
if [ ${#FAILURES[@]} -eq 0 ]; then
    echo "[PASS] boot-smoke ${BOARD}/${VARIANT} (${ELAPSED}s to verdict)"
    echo "  serial: ${SERIAL_LOG}"
    echo "  junit:  ${JUNIT_XML}"
    exit 0
else
    echo "[FAIL] boot-smoke ${BOARD}/${VARIANT} (${ELAPSED}s):"
    for f in "${FAILURES[@]}"; do
        echo "  - $f"
    done
    echo "  serial: ${SERIAL_LOG}"
    echo "  junit:  ${JUNIT_XML}"
    exit 1
fi
