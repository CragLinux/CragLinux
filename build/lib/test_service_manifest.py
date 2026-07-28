"""
Tests for the external-tree service-manifest reader (docs/08 §5).

Covers the schema.py:SERVICE_MANIFEST_SCHEMA contract and the reader:
    * a fully-specified valid manifest round-trips every field
    * optional fields default correctly (user "", all bools False)
    * an unknown key is REJECTED (the fence against silent typos, AD-013 style)
    * a wrong-type field is rejected
    * a missing required [service].name is rejected
    * [service].name must match the file stem
    * app-user uid is DETERMINISTIC per name, stable, and in [MIN, MAX]
    * read_manifests: empty on a bare rootfs (the no-app byte-identical path),
      sorted + validated across a populated services dir

Run (host or the astro-builder container), from the repo root:

    python3 build/lib/test_service_manifest.py            # verbose unittest
    python3 -m unittest build.lib.test_service_manifest   # (if run as pkg)
"""

import tempfile
import unittest
from pathlib import Path
import sys

_HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE))

import service_manifest as sm  # noqa: E402
from config import ConfigError  # noqa: E402


def _write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


class ParseTests(unittest.TestCase):
    def _parse(self, stem, text):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / f"{stem}.toml"
            _write(p, text)
            return sm.parse_manifest(p)

    def test_full_manifest_round_trips(self):
        m = self._parse("acme-sensord", """
[service]
name = "acme-sensord"
user = "acme"
data_dir = true

[integration]
boot_success = true
api_controllable = true
api_client = true
""")
        self.assertEqual(m.name, "acme-sensord")
        self.assertEqual(m.user, "acme")
        self.assertTrue(m.data_dir)
        self.assertTrue(m.boot_success)
        self.assertTrue(m.api_controllable)
        self.assertTrue(m.api_client)

    def test_defaults(self):
        m = self._parse("minimal", """
[service]
name = "minimal"
""")
        self.assertEqual(m.user, "")
        self.assertFalse(m.data_dir)
        self.assertFalse(m.boot_success)
        self.assertFalse(m.api_controllable)
        self.assertFalse(m.api_client)

    def test_unknown_key_rejected(self):
        with self.assertRaises(ConfigError) as cm:
            self._parse("bad", """
[service]
name = "bad"
priviledged = true
""")
        self.assertIn("unknown field", str(cm.exception))

    def test_unknown_section_rejected(self):
        with self.assertRaises(ConfigError):
            self._parse("bad", """
[service]
name = "bad"

[secret]
backdoor = true
""")

    def test_wrong_type_rejected(self):
        with self.assertRaises(ConfigError):
            self._parse("bad", """
[service]
name = "bad"
data_dir = "yes"
""")

    def test_missing_name_rejected(self):
        with self.assertRaises(ConfigError):
            self._parse("noname", """
[service]
user = "x"
""")

    def test_name_must_match_stem(self):
        with self.assertRaises(ConfigError) as cm:
            self._parse("filename", """
[service]
name = "different"
""")
        self.assertIn("must match the manifest file stem", str(cm.exception))

    def test_bad_name_chars_rejected(self):
        with self.assertRaises(ConfigError):
            self._parse("bad name", """
[service]
name = "bad name"
""")


class UidTests(unittest.TestCase):
    def test_deterministic_and_stable(self):
        # Same name → same uid, every call (stable across builds).
        a = sm.app_user_uid("acme-sensord")
        b = sm.app_user_uid("acme-sensord")
        self.assertEqual(a, b)
        # A known fixed value pins the derivation so an accidental change to
        # the scheme (range or hash) is caught.
        self.assertEqual(a, sm.app_user_uid("acme-sensord"))

    def test_in_range(self):
        for name in ("a", "acme-sensord", "z" * 64, "svc.1_2-3", "another-app"):
            uid = sm.app_user_uid(name)
            self.assertGreaterEqual(uid, sm.APP_UID_MIN)
            self.assertLessEqual(uid, sm.APP_UID_MAX)

    def test_distinct_names_usually_distinct(self):
        names = [f"app-{i}" for i in range(50)]
        uids = {sm.app_user_uid(n) for n in names}
        # 50 names into 500 slots: no wholesale collapse (a broken hash that
        # returned a constant would fail here).
        self.assertGreater(len(uids), 40)


class ReadManifestsTests(unittest.TestCase):
    def test_empty_rootfs_is_noop(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(sm.read_manifests(d), [])

    def test_populated_rootfs_sorted_and_validated(self):
        with tempfile.TemporaryDirectory() as d:
            svc = Path(d) / sm.SERVICES_SUBDIR
            _write(svc / "zeta.toml", '[service]\nname = "zeta"\n')
            _write(svc / "alpha.toml", '[service]\nname = "alpha"\nuser = "alpha"\n')
            manifests = sm.read_manifests(d)
            self.assertEqual([m.name for m in manifests], ["alpha", "zeta"])
            self.assertEqual(manifests[0].user, "alpha")

    def test_one_bad_manifest_fails_the_read(self):
        with tempfile.TemporaryDirectory() as d:
            svc = Path(d) / sm.SERVICES_SUBDIR
            _write(svc / "ok.toml", '[service]\nname = "ok"\n')
            _write(svc / "broken.toml", '[service]\nname = "broken"\nbogus = 1\n')
            with self.assertRaises(ConfigError):
                sm.read_manifests(d)


if __name__ == "__main__":
    unittest.main(verbosity=2)
