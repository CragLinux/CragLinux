#!/bin/bash
# Patch definitions for the cross-compilation toolchain
#
# This file is sourced by sdk/build-toolchain.sh to apply security patches
# and bug fixes to upstream sources.
#
# Patch arrays are named: <COMPONENT>_PATCHES
# Each entry is a path relative to this directory (build/patches/):
#   - musl/    musl libc patches (iconv CVE fixes)
#   - kernel/  kernel Clang-build patches, applied by build/lib/kernel.sh
#     (kernel patches are NOT listed here; kernel.sh discovers them by
#      kernel major.minor under build/patches/kernel/<version>/)
#
# RESOLVED(migration, phase 2): the musl iconv patches are superseded.
# Verified 2026-07 against musl v1.2.6 and the cports pin (e3c9e1a0):
#   - both patches are upstream musl commits (e5adcd97, c47ad25e) that
#     shipped in the musl 1.2.6 release (src/locale/iconv.c in v1.2.6
#     contains the fixed EUC-KR bounds check and the wctomb_utf8 hardening);
#   - cports main/musl builds a 1.2.6+ git snapshot, so the distro-side
#     musl never needed them.
# The SDK now pins MUSL_VERSION=1.2.6, so the entries below are disabled.
# The patch files are kept under musl/ for provenance/reference only.

##############################################################################
# musl libc patches
##############################################################################

# CVE patches for musl 1.2.5 iconv vulnerabilities (CVE-2025-26519)
# Reference: https://www.openwall.com/lists/musl/2025/02/13/1
# Included upstream in musl >= 1.2.6 — do not re-enable unless the SDK
# musl pin ever drops below 1.2.6.
MUSL_PATCHES=(
    # "musl/0001-iconv-fix-euc-kr-decoder-bounds-check.patch"   # upstream in 1.2.6
    # "musl/0002-iconv-harden-utf8-output-against-decoder-bugs.patch"  # upstream in 1.2.6
)

##############################################################################
# LLVM/Clang patches (if needed)
##############################################################################

LLVM_PATCHES=(
    # Add LLVM patches here as needed
)

##############################################################################
# Linux kernel header patches (if needed)
##############################################################################

LINUX_PATCHES=(
    # Add Linux header patches here as needed
)
