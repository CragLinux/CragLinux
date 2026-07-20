# Astro addition (not in cports upstream; docs/05 §1): libubootenv is the
# userspace U-Boot environment library + fw_printenv/fw_setenv tools. RAUC's
# uboot bootloader backend shells out to fw_setenv/fw_printenv to flip
# BOOT_ORDER / BOOT_x_LEFT (AD-009). Config comes from /etc/fw_env.config,
# which Astro generates per board at rootfs assembly (env-in-FAT file on the
# bootenv partition — MIGRATION-NOTES §12 deviation 1).
# Candidate for upstreaming to Chimera cports (standard package, no
# Astro-specific content; see build/patches/cports/UPSTREAMING.md process note).
pkgname = "libubootenv"
pkgver = "0.3.7"
pkgrel = 1
build_style = "cmake"
hostmakedepends = ["cmake", "ninja", "pkgconf"]
makedepends = [
    "libyaml-devel",
    "linux-headers",
    "musl-bsd-headers",  # sys/queue.h
    "zlib-ng-compat-devel",
]
pkgdesc = "U-Boot environment access library and tools"
license = "LGPL-2.1-or-later"
url = "https://github.com/sbabic/libubootenv"
source = f"{url}/archive/refs/tags/v{pkgver}.tar.gz>libubootenv-{pkgver}.tar.gz"
sha256 = "92021fc5a0a965030588d0c867a771d28b28c0d17c9fd022f0dafe9f01de714e"
# NDEBUG: without it, libuboot_open() prints "Environment OK, copy 0" to
# STDOUT (uboot_env.c, gated on !NDEBUG; cbuild's buildtype=plain defines
# nothing). RAUC parses fw_printenv stdout, so that line gets ingested as
# variable data and written back — after a few mark-good/install round
# trips the bootloader env is full of junk BOOT_ORDER variants and slot
# selection breaks (observed in the AD-020 rollback test).
tool_flags = {"CFLAGS": ["-DNDEBUG"]}


@subpackage("libubootenv-devel")
def _(self):
    return self.default_devel()


@subpackage("libubootenv-progs")
def _(self):
    self.subdesc = "fw_printenv/fw_setenv tools"
    return ["usr/bin/fw_printenv", "usr/bin/fw_setenv"]
