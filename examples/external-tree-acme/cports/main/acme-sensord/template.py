# The docs/08 §7 reference app template: a team application shipped as
# an apk package built from THIS TREE's cports collection (AD-017 —
# apps are packages, never overlay files). Local sources only: the
# daemon is small enough to live in files/, so there is no remote
# fetch; real product templates more typically pin a git tag (see the
# docs/08 §3 example).
#
# No build_style: build/install are custom phases (the pattern of
# main/base-cbuild-progs in the cports fork). cbuild's compiler util
# supplies the cross CC/CFLAGS/LDFLAGS for the target image.
pkgname = "acme-sensord"
pkgver = "1.0.0"
pkgrel = 0
pkgdesc = "ACME plant-floor sensor daemon"
license = "custom:example"
url = "https://example.org/crag/external-tree-acme"


def build(self):
    from cbuild.util import compiler

    self.cp(self.files_path / "acme-sensord.c", ".")
    cc = compiler.C(self)
    cc.invoke(["acme-sensord.c"], "acme-sensord")


def install(self):
    self.install_bin("acme-sensord")
    # dinit service description -> usr/lib/dinit.d/ (subpackage below).
    # NOT enable=True: enablement is driven by the service manifest at
    # image assembly (docs/08 §5), not by the package.
    self.install_service(self.files_path / "acme-sensord")
    # service manifest -> usr/lib/crag/services/ (docs/08 §5)
    self.install_file(
        self.files_path / "acme-sensord.toml", "usr/lib/crag/services"
    )
    # a custom: license id requires the text installed (pkg lint 098)
    self.install_license(self.files_path / "LICENSE")


@subpackage("acme-sensord-dinit")
def _(self):
    self.subdesc = "dinit service"
    self.depends = [self.parent, "dinit-chimera"]
    self.install_if = [self.parent, "dinit-chimera"]
    # The service file depends-on cragd + data-mount, which are Crag
    # OVERLAY services (etc/dinit.d) that no apk provides — the svc:
    # provider scan cannot resolve them, so it is off for this
    # text-only subpackage. The parent keeps full dependency scanning.
    self.options = ["!scanrundeps"]

    return ["usr/lib/dinit.d"]
