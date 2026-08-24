#!/bin/bash
set -euo pipefail

# Crag Linux - AD-020 gate: full A/B update + rollback test (docs/10 §4)
#
# Runs against the DEV variant (same A/B layout and update machinery as
# prod — docs/02 §3; dev additionally ships sshd + the dev test key, which
# is how the harness drives the guest).
#
# Phases (docs/10 §4 item 4; each is one junit <testcase>):
#   boot-slot-a    boot the built image on a +1G scratch overlay, wait
#                  for SSH, assert slot A booted and was marked good
#   api-install    install the current build's bundle THROUGH THE CRAGD
#                  API in-guest (cragctl update install -> staged upload
#                  -> AD-021 gate -> RAUC operation polled to completion)
#                  -> installs to slot B; assert the operation succeeded
#                  and update.progress events were published
#   api-apply-flip apply via the API (cragctl update apply) -> assert
#                  slot B booted + marked good (slot flip worked)
#   poison-rollback build a POISONED bundle (cragd health check
#                  sabotaged -> boot-success unreachable), install ->
#                  goes to slot A; reboot -> bootloader prefers A; each
#                  attempt fails, the boot-success watchdog forces
#                  reboots, attempt counters exhaust, bootloader falls
#                  back to B; assert: back on slot B, marked good again
#                  -> automatic rollback OK
#
# BOTH-PATHS COVERAGE (deliberate): the good-bundle install (api-install)
# exercises the docs/05 §5.1 API-driven workflow end to end; the poisoned
# install stays on direct `rauc install` over SSH so the non-API entry
# point (docs/05 §5.2 USB/offline flows drive RAUC the same way) keeps
# gate coverage too.
#
# Harness plumbing lives in build/lib/testlib.sh.
#
# Usage:
#   ./build/test-update-rollback.sh <board> [--timeout=SECONDS]
#
# Outputs: serial log build/state/logs/ad020-<board>.log, junit XML in
# build/state/test-results/ad020-<board>.xml.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/testlib.sh"

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

tl_containerize "build/test-update-rollback.sh" "$BOARD" "--timeout=${TIMEOUT}"

##############################################################################
# Setup
##############################################################################
tl_init "ad020-${BOARD}" "$BOARD" "$VARIANT"
SSH_PORT=$(( 20000 + RANDOM % 10000 ))
tl_ssh_init
VERSION="${CRAG_VERSION:-0.0.0-dev}"
BUNDLE="${TL_OUT}/crag-${BOARD}-${VERSION}.raucb"
[ -f "$BUNDLE" ] || { echo "ERROR: bundle not found: ${BUNDLE} — run ./build/crag-build.sh ${BOARD} ${VARIANT} --step=bundle"; exit 1; }

##############################################################################
# Phase: boot-slot-a — first boot, slot A good
##############################################################################
phase_boot_slot_a() {
    echo "[STEP] Booting ${BOARD}/${VARIANT} (scratch, ssh :${SSH_PORT})..."
    tl_start_qemu --ssh-port="$SSH_PORT"
    tl_wait_ssh "initial boot" || return 1

    local slot
    slot=$(guest_slot)
    [ "$slot" = "A" ] || fail "expected first boot from slot A, got '${slot}'"
    tl_wait_serial 'rauc: boot marked good (slot A)' "slot A was not marked good on first boot" && \
        echo "[OK] slot A booted and marked good ($(elapsed)s)"

    # Shorten the boot-success watchdog for the rollback phase (test knob
    # — /data survives updates, so the poisoned slot sees it too)
    "${SSH[@]}" "echo 45 > /data/.crag/boot-watchdog-timeout" || \
        fail "could not set watchdog timeout knob"
}

##############################################################################
# Phase: api-install — the current bundle through the cragd API -> slot B
#
# This phase is the API-path half of the both-paths coverage (see header):
# cragctl streams the bundle into POST /api/v1/update, the AD-021 gate and
# InspectBundle run in cragd, and cragctl polls the returned operation to
# a terminal state — its exit code IS the operation-completion assertion.
##############################################################################
phase_api_install() {
    echo "[STEP] Installing bundle via cragd API ($(basename "$BUNDLE"))..."
    "${SSH[@]}" "cat > /data/update.raucb" < "$BUNDLE" || fail "bundle upload failed"
    local INSTALL_LOG="${TL_LOG_DIR}/ad020-${BOARD}-api-install.log"
    if ! "${SSH[@]}" "cragctl update install /data/update.raucb" > "$INSTALL_LOG" 2>&1; then
        cat "$INSTALL_LOG" >> "$SERIAL_LOG"
        fail "API install failed (cragctl update install — see transcript in serial log)"
        return 1
    fi
    cat "$INSTALL_LOG" >> "$SERIAL_LOG"
    grep -q 'install operation succeeded' "$INSTALL_LOG" || \
        fail "install transcript missing the operation-succeeded line"

    # Event assertion: at least one update.progress event must have been
    # published. cragctl's drain mode replays the daemon's event ring
    # (Last-Event-ID: 0) and exits at the first quiet period.
    local EVENTS_LOG="${TL_LOG_DIR}/ad020-${BOARD}-events.log"
    "${SSH[@]}" "cragctl events" > "$EVENTS_LOG" 2>&1 || fail "cragctl events drain failed"
    cat "$EVENTS_LOG" >> "$SERIAL_LOG"
    grep -q 'update\.progress' "$EVENTS_LOG" || \
        fail "no update.progress event observed in the event ring"
}

