#!/bin/bash
set -euo pipefail

# Crag Linux - cragd API integration suite (M3 phase 3, docs/10 §4
# "cragd-api"): boots the dev image and exercises the network group end
# to end over the REAL stack — rtnetlink observation, dhcpcd addressing,
# cragd-rendered resolv.conf, and a full wifi station flow against an
# iwd access point on the kernel's mac80211_hwsim rig (two virtual
# radios, boards/*/kernel/qemu.fragment).
#
# Cases, in order (each is one junit <testcase> with wall time):
#   boot           dev image boots on a scratch overlay, SSH answers
#   system-auth    GET /system via cragctl + the AD-014 auth matrix on
#                  127.0.0.1:8080 (401 problem+json without/with-bad
#                  token, 200 with the firstboot token) — phase-1
#                  regression
#   network-eth0   GET /network shows eth0 with carrier and the QEMU
#                  slirp 10.0.2.x address (rtnetlink observation path)
#   resolv-conf    /etc/resolv.conf is the baked symlink into
#                  /run/crag-resolv/resolv.conf (world-readable — the
#                  0750 /run/crag gate must NOT cover it: unprivileged
#                  daemons like chronyd resolve through it), the target
#                  carries cragd's rendered marker comment and the
#                  slirp DNS (docs/07 §2 one-writer model, dhcpcd hook
#                  -> lease -> render)
#   update-status  GET /update/status reachable (phase-2 regression)
#   wifi-e2e       hwsim choreography: iwctl puts radio 1 in AP mode
#                  with iwd's built-in DHCP (AP profile in
#                  /data/net/iwd/ap, iwd.ap(5)), then THROUGH THE API:
#                  scan -> networks lists the test SSID -> connect ->
#                  GET /network/wifi reaches "connected" -> wlan0 holds
#                  an address from the AP pool in GET /network ->
#                  forget -> disconnected
#   cragd-rss     cragd VmRSS < 16 MiB after all of it (docs/06 §3)
#
# Hardening-pass cases (task #32), appended after cragd-rss:
#   api-negative   malformed/oversized bodies: invalid JSON and
#                  unknown-member bodies to the PUT/POST endpoints ->
#                  400 problem+json; a body over the 64 KiB cap -> 413
#                  problem+json (delivered, not RST); an update upload
#                  whose declared length exceeds free /data space ->
#                  507 insufficient-storage without staging residue
#   auth-matrix    bearer hardening on 127.0.0.1:8080 (valid token +
#                  trailing garbage, empty bearer, bare "Bearer", wrong
#                  scheme -> all 401 problem+json), token-file rotation
#                  mid-session (old token 401s IMMEDIATELY — the auth
#                  cache is keyed on inode/size/mtime, not TTL), and the
#                  crag-api unix-socket group gate (non-member uid is
#                  refused at connect; member uid gets 200)
#   concurrency    20 parallel GET /system + 2 parallel POST wifi/scan
#                  (in-flight scan coalesces: both 202 + operation) with
#                  an SSE client attached: no 5xx anywhere, SSE ids
#                  strictly monotonic, cragd RSS still < 16 MiB
#   fuzz-lite      a dozen wrong-method/wrong-path probes -> 404/405
#                  problem+json shape (urn type, no connection drops)
#
# M3 phase-4 cases (docs/07 §4-§6), at the end (provisioning-e2e and
# factory-reset reboot the guest into a fresh /data):
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
#   factory-reset  wrong confirm 400s; cragctl --yes-really-wipe
#                  reboots into a FRESH /data: 'provisioning' again, new
#                  api token (old one 401s), REGENERATED machine-id (it
#                  lives in the /etc overlay upper on /data — MIGRATION-
#                  NOTES §12), firstboot stamps fresh, wifi config gone.
#   time           docs/07 §6: build-epoch floor applied (now >= floor,
#                  cragctl time agrees) and chrony reaches real NTP
#                  through slirp's UDP forwarding — time.synced true
#                  (CRAG_TEST_OFFLINE=1 flips that assert for
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
#   ./build/test-api.sh <board> [--timeout=SECONDS] [--case=NAME[,NAME...]]
#   ./build/test-api.sh <board> --list-cases
#
# --case boots the guest once (the boot case always runs) and runs only
# the selected case(s), in registry order. Mind the documented state
# dependencies when cherry-picking (wifi-e2e promotes the device;
# provisioning-e2e/factory-reset wipe /data).
#
# Outputs: serial log build/state/logs/api-<board>.log, junit XML in
# build/state/test-results/api-<board>.xml.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/lib/testlib.sh"

# ---- case registry ----------------------------------------------------------
# Registry order IS execution order; the destructive phase-4 cases stay
# last. `boot` always runs (the others drive the guest it boots).
API_CASES=(
    boot
    system-auth
    network-eth0
    resolv-conf
    update-status
    wifi-e2e
    cragd-rss
    api-negative
    auth-matrix
    concurrency
    fuzz-lite
    provisioning-e2e
    factory-reset
    time
)

BOARD="${1:?Usage: $0 <board> [--timeout=SECONDS] [--case=NAME] [--list-cases]}"
shift
VARIANT="dev"
TIMEOUT=900
SELECT=()
CASE_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --timeout=*) TIMEOUT="${arg#--timeout=}" ;;
        --case=*)
            CASE_ARGS+=("$arg")
            IFS=',' read -ra picked <<<"${arg#--case=}"
            SELECT+=("${picked[@]}")
            ;;
        --list-cases)
            printf '%s\n' "${API_CASES[@]}"
            exit 0
            ;;
        *) echo "ERROR: unknown option: $arg"; exit 1 ;;
    esac
done
for s in "${SELECT[@]:+${SELECT[@]}}"; do
    known=false
    for c in "${API_CASES[@]}"; do [ "$c" = "$s" ] && known=true; done
    [ "$known" = true ] || { echo "ERROR: unknown case '${s}' (--list-cases shows the registry)"; exit 1; }
done

tl_containerize "build/test-api.sh" "$BOARD" "--timeout=${TIMEOUT}" \
    "${CASE_ARGS[@]:+${CASE_ARGS[@]}}"

##############################################################################
# Setup
##############################################################################
tl_init "api-${BOARD}" "$BOARD" "$VARIANT"
SSH_PORT=$(( 20000 + RANDOM % 10000 ))
tl_ssh_init
[ -d "$TL_OUT" ] || { echo "ERROR: image dir not found: ${TL_OUT} — run ./build/crag-build.sh ${BOARD} ${VARIANT}"; exit 1; }

# Wifi rig constants (arbitrary but pinned so failures are greppable)
TEST_SSID="crag-hwsim"
TEST_PSK="cragtest1234"
AP_ADDR="192.168.80.1"
AP_POOL_RE='192\.168\.80\.'

# Provisioning-AP constants (docs/07 §4 baked decisions; wifi.zig pins
# them — a drift here fails loudly against the live daemon)
PORTAL_ADDR="192.168.223.1"
PORTAL_POOL_RE='192\.168\.223\.'

CRAGD_SOCK="/run/crag/cragd.sock"

# ---- guest helpers ---------------------------------------------------------
# All API calls run in-guest with curl (dev image ships it) against the
# unix socket: the group-gated default surface (AD-014).
api_get()    { "${SSH[@]}" "curl -s --max-time 20 --unix-socket ${CRAGD_SOCK} http://localhost$1"; }
api_code()   { "${SSH[@]}" "curl -s -o /dev/null -w '%{http_code}' --max-time 20 -X $1 --unix-socket ${CRAGD_SOCK} http://localhost$2"; }
api_post()   { "${SSH[@]}" "curl -s --max-time 20 -X POST --unix-socket ${CRAGD_SOCK} http://localhost$1"; }

