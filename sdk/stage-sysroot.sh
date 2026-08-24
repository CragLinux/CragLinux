#!/bin/bash
set -euo pipefail

# Crag SDK — image-derived app sysroot (AD-002, docs/03 §3, docs/08 §6).
#
# "Sysroot generated from the built image's package set: apk-install
# *-devel of everything in the image into a staging sysroot, so apps
# compile against exactly what ships."
#
# Input is the ASSEMBLED image's apk database
# (build/state/images/<board>-<variant>/rootfs/lib/apk/db/installed) —
# NOT packages.manifest: the manifest is the *listed* set (~27 names);
# the DB is the resolved runtime closure (~125 packages), and AD-002
# says "everything in the image". For every installed package P whose
# cports template tree has a P-devel subpackage (cports materializes
# every subpackage as a symlink dir, so `-e cports/main/P-devel` is an
# O(1) offline test covering subpackage-level names like libcxx-devel),
# P-devel is apk-installed — with the SAME trust model as the rootfs
# binary mode (pinned Chimera keys + cbuild dev keys, local repo first
# with exact version pins, NO --allow-untrusted). linux-headers is
# added unconditionally (kernel uapi headers for app builds).
#
# The result is a MERGED-/usr, apk-shaped sysroot (usr/include,
# usr/lib) that is deliberately SEPARATE from the SDK's flat bootstrap
# sysroot (build/state/<arch>/sysroot). Clang's header search is
# layout-conditional: as soon as a sysroot has usr/include,
# <sysroot>/include drops out of the search path entirely — mixing apk
# packages into the flat sysroot would make the SDK's own musl headers
# invisible. Two sysroots, two jobs: the flat one bootstraps the
# toolchain; this one is what apps compile against.
#
# Output (per image, so "exact target image" is literal):
#   build/state/images/<board>-<variant>/sysroot/          the sysroot
#   build/state/images/<board>-<variant>/sdk/environment   . me (docs/08 §6)
#   build/state/images/<board>-<variant>/sdk/bin/<triple>-clang{,++}
#   build/state/images/<board>-<variant>/sdk/<arch>-toolchain.cmake
#
# The per-image compiler wrappers chain to the arch SDK wrappers
# (build/state/<arch>/bin/<triple>-clang) appending
# --sysroot=<app-sysroot> AFTER the wrapper's own flags — clang's
# last-one-wins makes the app sysroot take effect while every other
# cross flag (target, march, lld, compiler-rt) is inherited.
#
# Usage:  sdk/stage-sysroot.sh <board> <variant>
# Needs:  the image built (crag-build.sh <board> <variant>) and the
#         SDK toolchain for its arch (sdk/build-toolchain.sh <arch>).
# Runs host-side or in the crag-builder container (apk via
# resolve_apk, same as the cragd deps extraction).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${PROJECT_ROOT}/build/lib/common.sh"
source "${PROJECT_ROOT}/build/lib/cragd.sh"   # resolve_apk

BOARD="${1:?Usage: $0 <board> <variant>}"
VARIANT="${2:?Usage: $0 <board> <variant>}"

IMAGE_DIR="${PROJECT_ROOT}/build/state/images/${BOARD}-${VARIANT}"
INSTALLED_DB="${IMAGE_DIR}/rootfs/lib/apk/db/installed"
[ -f "$INSTALLED_DB" ] || \
    die "no installed-package DB at ${INSTALLED_DB} — build the image first: ./build/crag-build.sh ${BOARD} ${VARIANT}"

BOARD_ARCH=$(python3 "${PROJECT_ROOT}/build/lib/config.py" board \
    "${PROJECT_ROOT}/boards/${BOARD}/board.toml" --format=json | \
    python3 -c 'import json,sys; print(json.load(sys.stdin)["board"]["arch"])')
CBUILD_ARCH=$(cbuild_arch_for "$BOARD_ARCH")

# Arch -> SDK triple, same mapping as sdk/build-toolchain.sh's case block.
case "$BOARD_ARCH" in
    armv7hf) TRIPLE="armv7-unknown-linux-musleabihf" ;;
    aarch64) TRIPLE="aarch64-unknown-linux-musl" ;;
    x86_64)  TRIPLE="x86_64-unknown-linux-musl" ;;
    *) die "unsupported arch for the app SDK: ${BOARD_ARCH}" ;;
esac

SDK_BIN="${PROJECT_ROOT}/build/state/${BOARD_ARCH}/bin"
[ -x "${SDK_BIN}/${TRIPLE}-clang" ] || \
    die "SDK toolchain for ${BOARD_ARCH} not built (${SDK_BIN}/${TRIPLE}-clang missing) — run: ./sdk/build-toolchain.sh ${BOARD_ARCH}"