##############################################################################
# Phase: api-apply-flip — apply via the API, verify the A->B flip
##############################################################################
phase_api_apply_flip() {
    echo "[STEP] Applying update via API (reboot into the new slot)..."
    # The 202 lands just before dinit teardown kills sshd, so the
    # transcript (or the ssh exit status) can be lost in that race —
    # apply is best-effort here; the hard assertions are the slot flip +
    # mark-good below.
    "${SSH[@]}" "cragctl update apply" >> "$SERIAL_LOG" 2>&1 || \
        echo "[WARN] apply transcript lost (connection dropped at reboot); relying on slot assertions"
    # Event-driven reboot tracking: wait for the guest to actually go
    # DOWN first, so the following wait cannot be satisfied by the old
    # boot still answering (the old fixed sleep raced exactly that).
    tl_wait_ssh_down "apply reboot" || :
    tl_wait_ssh "post-update boot" || return 1

    local slot
    slot=$(guest_slot)
    [ "$slot" = "B" ] || fail "expected slot B after update, got '${slot}'"
    tl_wait_serial 'rauc: boot marked good (slot B)' "slot B was not marked good after update" && \
        echo "[OK] API update installed, slot flip A->B verified ($(elapsed)s)"
}

##############################################################################
# Phase: poison-rollback — poisoned bundle -> slot A, automatic rollback
#
# DELIBERATELY installs via direct `rauc install` over SSH, not the API:
# the api-install phase already covered the cragd path, and this keeps the
# non-API entry point (docs/05 §5.2 USB/offline flows call RAUC the same
# way) under the gate. It also sidesteps the AD-021 version gate for the
# poisoned bundle, which is exactly the raw-RAUC behavior we want to prove
# rollback against.
##############################################################################
slot_b_remarked_good() {
    N_GOOD_B=$(grep -ac 'rauc: boot marked good (slot B)' "$SERIAL_LOG" || :)
    [ "${N_GOOD_B:-0}" -ge 2 ]
}

phase_poison_rollback() {
    echo "[STEP] Building poisoned bundle (cragd health check sabotaged)..."
    local PW="${TL_OUT}/image-work/poison"
    rm -rf "$PW"; mkdir -p "$PW"
    cp --reflink=auto "${TL_OUT}/image-work/rootfs.ext4" "${PW}/rootfs.img"
    # remove the cragd binary -> cragd fails -> boot-success unreachable
    debugfs -w -R "rm /usr/bin/cragd" "${PW}/rootfs.img" >/dev/null 2>&1
    cp --reflink=auto "${TL_OUT}/image-work/boot.vfat" "${PW}/boot.vfat"
    local COMPAT
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
    local POISON="${TL_OUT}/crag-${BOARD}-poisoned.raucb"
    rm -f "$POISON"
    rauc bundle --cert="${PROJECT_ROOT}/keys/dev/rauc-signing.cert.pem" \
                --key="${PROJECT_ROOT}/keys/dev/rauc-signing.key.pem" \
                "$PW" "$POISON" >/dev/null
    rm -rf "$PW"

    echo "[STEP] Installing poisoned bundle..."
    "${SSH[@]}" "cat > /data/poison.raucb" < "$POISON" || fail "poisoned bundle upload failed"
    if ! "${SSH[@]}" "rauc install /data/poison.raucb" >> "$SERIAL_LOG" 2>&1; then
        fail "rauc install (poisoned bundle) failed unexpectedly at install time"
        return 1
    fi

    echo "[STEP] Rebooting into the poisoned slot; waiting for automatic rollback..."
    "${SSH[@]}" "reboot" 2>/dev/null || :
    # The reboot request lands asynchronously; wait for the port to
    # actually die instead of a fixed settle sleep.
    tl_wait_ssh_down "reboot into poisoned slot" || :

    # The guest now: boots A (poisoned) -> watchdog reboot xN -> falls
    # back to B -> marks good. Wait for SSH to return AND the slot to be
    # B (ssh may transiently answer on the poisoned slot: cragd broken
    # but sshd runs — the watchdog still reboots it; keep waiting).
    local rollback_ok=false slot
    while [ "$(elapsed)" -lt "$TIMEOUT" ]; do
        if "${SSH[@]}" true 2>/dev/null; then
            slot=$(guest_slot)
            if [ "$slot" = "B" ]; then rollback_ok=true; break; fi
        fi
        sleep 5
    done
    if [ "$rollback_ok" = true ]; then
        local n_wd
        n_wd=$(grep -ac 'crag-boot-watchdog: boot-success not reached' "$SERIAL_LOG" || :)
        [ "${n_wd:-0}" -ge 1 ] || fail "no watchdog force-reboot observed in serial log"
        # final marked-good on B after the fallback (2nd occurrence)
        tl_wait_for "slot B re-marked good" 120 slot_b_remarked_good || \
            fail "slot B not re-marked good after rollback"
        echo "[OK] automatic rollback to slot B verified (${n_wd} watchdog reboots) ($(elapsed)s)"
    else
        fail "rollback to slot B not observed within ${TIMEOUT}s"
    fi
}

##############################################################################
# Driver
##############################################################################
run_phase() {
    local rc=0
    case_begin "$1"
    "phase_${1//-/_}" || rc=$?
    case_end
    [ "$rc" -eq 0 ] || tl_finish "ad020-update-rollback"
}

run_phase "boot-slot-a"
run_phase "api-install"
run_phase "api-apply-flip"
run_phase "poison-rollback"

tl_finish "ad020-update-rollback"
