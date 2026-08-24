#!/bin/bash
set -euo pipefail

# Crag Linux - CI suites (AD-024, docs/10 §4)
#
# Local-first: this script IS the pipeline. Hosted CI workflows
# (.github/workflows/) are thin wrappers that check out, restore caches,
# and run exactly this — any CI failure reproduces on a laptop with the
# same command.
#
# Usage:
#   ./build/crag-ci.sh pr [--boards=b1,b2] [--skip-gate]
#
# Suites:
#   pr    docs/10 §4 "Per-PR": lint -> per-arch board builds (dev+prod,
#         image+bundle) -> boot-smoke (both variants) -> AD-020
#         update/rollback gate (dev). Steps owned by later milestones
#         (cragd unit/API suites: M3; external-tree example: M4) are
#         reported as SKIPPED so the suite shape already matches the doc.
#
# Results: junit XML per test in build/state/test-results/, summary table
# on stdout, nonzero exit if anything failed.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SUITE="${1:?Usage: $0 pr [--boards=...] [--skip-gate]}"
shift
BOARDS="qemu-x86_64 qemu-aarch64 qemu-armv7"   # one per arch, docs/10 §4
SKIP_GATE=false
for arg in "$@"; do
    case "$arg" in
        --boards=*) BOARDS="${arg#--boards=}"; BOARDS="${BOARDS//,/ }" ;;
        --skip-gate) SKIP_GATE=true ;;
        *) echo "ERROR: unknown option: $arg"; exit 1 ;;
    esac
done
[ "$SUITE" = "pr" ] || { echo "ERROR: unknown suite: ${SUITE} (only 'pr' exists yet)"; exit 1; }

ENGINE="${CONTAINER_ENGINE:-$(command -v podman >/dev/null && echo podman || echo docker)}"
IMAGE_NAME="${CONTAINER_IMAGE:-crag-builder}"
in_container() {
    "$ENGINE" run --rm --userns=keep-id --privileged \
        -v "${PROJECT_ROOT}:/workspace:Z" "$IMAGE_NAME" -c "cd /workspace && $*"
}

declare -A RESULT
FAILED=0
step() {  # step <name> <cmd...>
    local name="$1"; shift
    echo ""
    echo "=== [${name}] ==="
    if "$@"; then
        RESULT[$name]="PASS"
    else
        RESULT[$name]="FAIL"
        FAILED=1
    fi
}
skip() {
    local name="$1" why="$2"
    RESULT[$name]="SKIP (${why})"
    echo ""
    echo "=== [${name}] SKIPPED: ${why} ==="
}