SYSROOT_DIR="${IMAGE_DIR}/sysroot"
SDK_DIR="${IMAGE_DIR}/sdk"
LOCAL_REPO="${PROJECT_ROOT}/cports/packages/main"
CHIMERA_REPO="https://repo.chimera-linux.org/current/main"

##############################################################################
# 1. The devel set, from the installed DB
##############################################################################
# apk v2-style plain-text DB: P: package name, V: version. The version is
# used to PIN local-repo installs (name=ver) so the sysroot cannot drift
# from the image even if the local repo gains newer builds later.
declare -a DEVEL_PKGS=()
declare -a SKIPPED=()
declare -A SEEN_DEVEL=()
pkg="" ver=""
devel_template_exists() {
    [ -e "${PROJECT_ROOT}/cports/main/$1" ] || \
        [ -e "${PROJECT_ROOT}/cports/user/$1" ]
}

add_devel() {
    local name="$1" want_ver="$2" devel pin
    devel="${name}-devel"
    if ! devel_template_exists "$devel"; then
        # A runtime library often installs as the -libs SUBPACKAGE while
        # the headers hang off the parent template (curl-libs but
        # curl-devel, openssl3-libs but openssl3-devel). The -libs
        # suffix is the "this library ships in the image" signal, so
        # its parent's devel belongs in the sysroot.
        if [ "${name%-libs}" != "$name" ] && \
           devel_template_exists "${name%-libs}-devel"; then
            devel="${name%-libs}-devel"
        else
            SKIPPED+=("$name")
            return 0
        fi
    fi
    # Two -libs siblings can resolve to one parent devel; take it once.
    [ -n "${SEEN_DEVEL[$devel]:-}" ] && return 0
    SEEN_DEVEL[$devel]=1
    # Pin to the local repo's version when the apk is there (it is the
    # very build the image installed from); Chimera-sourced fall back to
    # unpinned (their runtime came from Chimera-current too).
    pin=$(local_repo_version_sysroot "$devel")
    if [ -n "$pin" ]; then
        DEVEL_PKGS+=("${devel}=${pin}")
    else
        DEVEL_PKGS+=("$devel")
    fi
    return 0
}

# Same filename convention as rootfs.sh:local_repo_version (apk names are
# <name>-<pkgver>-r<rel>.apk; pkgver never contains dashes).
local_repo_version_sysroot() {
    local name="$1" f
    f=$(find "${LOCAL_REPO}/${CBUILD_ARCH}" -maxdepth 1 \
        -name "${name}-[0-9]*.apk" 2>/dev/null | sort -V | tail -1)
    [ -z "$f" ] && return 0
    basename "$f" .apk | awk -F- -v name="$name" '{
        ver = $(NF-1) "-" $NF
        if (substr($0, 1, length(name) + 1) == name "-") print ver
    }'
}

while IFS= read -r line; do
    case "$line" in
        P:*) pkg="${line#P:}" ;;
        V:*) ver="${line#V:}" ;;
        "")  [ -n "$pkg" ] && add_devel "$pkg" "$ver"; pkg="" ver="" ;;
    esac
done < "$INSTALLED_DB"
[ -n "$pkg" ] && add_devel "$pkg" "$ver"

# Kernel uapi headers: apps need them, no image package pulls them in.
DEVEL_PKGS+=("linux-headers")

[ "${#DEVEL_PKGS[@]}" -gt 1 ] || \
    die "no -devel packages resolved from ${INSTALLED_DB} — is the cports checkout present?"

##############################################################################
# 2. Idempotency stamp (cragd.sh extract pattern)
##############################################################################
STAMP="${SYSROOT_DIR}/.crag-sysroot-stamp"
WANT_STAMP=$(printf '%s\n' "${DEVEL_PKGS[@]}" | sort)
if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$WANT_STAMP" ]; then
    log_info "app sysroot up to date (${SYSROOT_DIR})"
    exit 0
fi

##############################################################################
# 3. apk-install into the staging sysroot (rootfs binary-mode trust)
##############################################################################
log_step "Staging app sysroot for ${BOARD}/${VARIANT} (${#DEVEL_PKGS[@]} devel package(s), ${#SKIPPED[@]} without -devel)..."

rm -rf "$SYSROOT_DIR"
mkdir -p "${SYSROOT_DIR}/etc/apk/keys"

