"""
Tests for the binary packages-mode version-skew guard (warn-only).

Covers the build/lib/skew_check.py contract:
    * parse_installed: apk v2 installed DB records (P:/V:/o:, blank-line
      separated; the final record yields without a trailing blank)
    * parse_adbdump: 'apk adbdump' text -> {name: version} pairing
    * template_version: pkgver+pkgrel -> "<ver>-r<rel>" from a cports
      template (main/ then user/), None when incomplete or absent
    * the skew rules via the CLI report (exit is always 0 — warn-only):
      SKEW when an installed version differs from its pinned template,
      SHADOWED when a source-built package was installed at a different
      version than the local repo provides (and that suppresses the skew
      line for it), unmapped when no pinned template exists, and the
      provenance attribution [local]/[chimera]/[unattributed]

Run (host or the crag-builder container), from the repo root:

    python3 build/lib/test_skew_check.py                  # verbose unittest
    python3 -m unittest build.lib.test_skew_check         # (if run as pkg)
"""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

_HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE))

import skew_check as sc

_SCRIPT = _HERE / "skew_check.py"


def _write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


class ParseInstalledTests(unittest.TestCase):
    def _parse(self, text):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "installed"
            p.write_text(text)
            return list(sc.parse_installed(p))

    def test_records_with_origins(self):
        got = self._parse(
            "P:foo\nV:1.2.3-r0\no:foo\n\n"
            "P:bar\nV:2.0-r1\no:bar-origin\n")
        self.assertEqual(got, [("foo", "1.2.3-r0", "foo"),
                               ("bar", "2.0-r1", "bar-origin")])

    def test_final_record_without_trailing_blank_yields(self):
        got = self._parse("P:foo\nV:1.0-r0\no:foo")
        self.assertEqual(got, [("foo", "1.0-r0", "foo")])

    def test_missing_origin_is_none(self):
        got = self._parse("P:foo\nV:1.0-r0\n\n")
        self.assertEqual(got, [("foo", "1.0-r0", None)])

    def test_empty_db(self):
        self.assertEqual(self._parse(""), [])


class ParseAdbdumpTests(unittest.TestCase):
    def _parse(self, text):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "dump.txt"
            p.write_text(text)
            return sc.parse_adbdump(p)

    def test_name_version_pairing(self):
        got = self._parse(
            "  - name: foo\n"
            "    version: 1.2.3-r0\n"
            "    origin: foo\n"
            "  - name: bar\n"
            "    version: 9-r0\n")
        self.assertEqual(got, {"foo": "1.2.3-r0", "bar": "9-r0"})

    def test_name_without_version_is_skipped(self):
        got = self._parse("  - name: foo\n  - name: bar\n    version: 1-r0\n")
        self.assertEqual(got, {"bar": "1-r0"})

    def test_empty_dump(self):
        self.assertEqual(self._parse(""), {})


class TemplateVersionTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.cports = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def _tmpl(self, rel, text):
        _write(self.cports / rel, text)

    def test_pkgver_pkgrel_combine(self):
        self._tmpl("main/foo/template.py", 'pkgver = "1.2.3"\npkgrel = 2\n')
        self.assertEqual(sc.template_version(self.cports, "foo"), "1.2.3-r2")

    def test_single_quoted_pkgver(self):
        self._tmpl("main/foo/template.py", "pkgver = '2.0'\npkgrel = 1\n")
        self.assertEqual(sc.template_version(self.cports, "foo"), "2.0-r1")

    def test_user_collection_found(self):
        self._tmpl("user/barn/template.py", 'pkgver = "0.5"\npkgrel = 1\n')
        self.assertEqual(sc.template_version(self.cports, "barn"), "0.5-r1")

    def test_missing_pkgrel_is_none(self):
        self._tmpl("main/foo/template.py", 'pkgver = "1.2.3"\n')
        self.assertIsNone(sc.template_version(self.cports, "foo"))

    def test_no_template_is_none(self):
        self.assertIsNone(sc.template_version(self.cports, "ghost"))

    def test_pkgver_not_at_line_start_is_ignored(self):
        self._tmpl("main/foo/template.py", '    pkgver = "1.2.3"\npkgrel = 1\n')
        self.assertIsNone(sc.template_version(self.cports, "foo"))