##############################################################################
# 1. Lint (docs/10 §4 item 1)
##############################################################################
lint_shell() {
    # Excluded classes (ratchet: remove as the backlog is cleaned up):
    #   SC2155 declare-and-assign  SC2034 unused-var  SC1090/91 dynamic source
    #   SC2164 bare cd — every entry point runs `set -e`, making cd fatal
    in_container 'shellcheck --severity=warning \
        -e SC2155,SC2034,SC1090,SC1091,SC2164 \
        build/*.sh build/lib/*.sh sdk/*.sh container/*.sh \
        boards/common/hooks/*.sh boards/*/hooks/*.sh \
        examples/*/hooks/*.sh \
        boards/common/overlay/usr/lib/crag/* \
        boards/common/overlay/usr/libexec/crag/* 2>&1' | tail -20
    return "${PIPESTATUS[0]}"
}
lint_python() {
    in_container 'ruff check build/lib/ build/validate-config.py' | tail -10
    return "${PIPESTATUS[0]}"
}
lint_config() {
    # schema validation over every board + variant TOML, plus the
    # example external trees (tree.toml + tree-provided variants)
    in_container 'rc=0
        for b in boards/*/board.toml; do
            python3 build/lib/config.py board "$b" --format=json > /dev/null || { echo "INVALID: $b"; rc=1; }
            for v in "$(dirname "$b")"/variants/*.toml; do
                [ -f "$v" ] || continue
                python3 build/lib/config.py variant "$v" --format=json > /dev/null || { echo "INVALID: $v"; rc=1; }
            done
        done
        for t in examples/*/tree.toml; do
            [ -f "$t" ] || continue
            python3 build/lib/config.py tree "$t" --format=json > /dev/null || { echo "INVALID: $t"; rc=1; }
            for v in "$(dirname "$t")"/variants/*.toml; do
                [ -f "$v" ] || continue
                python3 build/lib/config.py variant "$v" --format=json > /dev/null || { echo "INVALID: $v"; rc=1; }
            done
        done
        exit $rc'
}
lint_zig() {
    # cragd lands at M3; check formatting once sources exist
    if compgen -G "${PROJECT_ROOT}/cragd/src/*.zig" > /dev/null; then
        in_container 'zig fmt --check cragd/'
    else
        echo "(no cragd zig sources yet)"
    fi
}

step "lint-shell"  lint_shell
step "lint-python" lint_python
step "lint-config" lint_config
step "lint-zig"    lint_zig

##############################################################################
# 1b. build/lib unit suites (merge engine M4p0; fence + service manifests M4p1)
##############################################################################
build_lib_unit() {
    in_container 'python3 build/lib/test_merge_board_variant.py \
        && python3 build/lib/test_service_manifest.py \
        && ./build/lib/test_fence.sh \
        && ./build/lib/test_service_manifests_hook.sh'
}
step "build-lib-unit" build_lib_unit

##############################################################################
# 2. cragd unit tests + binary budget (docs/06 §3)
##############################################################################
cragd_unit() {
    # Unit/conformance tests with the container's pinned Zig, then the
    # docs/06 §3 budget: static x86_64 ReleaseSafe binary <= 8 MiB (the
    # same bound build_cragd enforces per-board at image assembly).
    # extract_cragd_deps first: build.zig's default -Dbasu-prefix is
    # build/state/x86_64/cragd-deps (basu sd-bus headers + libbasu.a).
    in_container 'source build/lib/common.sh && source build/lib/cragd.sh \
        && PROJECT_ROOT=/workspace extract_cragd_deps x86_64 \
        && cd cragd \
        && zig build test --cache-dir /workspace/build/state/zig-cache-ci \
        && zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe \
            --cache-dir /workspace/build/state/zig-cache-ci --prefix /tmp/cragd-budget \
        && size=$(stat -c %s /tmp/cragd-budget/bin/cragd) \
        && echo "cragd x86_64-linux-musl ReleaseSafe: ${size} bytes" \
        && [ "$size" -le $((8 * 1024 * 1024)) ]'
}
step "cragd-unit" cragd_unit

##############################################################################
# 3+4. Per-board: build (dev + prod, image + bundle) -> boot-smoke -> AD-020
##############################################################################
for B in $BOARDS; do
    step "build-${B}-prod" "${SCRIPT_DIR}/crag-build.sh" "$B" prod
    step "build-${B}-dev"  "${SCRIPT_DIR}/crag-build.sh" "$B" dev
    if [ "${RESULT[build-${B}-prod]}" = "PASS" ]; then
        step "boot-smoke-${B}-prod" "${SCRIPT_DIR}/test-boot-smoke.sh" "$B" prod
    else
        skip "boot-smoke-${B}-prod" "build failed"
    fi
    if [ "${RESULT[build-${B}-dev]}" = "PASS" ]; then
        step "boot-smoke-${B}-dev" "${SCRIPT_DIR}/test-boot-smoke.sh" "$B" dev
        if [ "$SKIP_GATE" = true ]; then
            skip "ad020-${B}" "--skip-gate"
        else
            step "ad020-${B}" "${SCRIPT_DIR}/test-update-rollback.sh" "$B"
        fi
    else
        skip "boot-smoke-${B}-dev" "build failed"
        skip "ad020-${B}" "build failed"
    fi
done

##############################################################################
# 5+6. cragd API suite (M3 phase 3, hwsim rig), external-tree example (M4)
##############################################################################
# The API suite boots ONE board's dev image: qemu-x86_64 (fastest TCG).
# It needs that build to have run in this invocation (or --boards to have
# included it) — otherwise it is skipped, not failed.
API_BOARD="qemu-x86_64"
if [ "${RESULT[build-${API_BOARD}-dev]:-}" = "PASS" ]; then
    step "cragd-api" "${SCRIPT_DIR}/test-api.sh" "$API_BOARD"
else
    skip "cragd-api" "needs a passing ${API_BOARD} dev build in this run"
fi
# The docs/08 §7 reference tree, kept green here (docs/10 §4 item 6):
# a full image build with --external (tree templates source-built into
# the apk world, manifest wiring, fence on the tree overlay), then a
# boot-smoke of the product image. Uses the API board: its base
# packages are binary-mode and its kernel is warm when the default
# board set ran.
step "external-tree" "${SCRIPT_DIR}/crag-build.sh" "$API_BOARD" acme-prod \
    --external="${PROJECT_ROOT}/examples/external-tree-acme"
if [ "${RESULT[external-tree]}" = "PASS" ]; then
    step "external-tree-smoke" "${SCRIPT_DIR}/test-boot-smoke.sh" "$API_BOARD" acme-prod
else
    skip "external-tree-smoke" "build failed"
fi

##############################################################################
# 7. AD-026 deploy loop + image-derived app sysroot (M4 phase 3)
##############################################################################
# Needs the arch SDK toolchain (a build/state artifact hosted CI does
# not cache — skipped cleanly there; local runs cover it, docs/03 §3
# fix item 3). test-deploy.sh stages the sysroot, compiles the acme
# daemon against it, then proves binary+package sideloads against a
# booted dev VM. The final rebuild restores the no-tree dev image so
# later runs never inherit acme state.
if ls "${PROJECT_ROOT}/build/state/x86_64/bin/"*-clang >/dev/null 2>&1; then
    step "deploy-build" "${SCRIPT_DIR}/crag-build.sh" "$API_BOARD" dev \
        --external="${PROJECT_ROOT}/examples/external-tree-acme"
    if [ "${RESULT[deploy-build]}" = "PASS" ]; then
        step "deploy-loop" "${SCRIPT_DIR}/test-deploy.sh" "$API_BOARD"
        step "deploy-restore" "${SCRIPT_DIR}/crag-build.sh" "$API_BOARD" dev
    else
        skip "deploy-loop" "dev+tree build failed"
        skip "deploy-restore" "dev+tree build failed"
    fi
else
    skip "deploy-build" "SDK toolchain not built (./sdk/build-toolchain.sh x86_64)"
    skip "deploy-loop" "SDK toolchain not built"
    skip "deploy-restore" "SDK toolchain not built"
fi

##############################################################################
# Summary
##############################################################################
echo ""
echo "==================== crag ci ${SUITE} ===================="
for k in $(printf '%s\n' "${!RESULT[@]}" | sort); do
    printf '  %-28s %s\n' "$k" "${RESULT[$k]}"
done
echo "==========================================================="
if [ "$FAILED" -ne 0 ]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: PASS"