# The AP-surface listener (192.168.223.1:8080). Guest-local curl: the
# surface is tagged PER LISTENER by cragd (spine main.zig), so any
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

# cragd VmRSS in kB. The image ships no pidof/pgrep/ps — find cragd by
# /proc/<pid>/comm.
cragd_rss_kb() {
    local out
    out=$("${SSH[@]}" 'for c in /proc/[0-9]*/comm; do read -r n < "$c" 2>/dev/null || continue; if [ "$n" = cragd ]; then cat "${c%/comm}/status"; break; fi; done' 2>/dev/null || :)
    printf '%s\n' "$out" | awk '/^VmRSS:/{print $2}'
}

# check_rss <label> — assert the docs/06 §3 16 MiB budget.
check_rss() {
    local kb
    kb=$(cragd_rss_kb)
    echo "cragd VmRSS ($1): ${kb:-<unknown>} kB (budget 16384 kB)"
    if [ -z "${kb:-}" ]; then
        fail "could not read cragd VmRSS ($1 — daemon dead?)"
    elif [ "$kb" -ge 16384 ]; then
        fail "cragd VmRSS ${kb} kB breaches the 16 MiB budget ($1)"
    fi
}

# ---- poll conditions for tl_wait_for ---------------------------------------

# radios_up <dev...> — all named radios visible in iwd; sets DEVLIST.
radios_up() {
    DEVLIST=$("${SSH[@]}" "iwctl device list" 2>/dev/null || :)
    local d
    for d in "$@"; do
        echo "$DEVLIST" | grep -q "$d" || return 1
    done
}

# iface_has_addr <iface> <prefix-or-regex-mode> <value> — GET /network
# shows an address on <iface>; sets NET_BODY. Mode: prefix | re.
iface_has_addr() {
    NET_BODY=$(api_get /api/v1/network || :)
    case "$2" in
        prefix) jq -e --arg i "$1" --arg a "$3" \
            '.interfaces[] | select(.name==$i) | .addresses[] | select(startswith($a))' \
            >/dev/null 2>&1 <<<"$NET_BODY" ;;
        re) jq -e --arg i "$1" --arg re "$3" \
            '.interfaces[] | select(.name==$i) | .addresses[] | select(test($re))' \
            >/dev/null 2>&1 <<<"$NET_BODY" ;;
    esac
}

# ap_mode_ready <dev> — `iwctl ap <dev> show` only answers once the
# radio actually IS in ap mode (replaces the old post-set-property
# settle sleep with a condition).
ap_mode_ready() { "${SSH[@]}" "iwctl ap $1 show" >/dev/null 2>&1; }

scan_op_done() {
    OP_STATE=$(api_get "$1" | jq -r '.state // empty' 2>/dev/null || :)
    [ "$OP_STATE" = "succeeded" ] || [ "$OP_STATE" = "failed" ]
}

prov_state_is() {
    PROV_STATE=$(api_get /api/v1/system | jq -r '.provisioning // empty' 2>/dev/null || :)
    [ "$PROV_STATE" = "$1" ]
}

wifi_disconnected() {
    WIFI_STATE=$(api_get /api/v1/network/wifi || :)
    local state ssid_now
    state=$(jq -r '.state // empty' <<<"$WIFI_STATE" 2>/dev/null || :)
    ssid_now=$(jq -r '.connected_ssid // empty' <<<"$WIFI_STATE" 2>/dev/null || :)
    LAST_WIFI_VERDICT="$state"
    [ "$state" != "connected" ] && [ -z "$ssid_now" ]
}

time_synced_true() {
    [ "$(api_get /api/v1/system | jq -r '.time_synced' 2>/dev/null || :)" = "true" ]
}

portal_ap_ready() {
    AP_SHOW=$("${SSH[@]}" "cragctl wifi ap show" 2>/dev/null || :)
    echo "$AP_SHOW" | grep -q '^enabled  yes$' || return 1
    # The AP address on wlan0 is the readiness signal for the listener +
    # DHCP pool, not just the iwd mode flip.
    iface_has_addr wlan0 prefix "$PORTAL_ADDR"
}

# wait_wifi_state <want-state> <max-s-unscaled> [want-ssid]
# Poll GET /network/wifi, narrating transitions; sets WIFI_STATE.
wait_wifi_state() {
    local want="$1" max want_ssid="${3:-}"
    max=$(tl_scale "$2")
    local t0 state last_state=""
    t0=$(date +%s)
    while :; do
        WIFI_STATE=$(api_get /api/v1/network/wifi || :)
        state=$(jq -r '.state // empty' <<<"$WIFI_STATE" 2>/dev/null || :)
        if [ "$state" != "$last_state" ]; then
            echo "  wifi state: ${state:-<unparseable>}"
            last_state="$state"
        fi
        if [ "$state" = "$want" ]; then
            if [ -z "$want_ssid" ] || jq -e --arg s "$want_ssid" '.connected_ssid==$s' >/dev/null 2>&1 <<<"$WIFI_STATE"; then
                return 0
            fi
        fi
        if [ $(( $(date +%s) - t0 )) -ge "$max" ]; then
            LAST_WIFI_VERDICT="$last_state"
            return 1
        fi
        sleep 2
    done
}

# ---- shared wifi-rig steps -------------------------------------------------

# write_ap_profile — the iwd.ap(5) profile with the [IPv4] DHCP pool.
# The outer double quotes expand ${TEST_PSK}/${AP_ADDR} locally; the
# quoted 'EOF' keeps the remote shell from expanding anything else.
write_ap_profile() {
    "${SSH[@]}" "mkdir -p /data/net/iwd/ap && cat > /data/net/iwd/ap/${TEST_SSID}.ap <<'EOF'
# Test-rig AP profile (iwd.ap(5)): [IPv4] enables iwd's built-in DHCP
# server for this AP — the pool cragd's station side must lease from.
[Security]
Passphrase=${TEST_PSK}

[IPv4]
Address=${AP_ADDR}
Netmask=255.255.255.0
EOF"
}

# apply_iwd_netconfig_override — see the HWSIM/IWD TRAP header note.
apply_iwd_netconfig_override() {
    "${SSH[@]}" "mkdir -p /run/crag-test/iwd \
        && sed 's/^EnableNetworkConfiguration=false/EnableNetworkConfiguration=true/' /etc/iwd/main.conf > /run/crag-test/iwd/main.conf \
        && mount --bind /run/crag-test/iwd /etc/iwd \
        && dinitctl restart iwd"
}

# scan_until_ssid <ssid> — up to three API scans until the SSID shows in
# GET /networks; sets NETWORKS. Records a fail() on a missing operation.
scan_until_ssid() {
    local attempt
    for attempt in 1 2 3; do
        SCAN_RESP=$(api_post /api/v1/network/wifi/scan || :)
        OP_PATH=$(jq -r '.operation // empty' <<<"$SCAN_RESP" 2>/dev/null || :)
        if [ -z "$OP_PATH" ]; then
            evidence "POST /network/wifi/scan (attempt ${attempt})" "$SCAN_RESP"
            fail "scan did not return an operation"
            return 1
        fi
        echo "  scan attempt ${attempt}: operation ${OP_PATH}"
        tl_wait_for "scan operation terminal" 30 scan_op_done "$OP_PATH" || :
        echo "  scan operation state: ${OP_STATE:-<none>}"
        NETWORKS=$(api_get /api/v1/network/wifi/networks || :)
        evidence "GET /network/wifi/networks (attempt ${attempt})" "$NETWORKS"
        if jq -e --arg s "$1" 'any(.[]; .ssid==$s)' >/dev/null 2>&1 <<<"$NETWORKS"; then
            return 0
        fi
        # Retry pacing, not a wait-for-condition: hwsim beacons need a
        # beat between scan rounds and the next scan IS the probe.
        sleep 3
    done
    return 1
}

