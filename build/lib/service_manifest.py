"""
Crag external-tree SERVICE MANIFEST reader (docs/08 §5).

An app apk installs `usr/lib/crag/services/<name>.toml` next to its dinit
service file. At IMAGE ASSEMBLY the hook boards/common/hooks/40-service-
manifests.sh reads every manifest that landed in the ASSEMBLED rootfs (they
arrive via apk, NOT via overlay — the code/config fence in merge.sh forbids
apps in overlays) and wires: system users, /data/apps/<name> data dirs, the
per-service env file, boot-success dependencies, crag-api group membership,
and service enablement.

This module is the single validated reader those consumers share. Validation
reuses config.py's validate_config + apply_defaults (the same pipeline board /
variant / tree configs use), against schema.py:SERVICE_MANIFEST_SCHEMA — so a
manifest with an unknown key, a wrong type, or a missing [service].name fails
fast with the familiar "Configuration errors in <path>" message.

Schema (schema.py:SERVICE_MANIFEST_SCHEMA, docs/08 §5):

    [service]
      name             (str,  required)
      user             (str,  opt "")     system user; "" => runs as root
      data_dir         (bool, opt False)  true => /data/apps/<name>, CRAG_DATA_DIR
    [integration]
      boot_success     (bool, opt False)  depends-on of boot-success (AD-011)
      api_controllable (bool, opt False)  POST /services/<name>/{restart,stop,start}
      api_client       (bool, opt False)  join crag-api group (unix socket)

APP-USER UID SCHEME (deterministic, stable across builds)
---------------------------------------------------------
A service that declares [service].user gets a SYSTEM uid derived purely from
the service name, so the same app lands on the same uid on every build, on
every machine, regardless of build order or which other apps are present:

    uid = APP_UID_MIN + ( sha256(name) mod (APP_UID_MAX - APP_UID_MIN + 1) )

    APP_UID_MIN = 400, APP_UID_MAX = 899   (500 stable slots)

Range rationale: above the platform users (cragd uid/gid 300, crag-api gid
301 — 05-platform-users.sh) and comfortably below the human-user floor (1000),
so app users never collide with either. SHA-256 (not Python's salted hash())
keeps the value independent of PYTHONHASHSEED / interpreter version. Hash
COLLISIONS (two names → same uid) are possible within the 500-slot space; the
assembly hook resolves them by linear-probing upward within [MIN, MAX] and is
the authority on the final assignment — this module gives the deterministic
STARTING uid. (Documented so the fill agent implements probing consistently.)

Usage (library):
    from service_manifest import read_manifests, app_user_uid
    for m in read_manifests(rootfs_dir):
        ...

Usage (CLI — how the shell hook consumes it):
    python3 build/lib/service_manifest.py read  <rootfs_dir>   # JSON array
    python3 build/lib/service_manifest.py uid   <service_name> # the uid, one line
"""

import hashlib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import config as _config  # noqa: E402  (path insert must precede import)
from schema import SERVICE_MANIFEST_SCHEMA  # noqa: E402

ConfigError = _config.ConfigError

# The rootfs-relative directory apk-installed manifests live in (docs/08 §5).
SERVICES_SUBDIR = "usr/lib/crag/services"

# App-user uid window (see module docstring).
APP_UID_MIN = 400
APP_UID_MAX = 899

# Valid service name: the manifest stem, the dinit service name, the uid key,
# and the /data/apps/<name> component all reuse it, so keep it filesystem- and
# dinit-safe (no '/', whitespace, or surprises).
import re  # noqa: E402

_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


