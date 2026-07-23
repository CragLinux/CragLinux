# shellcheck shell=bash
# Astro Linux - shared test-harness plumbing (docs/03 §5, docs/10 §4).
#
# Sourced by the QEMU suites (test-boot-smoke.sh, test-api.sh,
# test-update-rollback.sh) after they parse BOARD/VARIANT/TIMEOUT.
# Everything the three harnesses used to duplicate lives here:
#
#   tl_containerize   host->container self-reexec. The serial log must be
#                     redirected INSIDE the container — redirecting the
#                     podman invocation itself loses the stream
#                     (MIGRATION-NOTES §12).
#   tl_init           log/junit paths, elapsed clock, per-board timeout
#                     multiplier (armv7 TCG runs ~1.5x slower than
#                     x86_64 — deadlines scale in ONE place, tl_scale,
#                     instead of magic numbers per suite).
#   tl_ssh_init       the hardened SSH command array. ServerAliveInterval/
#                     CountMax are load-bearing: a session that connects
#                     JUST as the guest reboots otherwise hangs forever on
#                     the half-dead slirp hostfwd TCP — ConnectTimeout
#                     only bounds the connect (caught live twice: a
#                     wedged wait_ssh_down and a ~10 min phase-3 reboot
#                     hang, MIGRATION-NOTES §14/§20).
#   tl_start_qemu     run-qemu.sh wrapper with a stale-QEMU preflight: a
#                     leftover qemu process (aborted run, still-running
#                     container) holds qcow2/pflash file locks and the
#                     next boot dies with an obscure "Failed to get
#                     'write' lock" mid-suite — the preflight names the
#                     problem crisply before anything boots.
#   tl_wait_ssh / tl_wait_ssh_down / tl_wait_serial / tl_wait_for
#                     event-driven waits with scaled deadlines — no bare
#                     sleeps; the serial wait POLLS the log (mark-good
#                     lands tens of seconds after SSH answers, so console
#                     asserts must wait, not sample).
#   guest_slot        rauc.slot= from the guest's /proc/cmdline.
#   case_begin / fail / case_end / evidence
#                     per-testcase bookkeeping (first failure wins the
#                     junit message; every one is printed).
#   tl_finish         QEMU teardown + junit (one <testcase> per case,
#                     per-case wall time) + summary + exit.
#
# Contract: suites set PROJECT_ROOT and SCRIPT_DIR before sourcing.

##############################################################################
# Containerization
##############################################################################

# tl_containerize <repo-relative-script> [args...]
# No-op inside a container; on the host, re-exec the script in the
# astro-builder image with the given args (%q-quoted verbatim).
tl_containerize() {
    if [ -f /run/.containerenv ] || [ -f /.dockerenv ]; then
        return 0
    fi
    local script="$1" engine image argv=""
    shift
    engine="${CONTAINER_ENGINE:-$(command -v podman >/dev/null && echo podman || echo docker)}"
    image="${CONTAINER_IMAGE:-astro-builder}"
    local a
    for a in "$@"; do
        argv+=" $(printf '%q' "$a")"
    done
    exec "$engine" run --rm --userns=keep-id --privileged \
        -v "${PROJECT_ROOT}:/workspace:Z" "$image" \
        -c "cd /workspace && ./${script}${argv}"
}

##############################################################################
# Init: paths, clock, per-board deadline scaling
##############################################################################

# tl_init <tag> <board> <variant>
# <tag> names the artifacts (logs/<tag>.log, test-results/<tag>.xml) —
# each suite keeps its historical names (boot-smoke-<b>-<v>, api-<b>,
# ad020-<b>) so CI consumers see no path churn.
tl_init() {
    TL_TAG="$1"
    TL_BOARD="$2"
    TL_VARIANT="$3"
    TL_OUT="${PROJECT_ROOT}/build/state/images/${TL_BOARD}-${TL_VARIANT}"
    TL_LOG_DIR="${PROJECT_ROOT}/build/state/logs"
    TL_RESULT_DIR="${PROJECT_ROOT}/build/state/test-results"
    mkdir -p "$TL_LOG_DIR" "$TL_RESULT_DIR"
    SERIAL_LOG="${TL_LOG_DIR}/${TL_TAG}.log"
    JUNIT_XML="${TL_RESULT_DIR}/${TL_TAG}.xml"
    START_TS=$(tl_now)
    QEMU_PID=""
    CASE_NAMES=()
    CASE_FAILS=()
    CASE_TIMES=()
    CURRENT_CASE=""
    CURRENT_FAIL=""
    CURRENT_CASE_T0=0
    # junit <testcase> names are "<case>${TL_CASE_SUFFIX}"; suites that
    # already bake the board into the case name set the suffix to "".
    TL_CASE_SUFFIX="-${TL_BOARD}"
    # Deadline multiplier, percent. Calibrated against the M2/M3 fleet
    # numbers (MIGRATION-NOTES §14/§20): armv7 TCG is ~1.5x slower than
    # x86_64, aarch64 ~1.25x. Applied by tl_scale to every helper
    # deadline; the suite-level --timeout stays the caller's business.
    case "$TL_BOARD" in
        *armv7*)   TL_MULT_PCT=150 ;;
        *aarch64*) TL_MULT_PCT=125 ;;
        *)         TL_MULT_PCT=100 ;;
    esac
    : > "$SERIAL_LOG"
}