##############################################################################
# Case: boot
##############################################################################
case_boot() {
    echo "[STEP] Booting ${BOARD}/${VARIANT} (scratch overlay, ssh :${SSH_PORT})..."
    tl_start_qemu --ssh-port="$SSH_PORT"
    tl_wait_ssh "initial boot" || return 1
    echo "[STEP] SSH is up"
}

##############################################################################
# Case: system-auth — GET /system + the AD-014 401 matrix (regression)
##############################################################################
case_system_auth() {
    echo "[STEP] cragctl system over the unix socket..."
    local SYS_OUT code hdr TOKEN
    SYS_OUT=$("${SSH[@]}" "cragctl system" 2>&1) || fail "cragctl system failed"
    evidence "cragctl system" "$SYS_OUT"
    echo "$SYS_OUT" | grep -q "board" || fail "cragctl system output missing the board line"

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
}

##############################################################################
# Case: network-eth0 — observed state via rtnetlink + slirp DHCP
##############################################################################
case_network_eth0() {
    echo "[STEP] GET /api/v1/network..."
    local NET_BODY
    NET_BODY=$(api_get /api/v1/network || :)
    evidence "GET /network" "$NET_BODY"
    if ! jq -e '.interfaces[] | select(.name=="eth0") | select(.carrier==true)' >/dev/null 2>&1 <<<"$NET_BODY"; then
        fail "eth0 missing or carrier!=true in GET /network"
    fi
    if ! jq -e '.interfaces[] | select(.name=="eth0") | .addresses[] | select(test("^10\\.0\\.2\\."))' >/dev/null 2>&1 <<<"$NET_BODY"; then
        fail "eth0 has no slirp 10.0.2.x address in GET /network"
    fi
    jq -e '.wan.order | length >= 1' >/dev/null 2>&1 <<<"$NET_BODY" || fail "GET /network missing wan.order"
}

##############################################################################
# Case: resolv-conf — docs/07 §2 one-writer model, live
##############################################################################
case_resolv_conf() {
    echo "[STEP] /etc/resolv.conf symlink + rendered target..."
    local LINK RESOLV
    LINK=$("${SSH[@]}" "readlink /etc/resolv.conf" || :)
    echo "readlink /etc/resolv.conf -> '${LINK}'"
    case "$LINK" in
        ../run/crag-resolv/resolv.conf|/run/crag-resolv/resolv.conf) : ;;
        *) fail "/etc/resolv.conf is not the crag symlink (got '${LINK}')" ;;
    esac
    RESOLV=$("${SSH[@]}" "cat /run/crag-resolv/resolv.conf" || :)
    evidence "/run/crag-resolv/resolv.conf" "$RESOLV"
    # The renderer must brand its output (one-writer marker): a comment
    # line naming cragd distinguishes the rendered file from anything a
    # stray resolvconf/dhcpcd hook could have written.
    echo "$RESOLV" | grep -q '^#.*cragd' || fail "resolv.conf missing the cragd rendered-marker comment"
    echo "$RESOLV" | grep -q '^nameserver 10\.0\.2\.' || fail "resolv.conf missing the slirp DNS (10.0.2.x) learned via the dhcpcd lease hook"
}

##############################################################################
# Case: update-status — phase-2 surface still reachable (regression)
##############################################################################
case_update_status() {
    echo "[STEP] cragctl update status..."
    local UPD_OUT
    UPD_OUT=$("${SSH[@]}" "cragctl update status" 2>&1) || fail "cragctl update status failed"
    evidence "cragctl update status" "$UPD_OUT"
    echo "$UPD_OUT" | grep -q 'boot_slot' || fail "update status output missing boot_slot"
    echo "$UPD_OUT" | grep -q 'SLOT' || fail "update status output missing the slot table"
}

##############################################################################
# Case: wifi-e2e — hwsim AP on radio 1, full station flow via the API
##############################################################################
case_wifi_e2e() {
    echo "[STEP] Waiting for both hwsim radios in iwd (iwctl device list)..."
    if ! tl_wait_for "hwsim radios" 60 radios_up wlan0 wlan1; then
        evidence "iwctl device list" "${DEVLIST:-<empty>}"
        fail "hwsim radios wlan0/wlan1 not visible in iwd within the window"
        return 1
    fi
    evidence "iwctl device list" "${DEVLIST:-<empty>}"

    echo "[STEP] Writing the AP provisioning profile (/data/net/iwd/ap/${TEST_SSID}.ap)..."
    write_ap_profile || fail "could not write the AP profile"

    echo "[STEP] Enabling iwd netconfig for the AP phase (bind-mount /etc/iwd override; see header)..."
    apply_iwd_netconfig_override || fail "could not apply the iwd netconfig override"

    echo "[STEP] Waiting for iwd to come back with both radios..."
    tl_wait_for "iwd restart with radios" 60 radios_up wlan0 wlan1 || :

    echo "[STEP] Switching wlan1 to AP mode and starting the profile..."
    "${SSH[@]}" "iwctl device wlan1 set-property Mode ap" || fail "iwctl set-property Mode ap failed"
    tl_wait_for "wlan1 in ap mode" 10 ap_mode_ready wlan1 || :
    "${SSH[@]}" "iwctl ap wlan1 start-profile ${TEST_SSID}" || fail "iwctl ap start-profile failed"

    # Address assertion goes through cragd's GET /network (rtnetlink
    # observation) — the image ships no iproute2, and the API is the
    # surface under test anyway.
    if ! tl_wait_for "wlan1 AP address" 30 iface_has_addr wlan1 prefix "$AP_ADDR"; then
        local AP_STATE
        AP_STATE=$("${SSH[@]}" "iwctl ap wlan1 show" 2>&1 || :; printf '%s\n' "GET /network: ${NET_BODY:-<empty>}")
        evidence "AP bring-up state" "$AP_STATE"
        fail "wlan1 never got the AP address ${AP_ADDR} (iwd DHCP server not up — netconfig override or profile [IPv4] broken?)"
        return 1
    fi
    echo "[OK] AP up on wlan1 (${AP_ADDR}, iwd DHCP pool)"

    echo "[STEP] API: wifi scan until '${TEST_SSID}' is visible..."
    scan_until_ssid "$TEST_SSID" || fail "'${TEST_SSID}' never appeared in GET /network/wifi/networks after 3 scans"

    echo "[STEP] API: PUT /network/wifi/connection (connect)..."
    local CONNECT_CODE CONNECT_BODY
    CONNECT_CODE=$("${SSH[@]}" "curl -s -o /tmp/connect-body -w '%{http_code}' --max-time 20 -X PUT -H 'Content-Type: application/json' --data '{\"ssid\":\"${TEST_SSID}\",\"psk\":\"${TEST_PSK}\"}' --unix-socket ${CRAGD_SOCK} http://localhost/api/v1/network/wifi/connection" || echo "000")
    if [ "${CONNECT_CODE:0:1}" != "2" ]; then
        CONNECT_BODY=$("${SSH[@]}" "cat /tmp/connect-body" 2>/dev/null || :)
        evidence "PUT /network/wifi/connection -> ${CONNECT_CODE}" "$CONNECT_BODY"
        fail "connect PUT answered ${CONNECT_CODE}, expected 2xx"
    fi

    echo "[STEP] Polling GET /network/wifi until state=connected..."
    if ! wait_wifi_state connected 60; then
        evidence "GET /network/wifi (last)" "${WIFI_STATE:-<empty>}"
        fail "station never reached state=connected (last: '${LAST_WIFI_VERDICT:-}')"
        return 1
    fi
    jq -e --arg s "$TEST_SSID" '.connected_ssid==$s' >/dev/null 2>&1 <<<"$WIFI_STATE" \
        || fail "connected_ssid is not '${TEST_SSID}'"
    echo "[OK] station connected to ${TEST_SSID}"

    echo "[STEP] Asserting wlan0 leased an address from the AP pool (${AP_POOL_RE}x)..."
    tl_wait_for "wlan0 AP-pool lease" 30 iface_has_addr wlan0 re "^${AP_POOL_RE}" \
        || fail "wlan0 never held a ${AP_POOL_RE}x address in GET /network"
    evidence "GET /network (after connect)" "${NET_BODY:-<empty>}"

    echo "[STEP] API: DELETE /network/wifi/connection (forget)..."
    local DEL_CODE
    DEL_CODE=$(api_code DELETE /api/v1/network/wifi/connection || echo "000")
    [ "$DEL_CODE" = "204" ] || fail "forget answered ${DEL_CODE}, expected 204"

    if tl_wait_for "station disconnect" 30 wifi_disconnected; then
        echo "[OK] profile forgotten, station state: ${LAST_WIFI_VERDICT:-<none>}"
    else
        evidence "GET /network/wifi (after forget)" "${WIFI_STATE:-<empty>}"
        fail "station still connected after forget"
    fi

    echo "[STEP] Restoring the shipped iwd posture (umount override, restart iwd)..."
    "${SSH[@]}" "iwctl ap wlan1 stop >/dev/null 2>&1 || :; umount /etc/iwd && dinitctl restart iwd" \
        || echo "[WARN] iwd posture restore failed (test-scoped guest, not fatal)"
}

