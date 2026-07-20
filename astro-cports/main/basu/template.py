# Astro addition (not in cports upstream; docs/06 §3, AD-016): basu is
# the systemd-free sd-bus extraction — astrod's D-Bus client library,
# wrapped in exactly one Zig module (astrod/src/bus.zig). libcap/audit
# stay off: musl target, and astrod runs unprivileged by design
# (docs/02 §7). Candidate for upstreaming to Chimera cports (standard
# package, no Astro-specific content).
pkgname = "basu"
pkgver = "0.2.1"
pkgrel = 0
build_style = "meson"
configure_args = [
    "-Dlibcap=disabled",
    "-Daudit=disabled",
]
hostmakedepends = ["gperf", "meson", "pkgconf"]
makedepends = ["linux-headers"]
pkgdesc = "Sd-bus library extracted from systemd, without systemd"
license = "LGPL-2.1-or-later"
url = "https://git.sr.ht/~emersion/basu"
source = f"{url}/archive/v{pkgver}.tar.gz"
sha256 = "43b327073d1ac7bc6cbc0d3dfff729348fc970dfff0551ad40e366332e990204"


@subpackage("basu-devel")
def _(self):
    return self.default_devel()
