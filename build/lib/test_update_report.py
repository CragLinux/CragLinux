"""
Tests for the cports update-currency report (update-check sweep).

Covers the build/lib/update_report.py contracts:
    * _LINE parsing of `cbuild update-check` output ("main/foo: 1.2.3 ->
      1.3.0"), including dotted/plus pkg names and rpkgver versions, and
      the rejection of trailing junk
    * check_one result mapping (with subprocess mocked): update entries,
      the timeout error entry, error entries from cbuild's stderr — or its
      stdout, because cbuild logs fatal errors via its logger to STDOUT —
      None for "up to date", and an update line winning over a nonzero exit
    * crag_maintained: only main|user template.py paths past the fork point
    * shipped_packages: base + per-board packages.list (comments stripped)
      and variant [packages].install extraction
    * list_templates: "crag" scope lists only still-present maintained
      templates, "all" scope lists every real template dir
    * the report shaping: priority ranking (shipped+maintained first, then
      shipped, then maintained, then the rest), maintained/shipped flags,
      and the report.json / report.md outputs

Run (host or the crag-builder container), from the repo root:

    python3 build/lib/test_update_report.py               # verbose unittest
    python3 -m unittest build.lib.test_update_report      # (if run as pkg)
"""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

_HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE))

import update_report as ur


def _write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def _cp(returncode=0, stdout="", stderr=""):
    return subprocess.CompletedProcess(args=["cbuild"], returncode=returncode,
                                       stdout=stdout, stderr=stderr)


class LineRegexTests(unittest.TestCase):
    def _match(self, line):
        return ur._LINE.match(line.strip())

    def test_plain_update_line(self):
        m = self._match("main/foo: 1.2.3 -> 1.3.0")
        self.assertIsNotNone(m)
        self.assertEqual(m.group("repo"), "main")
        self.assertEqual(m.group("pkg"), "foo")
        self.assertEqual(m.group("cur"), "1.2.3")
        self.assertEqual(m.group("new"), "1.3.0")

    def test_fancy_pkg_and_version_shapes(self):
        m = self._match("user/foo-bar.baz+qux: 1.0.0-r0 -> 2.0.0-rc1")
        self.assertIsNotNone(m)
        self.assertEqual(m.group("pkg"), "foo-bar.baz+qux")
        self.assertEqual(m.group("cur"), "1.0.0-r0")
        self.assertEqual(m.group("new"), "2.0.0-rc1")

    def test_trailing_junk_rejected(self):
        self.assertIsNone(self._match("main/foo: 1.2.3 -> 1.3.0 extra"))
        self.assertIsNone(self._match("main/foo: 1.2.3"))
        self.assertIsNone(self._match("nonsense line"))
        self.assertIsNone(self._match("foo: 1.2.3 -> 1.3.0"))  # no repo/


class CheckOneTests(unittest.TestCase):
    def _run(self, cp=None, side_effect=None):
        with mock.patch.object(ur.subprocess, "run",
                               return_value=cp, side_effect=side_effect) as m:
            return ur.check_one("main/foo"), m

    def test_update_line_maps_to_entry(self):
        res, m = self._run(cp=_cp(stdout="main/foo: 1.2.3 -> 1.3.0\n"))
        self.assertEqual(res, {"repo": "main", "pkg": "foo",
                               "current": "1.2.3", "latest": "1.3.0",
                               "template": "main/foo"})
        # invoked as `./cbuild update-check <tmpl>` inside the cports checkout
        args, kwargs = m.call_args
        self.assertEqual(args[0], ["./cbuild", "update-check", "main/foo"])
        self.assertEqual(kwargs["cwd"], str(ur.CPORTS))
        self.assertEqual(kwargs["timeout"], 120)

    def test_up_to_date_is_none(self):
        res, _ = self._run(cp=_cp(stdout="Everything up to date\n"))
        self.assertIsNone(res)

    def test_timeout_is_an_error_entry(self):
        res, _ = self._run(side_effect=subprocess.TimeoutExpired(
            cmd="cbuild", timeout=120))
        self.assertEqual(res, {"template": "main/foo", "error": "timeout"})

    def test_nonzero_exit_takes_last_stderr_line(self):
        res, _ = self._run(cp=_cp(returncode=1, stderr="noise\nfatal: no net\n"))
        self.assertEqual(res, {"template": "main/foo", "error": "fatal: no net"})

    def test_nonzero_exit_falls_back_to_stdout_logger(self):
        # cbuild logs fatal errors via its logger to STDOUT (cbuild/core/logger.py)
        res, _ = self._run(cp=_cp(returncode=1, stdout="info\nfatal: boom\n"))
        self.assertEqual(res, {"template": "main/foo", "error": "fatal: boom"})

    def test_update_line_wins_over_nonzero_exit(self):
        res, _ = self._run(cp=_cp(returncode=3, stdout="main/foo: 1 -> 2\n"))
        self.assertEqual(res["pkg"], "foo")
        self.assertEqual(res["latest"], "2")


class CragMaintainedTests(unittest.TestCase):
    def _run(self, diff_text):
        with mock.patch.object(ur.subprocess, "run",
                               return_value=_cp(stdout=diff_text)):
            return ur.crag_maintained()

    def test_only_template_paths_count(self):
        got = self._run(
            "main/foo/template.py\n"
            "user/bar/template.py\n"
            "main/foo/patches/fix.patch\n"
            "README.md\n"
            "other/tree/template.py\n"
            "main/foo/template.pyc\n")
        self.assertEqual(got, {"foo", "bar"})

    def test_empty_delta(self):
        self.assertEqual(self._run(""), set())


