# The config-only counterpart to acme-sensord (docs/08 §7): branding
# and default configuration shipped as a PACKAGE. Together with this
# tree's overlay/ it demonstrates both sides of the code/config fence
# (docs/08 §3): configuration may travel either way — as a package or
# as overlay files — but executable code may ONLY travel as a package;
# an ELF (or anything under (usr/)bin, (usr/)sbin, fenced usr/lib)
# in overlay/ dies the build.
pkgname = "acme-branding"
pkgver = "1.0.0"
pkgrel = 0
pkgdesc = "ACME product branding and default configuration"
license = "custom:example"
url = "https://example.org/astro/external-tree-acme"
# /etc contents are apk-protected config files
options = ["etcfiles"]


def install(self):
    self.install_file(self.files_path / "branding.conf", "etc/acme")
    self.install_file(self.files_path / "acme-logo.txt", "usr/share/acme")
    # a custom: license id requires the text installed (pkg lint 098)
    self.install_license(self.files_path / "LICENSE")
