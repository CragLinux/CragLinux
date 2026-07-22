#!/bin/bash
set -euo pipefail

# Astro Linux - astrod API integration suite (M3 phase 3, docs/10 §4
# "astrod-api"): boots the dev image and exercises the network group end
# to end over the REAL stack — rtnetlink observation, dhcpcd addressing,
# astrod-rendered resolv.conf, and a full wifi station flow against an
# iwd access point on the kernel's mac80211_hwsim rig (two virtual
# radios, boards/*/kernel/qemu.fragment).
#
# Assertions, in order (each is one junit testcase):
#   boot           dev image boots on a scratch overlay, SSH answers
#   system-auth    GET /system via astroctl + the AD-014 auth matrix on
#                  127.0.0.1:8080 (401 problem+json without/with-bad
#                  token, 200 with the firstboot token) — phase-1
#                  regression
#   network-eth0   GET /network shows eth0 with carrier and the QEMU
#                  slirp 10.0.2.x address (rtnetlink observation path)
#   resolv-conf    /etc/resolv.conf is the baked symlink into
#                  /run/astro-resolv/resolv.conf (world-readable — the
#                  0750 /run/astro gate must NOT cover it: unprivileged
#                  daemons like chronyd resolve through it), the target
#                  carries astrod's
#                  rendered marker comment and the slirp DNS (docs/07 §2
#                  one-writer model, dhcpcd hook -> lease -> render)
#   update-status  GET /update/status reachable (phase-2 regression)
#   wifi-e2e       hwsim choreography: iwctl puts radio 1 in AP mode
#                  with iwd's built-in DHCP (AP profile in
#                  /data/net/iwd/ap, iwd.ap(5)), then THROUGH THE API:
#                  scan -> networks lists the test SSID -> connect ->
#                  GET /network/wifi reaches "connected" -> wlan0 holds
#                  an address from the AP pool in GET /network ->
#                  forget -> disconnected
#   astrod-rss     astrod VmRSS < 16 MiB after all of it (docs/06 §3)
#
# M3 phase-4 cases (docs/07 §4-§6), appended after the seven above:
#   provisioning-e2e  the full provisioning story on the 3-radio hwsim
#                  rig (radio 0 = DUT station/AP flip, radio 1 = test
#                  upstream AP, radio 2 = the "phone"): factory reset to
#                  reach the fresh-boot state (wifi-e2e above promoted
#                  the device — 'provisioned' is terminal, docs/07 §4),
#                  assert 'provisioning' NOT 'provisioned' (no wifi
#                  config + eth0 lease + wired_provisions=false), force
#                  the AP with the manual override (the docs/07 §4
#                  auto-trigger is "no ethernet carrier", which a slirp
#                  rig never has), associate the phone radio with the
#                  derived SSID/PSK, exercise the portal surface
#                  (probe 302, page, redacted /system, scan/networks,
#                  403 outside the subset, nft redirect ruleset), submit
#                  the upstream credentials, and watch the single-radio
#                  flip end 'provisioned' with the AP gone for good.
#   factory-reset  wrong confirm 400s; astroctl --yes-really-wipe
#                  reboots into a FRESH /data: 'provisioning' again, new
#                  api token (old one 401s), REGENERATED machine-id (it
#                  lives in the /etc overlay upper on /data — MIGRATION-
#                  NOTES §12), firstboot stamps fresh, wifi config gone.
#   time           docs/07 §6: build-epoch floor applied (now >= floor,
#                  astroctl time agrees) and chrony reaches real NTP
#                  through slirp's UDP forwarding — time.synced true
#                  (ASTRO_TEST_OFFLINE=1 flips that assert for
#                  air-gapped runs).
#
# HWSIM/IWD TRAP (verified in iwd-3.12 sources, do not "simplify"):
# iwd's AP DHCP server needs BOTH the profile's [IPv4] group (iwd.ap(5))
# AND main.conf [General].EnableNetworkConfiguration=true — ap_load_ipv4
# (src/ap.c:3363) returns without creating the DHCP server when
# netconfig is globally off. The shipped image keeps it OFF by AD-015
# (dhcpcd owns addressing), so this suite bind-mounts a test-scoped
# /etc/iwd override (works on ro rootfs, restored by umount) for the
# wifi phase. Side effect, accepted for the rig: iwd also runs its own
# station netconfig while the override is active; the wlan0-address
# assertion checks the ADDRESS CAME FROM THE AP POOL, and dhcpcd's
# ownership is asserted separately on eth0 in resolv-conf/network-eth0.
#
# Usage:
#   ./build/test-api.sh <board> [--timeout=SECONDS]
#
# Outputs: serial log build/state/logs/api-<board>.log, junit XML in
# build/state/test-results/api-<board>.xml.

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

# Host side: re-exec in the container (QEMU, ssh, jq live there)
if [ ! -f /run/.containerenv ] && [ ! -f /.dockerenv ]; then
    ENGINE="${CONTAINER_ENGINE:-$(command -v podman >/dev/null && echo podman || echo docker)}"
    IMAGE_NAME="${CONTAINER_IMAGE:-astro-builder}"
    exec "$ENGINE" run --rm --userns=keep-id --privileged \
        -v "${PROJECT_ROOT}:/workspace:Z" "$IMAGE_NAME" \
        -c "cd /workspace && ./build/test-api.sh ${BOARD} --timeout=${TIMEOUT}"
fi

##############################################################################
# Setup
##############################################################################
OUT="${PROJECT_ROOT}/build/state/images/${BOARD}-${VARIANT}"
LOG_DIR="${PROJECT_ROOT}/build/state/logs"
RESULT_DIR="${PROJECT_ROOT}/build/state/test-results"
mkdir -p "$LOG_DIR" "$RESULT_DIR"
SERIAL_LOG="${LOG_DIR}/api-${BOARD}.log"
JUNIT_XML="${RESULT_DIR}/api-${BOARD}.xml"
SSH_KEY="${PROJECT_ROOT}/keys/dev/ssh-test"
SSH_PORT=$(( 20000 + RANDOM % 10000 ))
START_TS=$(date +%s)

# Wifi rig constants (arbitrary but pinned so failures are greppable)
TEST_SSID="astro-hwsim"
TEST_PSK="astrotest1234"
AP_ADDR="192.168.80.1"
AP_POOL_RE='192\.168\.80\.'

# Provisioning-AP constants (docs/07 §4 baked decisions; wifi.zig pins
# them — a drift here fails loudly against the live daemon)
PORTAL_ADDR="192.168.223.1"
PORTAL_POOL_RE='192\.168\.223\.'

[ -f "$SSH_KEY" ] || { echo "ERROR: dev SSH key missing — run ./build/astro-keys.sh init-dev"; exit 1; }
[ -d "$OUT" ] || { echo "ERROR: image dir not found: ${OUT} — run ./build/astro-build.sh ${BOARD} ${VARIANT}"; exit 1; }