##############################################################################
# Case: cragd-rss — docs/06 §3 budget after the classic flow
##############################################################################
case_cragd_rss() {
    echo "[STEP] cragd VmRSS after the phase-3 cases..."
    check_rss "post wifi-e2e"
}

##############################################################################
# Case: api-negative — malformed/oversized bodies, storage exhaustion
##############################################################################
case_api_negative() {
    local hdr code body

    echo "[STEP] Invalid JSON to the strict PUT/POST endpoints -> 400 problem+json..."
    # PUT /network/wifi/ap: garbage body (no state change on 400).
    hdr=$("${SSH[@]}" "curl -si --max-time 20 -X PUT -H 'Content-Type: application/json' --data 'this-is-not-json' --unix-socket ${CRAGD_SOCK} http://localhost/api/v1/network/wifi/ap" || :)
    echo "$hdr" | head -1 | grep -q ' 400 ' || { evidence "PUT wifi/ap garbage" "$hdr"; fail "garbage PUT wifi/ap did not answer 400"; }
    echo "$hdr" | grep -qi '^content-type: application/problem+json' || fail "400 (garbage wifi/ap) is not problem+json"
    echo "$hdr" | grep -q 'urn:crag:problem:bad-request' || fail "400 (garbage wifi/ap) missing the bad-request urn"

    # PUT /network/wifi/ap: valid JSON, unknown member (strict body).
    code=$("${SSH[@]}" "curl -s -o /dev/null -w '%{http_code}' --max-time 20 -X PUT -H 'Content-Type: application/json' --data '{\"enabled\":true,\"bonus\":1}' --unix-socket ${CRAGD_SOCK} http://localhost/api/v1/network/wifi/ap" || echo "000")
    [ "$code" = "400" ] || fail "unknown-member PUT wifi/ap answered ${code}, expected 400 (strict body)"

    # PUT /network/wifi/connection: garbage body.
    code=$("${SSH[@]}" "curl -s -o /dev/null -w '%{http_code}' --max-time 20 -X PUT -H 'Content-Type: application/json' --data '{{{' --unix-socket ${CRAGD_SOCK} http://localhost/api/v1/network/wifi/connection" || echo "000")
    [ "$code" = "400" ] || fail "garbage PUT wifi/connection answered ${code}, expected 400"

    # POST /system/factory-reset: garbage body must 400, never wipe.
    code=$("${SSH[@]}" "curl -s -o /dev/null -w '%{http_code}' --max-time 20 -X POST -H 'Content-Type: application/json' --data 'not json either' --unix-socket ${CRAGD_SOCK} http://localhost/api/v1/system/factory-reset" || echo "000")
    [ "$code" = "400" ] || fail "garbage POST factory-reset answered ${code}, expected 400"

    echo "[STEP] Body over the 64 KiB cap -> 413 problem+json, response delivered..."
    "${SSH[@]}" "dd if=/dev/zero bs=1024 count=80 2>/dev/null | tr '\\0' 'a' > /tmp/big-body" || fail "could not build the oversized body"
    hdr=$("${SSH[@]}" "curl -si --max-time 20 -X PUT -H 'Content-Type: application/json' --data-binary @/tmp/big-body --unix-socket ${CRAGD_SOCK} http://localhost/api/v1/network/wifi/ap" || echo "CURL-TRANSPORT-FAIL")
    if [ "$hdr" = "CURL-TRANSPORT-FAIL" ]; then
        # The daemon closing with unread request bytes RSTs the response
        # away — the client never sees the 413. That is a real bug shape,
        # not a test artifact.
        fail "oversized body: curl transport error instead of a 413 response (early-close RST?)"
    else
        echo "$hdr" | head -1 | grep -q ' 413 ' || { evidence "oversized-body response" "$(echo "$hdr" | head -5)"; fail "oversized body did not answer 413"; }
        echo "$hdr" | grep -qi '^content-type: application/problem+json' || fail "413 is not problem+json"
        echo "$hdr" | grep -q 'urn:crag:problem:content-too-large' || fail "413 missing the content-too-large urn"
    fi

    echo "[STEP] Update upload larger than free /data -> 507 insufficient-storage..."
    # stageStream checks the DECLARED length against statvfs free space
    # before reading the body, so a forged Content-Length (no tmpfs/
    # fallocate needed) exercises the exact production path. The value
    # must FIT usize on 32-bit boards (armv7 cragd: u32, max ~4 GiB —
    # anything larger fails Content-Length parsing and answers 400
    # unrepresentable, caught live on qemu-armv7) while still exceeding
    # the ~1 GiB free /data of the +1G scratch overlay: 2.8 GiB.
    local staged_before staged_after
    staged_before=$("${SSH[@]}" "ls /data/.crag/staging 2>/dev/null | wc -l" || echo 0)
    hdr=$("${SSH[@]}" "curl -si --max-time 20 -X POST -H 'Content-Type: application/octet-stream' -H 'Content-Length: 3000000000' --data-binary '' --unix-socket ${CRAGD_SOCK} http://localhost/api/v1/update" || echo "CURL-TRANSPORT-FAIL")
    if [ "$hdr" = "CURL-TRANSPORT-FAIL" ]; then
        fail "oversized upload: curl transport error instead of a 507 response"
    else
        echo "$hdr" | head -1 | grep -q ' 507 ' || { evidence "oversized-upload response" "$(echo "$hdr" | head -5)"; fail "2.8 GiB declared upload did not answer 507"; }
        echo "$hdr" | grep -q 'urn:crag:problem:insufficient-storage' || fail "507 missing the insufficient-storage urn"
    fi
    staged_after=$("${SSH[@]}" "ls /data/.crag/staging 2>/dev/null | wc -l" || echo 0)
    [ "${staged_after:-0}" -le "${staged_before:-0}" ] || fail "507 path left staging residue (${staged_before} -> ${staged_after} files)"
}

