#!/bin/bash
# Unit test for the image-assembly service-manifest hook (docs/08 §5):
# boards/common/hooks/40-service-manifests.sh.
#
# Builds a throwaway "assembled rootfs" fixture, drops app service manifests
# into usr/lib/crag/services/, sources the hook against it (exactly as
# run_hooks does), and asserts every integration effect:
#
#   * [service].user created as a system user at the DETERMINISTIC uid from
#     service_manifest.py, with a matching primary group + locked shadow entry
#   * a uid hash-COLLISION is resolved by probing upward (starting uid taken =>
#     the app user lands at the next free slot)
#   * api_client => the user joins the crag-api group (and ONLY that user)
#   * the per-service env-file carries CRAG_API_SOCKET, and CRAG_DATA_DIR
#     only when data_dir=true
#   * boot_success => `depends-on: <name>` appended to /etc/dinit.d/boot-success
#     (and NOT for a service that didn't opt in)
#   * data_dir => "<name> <owner>" recorded in /etc/crag/app-data-dirs for the
#     boot-time data-mount replay
#   * the service is enabled via a boot.d symlink at the packaged target shape
#   * NO manifests => the hook makes NO changes (the byte-identical no-app path)
#
# Run (host or crag-builder container), from the repo root:
#   ./build/lib/test_service_manifests_hook.sh

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
HOOK="$ROOT/boards/common/hooks/40-service-manifests.sh"
READER="$ROOT/build/lib/service_manifest.py"