# ServerAliveInterval/CountMax: a session that connects JUST as the
# guest reboots (the factory-reset cases) otherwise hangs forever on the
# half-dead slirp hostfwd TCP — ConnectTimeout only bounds the connect.
# Caught live: wait_ssh_down's `ssh true` wedged a whole run.
SSH=(ssh -i "$SSH_KEY" -p "$SSH_PORT" -o StrictHostKeyChecking=no
     -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
     -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=3
     root@127.0.0.1)

elapsed() { echo $(( $(date +%s) - START_TS )); }

# ---- per-case bookkeeping (junit: one testcase per suite item) -------------
CASE_NAMES=()
CASE_FAILS=()
CURRENT_CASE=""
CURRENT_FAIL=""
case_begin() {
    CURRENT_CASE="$1"
    CURRENT_FAIL=""
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

# ---- guest helpers ---------------------------------------------------------
# All API calls run in-guest with curl (dev image ships it) against the
# unix socket: the group-gated default surface (AD-014).
api_get()    { "${SSH[@]}" "curl -s --max-time 20 --unix-socket /run/astro/astrod.sock http://localhost$1"; }
api_code()   { "${SSH[@]}" "curl -s -o /dev/null -w '%{http_code}' --max-time 20 -X $1 --unix-socket /run/astro/astrod.sock http://localhost$2"; }
api_post()   { "${SSH[@]}" "curl -s --max-time 20 -X POST --unix-socket /run/astro/astrod.sock http://localhost$1"; }

wait_ssh() {
    local desc="$1"
    while :; do
        if "${SSH[@]}" true 2>/dev/null; then
            return 0
        fi
        if [ "$(elapsed)" -ge "$TIMEOUT" ]; then
            fail "SSH never came up (${desc})"
            return 1
        fi
        sleep 3
    done
}

# Reboot bookkeeping for the phase-4 cases: after a deferred-shutdown
# action (factory reset), first wait for the guest to actually go DOWN
# so the following wait_ssh cannot be satisfied by the old boot.
wait_ssh_down() {
    local desc="$1" waited=0
    while [ "$waited" -lt 180 ]; do
        if ! "${SSH[@]}" true 2>/dev/null; then
            return 0
        fi
        sleep 2; waited=$((waited + 2))
    done
    fail "guest never went down (${desc})"
    return 1
}

# The AP-surface listener (192.168.223.1:8080). Guest-local curl: the
# surface is tagged PER LISTENER by astrod (spine main.zig), so any
# connection accepted here exercises the AP subset/redaction/403 rules.
# Why not `curl --interface wlan2` over the air, as a phone would: all
# three hwsim radios share ONE network stack in this rig, so the TCP
# reply to a local source address short-circuits via loopback and a
# SO_BINDTODEVICE-bound client socket never sees it (and the request
# path needs accept_local/rp_filter surgery to dodge the martian
# filter). The over-the-air half is proven by the wlan2 association +
# DHCP lease from the AP pool; a true phone-path HTTP assert needs a
# second stack (netns rig or a second guest) — recorded as deferred.
portal_get()  { "${SSH[@]}" "curl -s --max-time 20 http://${PORTAL_ADDR}:8080$1"; }
portal_code() { "${SSH[@]}" "curl -s -o /dev/null -w '%{http_code}' --max-time 20 -X $1 http://${PORTAL_ADDR}:8080$2"; }

QEMU_PID=
start_qemu() {
    "${SCRIPT_DIR}/run-qemu.sh" "$BOARD" "$VARIANT" --image --scratch=+1G \
        --ssh-port="$SSH_PORT" >> "$SERIAL_LOG" 2>&1 &
    QEMU_PID=$!
}

finish() {
    [ -n "$QEMU_PID" ] && kill "$QEMU_PID" 2>/dev/null || :
    wait "$QEMU_PID" 2>/dev/null || :
    local t nfail=0
    t=$(elapsed)
    xml_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
    local i
    for i in "${!CASE_NAMES[@]}"; do
        [ -n "${CASE_FAILS[$i]}" ] && nfail=$((nfail + 1))
    done
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo "<testsuite name=\"astrod-api\" tests=\"${#CASE_NAMES[@]}\" failures=\"${nfail}\" time=\"${t}\">"
        for i in "${!CASE_NAMES[@]}"; do
            if [ -n "${CASE_FAILS[$i]}" ]; then
                echo "  <testcase name=\"${CASE_NAMES[$i]}-${BOARD}\">"
                echo "    <failure message=\"$(printf '%s' "${CASE_FAILS[$i]}" | xml_escape)\"/>"
                echo "  </testcase>"
            else
                echo "  <testcase name=\"${CASE_NAMES[$i]}-${BOARD}\"/>"
            fi
        done
        echo "</testsuite>"
    } > "$JUNIT_XML"
    echo ""
    if [ "$nfail" -eq 0 ]; then
        echo "[PASS] astrod-api ${BOARD} (${#CASE_NAMES[@]} cases, ${t}s)"
    else
        echo "[FAIL] astrod-api ${BOARD} (${nfail}/${#CASE_NAMES[@]} cases failed, ${t}s):"
        for i in "${!CASE_NAMES[@]}"; do
            [ -n "${CASE_FAILS[$i]}" ] && echo "  - ${CASE_NAMES[$i]}: ${CASE_FAILS[$i]}"
        done
    fi
    echo "  serial: ${SERIAL_LOG}"
    echo "  junit:  ${JUNIT_XML}"
    [ "$nfail" -eq 0 ]
    exit $?
}

: > "$SERIAL_LOG"

##############################################################################
# Case: boot
##############################################################################
case_begin "boot"
echo "[STEP] Booting ${BOARD}/${VARIANT} (scratch overlay, ssh :${SSH_PORT})..."
start_qemu
if ! wait_ssh "initial boot"; then
    case_end
    finish
fi
echo "[STEP] SSH is up"
case_end

##############################################################################
# Case: system-auth — GET /system + the AD-014 401 matrix (regression)
##############################################################################
case_begin "system-auth"
echo "[STEP] astroctl system over the unix socket..."
SYS_OUT=$("${SSH[@]}" "astroctl system" 2>&1) || fail "astroctl system failed"
evidence "astroctl system" "$SYS_OUT"
echo "$SYS_OUT" | grep -q "board" || fail "astroctl system output missing the board line"

echo "[STEP] Bearer-token matrix on 127.0.0.1:8080..."
TOKEN=$("${SSH[@]}" "cat /data/config/api-token" | tr -d '[:space:]') || fail "cannot read /data/config/api-token"
[ -n "$TOKEN" ] || fail "empty api token"

code=$("${SSH[@]}" "curl -s -o /dev/null -w '%{http_code}' --max-time 20 http://127.0.0.1:8080/api/v1/system" || echo "000")
[ "$code" = "401" ] || fail "no-token request answered ${code}, expected 401"

hdr=$("${SSH[@]}" "curl -si --max-time 20 http://127.0.0.1:8080/api/v1/system" || :)
echo "$hdr" | grep -qi '^content-type: application/problem+json' || {
    evidence "401 response head" "$hdr"
    fail "401 is not application/problem+json"
}

code=$("${SSH[@]}" "curl -s -o /dev/null -w '%{http_code}' --max-time 20 -H 'Authorization: Bearer wrong-token' http://127.0.0.1:8080/api/v1/system" || echo "000")
[ "$code" = "401" ] || fail "bad-token request answered ${code}, expected 401"