class ServiceManifest:
    """A validated service manifest (schema.py:SERVICE_MANIFEST_SCHEMA)."""

    __slots__ = (
        "name", "user", "data_dir",
        "boot_success", "api_controllable", "api_client",
        "source_path",
    )

    def __init__(self, cfg, source_path):
        svc = cfg["service"]
        integ = cfg.get("integration", {})
        self.name = svc["name"]
        self.user = svc["user"]
        self.data_dir = svc["data_dir"]
        self.boot_success = integ.get("boot_success", False)
        self.api_controllable = integ.get("api_controllable", False)
        self.api_client = integ.get("api_client", False)
        self.source_path = str(source_path)

    def uid(self):
        """The deterministic STARTING app-user uid for this service."""
        return app_user_uid(self.name)

    def to_dict(self):
        return {
            "name": self.name,
            "user": self.user,
            "data_dir": self.data_dir,
            "boot_success": self.boot_success,
            "api_controllable": self.api_controllable,
            "api_client": self.api_client,
            "uid": self.uid(),
            "source_path": self.source_path,
        }


def app_user_uid(name):
    """Deterministic starting app-user uid for a service name (see docstring)."""
    digest = hashlib.sha256(name.encode("utf-8")).hexdigest()
    span = APP_UID_MAX - APP_UID_MIN + 1
    return APP_UID_MIN + (int(digest, 16) % span)


def parse_manifest(path):
    """Load, validate, and default one manifest file → ServiceManifest.

    Raises ConfigError on any schema violation, on a name that is not a safe
    service identifier, or on a [service].name that disagrees with the file
    stem (the hook keys users/data-dirs/env by name, so the two must agree).
    """
    path = Path(path)
    if not path.is_file():
        raise ConfigError(f"Service manifest not found: {path}")

    import tomllib
    with open(path, "rb") as f:
        raw = tomllib.load(f)

    _config.validate_config(raw, SERVICE_MANIFEST_SCHEMA, str(path))
    cfg = _config.apply_defaults(raw, SERVICE_MANIFEST_SCHEMA)

    name = cfg["service"]["name"]
    if not _NAME_RE.match(name):
        raise ConfigError(
            f"Configuration errors in {path}:\n"
            f"  [service].name: '{name}' is not a valid service name "
            "(allowed: letters, digits, '.', '_', '-'; must start "
            "alphanumeric) — it names the dinit service, the app user, and "
            "the /data/apps/<name> dir (docs/08 §5)"
        )
    stem = path.stem
    if name != stem:
        raise ConfigError(
            f"Configuration errors in {path}:\n"
            f"  [service].name = '{name}' must match the manifest file stem "
            f"'{stem}' (the file is installed as "
            f"usr/lib/crag/services/<name>.toml — docs/08 §5)"
        )
    return ServiceManifest(cfg, path)


def read_manifests(rootfs_dir):
    """Every validated manifest in an assembled rootfs, sorted by name.

    Globs <rootfs_dir>/usr/lib/crag/services/*.toml. Returns [] when the
    directory is absent (the no-app / no-external-tree path — the assembly
    hook is then a no-op and the image is byte-identical). Deterministic
    order (sorted by service name) so downstream effects (uid assignment,
    boot-success dependency lines) are reproducible.
    """
    services_dir = Path(rootfs_dir) / SERVICES_SUBDIR
    if not services_dir.is_dir():
        return []
    manifests = [parse_manifest(p) for p in sorted(services_dir.glob("*.toml"))]
    manifests.sort(key=lambda m: m.name)
    return manifests


def main():
    import argparse

    parser = argparse.ArgumentParser(description="Crag service-manifest reader (docs/08 §5)")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_read = sub.add_parser("read", help="Emit all manifests in an assembled rootfs as JSON")
    p_read.add_argument("rootfs_dir")

    p_uid = sub.add_parser("uid", help="Print the deterministic app-user uid for a service name")
    p_uid.add_argument("name")

    args = parser.parse_args()

    try:
        if args.cmd == "read":
            manifests = read_manifests(args.rootfs_dir)
            print(json.dumps([m.to_dict() for m in manifests], indent=2))
        elif args.cmd == "uid":
            print(app_user_uid(args.name))
    except ConfigError as e:
        print(str(e), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
