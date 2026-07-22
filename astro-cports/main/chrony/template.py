# Astro shadow of cports main/chrony (M3 phase 4, docs/07 §6): identical
# to the pinned template except NTS/gnutls support is removed. The pinned
# chrony pulls gnutls-devel, and full gnutls cannot be cross-built in this
# pipeline: gnutls (libdane) → unbound → protobuf-c → protobuf, and
# protobuf is marked broken for cross in the pin ("generated
# protobuf-targets.cmake looks for protoc in target sysroot"). Astro's
# baked chrony.conf is pool+makestep only — NTS was never part of the
# docs/07 §6 story (time.synced comes from adjtimex STA_UNSYNC), and
# sechash/CMAC still come from nettle (kept in makedepends), so plain NTP
# authentication (keys) is unaffected. pkgrel is bumped so this build
# always supersedes any same-version chrony and cbuild never skips it as
# already-present (same rationale as the openssh shadow).
pkgname = "chrony"
pkgver = "4.8"
pkgrel = 1
build_style = "gnu_configure"
configure_args = [
    "--with-user=_chrony",
    "--with-sendmail=/usr/bin/sendmail",
    "--enable-ntp-signd",
    "--enable-scfilter",
    "--disable-nts",
    "--without-gnutls",
]
configure_gen = []
make_dir = "."
hostmakedepends = ["pkgconf"]
makedepends = [
    "dinit-chimera",
    "libcap-devel",
    "libedit-devel",
    "libseccomp-devel",
    "linux-headers",
    "nettle-devel",
]
checkdepends = ["bash"]
pkgdesc = "NTP client and server"
license = "GPL-2.0-or-later"
url = "https://chrony-project.org"
source = f"https://chrony-project.org/releases/chrony-{pkgver}.tar.gz"
sha256 = "33ea8eb2a4daeaa506e8fcafd5d6d89027ed6f2f0609645c6f149b560d301706"
options = ["etcfiles"]


def post_install(self):
    # config
    self.install_file(
        "examples/chrony.conf.example1", "etc", name="chrony.conf"
    )
    self.install_sysusers("^/sysusers.conf")
    self.install_tmpfiles("^/tmpfiles.conf")
    # dinit services
    self.install_service("^/chronyd")
    self.install_service("^/chrony", enable=True)