code=$("${SSH[@]}" "curl -s -o /dev/null -w '%{http_code}' --max-time 20 -H 'Authorization: Bearer ${TOKEN}' http://127.0.0.1:8080/api/v1/system" || echo "000")
[ "$code" = "200" ] || fail "good-token request answered ${code}, expected 200"
case_end

##############################################################################
# Case: network-eth0 — observed state via rtnetlink + slirp DHCP
##############################################################################
case_begin "network-eth0"
echo "[STEP] GET /api/v1/network..."
NET_BODY=$(api_get /api/v1/network || :)
evidence "GET /network" "$NET_BODY"
if ! jq -e '.interfaces[] | select(.name=="eth0") | select(.carrier==true)' >/dev/null 2>&1 <<<"$NET_BODY"; then
    fail "eth0 missing or carrier!=true in GET /network"
fi
if ! jq -e '.interfaces[] | select(.name=="eth0") | .addresses[] | select(test("^10\\.0\\.2\\."))' >/dev/null 2>&1 <<<"$NET_BODY"; then
    fail "eth0 has no slirp 10.0.2.x address in GET /network"
fi
jq -e '.wan.order | length >= 1' >/dev/null 2>&1 <<<"$NET_BODY" || fail "GET /network missing wan.order"
case_end

##############################################################################
# Case: resolv-conf — docs/07 §2 one-writer model, live
##############################################################################
case_begin "resolv-conf"
echo "[STEP] /etc/resolv.conf symlink + rendered target..."
LINK=$("${SSH[@]}" "readlink /etc/resolv.conf" || :)
echo "readlink /etc/resolv.conf -> '${LINK}'"
case "$LINK" in
    ../run/astro-resolv/resolv.conf|/run/astro-resolv/resolv.conf) : ;;
    *) fail "/etc/resolv.conf is not the astro symlink (got '${LINK}')" ;;
esac
RESOLV=$("${SSH[@]}" "cat /run/astro-resolv/resolv.conf" || :)
evidence "/run/astro-resolv/resolv.conf" "$RESOLV"
# The renderer must brand its output (one-writer marker): a comment line
# naming astrod distinguishes the rendered file from anything a stray
# resolvconf/dhcpcd hook could have written.
echo "$RESOLV" | grep -q '^#.*astrod' || fail "resolv.conf missing the astrod rendered-marker comment"
echo "$RESOLV" | grep -q '^nameserver 10\.0\.2\.' || fail "resolv.conf missing the slirp DNS (10.0.2.x) learned via the dhcpcd lease hook"
case_end

##############################################################################
# Case: update-status — phase-2 surface still reachable (regression)
##############################################################################
case_begin "update-status"
echo "[STEP] astroctl update status..."
UPD_OUT=$("${SSH[@]}" "astroctl update status" 2>&1) || fail "astroctl update status failed"
evidence "astroctl update status" "$UPD_OUT"
echo "$UPD_OUT" | grep -q 'boot_slot' || fail "update status output missing boot_slot"
echo "$UPD_OUT" | grep -q 'SLOT' || fail "update status output missing the slot table"
case_end

##############################################################################
# Case: wifi-e2e — hwsim AP on radio 1, full station flow via the API
##############################################################################
case_begin "wifi-e2e"

echo "[STEP] Waiting for both hwsim radios in iwd (iwctl device list)..."
radios_ok=false
waited=0
while [ "$waited" -lt 60 ]; do
    DEVLIST=$("${SSH[@]}" "iwctl device list" 2>/dev/null || :)
    if echo "$DEVLIST" | grep -q 'wlan0' && echo "$DEVLIST" | grep -q 'wlan1'; then
        radios_ok=true
        break
    fi
    sleep 3; waited=$((waited + 3))
done
evidence "iwctl device list" "${DEVLIST:-<empty>}"
if [ "$radios_ok" != true ]; then
    fail "hwsim radios wlan0/wlan1 not visible in iwd within 60s"
    case_end
    finish
fi

echo "[STEP] Writing the AP provisioning profile (/data/net/iwd/ap/${TEST_SSID}.ap)..."
# The outer double quotes expand ${TEST_PSK}/${AP_ADDR} locally; the
# quoted 'EOF' keeps the remote shell from expanding anything else.
"${SSH[@]}" "mkdir -p /data/net/iwd/ap && cat > /data/net/iwd/ap/${TEST_SSID}.ap <<'EOF'
# Test-rig AP profile (iwd.ap(5)): [IPv4] enables iwd's built-in DHCP
# server for this AP — the pool astrod's station side must lease from.
[Security]
Passphrase=${TEST_PSK}

[IPv4]
Address=${AP_ADDR}
Netmask=255.255.255.0
EOF" || fail "could not write the AP profile"

echo "[STEP] Enabling iwd netconfig for the AP phase (bind-mount /etc/iwd override; see header)..."
"${SSH[@]}" "mkdir -p /run/astro-test/iwd \
    && sed 's/^EnableNetworkConfiguration=false/EnableNetworkConfiguration=true/' /etc/iwd/main.conf > /run/astro-test/iwd/main.conf \
    && mount --bind /run/astro-test/iwd /etc/iwd \
    && dinitctl restart iwd" || fail "could not apply the iwd netconfig override"

echo "[STEP] Waiting for iwd to come back with both radios..."
waited=0
while [ "$waited" -lt 60 ]; do
    DEVLIST=$("${SSH[@]}" "iwctl device list" 2>/dev/null || :)
    if echo "$DEVLIST" | grep -q 'wlan0' && echo "$DEVLIST" | grep -q 'wlan1'; then
        break
    fi
    sleep 3; waited=$((waited + 3))
done

echo "[STEP] Switching wlan1 to AP mode and starting the profile..."
"${SSH[@]}" "iwctl device wlan1 set-property Mode ap" || fail "iwctl set-property Mode ap failed"
sleep 2
"${SSH[@]}" "iwctl ap wlan1 start-profile ${TEST_SSID}" || fail "iwctl ap start-profile failed"

# Address assertion goes through astrod's GET /network (rtnetlink
# observation) — the image ships no iproute2, and the API is the
# surface under test anyway.
ap_ip_ok=false
waited=0
while [ "$waited" -lt 30 ]; do
    NET_BODY=$(api_get /api/v1/network || :)
    if jq -e --arg a "$AP_ADDR" \
        '.interfaces[] | select(.name=="wlan1") | .addresses[] | select(startswith($a))' \
        >/dev/null 2>&1 <<<"$NET_BODY"; then
        ap_ip_ok=true
        break
    fi
    sleep 2; waited=$((waited + 2))
done
if [ "$ap_ip_ok" != true ]; then
    AP_STATE=$("${SSH[@]}" "iwctl ap wlan1 show" 2>&1 || :; printf '%s\n' "GET /network: ${NET_BODY:-<empty>}")
    evidence "AP bring-up state" "$AP_STATE"
    fail "wlan1 never got the AP address ${AP_ADDR} (iwd DHCP server not up — netconfig override or profile [IPv4] broken?)"
    case_end
    finish