# Monotonic clock (suspend-immune): a host sleep mid-suite must not blow
# deadlines — CLOCK_MONOTONIC pauses across suspend, wall clock does not
# (observed: a healthy AD-020 boot SIGTERMed after a 4 h host suspend
# because date +%s jumped past the deadline).
tl_now() { awk '{print int($1)}' /proc/uptime; }

elapsed() { echo $(( $(tl_now) - START_TS )); }

# tl_scale <seconds> — the board-scaled deadline (ceiling division).
tl_scale() { echo $(( ($1 * TL_MULT_PCT + 99) / 100 )); }

##############################################################################
# SSH
##############################################################################

# tl_ssh_init — requires SSH_PORT set (callers pick a random high port);
# checks the dev key and builds the SSH command array.
tl_ssh_init() {
    SSH_KEY="${PROJECT_ROOT}/keys/dev/ssh-test"
    [ -f "$SSH_KEY" ] || { echo "ERROR: dev SSH key missing — run ./build/astro-keys.sh init-dev"; exit 1; }
    SSH=(ssh -i "$SSH_KEY" -p "$SSH_PORT" -o StrictHostKeyChecking=no
         -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
         -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=3
         root@127.0.0.1)
}

##############################################################################
# QEMU lifecycle
##############################################################################

# Stale-QEMU preflight (MIGRATION-NOTES §20 lesson, promoted to a check):
# qemu-img info takes a shared lock, so it fails IFF another process
# holds a write lock — exactly the stale-qemu signature (a leftover run
# write-locks scratch.qcow2 and, on grub boards, OVMF_VARS.fd). Detect
# it up front and say so, instead of an obscure mid-suite bootloop.
tl_qemu_lock_check() {
    local f
    for f in "${TL_OUT}/scratch.qcow2" "${TL_OUT}/OVMF_VARS.fd" \
             "${TL_OUT}"/astro-"${TL_BOARD}"-*.qcow2; do
        [ -f "$f" ] || continue
        if ! qemu-img info "$f" >/dev/null 2>&1; then
            echo "ERROR: $(basename "$f") is write-locked by another QEMU process."
            echo "  A previous ${TL_BOARD} run left a stale qemu alive (or another suite is"
            echo "  running against the same image directory). This suite refuses to start"
            echo "  rather than corrupt that guest / die on the lock mid-boot."
            echo "  On the HOST (containers share the file locks, not the pid namespace):"
            echo "    pgrep -af qemu-system | grep ${TL_BOARD}   # find it"
            echo "    pkill -f '${TL_BOARD}-${TL_VARIANT}'        # or kill the stale container"
            exit 1
        fi
    done
}

# tl_start_qemu [extra run-qemu.sh args...] — boots the full image on a
# +1G scratch overlay, serial appended to SERIAL_LOG, QEMU_PID set.
tl_start_qemu() {
    tl_qemu_lock_check
    "${SCRIPT_DIR}/run-qemu.sh" "$TL_BOARD" "$TL_VARIANT" --image --scratch=+1G \
        "$@" >> "$SERIAL_LOG" 2>&1 &
    QEMU_PID=$!
}

tl_stop_qemu() {
    if [ -n "${QEMU_PID:-}" ]; then
        kill "$QEMU_PID" 2>/dev/null || :
        wait "$QEMU_PID" 2>/dev/null || :
        QEMU_PID=""
    fi
}

##############################################################################
# Event-driven waits (bounded polls; deadlines scaled per board)
##############################################################################

# tl_wait_for <desc> <max-seconds-unscaled> <cmd...>
# Poll <cmd> every 2 s until it succeeds or the scaled deadline passes.
# Returns 1 on timeout (does NOT fail the case — callers decide).
tl_wait_for() {
    local desc="$1" max; max=$(tl_scale "$2")
    shift 2
    local t0; t0=$(tl_now)
    while :; do
        if "$@"; then return 0; fi
        [ $(( $(tl_now) - t0 )) -ge "$max" ] && return 1
        sleep 2
    done
}

# tl_wait_ssh <desc> [max-seconds] — until the guest answers over SSH.
# Default deadline is the suite TIMEOUT (unscaled: it is caller-provided).
# On timeout: fail() and return 1.
tl_wait_ssh() {
    local desc="$1" max="${2:-$TIMEOUT}"
    local t0; t0=$(tl_now)
    while :; do
        if "${SSH[@]}" true 2>/dev/null; then
            return 0
        fi
        if [ $(( $(tl_now) - t0 )) -ge "$max" ]; then
            fail "SSH never came up (${desc})"
            return 1
        fi
        sleep 3
    done
}