class SkewRulesCliTests(unittest.TestCase):
    """The warn-only rules through the real CLI (how the build invokes it)."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        base = Path(self._tmp.name)
        self.cports = base / "cports"
        _write(self.cports / "main" / "foo" / "template.py",
               'pkgver = "1.2.3"\npkgrel = 2\n')  # pinned: 1.2.3-r2
        self.installed = base / "installed"
        self.out = base / "report.txt"

    def tearDown(self):
        self._tmp.cleanup()

    def _run(self, installed_text, *extra):
        self.installed.write_text(installed_text)
        return subprocess.run(
            [sys.executable, str(_SCRIPT),
             "--installed", str(self.installed),
             "--cports", str(self.cports),
             "--out", str(self.out), *extra],
            capture_output=True, text=True)

    def test_matching_version_is_clean(self):
        r = self._run("P:foo\nV:1.2.3-r2\no:foo\n\n")
        self.assertEqual(r.returncode, 0)
        report = self.out.read_text()
        self.assertIn("no skew: every installed package matches", report)
        self.assertIn("[INFO]", r.stdout)
        self.assertNotIn("SKEW", report)

    def test_skew_is_reported_warn_only(self):
        r = self._run("P:foo\nV:1.2.4-r0\no:foo\n\n")
        self.assertEqual(r.returncode, 0)  # guard never fails the build
        report = self.out.read_text()
        self.assertIn("SKEW vs pinned templates (1)", report)
        self.assertIn("installed 1.2.4-r0", report)
        self.assertIn("pinned template is 1.2.3-r2", report)
        self.assertIn("[WARN] version skew", r.stderr)

    def test_shadowed_when_binary_repo_beats_source_build(self):
        sm = Path(self._tmp.name) / "source-manifest"
        sm.write_text("main/foo  # built from source\n")
        local = Path(self._tmp.name) / "local.txt"
        local.write_text("  - name: foo\n    version: 1.0-r0\n")
        r = self._run("P:foo\nV:9-r0\no:foo\n\n",
                      "--source-manifest", str(sm),
                      "--local-dump", str(local))
        self.assertEqual(r.returncode, 0)
        report = self.out.read_text()
        self.assertIn("SHADOWED source-built packages (1)", report)
        self.assertIn("installed 9-r0", report)
        self.assertIn("local Crag build is 1.0-r0", report)
        # shadowed suppresses the skew line for that package
        self.assertNotIn("SKEW vs pinned templates", report)
        self.assertIn("[WARN]", r.stderr)

    def test_no_shadow_when_source_build_version_installed(self):
        sm = Path(self._tmp.name) / "source-manifest"
        sm.write_text("foo\n")  # bare template name normalizes too
        local = Path(self._tmp.name) / "local.txt"
        local.write_text("  - name: foo\n    version: 1.0-r0\n")
        r = self._run("P:foo\nV:1.0-r0\no:foo\n\n",
                      "--source-manifest", str(sm),
                      "--local-dump", str(local))
        report = self.out.read_text()
        self.assertNotIn("SHADOWED", report)
        self.assertNotIn("SKEW", report)
        self.assertIn("no skew:", report)

    def test_unmapped_package_reported(self):
        r = self._run("P:ghost\nV:1-r0\no:ghost\n\n")
        self.assertEqual(r.returncode, 0)
        report = self.out.read_text()
        self.assertIn("unmapped packages (1)", report)
        self.assertIn("no pinned template found", report)

    def test_origin_subpackage_names_resolve_via_origin(self):
        # installed subpackage with o: origin -> pinned via the origin template
        r = self._run("P:foo-libs\nV:1.2.3-r2\no:foo\n\n")
        report = self.out.read_text()
        self.assertIn("no skew:", report)
        self.assertNotIn("SKEW", report)

    def test_provenance_attribution(self):
        local = Path(self._tmp.name) / "local.txt"
        local.write_text("  - name: foo\n    version: 1.2.4-r0\n")
        r = self._run("P:foo\nV:1.2.4-r0\no:foo\n\n",
                      "--local-dump", str(local))
        self.assertIn("[local]", self.out.read_text())
        chim = Path(self._tmp.name) / "chim.txt"
        chim.write_text("  - name: foo\n    version: 1.2.4-r0\n")
        self._run("P:foo\nV:1.2.4-r0\no:foo\n\n",
                  "--chimera-dump", str(chim))
        self.assertIn("[chimera]", self.out.read_text())

    def test_package_without_origin_defaults_to_its_name(self):
        r = self._run("P:foo\nV:1.2.3-r2\n\n")
        self.assertIn("no skew:", self.out.read_text())


if __name__ == "__main__":
    unittest.main(verbosity=2)