fi
echo "[OK] AP up on wlan1 (${AP_ADDR}, iwd DHCP pool)"

echo "[STEP] API: wifi scan until '${TEST_SSID}' is visible..."
ssid_seen=false
for attempt in 1 2 3; do
    SCAN_RESP=$(api_post /api/v1/network/wifi/scan || :)
    OP_PATH=$(jq -r '.operation // empty' <<<"$SCAN_RESP" 2>/dev/null || :)
    if [ -z "$OP_PATH" ]; then
        evidence "POST /network/wifi/scan (attempt ${attempt})" "$SCAN_RESP"
        fail "scan did not return an operation"
        break
    fi
    echo "  scan attempt ${attempt}: operation ${OP_PATH}"
    waited=0
    while [ "$waited" -lt 30 ]; do
        OP_STATE=$(api_get "$OP_PATH" | jq -r '.state // empty' 2>/dev/null || :)
        if [ "$OP_STATE" = "succeeded" ] || [ "$OP_STATE" = "failed" ]; then
            break
        fi
        sleep 2; waited=$((waited + 2))
    done
    echo "  scan operation state: ${OP_STATE:-<none>}"
    NETWORKS=$(api_get /api/v1/network/wifi/networks || :)
    evidence "GET /network/wifi/networks (attempt ${attempt})" "$NETWORKS"
    if jq -e --arg s "$TEST_SSID" 'any(.[]; .ssid==$s)' >/dev/null 2>&1 <<<"$NETWORKS"; then
        ssid_seen=true
        break
    fi
    sleep 3
done
[ "$ssid_seen" = true ] || fail "'${TEST_SSID}' never appeared in GET /network/wifi/networks after 3 scans"

echo "[STEP] API: PUT /network/wifi/connection (connect)..."
CONNECT_CODE=$("${SSH[@]}" "curl -s -o /tmp/connect-body -w '%{http_code}' --max-time 20 -X PUT -H 'Content-Type: application/json' --data '{\"ssid\":\"${TEST_SSID}\",\"psk\":\"${TEST_PSK}\"}' --unix-socket /run/astro/astrod.sock http://localhost/api/v1/network/wifi/connection" || echo "000")
if [ "${CONNECT_CODE:0:1}" != "2" ]; then
    CONNECT_BODY=$("${SSH[@]}" "cat /tmp/connect-body" 2>/dev/null || :)
    evidence "PUT /network/wifi/connection -> ${CONNECT_CODE}" "$CONNECT_BODY"
    fail "connect PUT answered ${CONNECT_CODE}, expected 2xx"
fi

echo "[STEP] Polling GET /network/wifi until state=connected (60s)..."
connected=false
waited=0
last_state=""
while [ "$waited" -lt 60 ]; do
    WIFI_STATE=$(api_get /api/v1/network/wifi || :)
    state=$(jq -r '.state // empty' <<<"$WIFI_STATE" 2>/dev/null || :)
    if [ "$state" != "$last_state" ]; then
        echo "  wifi state: ${state:-<unparseable>}"
        last_state="$state"
    fi
    if [ "$state" = "connected" ]; then
        connected=true
        break
    fi
    sleep 2; waited=$((waited + 2))
done
if [ "$connected" != true ]; then
    evidence "GET /network/wifi (last)" "${WIFI_STATE:-<empty>}"
    fail "station never reached state=connected within 60s (last: '${last_state}')"
    case_end
    finish
fi
jq -e --arg s "$TEST_SSID" '.connected_ssid==$s' >/dev/null 2>&1 <<<"$WIFI_STATE" \
    || fail "connected_ssid is not '${TEST_SSID}'"
echo "[OK] station connected to ${TEST_SSID}"

echo "[STEP] Asserting wlan0 leased an address from the AP pool (${AP_POOL_RE}x)..."
lease_ok=false
waited=0
while [ "$waited" -lt 30 ]; do
    NET_BODY=$(api_get /api/v1/network || :)
    if jq -e --arg re "^${AP_POOL_RE}" '.interfaces[] | select(.name=="wlan0") | .addresses[] | select(test($re))' >/dev/null 2>&1 <<<"$NET_BODY"; then
        lease_ok=true
        break
    fi
    sleep 2; waited=$((waited + 2))
done
evidence "GET /network (after connect)" "${NET_BODY:-<empty>}"
[ "$lease_ok" = true ] || fail "wlan0 never held a ${AP_POOL_RE}x address in GET /network"

echo "[STEP] API: DELETE /network/wifi/connection (forget)..."
DEL_CODE=$(api_code DELETE /api/v1/network/wifi/connection || echo "000")
[ "$DEL_CODE" = "204" ] || fail "forget answered ${DEL_CODE}, expected 204"

disconnected=false
waited=0
while [ "$waited" -lt 30 ]; do
    WIFI_STATE=$(api_get /api/v1/network/wifi || :)
    state=$(jq -r '.state // empty' <<<"$WIFI_STATE" 2>/dev/null || :)
    ssid_now=$(jq -r '.connected_ssid // empty' <<<"$WIFI_STATE" 2>/dev/null || :)
    if [ "$state" != "connected" ] && [ -z "$ssid_now" ]; then
        disconnected=true
        break
    fi
    sleep 2; waited=$((waited + 2))
done
if [ "$disconnected" = true ]; then
    echo "[OK] profile forgotten, station state: ${state:-<none>}"
else
    evidence "GET /network/wifi (after forget)" "${WIFI_STATE:-<empty>}"
    fail "station still connected after forget"
fi

echo "[STEP] Restoring the shipped iwd posture (umount override, restart iwd)..."
"${SSH[@]}" "iwctl ap wlan1 stop >/dev/null 2>&1 || :; umount /etc/iwd && dinitctl restart iwd" \
    || echo "[WARN] iwd posture restore failed (test-scoped guest, not fatal)"
case_end

##############################################################################
# Case: astrod-rss — docs/06 §3 budget after the whole suite
##############################################################################
case_begin "astrod-rss"
echo "[STEP] astrod VmRSS after the suite..."
# The image ships no pidof/pgrep/ps — find astrod by /proc/<pid>/comm.
STATUS_OUT=$("${SSH[@]}" 'for c in /proc/[0-9]*/comm; do read -r n < "$c" 2>/dev/null || continue; if [ "$n" = astrod ]; then cat "${c%/comm}/status"; break; fi; done' 2>/dev/null || :)
RSS_KB=$(printf '%s\n' "$STATUS_OUT" | awk '/^VmRSS:/{print $2}')
echo "astrod VmRSS: ${RSS_KB:-<unknown>} kB (budget 16384 kB)"
if [ -z "${RSS_KB:-}" ]; then
    fail "could not read astrod VmRSS (daemon dead?)"
elif [ "$RSS_KB" -ge 16384 ]; then
    fail "astrod VmRSS ${RSS_KB} kB breaches the 16 MiB budget"
fi
case_end

