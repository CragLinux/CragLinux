#!/bin/bash
# Unit test for the code/config fence (docs/08 §3, AD-017) in merge.sh:
# fence_check(incoming_file_abs, dest_relpath, layer_name).
#
#   * a fixture ELF anywhere            => die
#   * a fixture file under usr/bin      => die
#   * a fixture file under usr/sbin     => die
#   * a fixture file under an unlisted usr/lib dir => die
#   * a config file (etc/...)           => pass
#   * a dinit service TEXT file (usr/lib/dinit.d/...) => pass
#   * a usr/lib/crag script            => pass
#   * usr/lib/os-release (exact)        => pass
#   * a symlink into an allowed dir under an allowed hook dir => pass
#   * an ELF is rejected even under an ALLOWED path (rule 2 is path-independent)
#
# AND the real-overlay AUDIT: every file in boards/common/overlay and each
# boards/*/overlay must pass the fence (the M4-phase-1 requirement that the
# fence runs on existing overlays and the no-app path stays byte-identical).
#
# Run (host or crag-builder container), from the repo root:
#   ./build/lib/test_fence.sh

set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

# shellcheck source=build/lib/common.sh
source "$HERE/common.sh"
# shellcheck source=build/lib/merge.sh
source "$HERE/merge.sh"

PASS=0
FAIL=0

# expect_pass <desc> <file> <rel> — fence_check must return 0 (no die).
expect_pass() {
    local desc="$1" file="$2" rel="$3"
    if ( fence_check "$file" "$rel" "test-layer" ) >/dev/null 2>&1; then
        echo "  [ok]   pass: ${desc}"
        PASS=$((PASS + 1))
    else
        echo "  [FAIL] expected PASS but fence died: ${desc} (${rel})"
        FAIL=$((FAIL + 1))
    fi
}

# expect_fail <desc> <file> <rel> — fence_check must die (nonzero exit).
expect_fail() {
    local desc="$1" file="$2" rel="$3"
    if ( fence_check "$file" "$rel" "test-layer" ) >/dev/null 2>&1; then
        echo "  [FAIL] expected FAIL but fence passed: ${desc} (${rel})"
        FAIL=$((FAIL + 1))
    else
        echo "  [ok]   fail: ${desc}"
        PASS=$((PASS + 1))
    fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- fixtures --------------------------------------------------------------
printf '\x7fELF\x02\x01\x01' > "$TMP/elf.bin"            # ELF magic + a few bytes
printf '#!/bin/sh\necho hi\n' > "$TMP/script.sh"          # a shell script (NOT elf)
printf 'KEY=value\n' > "$TMP/plain.conf"                  # config text
printf 'type = process\nrestart = true\n' > "$TMP/svc"    # dinit service text
printf 'NAME=Crag\n' > "$TMP/os-release"
ln -s ../crag/hook.sh "$TMP/hooklink"                    # a symlink

echo "== fence rejections (die) =="
expect_fail "ELF under etc (rule 2 anywhere)"     "$TMP/elf.bin"    "etc/acme/agent"
expect_fail "ELF under an ALLOWED usr/lib/crag"  "$TMP/elf.bin"    "usr/lib/crag/agent"
expect_fail "plain file under usr/bin"            "$TMP/script.sh"  "usr/bin/acme-tool"
expect_fail "plain file under usr/sbin"           "$TMP/script.sh"  "usr/sbin/acme-tool"
expect_fail "file under unlisted usr/lib dir"     "$TMP/plain.conf" "usr/lib/acme/whatever.conf"
expect_fail "file directly under usr/lib"         "$TMP/plain.conf" "usr/lib/libacme.conf"
# merged-/usr aliases: bin/ sbin/ lib/ lib64/ ARE usr/... on this image and
# must be fenced identically (else a trivial evasion).
expect_fail "merged-usr bin/ alias"               "$TMP/script.sh"  "bin/acme-tool"
expect_fail "merged-usr sbin/ alias"              "$TMP/script.sh"  "sbin/acme-tool"
expect_fail "merged-usr lib/ unlisted alias"      "$TMP/plain.conf" "lib/acme/x.conf"
expect_fail "merged-usr lib64/ alias"             "$TMP/plain.conf" "lib64/acme/x.conf"
# /-anchored prefix: usr/lib/crag-evil shares the "crag" text but is a
# DIFFERENT dir than the allowlisted usr/lib/crag/ — must NOT be allowed.
expect_fail "prefix-lookalike usr/lib/crag-evil" "$TMP/script.sh"  "usr/lib/crag-evil/x"
# a symlink is path-checked (rule 1) even though it is never ELF-probed.
expect_fail "symlink under fenced usr/bin"        "$TMP/hooklink"   "usr/bin/acme-link"

echo "== fence passes =="
expect_pass "config under etc"                    "$TMP/plain.conf" "etc/acme/defaults.toml"
expect_pass "cert-ish file under etc"             "$TMP/plain.conf" "etc/ssl/certs/acme.pem"
expect_pass "dinit service TEXT under usr/lib"    "$TMP/svc"        "usr/lib/dinit.d/acme-sensord"
expect_pass "crag platform script (allowed)"     "$TMP/script.sh"  "usr/lib/crag/x.sh"
expect_pass "tmpfiles.d config"                   "$TMP/plain.conf" "usr/lib/tmpfiles.d/acme.conf"
expect_pass "udev rule (text)"                    "$TMP/plain.conf" "usr/lib/udev/rules.d/70-acme.rules"
expect_pass "os-release exact file"               "$TMP/os-release" "usr/lib/os-release"
expect_pass "os-release drop-in"                  "$TMP/plain.conf" "usr/lib/os-release.d/acme.conf"
expect_pass "dhcpcd hook symlink"                 "$TMP/hooklink"   "usr/lib/dhcpcd-hooks/60-crag-lease"
expect_pass "usr/share is not fenced"             "$TMP/plain.conf" "usr/share/dbus-1/system.d/x.conf"
expect_pass "usr/libexec is not fenced"           "$TMP/script.sh"  "usr/libexec/crag/mark-good"
# merged-usr alias landing in an ALLOWED usr/lib subtree still passes.
expect_pass "merged-usr lib/dinit.d alias"        "$TMP/svc"        "lib/dinit.d/acme-sensord"

# --- AUDIT: every real overlay file passes ---------------------------------
echo "== AUDIT: existing overlays pass the fence =="
AUDIT_FAIL=0
audit_dir() {
    local base="$1"
    [ -d "$base" ] || return 0
    local f rel
    while IFS= read -r -d '' f; do
        rel="${f#"$base"/}"
        if ( fence_check "$f" "$rel" "audit:$(basename "$(dirname "$base")")" ) >/dev/null 2>&1; then
            :
        else
            echo "  [FAIL] real overlay file REJECTED by fence: ${f} (rel=${rel})"
            AUDIT_FAIL=$((AUDIT_FAIL + 1))
        fi
    done < <(find "$base" \( -type f -o -type l \) -print0)
}
audit_dir "$ROOT/boards/common/overlay"
for d in "$ROOT"/boards/*/overlay; do
    [ "$d" = "$ROOT/boards/common/overlay" ] && continue
    audit_dir "$d"
done
if [ "$AUDIT_FAIL" -eq 0 ]; then
    echo "  [ok]   all existing overlay files pass the fence"
    PASS=$((PASS + 1))
else
    echo "  [FAIL] ${AUDIT_FAIL} existing overlay file(s) rejected"
    FAIL=$((FAIL + AUDIT_FAIL))
fi

echo ""
echo "fence test: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
