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
#                  /run/astro/resolv.conf, the target carries astrod's
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

[ -f "$SSH_KEY" ] || { echo "ERROR: dev SSH key missing — run ./build/astro-keys.sh init-dev"; exit 1; }
[ -d "$OUT" ] || { echo "ERROR: image dir not found: ${OUT} — run ./build/astro-build.sh ${BOARD} ${VARIANT}"; exit 1; }

SSH=(ssh -i "$SSH_KEY" -p "$SSH_PORT" -o StrictHostKeyChecking=no
     -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
     -o ConnectTimeout=5 root@127.0.0.1)

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
    ../run/astro/resolv.conf|/run/astro/resolv.conf) : ;;
    *) fail "/etc/resolv.conf is not the astro symlink (got '${LINK}')" ;;
esac
RESOLV=$("${SSH[@]}" "cat /run/astro/resolv.conf" || :)
evidence "/run/astro/resolv.conf" "$RESOLV"
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

finish