##############################################################################
# Case: provisioning-e2e — docs/07 §4 on the 3-radio rig (M3 phase 4)
##############################################################################
# Radio roles (mac80211_hwsim.radios=3, boards/*/board.toml cmdline):
#   wlan0 = DUT: astrod's station/AP flip radio (first device, v1 policy)
#   wlan1 = upstream test AP (the network the portal user selects)
#   wlan2 = the "phone": associates with the provisioning AP
case_begin "provisioning-e2e"

# -- Step 0: reach the factory-fresh state -----------------------------------
# wifi-e2e above PROMOTED the device: PUT wifi/connection made
# has_network_config true and eth0's lease already satisfies the v1
# connectivity check, so system.provisioning persisted 'provisioned' —
# and provisioned is TERMINAL until factory reset (docs/07 §4 "the AP
# never returns"; provision.zig). The phase-4 fresh-boot story therefore
# starts with a reset here; the factory-reset case below owns the full
# assertion set (tokens/machine-id/stamps), this one only needs the
# wipe+reboot.
echo "[STEP] Factory reset to reach the fresh-boot provisioning state..."
MID=$("${SSH[@]}" "cat /etc/machine-id" | tr -d '[:space:]') || fail "cannot read /etc/machine-id"
RESET_CODE=$("${SSH[@]}" "curl -s -o /tmp/reset-body -w '%{http_code}' --max-time 20 -X POST -H 'Content-Type: application/json' --data '{\"confirm\":\"${MID}\"}' --unix-socket /run/astro/astrod.sock http://localhost/api/v1/system/factory-reset" || echo "000")
if [ "$RESET_CODE" != "202" ]; then
    RESET_BODY=$("${SSH[@]}" "cat /tmp/reset-body" 2>/dev/null || :)
    evidence "POST /system/factory-reset -> ${RESET_CODE}" "$RESET_BODY"
    fail "setup factory reset answered ${RESET_CODE}, expected 202"
    case_end
    finish
fi
if ! wait_ssh_down "factory-reset reboot (setup)"; then case_end; finish; fi
if ! wait_ssh "boot after setup factory reset"; then case_end; finish; fi

# -- Step 1: fresh boot is 'provisioning', NOT 'provisioned' -----------------
# The dev image ships no wifi config; eth0 leases from slirp; the store
# default api.wired_provisions=false means the wired path only SURFACES
# availability (docs/07 §4) — so the answer must be 'provisioning'
# (factory flips to it on the startup edge with no usable config).
echo "[STEP] Asserting provisioning state on the fresh /data..."
prov_state=""
waited=0
while [ "$waited" -lt 60 ]; do
    prov_state=$(api_get /api/v1/system | jq -r '.provisioning // empty' 2>/dev/null || :)
    [ "$prov_state" = "provisioning" ] && break
    sleep 2; waited=$((waited + 2))
done
if [ "$prov_state" != "provisioning" ]; then
    evidence "GET /system (fresh boot)" "$(api_get /api/v1/system || :)"
    fail "fresh-boot provisioning state is '${prov_state:-<none>}', expected 'provisioning'"
fi
PROV_OUT=$("${SSH[@]}" "astroctl provision status" 2>&1) || fail "astroctl provision status failed"
evidence "astroctl provision status" "$PROV_OUT"
echo "$PROV_OUT" | grep -q '^state    provisioning$' || fail "provision status missing 'state    provisioning'"
echo "$PROV_OUT" | grep -q '^wired    eth0: carrier yes' || fail "provision status missing the eth0 wired observation"

# -- Step 2: upstream test AP on wlan1 (phase-3 mechanics, verbatim) ---------
echo "[STEP] Waiting for all three hwsim radios in iwd..."
radios_ok=false
waited=0
while [ "$waited" -lt 60 ]; do
    DEVLIST=$("${SSH[@]}" "iwctl device list" 2>/dev/null || :)
    if echo "$DEVLIST" | grep -q 'wlan0' && echo "$DEVLIST" | grep -q 'wlan1' && echo "$DEVLIST" | grep -q 'wlan2'; then
        radios_ok=true
        break
    fi
    sleep 3; waited=$((waited + 3))
done
evidence "iwctl device list (3-radio)" "${DEVLIST:-<empty>}"
if [ "$radios_ok" != true ]; then
    fail "hwsim radios wlan0/wlan1/wlan2 not visible in iwd within 60s (mac80211_hwsim.radios=3 missing from the cmdline?)"
    case_end
    finish
fi

echo "[STEP] Upstream AP profile + iwd netconfig override (see wifi-e2e header)..."
"${SSH[@]}" "mkdir -p /data/net/iwd/ap && cat > /data/net/iwd/ap/${TEST_SSID}.ap <<'EOF'
[Security]
Passphrase=${TEST_PSK}

[IPv4]
Address=${AP_ADDR}
Netmask=255.255.255.0
EOF" || fail "could not write the upstream AP profile"
"${SSH[@]}" "mkdir -p /run/astro-test/iwd \
    && sed 's/^EnableNetworkConfiguration=false/EnableNetworkConfiguration=true/' /etc/iwd/main.conf > /run/astro-test/iwd/main.conf \
    && mount --bind /run/astro-test/iwd /etc/iwd \
    && dinitctl restart iwd" || fail "could not apply the iwd netconfig override"
waited=0
while [ "$waited" -lt 60 ]; do
    DEVLIST=$("${SSH[@]}" "iwctl device list" 2>/dev/null || :)
    if echo "$DEVLIST" | grep -q 'wlan1' && echo "$DEVLIST" | grep -q 'wlan2'; then break; fi
    sleep 3; waited=$((waited + 3))
done
"${SSH[@]}" "iwctl device wlan1 set-property Mode ap" || fail "iwctl set-property Mode ap (wlan1) failed"
sleep 2
"${SSH[@]}" "iwctl ap wlan1 start-profile ${TEST_SSID}" || fail "iwctl ap start-profile (upstream) failed"
up_ok=false
waited=0
while [ "$waited" -lt 30 ]; do
    NET_BODY=$(api_get /api/v1/network || :)
    if jq -e --arg a "$AP_ADDR" '.interfaces[] | select(.name=="wlan1") | .addresses[] | select(startswith($a))' >/dev/null 2>&1 <<<"$NET_BODY"; then
        up_ok=true
        break
    fi
    sleep 2; waited=$((waited + 2))
done
[ "$up_ok" = true ] || fail "upstream AP never got ${AP_ADDR} on wlan1"

# Pre-AP station scan: GET /networks serves CACHED pre-AP results while
# the DUT radio is in AP mode (spec listWifiNetworks), so the upstream
# SSID must enter the cache BEFORE the flip.
echo "[STEP] Pre-AP scan until the upstream SSID is cached..."
ssid_seen=false
for attempt in 1 2 3; do
    SCAN_RESP=$(api_post /api/v1/network/wifi/scan || :)
    OP_PATH=$(jq -r '.operation // empty' <<<"$SCAN_RESP" 2>/dev/null || :)
    if [ -n "$OP_PATH" ]; then
        waited=0
        while [ "$waited" -lt 30 ]; do
            OP_STATE=$(api_get "$OP_PATH" | jq -r '.state // empty' 2>/dev/null || :)
            { [ "$OP_STATE" = "succeeded" ] || [ "$OP_STATE" = "failed" ]; } && break
            sleep 2; waited=$((waited + 2))
        done
    fi
    NETWORKS=$(api_get /api/v1/network/wifi/networks || :)
    if jq -e --arg s "$TEST_SSID" 'any(.[]; .ssid==$s)' >/dev/null 2>&1 <<<"$NETWORKS"; then
        ssid_seen=true
        break
    fi
    sleep 3