##############################################################################
# Case: auth-matrix — bearer hardening, token rotation, unix group gate
##############################################################################
case_auth_matrix() {
    local TOKEN code
    TOKEN=$("${SSH[@]}" "cat /data/config/api-token" | tr -d '[:space:]') || fail "cannot read /data/config/api-token"
    [ -n "$TOKEN" ] || { fail "empty api token"; return 0; }

    echo "[STEP] Bearer variants that must all 401..."
    local variant
    # token+garbage | empty bearer | bare Bearer | wrong scheme
    for variant in "Bearer ${TOKEN}xx" "Bearer " "Bearer" "Basic ${TOKEN}"; do
        code=$("${SSH[@]}" "curl -s -o /dev/null -w '%{http_code}' --max-time 20 -H 'Authorization: ${variant}' http://127.0.0.1:8080/api/v1/system" || echo "000")
        [ "$code" = "401" ] || fail "'Authorization: ${variant}' answered ${code}, expected 401"
    done

    echo "[STEP] Token rotation mid-session: old token dies immediately..."
    # The auth cache is keyed on (inode, size, mtime) — a rewrite must be
    # picked up on the very next request, no reload window to wait out.
    # Rewrite in place (>) so root:crag-api 0640 survives; restore after.
    local ROTATED="rotated-token-for-test-$(date +%s)"
    "${SSH[@]}" "printf '%s\n' '${ROTATED}' > /data/config/api-token" || fail "could not rotate the token file"
    code=$("${SSH[@]}" "curl -s -o /dev/null -w '%{http_code}' --max-time 20 -H 'Authorization: Bearer ${TOKEN}' http://127.0.0.1:8080/api/v1/system" || echo "000")
    [ "$code" = "401" ] || fail "OLD token still answered ${code} after rotation, expected immediate 401"
    code=$("${SSH[@]}" "curl -s -o /dev/null -w '%{http_code}' --max-time 20 -H 'Authorization: Bearer ${ROTATED}' http://127.0.0.1:8080/api/v1/system" || echo "000")
    [ "$code" = "200" ] || fail "ROTATED token answered ${code}, expected 200"
    "${SSH[@]}" "printf '%s\n' '${TOKEN}' > /data/config/api-token" || fail "could not restore the original token"
    code=$("${SSH[@]}" "curl -s -o /dev/null -w '%{http_code}' --max-time 20 -H 'Authorization: Bearer ${TOKEN}' http://127.0.0.1:8080/api/v1/system" || echo "000")
    [ "$code" = "200" ] || fail "restored token answered ${code}, expected 200"

    echo "[STEP] Unix-socket group gate: crag-api member vs non-member..."
    # /run/crag is 0750 cragd:crag-api (AD-014). uid 1000 'dev' is in
    # wheel only -> connect must be REFUSED by the filesystem; the cragd
    # uid (member by /etc/group) must get a 200. doas.conf's
    # "permit nopass root" makes the drop non-interactive.
    local NONMEM MEM
    NONMEM=$("${SSH[@]}" "doas -u dev curl -s -o /dev/null -w '%{http_code}' --max-time 10 --unix-socket ${CRAGD_SOCK} http://localhost/api/v1/system; echo rc=\$?" || :)
    echo "  non-member (dev): ${NONMEM}"
    echo "$NONMEM" | grep -q 'rc=0' && fail "non-member uid connected to the cragd socket (group gate broken)"
    MEM=$("${SSH[@]}" "doas -u cragd curl -s -o /dev/null -w '%{http_code}' --max-time 10 --unix-socket ${CRAGD_SOCK} http://localhost/api/v1/system" || echo "000")
    [ "$MEM" = "200" ] || fail "crag-api member answered '${MEM}' on the socket, expected 200"
}

##############################################################################
# Case: concurrency — parallel load + SSE coherence + RSS stability
##############################################################################
case_concurrency() {
    echo "[STEP] 20x GET /system + 2x POST wifi/scan under an attached SSE client..."
    # All guest-side (one ssh round trip): 20 background GETs, then two
    # near-simultaneous scan POSTs, with an SSE client subscribed from
    # id 0 (ring replay makes frames flow immediately, so attachment is
    # provable). Results land in /tmp/conc/ for host-side asserts.
    "${SSH[@]}" 'rm -rf /tmp/conc && mkdir -p /tmp/conc
curl -s -N --max-time 60 -H "Last-Event-ID: 0" --unix-socket /run/crag/cragd.sock http://localhost/api/v1/events > /tmp/conc/sse.log 2>/dev/null &
echo $! > /tmp/conc/sse.pid' || fail "could not start the SSE client"
    # Event-driven attach gate: the Last-Event-ID replay means bytes
    # arrive as soon as the subscription is live.
    sse_has_frames() { "${SSH[@]}" "grep -q '^id: ' /tmp/conc/sse.log" 2>/dev/null; }
    tl_wait_for "SSE replay frames" 20 sse_has_frames || fail "SSE client saw no id: frames after subscribing with Last-Event-ID: 0"

    "${SSH[@]}" 'i=0
pids=""
while [ $i -lt 20 ]; do
    curl -s -o /dev/null -w "%{http_code}\n" --max-time 30 --unix-socket /run/crag/cragd.sock http://localhost/api/v1/system > /tmp/conc/get.$i &
    pids="$pids $!"
    i=$((i+1))
done
curl -s --max-time 30 -X POST --unix-socket /run/crag/cragd.sock http://localhost/api/v1/network/wifi/scan -o /tmp/conc/scan1 -w "%{http_code}\n" > /tmp/conc/scan1.code &
pids="$pids $!"
curl -s --max-time 30 -X POST --unix-socket /run/crag/cragd.sock http://localhost/api/v1/network/wifi/scan -o /tmp/conc/scan2 -w "%{http_code}\n" > /tmp/conc/scan2.code &
pids="$pids $!"
for p in $pids; do wait $p; done' || fail "parallel request batch failed to run"

    local CODES
    CODES=$("${SSH[@]}" "cat /tmp/conc/get.* /tmp/conc/scan1.code /tmp/conc/scan2.code" || :)
    evidence "concurrency status codes" "$CODES"
    [ "$(echo "$CODES" | grep -c '200')" -ge 1 ] || fail "no 200s from the parallel GETs at all"
    echo "$CODES" | grep -Eq '5[0-9][0-9]' && fail "5xx observed under parallel load: $(echo "$CODES" | grep -E '5[0-9][0-9]' | head -3 | tr '\n' ' ')"
    local n200
    n200=$(echo "$CODES" | grep -c '^200$' || :)
    [ "${n200:-0}" -eq 20 ] || fail "expected 20x 200 from parallel GET /system, got ${n200}"

    # Scan semantics (wifi.zig): an in-flight scan is returned
    # idempotently — BOTH posts answer 202 with an operation ref; when
    # they hit the same in-flight scan the ids coincide.
    local S1 S2 C1 C2 OP1 OP2
    C1=$("${SSH[@]}" "cat /tmp/conc/scan1.code" || echo "000")
    C2=$("${SSH[@]}" "cat /tmp/conc/scan2.code" || echo "000")
    S1=$("${SSH[@]}" "cat /tmp/conc/scan1" || :)
    S2=$("${SSH[@]}" "cat /tmp/conc/scan2" || :)
    [ "$C1" = "202" ] || fail "parallel scan #1 answered ${C1}, expected 202"
    [ "$C2" = "202" ] || fail "parallel scan #2 answered ${C2}, expected 202"
    OP1=$(jq -r '.operation // empty' <<<"$S1" 2>/dev/null || :)
    OP2=$(jq -r '.operation // empty' <<<"$S2" 2>/dev/null || :)
    [ -n "$OP1" ] || fail "parallel scan #1 returned no operation ref"
    [ -n "$OP2" ] || fail "parallel scan #2 returned no operation ref"
    if [ "$OP1" = "$OP2" ]; then
        echo "  scans coalesced onto the in-flight operation: ${OP1}"
    else
        echo "  scans got distinct operations (${OP1} / ${OP2} — first finished before second landed)"
    fi

    echo "[STEP] SSE stream coherence (ids strictly monotonic)..."
    "${SSH[@]}" 'kill "$(cat /tmp/conc/sse.pid)" 2>/dev/null; :' || :
    local IDS
    IDS=$("${SSH[@]}" "sed -n 's/^id: //p' /tmp/conc/sse.log" || :)
    evidence "SSE event ids" "$IDS"
    [ -n "$IDS" ] || fail "SSE log carries no id: lines"
    if [ -n "$IDS" ]; then
        # sort -nc exits nonzero on any out-of-order pair; uniq -d
        # catches duplicates — together: strictly increasing.
        echo "$IDS" | sort -nc 2>/dev/null || fail "SSE ids are not monotonically increasing"
        [ -z "$(echo "$IDS" | uniq -d)" ] || fail "SSE stream repeated event ids"
    fi

    check_rss "after parallel load"
}

