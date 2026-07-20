#!/bin/bash
set -euo pipefail

# Astro Linux - AD-020 gate: full A/B update + rollback test (docs/10 §4)
#
# Runs against the DEV variant (same A/B layout and update machinery as
# prod — docs/02 §3; dev additionally ships sshd + the dev test key, which
# is how the harness drives the guest).
#
# Sequence (docs/10 §4 item 4):
#   1. boot the built image on a +1G scratch overlay, wait for SSH
#   2. assert slot A booted and was marked good
#   3. install the current build's bundle THROUGH THE ASTROD API in-guest
#      (astroctl update install -> staged upload -> AD-021 gate -> RAUC
#      operation polled to completion) -> installs to slot B; assert the
#      operation succeeded and update.progress events were published
#   4. apply via the API (astroctl update apply) -> assert slot B booted
#      + marked good (slot flip worked)
#   5. build a POISONED bundle (astrod health check sabotaged ->
#      boot-success unreachable), install -> goes to slot A
#   6. reboot -> bootloader prefers A; each attempt fails, the
#      boot-success watchdog forces reboots, attempt counters exhaust,
#      bootloader falls back to B
#   7. assert: back on slot B, marked good again -> automatic rollback OK
#
# BOTH-PATHS COVERAGE (deliberate): the good-bundle install (phase 2)
# exercises the docs/05 §5.1 API-driven workflow end to end; the poisoned
# install (phase 3) stays on direct `rauc install` over SSH so the non-API
# entry point (docs/05 §5.2 USB/offline flows drive RAUC the same way)
# keeps gate coverage too.
#
# Usage:
#   ./build/test-update-rollback.sh <board> [--timeout=SECONDS]
#
# Outputs: serial log build/state/logs/ad020-<board>.log, junit XML in
# build/state/test-results/ad020-<board>.xml.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

BOARD="${1:?Usage: $0 <board> [--timeout=SECONDS]}"
shift
VARIANT="dev"
TIMEOUT=900
for arg in "$@"; do
    case "$arg" in
        --timeout=*) TIMEOUT="${arg#--timeout=}" ;;
        *) echo "ERROR: unknown option: $arg"; exit 1 ;;
    esac
done

# Host side: re-exec in the container (QEMU, rauc, debugfs, ssh live there)
if [ ! -f /run/.containerenv ] && [ ! -f /.dockerenv ]; then
    ENGINE="${CONTAINER_ENGINE:-$(command -v podman >/dev/null && echo podman || echo docker)}"
    IMAGE_NAME="${CONTAINER_IMAGE:-astro-builder}"
    exec "$ENGINE" run --rm --userns=keep-id --privileged \
        -v "${PROJECT_ROOT}:/workspace:Z" "$IMAGE_NAME" \
        -c "cd /workspace && ./build/test-update-rollback.sh ${BOARD} --timeout=${TIMEOUT}"
fi

##############################################################################
# Setup
##############################################################################
OUT="${PROJECT_ROOT}/build/state/images/${BOARD}-${VARIANT}"
LOG_DIR="${PROJECT_ROOT}/build/state/logs"
RESULT_DIR="${PROJECT_ROOT}/build/state/test-results"
mkdir -p "$LOG_DIR" "$RESULT_DIR"
SERIAL_LOG="${LOG_DIR}/ad020-${BOARD}.log"
JUNIT_XML="${RESULT_DIR}/ad020-${BOARD}.xml"
SSH_KEY="${PROJECT_ROOT}/keys/dev/ssh-test"
SSH_PORT=$(( 20000 + RANDOM % 10000 ))
VERSION="${ASTRO_VERSION:-0.0.0-dev}"
BUNDLE="${OUT}/astro-${BOARD}-${VERSION}.raucb"
START_TS=$(date +%s)
FAILURES=()

[ -f "$SSH_KEY" ] || { echo "ERROR: dev SSH key missing — run ./build/astro-keys.sh init-dev"; exit 1; }
[ -f "$BUNDLE" ] || { echo "ERROR: bundle not found: ${BUNDLE} — run ./build/astro-build.sh ${BOARD} ${VARIANT} --step=bundle"; exit 1; }

SSH=(ssh -i "$SSH_KEY" -p "$SSH_PORT" -o StrictHostKeyChecking=no
     -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
     -o ConnectTimeout=5 root@127.0.0.1)

fail() { FAILURES+=("$1"); echo "[FAIL-POINT] $1"; }

elapsed() { echo $(( $(date +%s) - START_TS )); }

wait_ssh() {
    # $1 = description; waits until the guest answers over SSH
    local desc="$1" tries=0
    while :; do
        if "${SSH[@]}" true 2>/dev/null; then
            return 0
        fi
        tries=$((tries + 1))
        if [ $(( $(elapsed) )) -ge "$TIMEOUT" ]; then
            fail "SSH never came up (${desc})"
            finish
        fi
        sleep 3
    done
}