# Trust: pinned Chimera release keys + the cbuild dev signing keys —
# exactly rootfs.sh's binary-mode set, and like it, NO --allow-untrusted.
if [ ! -d "${PROJECT_ROOT}/build/keys/chimera" ] || \
   ! ls "${PROJECT_ROOT}/build/keys/chimera/"*.pub >/dev/null 2>&1; then
    die "no pinned Chimera keys in build/keys/chimera/ — refusing to TOFU a remote repo"
fi
cp "${PROJECT_ROOT}/build/keys/chimera/"*.pub "${SYSROOT_DIR}/etc/apk/keys/"
if ls "${PROJECT_ROOT}/cports/etc/keys/"*.pub >/dev/null 2>&1; then
    cp "${PROJECT_ROOT}/cports/etc/keys/"*.pub "${SYSROOT_DIR}/etc/apk/keys/"
fi

# Local repo first (version pins make it win deterministically); Chimera
# fallback for devel subpackages Crag never built. armv7 has no Chimera
# binary repo (docs/10 §4) — local only there.
{
    echo "v3 ${LOCAL_REPO}"
    [ "$CBUILD_ARCH" != "armv7" ] && echo "v3 ${CHIMERA_REPO}"
} > "${SYSROOT_DIR}/etc/apk/repositories"

apk_cmd=$(resolve_apk)
# --usermode iff unprivileged (rootfs.sh:apk_user_flags — build-uid file
# ownership is fine, even right, for a sysroot).
user_flags=""
[ "$(id -u)" -eq 0 ] || user_flags="--usermode"
# shellcheck disable=SC2086  # apk_cmd may carry an env prefix
$apk_cmd --root "$SYSROOT_DIR" \
    --arch "$CBUILD_ARCH" \
    --keys-dir etc/apk/keys \
    $user_flags \
    --initdb \
    add "${DEVEL_PKGS[@]}" \
    || die "apk add into the app sysroot failed (${BOARD}/${VARIANT})"

echo "$WANT_STAMP" > "$STAMP"

##############################################################################
# 4. Per-image SDK: wrappers, cmake toolchain, environment (docs/08 §6)
##############################################################################
mkdir -p "${SDK_DIR}/bin"

for tool in clang clang++; do
    cat > "${SDK_DIR}/bin/${TRIPLE}-${tool}" <<WRAP
#!/bin/bash
# Per-image app-SDK wrapper (generated by sdk/stage-sysroot.sh).
# Chains the arch SDK wrapper; the trailing --sysroot wins (clang is
# last-one-wins), pointing at the image-derived app sysroot.
exec "${SDK_BIN}/${TRIPLE}-${tool}" --sysroot="${SYSROOT_DIR}" "\$@"
WRAP
    chmod +x "${SDK_DIR}/bin/${TRIPLE}-${tool}"
done

CMAKE_FILE="${SDK_DIR}/${BOARD_ARCH}-toolchain.cmake"
cat > "$CMAKE_FILE" <<CMAKE
# Per-image app-SDK CMake toolchain (generated by sdk/stage-sysroot.sh).
# Compiler wrappers already carry target/march/sysroot/lld flags; the
# sysroot's crt/libs resolve from usr/lib like any linux sysroot.
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR ${BOARD_ARCH})
set(CMAKE_C_COMPILER ${SDK_DIR}/bin/${TRIPLE}-clang)
set(CMAKE_CXX_COMPILER ${SDK_DIR}/bin/${TRIPLE}-clang++)
set(CMAKE_SYSROOT ${SYSROOT_DIR})
set(CMAKE_FIND_ROOT_PATH ${SYSROOT_DIR})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
CMAKE

cat > "${SDK_DIR}/environment" <<ENVF
# Crag app-SDK environment for ${BOARD}/${VARIANT} (docs/08 §6).
# Source me:  . ${SDK_DIR#"${PROJECT_ROOT}"/}/environment
export SYSROOT="${SYSROOT_DIR}"
export CC="${SDK_DIR}/bin/${TRIPLE}-clang"
export CXX="${SDK_DIR}/bin/${TRIPLE}-clang++"
export CMAKE_TOOLCHAIN_FILE="${CMAKE_FILE}"
export PATH="${SDK_DIR}/bin:\${PATH}"
ENVF

log_info "app sysroot staged: ${SYSROOT_DIR}"
log_info "  devel packages: ${#DEVEL_PKGS[@]} ($(printf '%s\n' "${DEVEL_PKGS[@]}" | grep -c '=' || :) pinned local)"
log_info "  no -devel (skipped): ${SKIPPED[*]}"
log_info "  environment:    . ${SDK_DIR#"${PROJECT_ROOT}"/}/environment"
