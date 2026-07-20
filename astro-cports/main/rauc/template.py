# Astro addition (not in cports upstream; docs/05 §1): RAUC is the A/B
# update installer (AD-010 verity bundles, AD-011 dinit-supervised service).
# Stock port — Astro's dinit glue, system.conf generation and keyring live
# in the image assembly (boards/common/overlay + rootfs stage), not here,
# so this template stays upstreamable to Chimera cports.
# Notes:
#  - streaming (NBD) + network (libcurl) + json stay on: docs/05 §3
#    HTTP(S) streaming installs are a v1 capability.
#  - gpt=enabled (libfdisk) for the AD-007 GPT layout.
#  - tests off: the suite wants fakeroot/grub/qemu harnesses unavailable
#    in the cross bldroot.
pkgname = "rauc"
pkgver = "1.15.2"
pkgrel = 0
build_style = "meson"
configure_args = [
    "-Dservice=true",
    "-Dcreate=true",
    "-Dnetwork=true",
    "-Dstreaming=true",
    "-Djson=enabled",
    "-Dgpt=enabled",
    "-Dpkcs11_engine=false",
    "-Dtests=false",
    "-Dmanpages=false",
    "-Ddbuspolicydir=/usr/share/dbus-1/system.d",
    "-Ddbussystemservicedir=/usr/share/dbus-1/system-services",
    "-Ddbusinterfacesdir=/usr/share/dbus-1/interfaces",
]
hostmakedepends = ["glib-devel", "meson", "pkgconf"]
makedepends = [
    "curl-devel",
    "dbus-devel",
    "glib-devel",
    "json-glib-devel",
    "libnl-devel",
    "linux-headers",  # linux/nbd-netlink.h (streaming installs)
    "openssl3-devel",
    "util-linux-fdisk-devel",
]
depends = ["ca-certificates"]
pkgdesc = "Safe and secure A/B system updater"
license = "LGPL-2.1-only"
url = "https://rauc.io"
source = f"https://github.com/rauc/rauc/releases/download/v{pkgver}/rauc-{pkgver}.tar.xz"
sha256 = "127a24cde208c65b837ae978c695a00730f1094ee8b6c7d48cf58ef846eae340"
# no -devel: rauc installs programs + dbus/service data only (no headers)