guest_slot() {
    "${SSH[@]}" "sed -n 's/.*rauc\\.slot=\\([A-Za-z0-9]*\\).*/\\1/p' /proc/cmdline" 2>/dev/null || echo "?"
}

wait_serial() {
    # $1 = pattern, $2 = description, $3 = max seconds (default 120):
    # mark-good lands tens of seconds after SSH is reachable (rauc daemon
    # startup + retry backoff), so console asserts must wait, not sample
    local pat="$1" desc="$2" max="${3:-120}" waited=0
    while [ "$waited" -lt "$max" ]; do
        grep -aq "$pat" "$SERIAL_LOG" && return 0
        sleep 3
        waited=$((waited + 3))
    done
    fail "$desc (pattern '$pat' not seen in ${max}s)"
    return 1
}

QEMU_PID=
start_qemu() {
    "${SCRIPT_DIR}/run-qemu.sh" "$BOARD" "$VARIANT" --image --scratch=+1G \
        --ssh-port="$SSH_PORT" >> "$SERIAL_LOG" 2>&1 &
    QEMU_PID=$!
}

finish() {
    [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null || :
    wait "$QEMU_PID" 2>/dev/null || :
    local t
    t=$(elapsed)
    xml_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo "<testsuite name=\"ad020-update-rollback\" tests=\"1\" failures=\"${#FAILURES[@]}\" time=\"${t}\">"
        echo "  <testcase name=\"ad020-${BOARD}\" time=\"${t}\">"
        for f in "${FAILURES[@]:+${FAILURES[@]}}"; do
            echo "    <failure message=\"$(printf '%s' "$f" | xml_escape)\"/>"
        done
        echo "  </testcase>"
        echo "</testsuite>"
    } > "$JUNIT_XML"
    echo ""
    if [ ${#FAILURES[@]} -eq 0 ]; then
        echo "[PASS] AD-020 update+rollback ${BOARD} (${t}s)"
    else
        echo "[FAIL] AD-020 update+rollback ${BOARD} (${t}s):"
        for f in "${FAILURES[@]}"; do echo "  - $f"; done
    fi
    echo "  serial: ${SERIAL_LOG}"
    echo "  junit:  ${JUNIT_XML}"
    [ ${#FAILURES[@]} -eq 0 ]
    exit $?
}

: > "$SERIAL_LOG"

##############################################################################
# Phase 1: first boot, slot A good
##############################################################################
echo "[STEP] Booting ${BOARD}/${VARIANT} (scratch, ssh :${SSH_PORT})..."
start_qemu
wait_ssh "initial boot"

slot=$(guest_slot)
[ "$slot" = "A" ] || fail "expected first boot from slot A, got '${slot}'"
wait_serial 'rauc: boot marked good (slot A)' "slot A was not marked good on first boot" && \
    echo "[OK] slot A booted and marked good ($(elapsed)s)"

# Shorten the boot-success watchdog for the rollback phase (test knob —
# /data survives updates, so the poisoned slot sees it too)
"${SSH[@]}" "echo 45 > /data/.astro/boot-watchdog-timeout" || \
    fail "could not set watchdog timeout knob"

##############################################################################
# Phase 2: install the current bundle THROUGH THE ASTROD API -> slot B,
# apply via the API, verify flip.
#
# This phase is the API-path half of the both-paths coverage (see header):
# astroctl streams the bundle into POST /api/v1/update, the AD-021 gate and
# InspectBundle run in astrod, and astroctl polls the returned operation to
# a terminal state — its exit code IS the operation-completion assertion.
##############################################################################
echo "[STEP] Installing bundle via astrod API ($(basename "$BUNDLE"))..."
"${SSH[@]}" "cat > /data/update.raucb" < "$BUNDLE" || fail "bundle upload failed"
INSTALL_LOG="${LOG_DIR}/ad020-${BOARD}-api-install.log"
if ! "${SSH[@]}" "astroctl update install /data/update.raucb" > "$INSTALL_LOG" 2>&1; then
    cat "$INSTALL_LOG" >> "$SERIAL_LOG"
    fail "API install failed (astroctl update install — see transcript in serial log)"
    finish
fi
cat "$INSTALL_LOG" >> "$SERIAL_LOG"
grep -q 'install operation succeeded' "$INSTALL_LOG" || \
    fail "install transcript missing the operation-succeeded line"

# Event assertion: at least one update.progress event must have been
# published. astroctl's drain mode replays the daemon's event ring
# (Last-Event-ID: 0) and exits at the first quiet period.
EVENTS_LOG="${LOG_DIR}/ad020-${BOARD}-events.log"
"${SSH[@]}" "astroctl events" > "$EVENTS_LOG" 2>&1 || fail "astroctl events drain failed"
cat "$EVENTS_LOG" >> "$SERIAL_LOG"
grep -q 'update\.progress' "$EVENTS_LOG" || \
    fail "no update.progress event observed in the event ring"

echo "[STEP] Applying update via API (reboot into the new slot)..."
# The 202 lands just before dinit teardown kills sshd, so the transcript
# (or the ssh exit status) can be lost in that race — apply is best-effort
# here; the hard assertions are the slot flip + mark-good below.
"${SSH[@]}" "astroctl update apply" >> "$SERIAL_LOG" 2>&1 || \
    echo "[WARN] apply transcript lost (connection dropped at reboot); relying on slot assertions"
sleep 10
wait_ssh "post-update boot"

slot=$(guest_slot)
[ "$slot" = "B" ] || fail "expected slot B after update, got '${slot}'"
wait_serial 'rauc: boot marked good (slot B)' "slot B was not marked good after update" && \
    echo "[OK] API update installed, slot flip A->B verified ($(elapsed)s)"

##############################################################################
# Phase 3: poisoned bundle -> slot A, watch automatic rollback to B
#
# DELIBERATELY installs via direct `rauc install` over SSH, not the API:
# phase 2 already covered the astrod path, and this keeps the non-API entry
# point (docs/05 §5.2 USB/offline flows call RAUC the same way) under the
# gate. It also sidesteps the AD-021 version gate for the poisoned bundle,
# which is exactly the raw-RAUC behavior we want to prove rollback against.
##############################################################################
echo "[STEP] Building poisoned bundle (astrod health check sabotaged)..."
PW="${OUT}/image-work/poison"
rm -rf "$PW"; mkdir -p "$PW"
cp --reflink=auto "${OUT}/image-work/rootfs.ext4" "${PW}/rootfs.img"
# remove the astrod binary -> astrod fails -> boot-success unreachable
debugfs -w -R "rm /usr/bin/astrod" "${PW}/rootfs.img" >/dev/null 2>&1
cp --reflink=auto "${OUT}/image-work/boot.vfat" "${PW}/boot.vfat"
COMPAT=$(python3 "${SCRIPT_DIR}/lib/config.py" board "${PROJECT_ROOT}/boards/${BOARD}/board.toml" --format=json | jq -r '.rauc.compatible')
cat > "${PW}/manifest.raucm" <<EOF
[update]
compatible=${COMPAT}
version=${VERSION}+poisoned

[bundle]
format=verity

[image.rootfs]
filename=rootfs.img

[image.boot]
filename=boot.vfat
EOF
POISON="${OUT}/astro-${BOARD}-poisoned.raucb"
rm -f "$POISON"
rauc bundle --cert="${PROJECT_ROOT}/keys/dev/rauc-signing.cert.pem" \
            --key="${PROJECT_ROOT}/keys/dev/rauc-signing.key.pem" \
            "$PW" "$POISON" >/dev/null
rm -rf "$PW"

echo "[STEP] Installing poisoned bundle..."
"${SSH[@]}" "cat > /data/poison.raucb" < "$POISON" || fail "poisoned bundle upload failed"
if ! "${SSH[@]}" "rauc install /data/poison.raucb" >> "$SERIAL_LOG" 2>&1; then
    fail "rauc install (poisoned bundle) failed unexpectedly at install time"
    finish
fi

echo "[STEP] Rebooting into the poisoned slot; waiting for automatic rollback..."
"${SSH[@]}" "reboot" 2>/dev/null || :

# The guest now: boots A (poisoned) -> watchdog reboot xN -> falls back
# to B -> marks good. Wait for SSH to return AND the slot to be B.
sleep 10
rollback_ok=false
while [ "$(elapsed)" -lt "$TIMEOUT" ]; do
    if "${SSH[@]}" true 2>/dev/null; then
        slot=$(guest_slot)
        if [ "$slot" = "B" ]; then rollback_ok=true; break; fi
        # ssh up on the poisoned slot is unexpected (astrod broken but sshd
        # runs) — that's fine, the watchdog will still reboot it; keep waiting
    fi
    sleep 5
done
if [ "$rollback_ok" = true ]; then
    n_wd=$(grep -ac 'astro-boot-watchdog: boot-success not reached' "$SERIAL_LOG" || :)
    [ "${n_wd:-0}" -ge 1 ] || fail "no watchdog force-reboot observed in serial log"
    # final marked-good on B after the fallback (2nd occurrence; wait for it)
    waited=0
    while [ "$waited" -lt 120 ]; do
        n_good_b=$(grep -ac 'rauc: boot marked good (slot B)' "$SERIAL_LOG" || :)
        [ "${n_good_b:-0}" -ge 2 ] && break
        sleep 3; waited=$((waited + 3))
    done
    [ "${n_good_b:-0}" -ge 2 ] || fail "slot B not re-marked good after rollback"
    echo "[OK] automatic rollback to slot B verified (${n_wd} watchdog reboots) ($(elapsed)s)"
else
    fail "rollback to slot B not observed within ${TIMEOUT}s"
fi

finish