##############################################################################
# Case: fuzz-lite — wrong-method/wrong-path probes, problem+json shape
##############################################################################
case_fuzz_lite() {
    echo "[STEP] A dozen wrong-method/wrong-path probes..."
    # method path expected-status. 404: unknown path; 405: known path,
    # wrong (or unparseable) method. Every answer must be problem+json
    # with an urn:crag:problem type and the connection must close
    # cleanly (curl exit 0 — no drops, no stack traces).
    local probes=(
        "GET /api/v1/nope 404"
        "GET /api/v1/system/nope 404"
        "GET /api/v1/operations/ 404"
        "GET //api/v1/system 404"
        "GET /api/v1/../../etc/passwd 404"
        "DELETE /api/v1/system 405"
        "PUT /api/v1/system 405"
        "POST /api/v1/openapi.json 405"
        "POST /api/v1/operations 405"
        "PATCH /api/v1/network/wan 405"
        "GET /api/v1/update 405"
        "BREW /api/v1/system 405"
    )
    local probe m p want hdr got
    for probe in "${probes[@]}"; do
        read -r m p want <<<"$probe"
        hdr=$("${SSH[@]}" "curl -si --path-as-is --max-time 10 -X ${m} --unix-socket ${CRAGD_SOCK} 'http://localhost${p}'" || echo "CURL-TRANSPORT-FAIL")
        if [ "$hdr" = "CURL-TRANSPORT-FAIL" ]; then
            fail "${m} ${p}: connection dropped (no HTTP answer)"
            continue
        fi
        got=$(echo "$hdr" | head -1 | awk '{print $2}')
        [ "$got" = "$want" ] || fail "${m} ${p}: answered ${got}, expected ${want}"
        echo "$hdr" | grep -qi '^content-type: application/problem+json' || fail "${m} ${p}: not problem+json"
        echo "$hdr" | grep -q 'urn:crag:problem:' || fail "${m} ${p}: body missing the urn:crag:problem type"
        echo "  ${m} ${p} -> ${got} problem+json"
    done
}