class ShippedPackagesTests(unittest.TestCase):
    def test_lists_and_variant_installs_are_collected(self):
        with tempfile.TemporaryDirectory() as d:
            repo = Path(d)
            _write(repo / "boards/common/packages.list",
                   "# base set\nbasil\n\n  # comment\nbtmp # trailing\n")
            _write(repo / "boards/b1/packages.list", "b1pkg\n")
            _write(repo / "boards/b1/variants/dev.toml",
                   '[packages]\ninstall = [\n  "vpkg",\n  "vpkg2",\n]\n')
            _write(repo / "boards/b1/variants/prod.toml",
                   '[other]\nx = 1\n')
            with mock.patch.object(ur, "REPO", repo):
                got = ur.shipped_packages()
        self.assertEqual(got, {"basil", "btmp", "b1pkg", "vpkg", "vpkg2"})


class ListTemplatesTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.cports = Path(self._tmp.name)
        _write(self.cports / "main" / "pkg-a" / "template.py", "# a\n")
        _write(self.cports / "user" / "pkg-u" / "template.py", "# u\n")
        (self.cports / "main" / "empty-dir").mkdir(parents=True)

    def tearDown(self):
        self._tmp.cleanup()

    def _run(self, scope, maintained):
        with mock.patch.object(ur, "CPORTS", self.cports):
            return ur.list_templates(scope, maintained)

    def test_crag_scope_only_still_present_maintained_templates(self):
        got = self._run("crag", {"pkg-a", "pkg-u", "gone"})
        self.assertEqual(got, ["main/pkg-a", "user/pkg-u"])

    def test_all_scope_lists_every_real_template(self):
        got = self._run("all", set())
        self.assertEqual(got, ["main/pkg-a", "user/pkg-u"])

    def test_missing_cports_dir_is_empty(self):
        with mock.patch.object(ur, "CPORTS", self.cports / "nope"):
            self.assertEqual(ur.list_templates("all", set()), [])


class ReportShapingTests(unittest.TestCase):
    def test_priority_ranking_flags_and_outputs(self):
        tmpls = ["main/pkg-sm", "main/pkg-s", "main/pkg-m", "main/pkg-x",
                 "main/up2date"]
        entries = {
            "main/pkg-sm": {"repo": "main", "pkg": "pkg-sm",
                            "current": "1", "latest": "2", "template": "main/pkg-sm"},
            "main/pkg-s": {"repo": "main", "pkg": "pkg-s",
                           "current": "1", "latest": "2", "template": "main/pkg-s"},
            "main/pkg-m": {"repo": "main", "pkg": "pkg-m",
                           "current": "1", "latest": "2", "template": "main/pkg-m"},
            "main/pkg-x": {"repo": "main", "pkg": "pkg-x",
                           "current": "1", "latest": "2", "template": "main/pkg-x"},
            "main/up2date": None,
        }
        errors = [{"template": "main/pkg-x", "error": "net down"}]

        with tempfile.TemporaryDirectory() as d:
            out_dir = Path(d) / "report"
            argv = ["update_report.py", "--out-dir", str(out_dir),
                    "--scope", "crag"]
            with mock.patch.object(ur, "crag_maintained",
                                   return_value={"pkg-m", "pkg-sm"}), \
                 mock.patch.object(ur, "shipped_packages",
                                   return_value={"pkg-s", "pkg-sm"}), \
                 mock.patch.object(ur, "list_templates", return_value=tmpls), \
                 mock.patch.object(ur, "check_one",
                                   side_effect=lambda t: entries[t]), \
                 mock.patch.object(sys, "argv", argv):
                self.assertEqual(ur.main(), 0)

            report = json.loads((out_dir / "report.json").read_text())
            self.assertEqual(report["fork_point"], ur.FORK_POINT)
            self.assertEqual(report["scope"], "crag")
            self.assertEqual(report["checked"], len(tmpls))
            self.assertEqual([u["pkg"] for u in report["updates"]],
                             ["pkg-sm", "pkg-s", "pkg-m", "pkg-x"])
            flags = {u["pkg"]: (u["shipped"], u["maintained"])
                     for u in report["updates"]}
            self.assertEqual(flags, {"pkg-sm": (True, True), "pkg-s": (True, False),
                                     "pkg-m": (False, True), "pkg-x": (False, False)})
            self.assertEqual(report["errors"], [])

            md = (out_dir / "report.md").read_text()
            self.assertIn("# cports update report (crag)", md)
            self.assertIn("| Package | Current | Latest | Shipped | "
                          "Crag-owned | Template |", md)
            self.assertIn("| pkg-sm | 1 | 2 | yes | yes | `main/pkg-sm` |", md)
            self.assertIn("| pkg-x | 1 | 2 |  |  | `main/pkg-x` |", md)
            self.assertNotIn("## Check errors", md)

    def test_check_errors_section(self):
        with tempfile.TemporaryDirectory() as d:
            out_dir = Path(d) / "report"
            argv = ["update_report.py", "--out-dir", str(out_dir)]
            with mock.patch.object(ur, "crag_maintained", return_value=set()), \
                 mock.patch.object(ur, "shipped_packages", return_value=set()), \
                 mock.patch.object(ur, "list_templates", return_value=["main/bad"]), \
                 mock.patch.object(ur, "check_one",
                                   return_value={"template": "main/bad",
                                                 "error": "timeout"}), \
                 mock.patch.object(sys, "argv", argv):
                self.assertEqual(ur.main(), 0)
            report = json.loads((out_dir / "report.json").read_text())
            self.assertEqual(report["updates"], [])
            self.assertEqual(report["errors"],
                             [{"template": "main/bad", "error": "timeout"}])
            md = (out_dir / "report.md").read_text()
            self.assertIn("## Check errors", md)
            self.assertIn("- `main/bad`: timeout", md)


if __name__ == "__main__":
    unittest.main(verbosity=2)