done
[ "$ssid_seen" = true ] || fail "'${TEST_SSID}' never appeared in the pre-AP scan cache"

# -- Step 3: provisioning AP up via the manual override ----------------------
# The docs/07 §4 AUTO-trigger for the AP is "no ethernet carrier"; this
# rig always has eth0 carrier (that IS the wired-available path), so the
# AP is deliberately down here — which itself is asserted, then the
# manual override (PUT /network/wifi/ap, docs/06 §5.2) forces it up.
# This doubles as the astroctl `wifi ap enable` e2e.
echo "[STEP] AP down by default (eth carrier present), then wifi ap enable..."
AP_SHOW=$("${SSH[@]}" "astroctl wifi ap show" 2>&1) || fail "astroctl wifi ap show failed"
evidence "astroctl wifi ap show (pre-enable)" "$AP_SHOW"
echo "$AP_SHOW" | grep -q '^enabled  no$' || fail "AP unexpectedly up before the override (eth carrier should suppress the auto-trigger)"

"${SSH[@]}" "astroctl wifi ap enable" >/dev/null 2>&1 || fail "astroctl wifi ap enable failed"
ap_up=false
waited=0
while [ "$waited" -lt 60 ]; do
    AP_SHOW=$("${SSH[@]}" "astroctl wifi ap show" 2>/dev/null || :)
    if echo "$AP_SHOW" | grep -q '^enabled  yes$'; then
        # The AP address on wlan0 is the readiness signal for the
        # listener + DHCP pool, not just the iwd mode flip.
        NET_BODY=$(api_get /api/v1/network || :)
        if jq -e --arg a "$PORTAL_ADDR" '.interfaces[] | select(.name=="wlan0") | .addresses[] | select(startswith($a))' >/dev/null 2>&1 <<<"$NET_BODY"; then
            ap_up=true
            break
        fi
    fi
    sleep 2; waited=$((waited + 2))
done
evidence "astroctl wifi ap show (post-enable)" "${AP_SHOW:-<empty>}"
if [ "$ap_up" != true ]; then
    fail "provisioning AP never came up on wlan0 (${PORTAL_ADDR}) after wifi ap enable"
    case_end
    finish
fi

# Derived identity: SSID astro-<last 6 hex of machine-id>; the PSK line
# is the socket-surface-only label story (never served over HTTP).
AP_SSID=$(echo "$AP_SHOW" | awk '$1=="ssid"{print $2}')
AP_PSK=$(echo "$AP_SHOW" | awk '$1=="psk"{print $2}')
MID=$("${SSH[@]}" "cat /etc/machine-id" | tr -d '[:space:]') || :
WANT_SSID="astro-$(printf '%s' "$MID" | tail -c 6)"
[ "$AP_SSID" = "$WANT_SSID" ] || fail "AP ssid '${AP_SSID}' != derived '${WANT_SSID}'"
echo "$AP_PSK" | grep -Eq '^[0-9a-f]{16}$' || fail "derived PSK '${AP_PSK}' is not 16 lowercase hex chars"

# -- Step 4: the phone radio sees and joins the AP ---------------------------
echo "[STEP] wlan2: scan for ${AP_SSID} and connect with the derived PSK..."
ap_visible=false
for attempt in 1 2 3 4; do
    "${SSH[@]}" "iwctl station wlan2 scan" >/dev/null 2>&1 || :
    sleep 3
    WLAN2_NETS=$("${SSH[@]}" "iwctl station wlan2 get-networks" 2>/dev/null || :)
    if echo "$WLAN2_NETS" | grep -q "$AP_SSID"; then
        ap_visible=true
        break
    fi
done
evidence "iwctl station wlan2 get-networks" "${WLAN2_NETS:-<empty>}"
[ "$ap_visible" = true ] || fail "'${AP_SSID}' never visible from the phone radio (wlan2)"

"${SSH[@]}" "iwctl --passphrase ${AP_PSK} station wlan2 connect ${AP_SSID}" || fail "wlan2 could not associate with ${AP_SSID}"
lease_ok=false
waited=0
while [ "$waited" -lt 45 ]; do
    NET_BODY=$(api_get /api/v1/network || :)
    if jq -e --arg re "^${PORTAL_POOL_RE}" '.interfaces[] | select(.name=="wlan2") | .addresses[] | select(test($re))' >/dev/null 2>&1 <<<"$NET_BODY"; then
        lease_ok=true
        break
    fi
    sleep 2; waited=$((waited + 2))
done
evidence "GET /network (wlan2 joined)" "${NET_BODY:-<empty>}"
[ "$lease_ok" = true ] || fail "wlan2 never leased a ${PORTAL_POOL_RE}x address from the AP pool"

# -- Step 5: the portal surface --------------------------------------------
# See portal_get() for why these run guest-local against the AP listener
# rather than --interface wlan2 over the air.
echo "[STEP] Portal surface: probes, page, redacted subset, 403 wall..."
PROBE_OUT=$("${SSH[@]}" "curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 20 http://${PORTAL_ADDR}:8080/generate_204" || echo "000")
case "$PROBE_OUT" in
    302*/) : ;;
    *) fail "/generate_204 answered '${PROBE_OUT}', expected 302 with Location /" ;;
esac

PAGE=$(portal_get / || :)
echo "$PAGE" | grep -q 'Astro device setup' || {
    evidence "GET / (portal)" "${PAGE:0:400}"
    fail "portal page missing the 'Astro device setup' title"
}

REDACTED=$(portal_get /api/v1/system || :)
evidence "GET /system (AP surface)" "$REDACTED"
jq -e '.provisioning=="provisioning"' >/dev/null 2>&1 <<<"$REDACTED" || fail "AP-surface /system missing provisioning=provisioning"
if jq -e 'has("machine_id")' >/dev/null 2>&1 <<<"$REDACTED"; then
    fail "AP-surface /system leaked machine_id (redaction broken)"
fi
# Contrast: the authenticated socket surface still serves it.
jq -e 'has("machine_id")' >/dev/null 2>&1 <<<"$(api_get /api/v1/system)" || fail "socket-surface /system lost machine_id"

# Everything outside the subset answers 403 problem+json on this
# listener — even with a VALID bearer token (surface wall, not auth).
TOKEN=$("${SSH[@]}" "cat /data/config/api-token" | tr -d '[:space:]') || :
DENY=$("${SSH[@]}" "curl -si --max-time 20 -H 'Authorization: Bearer ${TOKEN}' http://${PORTAL_ADDR}:8080/api/v1/update/status" || :)
echo "$DENY" | head -1 | grep -q ' 403 ' || fail "non-subset route on the AP listener did not answer 403 (token attached)"
echo "$DENY" | grep -qi '^content-type: application/problem+json' || fail "AP-surface 403 is not problem+json"