PASS=0
FAIL=0
ok()   { echo "  [ok]   $1"; PASS=$((PASS + 1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

# assert_grep <file> <fixed-string> <desc>
assert_grep() {
    if grep -qF "$2" "$1" 2>/dev/null; then ok "$3"; else bad "$3 (missing '$2' in ${1##*/})"; fi
}
# assert_ngrep <file> <fixed-string> <desc> — must NOT be present
assert_ngrep() {
    if grep -qF "$2" "$1" 2>/dev/null; then bad "$3 (unexpected '$2' in ${1##*/})"; else ok "$3"; fi
}
assert_eq() {
    if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi
}

# Build a minimal assembled-rootfs skeleton at $1 (passwd/group/shadow + the
# boot-success milestone + boot.d), matching what 05/10/20 leave behind.
make_rootfs() {
    local r="$1"
    mkdir -p "$r/etc/dinit.d/boot.d" "$r/usr/lib/dinit.d" "$r/usr/lib/crag/services"
    printf 'root:x:0:0:root:/root:/bin/sh\ncragd:x:300:300:Crag config daemon:/var/empty:/bin/false\n' > "$r/etc/passwd"
    printf 'root:x:0:\ncragd:x:300:\ncrag-api:x:301:cragd\n' > "$r/etc/group"
    printf 'root:!:19000:0:99999:7:::\ncragd:!:19000:0:99999:7:::\n' > "$r/etc/shadow"
    chmod 600 "$r/etc/shadow"
    printf 'type = internal\ndepends-on: cragd\ndepends-on: data-mount\n' > "$r/etc/dinit.d/boot-success"
}

write_manifest() {  # <rootfs> <name> <body...>
    local r="$1" name="$2"; shift 2
    printf '%s\n' "$@" > "$r/usr/lib/crag/services/${name}.toml"
    # a token packaged dinit service so enable finds the ../../../usr/lib target
    printf 'type = process\ncommand = /usr/bin/%s\n' "$name" > "$r/usr/lib/dinit.d/${name}"
}

run_hook() {  # <rootfs>
    ( export ROOTFS_DIR="$1" PROJECT_ROOT="$ROOT" ROOTFS_TYPE="ext4"
      # shellcheck source=build/lib/common.sh
      source "$ROOT/build/lib/common.sh"
      # shellcheck source=boards/common/hooks/40-service-manifests.sh
      source "$HOOK" )
}

uid_of() { python3 "$READER" uid "$1"; }

################################################################################
echo "== scenario 1: two app manifests (boot_success+data_dir; api_controllable+api_client) =="
R="$(mktemp -d)"; trap 'rm -rf "$R"' EXIT
make_rootfs "$R"
write_manifest "$R" svc-alpha \
    '[service]' 'name = "svc-alpha"' 'user = "alpha"' 'data_dir = true' \
    '[integration]' 'boot_success = true'
write_manifest "$R" svc-beta \
    '[service]' 'name = "svc-beta"' 'user = "beta"' \
    '[integration]' 'api_controllable = true' 'api_client = true'

if run_hook "$R"; then ok "hook ran to completion"; else bad "hook exited nonzero"; fi

UID_A="$(uid_of svc-alpha)"; UID_B="$(uid_of svc-beta)"

# (a) users created at the deterministic uid, primary group + shadow
assert_grep "$R/etc/passwd" "alpha:x:${UID_A}:${UID_A}:" "alpha in passwd at deterministic uid ${UID_A}"
assert_grep "$R/etc/passwd" "beta:x:${UID_B}:${UID_B}:"  "beta in passwd at deterministic uid ${UID_B}"
assert_grep "$R/etc/passwd" "/bin/false"                 "app user shell is /bin/false"
assert_grep "$R/etc/group"  "alpha:x:${UID_A}:"          "alpha primary group"
assert_grep "$R/etc/group"  "beta:x:${UID_B}:"           "beta primary group"
assert_grep "$R/etc/shadow" "alpha:!:"                   "alpha locked shadow entry"
assert_grep "$R/etc/shadow" "beta:!:"                    "beta locked shadow entry"
assert_eq   "$(stat -c %a "$R/etc/shadow")" "600"        "shadow mode restored (dev => 600)"

# (b) data_dir recorded for boot-time creation (only for svc-alpha)
assert_grep  "$R/etc/crag/app-data-dirs" "svc-alpha alpha" "svc-alpha recorded in app-data-dirs (owner alpha)"
assert_ngrep "$R/etc/crag/app-data-dirs" "svc-beta"        "svc-beta NOT in app-data-dirs (no data_dir)"

# (c) env-files: both get the socket; only svc-alpha gets CRAG_DATA_DIR
assert_grep  "$R/etc/crag/services/svc-alpha.env" "CRAG_API_SOCKET=/run/crag/cragd.sock" "svc-alpha env has API socket"
assert_grep  "$R/etc/crag/services/svc-alpha.env" "CRAG_DATA_DIR=/data/apps/svc-alpha"      "svc-alpha env has data dir"
assert_grep  "$R/etc/crag/services/svc-beta.env"  "CRAG_API_SOCKET=/run/crag/cragd.sock"  "svc-beta env has API socket"
assert_ngrep "$R/etc/crag/services/svc-beta.env"  "CRAG_DATA_DIR"                            "svc-beta env has NO data dir"

# (d) boot_success => depends-on line (only for svc-alpha)
assert_grep  "$R/etc/dinit.d/boot-success" "depends-on: svc-alpha" "boot-success depends-on svc-alpha"
assert_ngrep "$R/etc/dinit.d/boot-success" "depends-on: svc-beta"  "boot-success does NOT depend on svc-beta"

# (e) api_client => join crag-api (beta only; alpha did not opt in)
if awk -F: '$1=="crag-api"{n=split($4,a,","); for(i=1;i<=n;i++) if(a[i]=="beta") ok=1} END{exit ok?0:1}' "$R/etc/group"; then
    ok "beta is a member of crag-api"
else
    bad "beta not in crag-api member list"
fi
if awk -F: '$1=="crag-api"{n=split($4,a,","); for(i=1;i<=n;i++) if(a[i]=="alpha") bad=1} END{exit bad?1:0}' "$R/etc/group"; then
    ok "alpha is NOT in crag-api (did not opt in)"
else
    bad "alpha unexpectedly in crag-api"
fi

# (f) enabled into boot.d at the packaged-service symlink shape
assert_eq "$(readlink "$R/etc/dinit.d/boot.d/svc-alpha")" "../../../usr/lib/dinit.d/svc-alpha" "svc-alpha enabled (packaged target)"
assert_eq "$(readlink "$R/etc/dinit.d/boot.d/svc-beta")"  "../../../usr/lib/dinit.d/svc-beta"  "svc-beta enabled (packaged target)"
rm -rf "$R"; trap - EXIT

################################################################################
echo "== scenario 2: uid hash-collision probes upward =="
R="$(mktemp -d)"; trap 'rm -rf "$R"' EXIT
make_rootfs "$R"
START="$(uid_of svc-alpha)"
# Pre-occupy svc-alpha's deterministic starting uid with an unrelated user so
# the hook must probe to START+1.
printf 'squatter:x:%s:%s::/var/empty:/bin/false\n' "$START" "$START" >> "$R/etc/passwd"
printf 'squatter:x:%s:\n' "$START" >> "$R/etc/group"
write_manifest "$R" svc-alpha '[service]' 'name = "svc-alpha"' 'user = "alpha"'
run_hook "$R" || bad "hook exited nonzero (collision scenario)"
assert_grep "$R/etc/passwd" "alpha:x:$((START + 1)):$((START + 1)):" "collision probed to START+1 ($((START + 1)))"
rm -rf "$R"; trap - EXIT

################################################################################
echo "== scenario 3: idempotent re-run makes no duplicate/extra changes =="
R="$(mktemp -d)"; trap 'rm -rf "$R"' EXIT
make_rootfs "$R"
write_manifest "$R" svc-alpha '[service]' 'name = "svc-alpha"' 'user = "alpha"' \
    '[integration]' 'boot_success = true' 'api_client = true'
run_hook "$R" >/dev/null 2>&1
FIRST_PASSWD="$(md5sum "$R/etc/passwd")"; FIRST_GROUP="$(md5sum "$R/etc/group")"
FIRST_BS="$(grep -c 'depends-on: svc-alpha' "$R/etc/dinit.d/boot-success")"
run_hook "$R" >/dev/null 2>&1
assert_eq "$(md5sum "$R/etc/passwd")" "$FIRST_PASSWD" "passwd unchanged on re-run (no duplicate user)"
assert_eq "$(md5sum "$R/etc/group")"  "$FIRST_GROUP"  "group unchanged on re-run (no duplicate membership)"
assert_eq "$(grep -c 'depends-on: svc-alpha' "$R/etc/dinit.d/boot-success")" "$FIRST_BS" "boot-success depends-on added once"
assert_eq "$FIRST_BS" "1" "exactly one depends-on: svc-alpha line"
rm -rf "$R"; trap - EXIT

################################################################################
echo "== scenario 4: NO manifests => the hook is a no-op (byte-identical path) =="
R="$(mktemp -d)"; trap 'rm -rf "$R"' EXIT
make_rootfs "$R"
rmdir "$R/usr/lib/crag/services"  # a rootfs with no app manifests at all
BEFORE="$(cd "$R" && find . \( -type f -o -type l \) -exec md5sum {} + | sort)"
run_hook "$R" || bad "hook exited nonzero (no-manifest scenario)"
AFTER="$(cd "$R" && find . \( -type f -o -type l \) -exec md5sum {} + | sort)"
if [ "$BEFORE" = "$AFTER" ]; then ok "rootfs byte-identical after no-manifest run"; else bad "rootfs changed on the no-manifest path"; fi
assert_eq "$([ -e "$R/etc/crag" ] && echo yes || echo no)" "no" "no /etc/crag created on the no-manifest path"
rm -rf "$R"; trap - EXIT

echo ""
echo "service-manifest hook test: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