##############################################################################
# Case: provisioning-e2e — docs/07 §4 on the 3-radio rig (M3 phase 4)
##############################################################################
# Radio roles (mac80211_hwsim.radios=3, boards/*/board.toml cmdline):
#   wlan0 = DUT: cragd's station/AP flip radio (first device, v1 policy)
#   wlan1 = upstream test AP (the network the portal user selects)
#   wlan2 = the "phone": associates with the provisioning AP
case_provisioning_e2e() {
    # -- Step 0: reach the factory-fresh state -------------------------------
    # wifi-e2e above PROMOTED the device: PUT wifi/connection made
    # has_network_config true and eth0's lease already satisfies the v1
    # connectivity check, so system.provisioning persisted 'provisioned'
    # — and provisioned is TERMINAL until factory reset (docs/07 §4 "the
    # AP never returns"; provision.zig). The phase-4 fresh-boot story
    # therefore starts with a reset here; the factory-reset case below
    # owns the full assertion set (tokens/machine-id/stamps), this one
    # only needs the wipe+reboot.
    echo "[STEP] Factory reset to reach the fresh-boot provisioning state..."
    local MID RESET_CODE RESET_BODY
    MID=$("${SSH[@]}" "cat /etc/machine-id" | tr -d '[:space:]') || fail "cannot read /etc/machine-id"
    RESET_CODE=$("${SSH[@]}" "curl -s -o /tmp/reset-body -w '%{http_code}' --max-time 20 -X POST -H 'Content-Type: application/json' --data '{\"confirm\":\"${MID}\"}' --unix-socket ${CRAGD_SOCK} http://localhost/api/v1/system/factory-reset" || echo "000")
    if [ "$RESET_CODE" != "202" ]; then
        RESET_BODY=$("${SSH[@]}" "cat /tmp/reset-body" 2>/dev/null || :)
        evidence "POST /system/factory-reset -> ${RESET_CODE}" "$RESET_BODY"
        fail "setup factory reset answered ${RESET_CODE}, expected 202"
        return 1
    fi
    tl_wait_ssh_down "factory-reset reboot (setup)" || return 1
    tl_wait_ssh "boot after setup factory reset" || return 1

    # -- Step 1: fresh boot is 'provisioning', NOT 'provisioned' -------------
    # The dev image ships no wifi config; eth0 leases from slirp; the
    # store default api.wired_provisions=false means the wired path only
    # SURFACES availability (docs/07 §4) — so the answer must be
    # 'provisioning' (factory flips to it on the startup edge with no
    # usable config).
    echo "[STEP] Asserting provisioning state on the fresh /data..."
    if ! tl_wait_for "provisioning state" 60 prov_state_is provisioning; then
        evidence "GET /system (fresh boot)" "$(api_get /api/v1/system || :)"
        fail "fresh-boot provisioning state is '${PROV_STATE:-<none>}', expected 'provisioning'"
    fi
    local PROV_OUT
    PROV_OUT=$("${SSH[@]}" "cragctl provision status" 2>&1) || fail "cragctl provision status failed"
    evidence "cragctl provision status" "$PROV_OUT"
    echo "$PROV_OUT" | grep -q '^state    provisioning$' || fail "provision status missing 'state    provisioning'"
    echo "$PROV_OUT" | grep -q '^wired    eth0: carrier yes' || fail "provision status missing the eth0 wired observation"

    # -- Step 2: upstream test AP on wlan1 (phase-3 mechanics, verbatim) -----
    echo "[STEP] Waiting for all three hwsim radios in iwd..."
    if ! tl_wait_for "3 hwsim radios" 60 radios_up wlan0 wlan1 wlan2; then
        evidence "iwctl device list (3-radio)" "${DEVLIST:-<empty>}"
        fail "hwsim radios wlan0/wlan1/wlan2 not visible in iwd (mac80211_hwsim.radios=3 missing from the cmdline?)"
        return 1
    fi
    evidence "iwctl device list (3-radio)" "${DEVLIST:-<empty>}"

    echo "[STEP] Upstream AP profile + iwd netconfig override (see wifi-e2e header)..."
    write_ap_profile || fail "could not write the upstream AP profile"
    apply_iwd_netconfig_override || fail "could not apply the iwd netconfig override"
    tl_wait_for "iwd restart with radios" 60 radios_up wlan1 wlan2 || :
    "${SSH[@]}" "iwctl device wlan1 set-property Mode ap" || fail "iwctl set-property Mode ap (wlan1) failed"
    tl_wait_for "wlan1 in ap mode" 10 ap_mode_ready wlan1 || :
    "${SSH[@]}" "iwctl ap wlan1 start-profile ${TEST_SSID}" || fail "iwctl ap start-profile (upstream) failed"
    tl_wait_for "upstream AP address" 30 iface_has_addr wlan1 prefix "$AP_ADDR" \
        || fail "upstream AP never got ${AP_ADDR} on wlan1"

    # Pre-AP station scan: GET /networks serves CACHED pre-AP results
    # while the DUT radio is in AP mode (spec listWifiNetworks), so the
    # upstream SSID must enter the cache BEFORE the flip.
    echo "[STEP] Pre-AP scan until the upstream SSID is cached..."
    scan_until_ssid "$TEST_SSID" || fail "'${TEST_SSID}' never appeared in the pre-AP scan cache"

    # -- Step 3: provisioning AP up via the manual override ------------------
    # The docs/07 §4 AUTO-trigger for the AP is "no ethernet carrier";
    # this rig always has eth0 carrier (that IS the wired-available
    # path), so the AP is deliberately down here — which itself is
    # asserted, then the manual override (PUT /network/wifi/ap, docs/06
    # §5.2) forces it up. This doubles as the cragctl `wifi ap enable`
    # e2e.
    echo "[STEP] AP down by default (eth carrier present), then wifi ap enable..."
    AP_SHOW=$("${SSH[@]}" "cragctl wifi ap show" 2>&1) || fail "cragctl wifi ap show failed"
    evidence "cragctl wifi ap show (pre-enable)" "$AP_SHOW"
    echo "$AP_SHOW" | grep -q '^enabled  no$' || fail "AP unexpectedly up before the override (eth carrier should suppress the auto-trigger)"

    "${SSH[@]}" "cragctl wifi ap enable" >/dev/null 2>&1 || fail "cragctl wifi ap enable failed"
    if ! tl_wait_for "provisioning AP up on wlan0" 60 portal_ap_ready; then
        evidence "cragctl wifi ap show (post-enable)" "${AP_SHOW:-<empty>}"
        fail "provisioning AP never came up on wlan0 (${PORTAL_ADDR}) after wifi ap enable"
        return 1
    fi
    evidence "cragctl wifi ap show (post-enable)" "${AP_SHOW:-<empty>}"

    # Derived identity: SSID crag-<last 6 hex of machine-id>; the PSK
    # line is the socket-surface-only label story (never served over
    # HTTP).
    local AP_SSID AP_PSK WANT_SSID
    AP_SSID=$(echo "$AP_SHOW" | awk '$1=="ssid"{print $2}')
    AP_PSK=$(echo "$AP_SHOW" | awk '$1=="psk"{print $2}')
    MID=$("${SSH[@]}" "cat /etc/machine-id" | tr -d '[:space:]') || :
    WANT_SSID="crag-$(printf '%s' "$MID" | tail -c 6)"
    [ "$AP_SSID" = "$WANT_SSID" ] || fail "AP ssid '${AP_SSID}' != derived '${WANT_SSID}'"
    echo "$AP_PSK" | grep -Eq '^[0-9a-f]{16}$' || fail "derived PSK '${AP_PSK}' is not 16 lowercase hex chars"

    # -- Step 4: the phone radio sees and joins the AP -----------------------
    echo "[STEP] wlan2: scan for ${AP_SSID} and connect with the derived PSK..."
    local ap_visible=false attempt WLAN2_NETS
    for attempt in 1 2 3 4; do
        "${SSH[@]}" "iwctl station wlan2 scan" >/dev/null 2>&1 || :
        # iwctl exposes no per-station scan-done signal for the helper
        # radio; pacing sleep between scan+get-networks rounds.
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
    tl_wait_for "wlan2 portal-pool lease" 45 iface_has_addr wlan2 re "^${PORTAL_POOL_RE}" \
        || fail "wlan2 never leased a ${PORTAL_POOL_RE}x address from the AP pool"
    evidence "GET /network (wlan2 joined)" "${NET_BODY:-<empty>}"

    # -- Step 5: the portal surface ------------------------------------------
    # See portal_get() for why these run guest-local against the AP
    # listener rather than --interface wlan2 over the air.
    echo "[STEP] Portal surface: probes, page, redacted subset, 403 wall..."
    local PROBE_OUT PAGE REDACTED TOKEN DENY SCAN_CODE PORTAL_NETS NFT_RULES
    PROBE_OUT=$("${SSH[@]}" "curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 20 http://${PORTAL_ADDR}:8080/generate_204" || echo "000")
    case "$PROBE_OUT" in
        302*/) : ;;
        *) fail "/generate_204 answered '${PROBE_OUT}', expected 302 with Location /" ;;
    esac

    PAGE=$(portal_get / || :)
    echo "$PAGE" | grep -q 'Crag device setup' || {
        evidence "GET / (portal)" "${PAGE:0:400}"
        fail "portal page missing the 'Crag device setup' title"
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

    # The privileged-port story: the root oneshot pair loaded an nft
    # table redirecting, on the AP interface only, 80->8080 and 53->5354
    # (docs/07 §4; kernel NFT_REDIR configs). Ruleset presence is the
    # assertion — the end-to-end port-80 hop needs a second network
    # stack (see portal_get) and the DNS catch-all needs a resolver
    # client the image does not ship; both are covered by unit tests +
    # this rule.
    NFT_RULES=$("${SSH[@]}" "nft list table ip crag_portal" 2>&1 || :)
    evidence "nft list table ip crag_portal" "$NFT_RULES"
    echo "$NFT_RULES" | grep -q 'dport 80' || fail "nft portal table missing the tcp 80 redirect"
    echo "$NFT_RULES" | grep -q '8080' || fail "nft portal table missing the 8080 target"
    echo "$NFT_RULES" | grep -q 'dport 53' || fail "nft portal table missing the udp 53 redirect"
    echo "$NFT_RULES" | grep -q '5354' || fail "nft portal table missing the 5354 target"

    # -- Step 6: submit upstream credentials, watch the flip -----------------
    echo "[STEP] PUT wifi/connection via the portal surface (the flip)..."
    local FLIP_CODE
    FLIP_CODE=$("${SSH[@]}" "curl -s -o /tmp/flip-body -w '%{http_code}' --max-time 20 -X PUT -H 'Content-Type: application/json' --data '{\"ssid\":\"${TEST_SSID}\",\"psk\":\"${TEST_PSK}\"}' http://${PORTAL_ADDR}:8080/api/v1/network/wifi/connection" || echo "000")
    if [ "${FLIP_CODE:0:1}" != "2" ]; then
        evidence "portal PUT connection -> ${FLIP_CODE}" "$("${SSH[@]}" "cat /tmp/flip-body" 2>/dev/null || :)"
        fail "portal connection PUT answered ${FLIP_CODE}, expected 2xx"
    fi
    # Return AP control to the state machine: with the override still
    # 'true' the manual force would fight the flip/'never returns' rule.
    "${SSH[@]}" "cragctl wifi ap auto" >/dev/null 2>&1 || fail "cragctl wifi ap auto failed"

    echo "[STEP] Waiting for the station to reach the upstream AP..."
    if ! wait_wifi_state connected 90 "$TEST_SSID"; then
        evidence "GET /network/wifi (last)" "${WIFI_STATE:-<empty>}"
        fail "station never connected to '${TEST_SSID}' after the flip (last state '${LAST_WIFI_VERDICT:-}')"
    fi

    tl_wait_for "provisioned state" 30 prov_state_is provisioned \
        || fail "state is '${PROV_STATE:-<none>}' after the flip, expected 'provisioned'"
    # mDNS TXT (provisioning=...) is NOT asserted over the wire: slirp
    # user-net does not bridge guest multicast, and an in-guest listener
    # would race the announcer on the same stack. GET /system above is
    # the TXT payload's source of truth; mdns.zig unit tests pin the
    # encoding. A bridged-net board owns the on-air assert when one
    # joins the lab.

    echo "[STEP] AP gone for good: show says no, the listener is dead..."
    AP_SHOW=$("${SSH[@]}" "cragctl wifi ap show" 2>/dev/null || :)
    echo "$AP_SHOW" | grep -q '^enabled  no$' || fail "wifi ap show still enabled after provisioning"
    local DEAD_CODE
    DEAD_CODE=$("${SSH[@]}" "curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://${PORTAL_ADDR}:8080/api/v1/system" || echo "000")
    # curl -w prints 000 itself on connect failure and the || echo then
    # doubles it ("000000"); normalize to the first three digits.
    DEAD_CODE="${DEAD_CODE:0:3}"
    if [ "$DEAD_CODE" != "000" ] && [ "$DEAD_CODE" != "403" ]; then
        # 000 = connection refused/unroutable (address gone with the
        # AP); a 403 would mean the listener outlived the AP but still
        # walls — tolerated with a warning, anything else is a leak.
        fail "portal listener still answering ${DEAD_CODE} after provisioning"
    fi

    # Same-lifetime memory budget after the whole AP/portal cycle (the
    # cragd-rss case above measured the pre-reset daemon).
    check_rss "after the provisioning cycle"
}