SCAN_CODE=$(portal_code POST /api/v1/network/wifi/scan || echo "000")
[ "$SCAN_CODE" = "202" ] || fail "portal scan answered ${SCAN_CODE}, expected 202"
PORTAL_NETS=$(portal_get /api/v1/network/wifi/networks || :)
jq -e --arg s "$TEST_SSID" 'any(.[]; .ssid==$s)' >/dev/null 2>&1 <<<"$PORTAL_NETS" || {
    evidence "GET /networks (AP surface)" "$PORTAL_NETS"
    fail "upstream '${TEST_SSID}' not in the portal's network list"
}

# The privileged-port story: the root oneshot pair loaded an nft table
# redirecting, on the AP interface only, 80->8080 and 53->5354
# (docs/07 §4; kernel NFT_REDIR configs). Ruleset presence is the
# assertion — the end-to-end port-80 hop needs a second network stack
# (see portal_get) and the DNS catch-all needs a resolver client the
# image does not ship; both are covered by unit tests + this rule.
NFT_RULES=$("${SSH[@]}" "nft list table ip astro_portal" 2>&1 || :)
evidence "nft list table ip astro_portal" "$NFT_RULES"
echo "$NFT_RULES" | grep -q 'dport 80' || fail "nft portal table missing the tcp 80 redirect"
echo "$NFT_RULES" | grep -q '8080' || fail "nft portal table missing the 8080 target"
echo "$NFT_RULES" | grep -q 'dport 53' || fail "nft portal table missing the udp 53 redirect"
echo "$NFT_RULES" | grep -q '5354' || fail "nft portal table missing the 5354 target"

# -- Step 6: submit upstream credentials, watch the flip ---------------------
echo "[STEP] PUT wifi/connection via the portal surface (the flip)..."
FLIP_CODE=$("${SSH[@]}" "curl -s -o /tmp/flip-body -w '%{http_code}' --max-time 20 -X PUT -H 'Content-Type: application/json' --data '{\"ssid\":\"${TEST_SSID}\",\"psk\":\"${TEST_PSK}\"}' http://${PORTAL_ADDR}:8080/api/v1/network/wifi/connection" || echo "000")
if [ "${FLIP_CODE:0:1}" != "2" ]; then
    evidence "portal PUT connection -> ${FLIP_CODE}" "$("${SSH[@]}" "cat /tmp/flip-body" 2>/dev/null || :)"
    fail "portal connection PUT answered ${FLIP_CODE}, expected 2xx"
fi
# Return AP control to the state machine: with the override still
# 'true' the manual force would fight the flip/'never returns' rule.
"${SSH[@]}" "astroctl wifi ap auto" >/dev/null 2>&1 || fail "astroctl wifi ap auto failed"

echo "[STEP] Waiting for the station to reach the upstream AP..."
connected=false
waited=0
last_state=""
while [ "$waited" -lt 90 ]; do
    WIFI_STATE=$(api_get /api/v1/network/wifi || :)
    state=$(jq -r '.state // empty' <<<"$WIFI_STATE" 2>/dev/null || :)
    if [ "$state" != "$last_state" ]; then
        echo "  wifi state: ${state:-<unparseable>}"
        last_state="$state"
    fi
    if [ "$state" = "connected" ] && jq -e --arg s "$TEST_SSID" '.connected_ssid==$s' >/dev/null 2>&1 <<<"$WIFI_STATE"; then
        connected=true
        break
    fi
    sleep 2; waited=$((waited + 2))
done
if [ "$connected" != true ]; then
    evidence "GET /network/wifi (last)" "${WIFI_STATE:-<empty>}"
    fail "station never connected to '${TEST_SSID}' after the flip (last state '${last_state}')"
fi

prov_state=""
waited=0
while [ "$waited" -lt 30 ]; do
    prov_state=$(api_get /api/v1/system | jq -r '.provisioning // empty' 2>/dev/null || :)
    [ "$prov_state" = "provisioned" ] && break
    sleep 2; waited=$((waited + 2))
done
[ "$prov_state" = "provisioned" ] || fail "state is '${prov_state:-<none>}' after the flip, expected 'provisioned'"
# mDNS TXT (provisioning=...) is NOT asserted over the wire: slirp
# user-net does not bridge guest multicast, and an in-guest listener
# would race the announcer on the same stack. GET /system above is the
# TXT payload's source of truth; mdns.zig unit tests pin the encoding.
# A bridged-net board owns the on-air assert when one joins the lab.

echo "[STEP] AP gone for good: show says no, the listener is dead..."
AP_SHOW=$("${SSH[@]}" "astroctl wifi ap show" 2>/dev/null || :)
echo "$AP_SHOW" | grep -q '^enabled  no$' || fail "wifi ap show still enabled after provisioning"
DEAD_CODE=$("${SSH[@]}" "curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://${PORTAL_ADDR}:8080/api/v1/system" || echo "000")
# curl -w prints 000 itself on connect failure and the || echo then
# doubles it ("000000"); normalize to the first three digits.
DEAD_CODE="${DEAD_CODE:0:3}"
if [ "$DEAD_CODE" != "000" ] && [ "$DEAD_CODE" != "403" ]; then
    # 000 = connection refused/unroutable (address gone with the AP);
    # a 403 would mean the listener outlived the AP but still walls —
    # tolerated with a warning, anything else is a leak.
    fail "portal listener still answering ${DEAD_CODE} after provisioning"
fi

# Same-lifetime memory budget after the whole AP/portal cycle (the
# astrod-rss case above measured the pre-reset daemon).
STATUS_OUT=$("${SSH[@]}" 'for c in /proc/[0-9]*/comm; do read -r n < "$c" 2>/dev/null || continue; if [ "$n" = astrod ]; then cat "${c%/comm}/status"; break; fi; done' 2>/dev/null || :)
RSS_KB=$(printf '%s\n' "$STATUS_OUT" | awk '/^VmRSS:/{print $2}')
echo "astrod VmRSS after the provisioning cycle: ${RSS_KB:-<unknown>} kB"
if [ -z "${RSS_KB:-}" ]; then
    fail "could not read astrod VmRSS after the provisioning cycle"
elif [ "$RSS_KB" -ge 16384 ]; then
    fail "astrod VmRSS ${RSS_KB} kB breaches the budget after the AP/portal cycle"
fi
case_end

##############################################################################
# Case: factory-reset — docs/07 §5 via astroctl (M3 phase 4)
##############################################################################
case_begin "factory-reset"
OLD_TOKEN=$("${SSH[@]}" "cat /data/config/api-token" | tr -d '[:space:]') || fail "cannot read the pre-reset api token"
OLD_MID=$("${SSH[@]}" "cat /etc/machine-id" | tr -d '[:space:]') || fail "cannot read the pre-reset machine-id"

