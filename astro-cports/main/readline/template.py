# ASTRO SHADOW of cports main/readline (M1 wave 2, recorded in
# MIGRATION-NOTES §12): the pinned template fetches a git snapshot from
# git.savannah.gnu.org's cgit, which is unreachable/erroring (HTTP 400
# after multi-minute stalls) and has no mirror with a matching checksum.
# This shadow builds the SAME code from the official GNU release tarball
# (readline-8.3) plus the official readline83-001 patch (converted to
# unified -p1 in patches/official-readline83-001.patch) — the snapshot
# rev 15970c43 == 8.3 patchlevel 1. Drop this shadow when the cports pin
# moves or savannah recovers.
#
# in general do not use this; look if it can be patched for libedit first
# there are APIs in readline that are not provided by libedit (usually
# really bad ones) and sometimes we cannot just replace it
pkgname = "readline"
pkgver = "8.3.001"
pkgrel = 2
build_style = "gnu_configure"
configure_args = [
    "--disable-static",
    "--enable-multibyte",
    "--with-curses",
    "bash_cv_termcap_lib=libncursesw",
]
# broken af
configure_gen = []
hostmakedepends = ["pkgconf"]
makedepends = ["ncurses-devel"]
pkgdesc = "GNU Readline library"
license = "GPL-3.0-or-later"
url = "https://tiswww.cwru.edu/php/chet/readline/rltop.html"
source = "$(GNU_SITE)/readline/readline-8.3.tar.gz"
sha256 = "fe5383204467828cd495ee8d1d3c037a7eba1389c22bc6a041f627976f9061cc"


def post_install(self):
    self.uninstall("usr/share/doc")


@subpackage("readline-devel")
def _(self):
    return self.default_devel(extra=["usr/share/info"])