# tl_wait_ssh_down <desc> [max-seconds-unscaled=180] — after a deferred
# shutdown action, wait for the guest to actually go DOWN so a following
# tl_wait_ssh cannot be satisfied by the old boot.
tl_wait_ssh_down() {
    local desc="$1" max; max=$(tl_scale "${2:-180}")
    local t0; t0=$(tl_now)
    while [ $(( $(tl_now) - t0 )) -lt "$max" ]; do
        if ! "${SSH[@]}" true 2>/dev/null; then
            return 0
        fi
        sleep 2
    done
    fail "guest never went down (${desc})"
    return 1
}

# tl_wait_serial <pattern> <desc> [max-seconds-unscaled=120]
# Poll the serial log for a pattern. Mark-good lands tens of seconds
# after SSH is reachable (rauc daemon startup + retry backoff), so
# console asserts must WAIT for the line, never sample once.
tl_wait_serial() {
    local pat="$1" desc="$2" max; max=$(tl_scale "${3:-120}")
    local t0; t0=$(tl_now)
    while [ $(( $(tl_now) - t0 )) -lt "$max" ]; do
        grep -aq "$pat" "$SERIAL_LOG" && return 0
        sleep 3
    done
    fail "$desc (pattern '$pat' not seen in ${max}s)"
    return 1
}

guest_slot() {
    "${SSH[@]}" "sed -n 's/.*rauc\\.slot=\\([A-Za-z0-9]*\\).*/\\1/p' /proc/cmdline" 2>/dev/null || echo "?"
}

##############################################################################
# Per-case bookkeeping (junit: one <testcase> per case, per-case time)
##############################################################################

case_begin() {
    CURRENT_CASE="$1"
    CURRENT_FAIL=""
    CURRENT_CASE_T0=$(tl_now)
    echo ""
    echo "=== [${CURRENT_CASE}] ($(elapsed)s) ==="
}

fail() {
    # First failure wins the junit message; every one is printed.
    [ -n "$CURRENT_FAIL" ] || CURRENT_FAIL="$1"
    echo "[FAIL-POINT] ${CURRENT_CASE}: $1"
}

case_end() {
    CASE_NAMES+=("$CURRENT_CASE")
    CASE_FAILS+=("${CURRENT_FAIL}")
    CASE_TIMES+=( $(( $(tl_now) - CURRENT_CASE_T0 )) )
    if [ -z "$CURRENT_FAIL" ]; then
        echo "[OK] ${CURRENT_CASE} ($(elapsed)s)"
    else
        echo "[FAILED] ${CURRENT_CASE}: ${CURRENT_FAIL}"
    fi
}

evidence() {
    # $1 = label, $2 = body/output: printed to stdout AND kept in the
    # serial log so a red CI run carries the response that condemned it.
    echo "----- evidence: $1 -----"
    printf '%s\n' "$2"
    echo "----- end evidence -----"
    { echo "[evidence] $1"; printf '%s\n' "$2"; } >> "$SERIAL_LOG"
}

##############################################################################
# junit + finish
##############################################################################

tl_xml_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }

# tl_write_junit <suite-name> — one <testcase> per registered case, with
# per-case wall time (the upgrade over the old single-testcase writers).
tl_write_junit() {
    local suite="$1" nfail=0 i
    for i in "${!CASE_NAMES[@]}"; do
        [ -n "${CASE_FAILS[$i]}" ] && nfail=$((nfail + 1))
    done
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo "<testsuite name=\"${suite}\" tests=\"${#CASE_NAMES[@]}\" failures=\"${nfail}\" time=\"$(elapsed)\">"
        for i in "${!CASE_NAMES[@]}"; do
            if [ -n "${CASE_FAILS[$i]}" ]; then
                echo "  <testcase name=\"${CASE_NAMES[$i]}${TL_CASE_SUFFIX}\" time=\"${CASE_TIMES[$i]}\">"
                echo "    <failure message=\"$(printf '%s' "${CASE_FAILS[$i]}" | tl_xml_escape)\"/>"
                echo "  </testcase>"
            else
                echo "  <testcase name=\"${CASE_NAMES[$i]}${TL_CASE_SUFFIX}\" time=\"${CASE_TIMES[$i]}\"/>"
            fi
        done
        echo "</testsuite>"
    } > "$JUNIT_XML"
    return "$nfail"
}

# tl_finish <suite-name> — teardown, junit, summary, exit.
tl_finish() {
    local suite="$1" nfail=0 i
    tl_stop_qemu
    tl_write_junit "$suite" || nfail=$?
    echo ""
    if [ "$nfail" -eq 0 ]; then
        echo "[PASS] ${suite} ${TL_BOARD} (${#CASE_NAMES[@]} cases, $(elapsed)s)"
    else
        echo "[FAIL] ${suite} ${TL_BOARD} (${nfail}/${#CASE_NAMES[@]} cases failed, $(elapsed)s):"
        for i in "${!CASE_NAMES[@]}"; do
            [ -n "${CASE_FAILS[$i]}" ] && echo "  - ${CASE_NAMES[$i]}: ${CASE_FAILS[$i]}"
        done
    fi
    echo "  serial: ${SERIAL_LOG}"
    echo "  junit:  ${JUNIT_XML}"
    [ "$nfail" -eq 0 ]
    exit $?
}