echo "[STEP] Wrong confirm is refused (400, no reboot)..."
BAD_CODE=$("${SSH[@]}" "curl -s -o /dev/null -w '%{http_code}' --max-time 20 -X POST -H 'Content-Type: application/json' --data '{\"confirm\":\"not-the-machine-id\"}' --unix-socket /run/astro/astrod.sock http://localhost/api/v1/system/factory-reset" || echo "000")
[ "$BAD_CODE" = "400" ] || fail "wrong-confirm factory reset answered ${BAD_CODE}, expected 400"
sleep 3
"${SSH[@]}" true 2>/dev/null || fail "guest went down after a REFUSED factory reset"

echo "[STEP] astroctl factory-reset --yes-really-wipe ${OLD_MID}..."
RESET_OUT=$("${SSH[@]}" "astroctl factory-reset --yes-really-wipe ${OLD_MID}" 2>&1) || fail "astroctl factory-reset failed: ${RESET_OUT}"
evidence "astroctl factory-reset" "$RESET_OUT"
echo "$RESET_OUT" | grep -q 'accepted' || fail "factory-reset output missing 'accepted'"
if ! wait_ssh_down "factory-reset reboot"; then case_end; finish; fi
if ! wait_ssh "boot after factory reset"; then case_end; finish; fi

echo "[STEP] Fresh data lifetime: state, stamps, token, machine-id..."
prov_state=""
waited=0
while [ "$waited" -lt 60 ]; do
    prov_state=$(api_get /api/v1/system | jq -r '.provisioning // empty' 2>/dev/null || :)
    [ "$prov_state" = "provisioning" ] && break
    sleep 2; waited=$((waited + 2))
done
[ "$prov_state" = "provisioning" ] || fail "post-reset state is '${prov_state:-<none>}', expected 'provisioning'"

"${SSH[@]}" "test -f /data/.astro/firstboot-done" || fail "firstboot did not rerun (no fresh done-stamp)"
"${SSH[@]}" "test ! -e /data/.astro/factory-reset-request" || fail "factory-reset flag survived the wipe"
SCHEMA=$("${SSH[@]}" "cat /data/.astro/schema-version" 2>/dev/null | tr -d '[:space:]' || :)
[ "$SCHEMA" = "1" ] || fail "post-reset schema-version is '${SCHEMA}', expected 1"

NEW_TOKEN=$("${SSH[@]}" "cat /data/config/api-token" | tr -d '[:space:]') || fail "no api token after the reset"
[ -n "$NEW_TOKEN" ] || fail "empty post-reset api token"
[ "$NEW_TOKEN" != "$OLD_TOKEN" ] || fail "api token survived the wipe (firstboot did not regenerate it)"
code=$("${SSH[@]}" "curl -s -o /dev/null -w '%{http_code}' --max-time 20 -H 'Authorization: Bearer ${OLD_TOKEN}' http://127.0.0.1:8080/api/v1/system" || echo "000")
[ "$code" = "401" ] || fail "OLD token answered ${code} on 127.0.0.1:8080, expected 401"
code=$("${SSH[@]}" "curl -s -o /dev/null -w '%{http_code}' --max-time 20 -H 'Authorization: Bearer ${NEW_TOKEN}' http://127.0.0.1:8080/api/v1/system" || echo "000")
[ "$code" = "200" ] || fail "NEW token answered ${code} on 127.0.0.1:8080, expected 200"

# Machine-id ownership (checked, asserted accordingly): the factory
# /etc/machine-id is EMPTY on the RO rootfs and dinit-chimera's
# early-machine-id writes the real one THROUGH THE /etc OVERLAY, whose
# upper lives on /data (MIGRATION-NOTES §12, data-mount.sh) — so a
# factory reset REGENERATES the identity. That is the intended
# sold-on-device behavior: the AP SSID/PSK and the mDNS instance name
# rotate with it, and the old confirm token can never wipe it again.
NEW_MID=$("${SSH[@]}" "cat /etc/machine-id" | tr -d '[:space:]') || fail "no machine-id after the reset"
[ -n "$NEW_MID" ] || fail "empty post-reset machine-id"
[ "$NEW_MID" != "$OLD_MID" ] || fail "machine-id survived the wipe (expected regeneration via the /etc overlay)"

WIFI_CONN=$(api_get /api/v1/network/wifi/connection || :)
[ "$WIFI_CONN" = "null" ] || fail "wifi connection config survived the wipe (got '${WIFI_CONN}')"
case_end

##############################################################################
# Case: time — docs/07 §6 floor + NTP sync (M3 phase 4)
##############################################################################
case_begin "time"
echo "[STEP] Build-epoch floor applied..."
BUILD_EPOCH=$("${SSH[@]}" "cat /etc/astro/build-epoch" | tr -d '[:space:]' || :)
case "$BUILD_EPOCH" in
    ''|*[!0-9]*) fail "/etc/astro/build-epoch missing or non-numeric ('${BUILD_EPOCH}')" ;;
esac
GUEST_NOW=$("${SSH[@]}" "date +%s" | tr -d '[:space:]' || echo 0)
if [ -n "$BUILD_EPOCH" ] && [ "$GUEST_NOW" -lt "$BUILD_EPOCH" ] 2>/dev/null; then
    fail "guest clock ${GUEST_NOW} is BEHIND the build epoch ${BUILD_EPOCH} (floor not applied)"
fi
TIME_OUT=$("${SSH[@]}" "astroctl time" 2>&1) || fail "astroctl time failed"
evidence "astroctl time" "$TIME_OUT"
echo "$TIME_OUT" | grep -q '^floor_ok yes$' || fail "astroctl time says the clock is behind the floor"
echo "$TIME_OUT" | grep -Eq '^floor    [0-9]+$' || fail "astroctl time missing the floor line"

# NTP sync: QEMU slirp forwards outbound UDP (the resolv-conf case
# already proves guest DNS through 10.0.2.3), so chronyd's
# `pool pool.ntp.org iburst` reaches real servers whenever the build
# host is online — synced=true within seconds of boot is the expected
# steady state, asserted here. Air-gapped runs set ASTRO_TEST_OFFLINE=1
# to flip the assertion (STA_UNSYNC must then still be set: false).
if [ "${ASTRO_TEST_OFFLINE:-0}" = "1" ]; then
    echo "[STEP] Offline run: time.synced must be false..."
    SYNCED=$(api_get /api/v1/system | jq -r '.time_synced' 2>/dev/null || :)
    [ "$SYNCED" = "false" ] || fail "offline run but time_synced='${SYNCED}', expected false"
else
    echo "[STEP] Waiting for chrony to sync through slirp UDP (120s)..."
    synced_ok=false
    waited=0
    while [ "$waited" -lt 120 ]; do
        SYNCED=$(api_get /api/v1/system | jq -r '.time_synced' 2>/dev/null || :)
        if [ "$SYNCED" = "true" ]; then
            synced_ok=true
            break
        fi
        sleep 5; waited=$((waited + 5))
    done
    if [ "$synced_ok" != true ]; then
        evidence "GET /system (time)" "$(api_get /api/v1/system || :)"
        fail "time_synced never became true (chrony unreachable? use ASTRO_TEST_OFFLINE=1 for air-gapped runs)"
    fi
    "${SSH[@]}" "astroctl time" 2>/dev/null | grep '^synced' || :
fi
case_end

finish