##############################################################################
# Case: factory-reset — docs/07 §5 via cragctl (M3 phase 4)
##############################################################################
case_factory_reset() {
    local OLD_TOKEN OLD_MID BAD_CODE RESET_OUT SCHEMA NEW_TOKEN NEW_MID code WIFI_CONN
    OLD_TOKEN=$("${SSH[@]}" "cat /data/config/api-token" | tr -d '[:space:]') || fail "cannot read the pre-reset api token"
    OLD_MID=$("${SSH[@]}" "cat /etc/machine-id" | tr -d '[:space:]') || fail "cannot read the pre-reset machine-id"

    echo "[STEP] Wrong confirm is refused (400, no reboot)..."
    BAD_CODE=$("${SSH[@]}" "curl -s -o /dev/null -w '%{http_code}' --max-time 20 -X POST -H 'Content-Type: application/json' --data '{\"confirm\":\"not-the-machine-id\"}' --unix-socket ${CRAGD_SOCK} http://localhost/api/v1/system/factory-reset" || echo "000")
    [ "$BAD_CODE" = "400" ] || fail "wrong-confirm factory reset answered ${BAD_CODE}, expected 400"
    # Negative dwell, not a wait-for-condition: nothing observable is
    # SUPPOSED to happen after a refused reset — give a mistaken reboot
    # a moment to manifest, then assert the guest still answers.
    sleep 3
    "${SSH[@]}" true 2>/dev/null || fail "guest went down after a REFUSED factory reset"

    echo "[STEP] cragctl factory-reset --yes-really-wipe ${OLD_MID}..."
    RESET_OUT=$("${SSH[@]}" "cragctl factory-reset --yes-really-wipe ${OLD_MID}" 2>&1) || fail "cragctl factory-reset failed: ${RESET_OUT}"
    evidence "cragctl factory-reset" "$RESET_OUT"
    echo "$RESET_OUT" | grep -q 'accepted' || fail "factory-reset output missing 'accepted'"
    tl_wait_ssh_down "factory-reset reboot" || return 1
    tl_wait_ssh "boot after factory reset" || return 1

    echo "[STEP] Fresh data lifetime: state, stamps, token, machine-id..."
    tl_wait_for "post-reset provisioning state" 60 prov_state_is provisioning \
        || fail "post-reset state is '${PROV_STATE:-<none>}', expected 'provisioning'"

    "${SSH[@]}" "test -f /data/.crag/firstboot-done" || fail "firstboot did not rerun (no fresh done-stamp)"
    "${SSH[@]}" "test ! -e /data/.crag/factory-reset-request" || fail "factory-reset flag survived the wipe"
    SCHEMA=$("${SSH[@]}" "cat /data/.crag/schema-version" 2>/dev/null | tr -d '[:space:]' || :)
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
    # early-machine-id writes the real one THROUGH THE /etc OVERLAY,
    # whose upper lives on /data (MIGRATION-NOTES §12, data-mount.sh) —
    # so a factory reset REGENERATES the identity. That is the intended
    # sold-on-device behavior: the AP SSID/PSK and the mDNS instance
    # name rotate with it, and the old confirm token can never wipe it
    # again.
    NEW_MID=$("${SSH[@]}" "cat /etc/machine-id" | tr -d '[:space:]') || fail "no machine-id after the reset"
    [ -n "$NEW_MID" ] || fail "empty post-reset machine-id"
    [ "$NEW_MID" != "$OLD_MID" ] || fail "machine-id survived the wipe (expected regeneration via the /etc overlay)"

    WIFI_CONN=$(api_get /api/v1/network/wifi/connection || :)
    [ "$WIFI_CONN" = "null" ] || fail "wifi connection config survived the wipe (got '${WIFI_CONN}')"
}

##############################################################################
# Case: time — docs/07 §6 floor + NTP sync (M3 phase 4)
##############################################################################
case_time() {
    echo "[STEP] Build-epoch floor applied..."
    local BUILD_EPOCH GUEST_NOW TIME_OUT SYNCED
    BUILD_EPOCH=$("${SSH[@]}" "cat /etc/crag/build-epoch" | tr -d '[:space:]' || :)
    case "$BUILD_EPOCH" in
        ''|*[!0-9]*) fail "/etc/crag/build-epoch missing or non-numeric ('${BUILD_EPOCH}')" ;;
    esac
    GUEST_NOW=$("${SSH[@]}" "date +%s" | tr -d '[:space:]' || echo 0)
    if [ -n "$BUILD_EPOCH" ] && [ "$GUEST_NOW" -lt "$BUILD_EPOCH" ] 2>/dev/null; then
        fail "guest clock ${GUEST_NOW} is BEHIND the build epoch ${BUILD_EPOCH} (floor not applied)"
    fi
    TIME_OUT=$("${SSH[@]}" "cragctl time" 2>&1) || fail "cragctl time failed"
    evidence "cragctl time" "$TIME_OUT"
    echo "$TIME_OUT" | grep -q '^floor_ok yes$' || fail "cragctl time says the clock is behind the floor"
    echo "$TIME_OUT" | grep -Eq '^floor    [0-9]+$' || fail "cragctl time missing the floor line"

    # NTP sync: QEMU slirp forwards outbound UDP (the resolv-conf case
    # already proves guest DNS through 10.0.2.3), so chronyd's
    # `pool pool.ntp.org iburst` reaches real servers whenever the build
    # host is online — synced=true within seconds of boot is the
    # expected steady state, asserted here. Air-gapped runs set
    # CRAG_TEST_OFFLINE=1 to flip the assertion (STA_UNSYNC must then
    # still be set: false).
    if [ "${CRAG_TEST_OFFLINE:-0}" = "1" ]; then
        echo "[STEP] Offline run: time.synced must be false..."
        SYNCED=$(api_get /api/v1/system | jq -r '.time_synced' 2>/dev/null || :)
        [ "$SYNCED" = "false" ] || fail "offline run but time_synced='${SYNCED}', expected false"
    else
        echo "[STEP] Waiting for chrony to sync through slirp UDP (120s)..."
        if ! tl_wait_for "chrony sync" 120 time_synced_true; then
            evidence "GET /system (time)" "$(api_get /api/v1/system || :)"
            fail "time_synced never became true (chrony unreachable? use CRAG_TEST_OFFLINE=1 for air-gapped runs)"
        fi
        "${SSH[@]}" "cragctl time" 2>/dev/null | grep '^synced' || :
    fi
}

##############################################################################
# Driver
##############################################################################
run_case() {
    local rc=0
    case_begin "$1"
    "case_${1//-/_}" || rc=$?
    case_end
    # A nonzero return is a FATAL case failure (guest unusable) — write
    # the junit for what ran and stop.
    [ "$rc" -eq 0 ] || tl_finish "cragd-api"
}

case_selected() {
    [ ${#SELECT[@]} -eq 0 ] && return 0
    [ "$1" = "boot" ] && return 0
    local s
    for s in "${SELECT[@]}"; do
        [ "$s" = "$1" ] && return 0
    done
    return 1
}

for name in "${API_CASES[@]}"; do
    case_selected "$name" || continue
    run_case "$name"
done

tl_finish "cragd-api"
