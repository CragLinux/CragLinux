"""
Tests for the apk-closure -> cports template mapper (GAP §3.4).

Covers the build/lib/closure_map.py contract:
    * parse_apk_errors: "(no such package)" / "(virtual)" tokens out of apk
      --simulate output, version constraints stripped (name>=1.2 -> name),
      de-duplicated in first-seen order
    * parse_index_dump: 'apk adbdump' text -> name->origin map + provides
      tokens (with "=..." version suffixes stripped), first provider wins
    * find_template_dir: direct cports/<cat>/<name>/template.py lookup,
      symlinked templates resolve to their real template ("main/llvm"), and
      main/ wins the category race
    * find_subpackage_template: @subpackage("<name>") declarations in
      template sources, both quote styles
    * the CLI: exit 0 + unique "cat/template" lines when at least one dep
      maps (direct dir, provider oracle, or subpackage search — the three
      resolution strategies in that order), exit 2 when nothing maps

Run (host or the crag-builder container), from the repo root:

    python3 build/lib/test_closure_map.py                 # verbose unittest
    python3 -m unittest build.lib.test_closure_map        # (if run as pkg)
"""

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

_HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE))

import closure_map as cm

_SCRIPT = _HERE / "closure_map.py"


def _write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


class ParseApkErrorsTests(unittest.TestCase):
    def _parse(self, text):
        return cm.parse_apk_errors(text)

    def test_no_such_package_tokens(self):
        text = (
            "ERROR: unable to select packages:\n"
            "  so:libkrb5.so.26 (no such package):\n"
            "    required by: openssh-10.3_p1-r1[so:libkrb5.so.26]\n"
            "  dhcpcd-dinit (no such package):\n"
        )
        self.assertEqual(self._parse(text),
                         ["so:libkrb5.so.26", "dhcpcd-dinit"])

    def test_virtual_tokens(self):
        text = "  some-virtual (virtual):\n"
        self.assertEqual(self._parse(text), ["some-virtual"])

    def test_version_constraints_stripped(self):
        text = (
            "  foo>=1.2 (no such package):\n"
            "  bar=1.2-r0 (no such package):\n"
            "  baz~1 (no such package):\n"
        )
        self.assertEqual(self._parse(text), ["foo", "bar", "baz"])

    def test_duplicates_collapse_first_seen_order(self):
        text = (
            "  zeta (no such package):\n"
            "  alpha (no such package):\n"
            "  zeta>=2 (no such package):\n"
        )
        self.assertEqual(self._parse(text), ["zeta", "alpha"])

    def test_noise_lines_ignored(self):
        text = (
            "ERROR: unable to select packages:\n"
            "    required by: openssh-10.3_p1-r1[so:libkrb5.so.26]\n"
            "  nothing to see here\n"
        )
        self.assertEqual(self._parse(text), [])

    def test_empty_input(self):
        self.assertEqual(self._parse(""), [])


class ParseIndexDumpTests(unittest.TestCase):
    def _parse(self, text):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "dump.txt"
            p.write_text(text)
            return cm.parse_index_dump(p)

    def test_names_and_origins(self):
        by_name, providers = self._parse(
            "  - name: openssh\n"
            "    origin: openssh\n"
            "    version: 10.3_p1-r1\n"
            "  - name: openssh-client\n"
            "    origin: openssh\n"
        )
        self.assertEqual(by_name,
                         {"openssh": "openssh", "openssh-client": "openssh"})
        self.assertEqual(providers, {})

    def test_missing_origin_maps_to_none(self):
        by_name, _ = self._parse("  - name: pkg\n")
        self.assertEqual(by_name, {"pkg": None})

    def test_provides_tokens_strip_version_suffix(self):
        _, providers = self._parse(
            "  - name: krb5-libs\n"
            "    origin: krb5\n"
            "    provides:\n"
            "      - so:libkrb5.so.26=26\n"
            "      - cmd:kinit\n"
            "    depend: x\n"
        )
        self.assertEqual(providers,
                         {"so:libkrb5.so.26": "krb5-libs", "cmd:kinit": "krb5-libs"})

    def test_first_provider_wins(self):
        _, providers = self._parse(
            "  - name: first\n"
            "    provides:\n"
            "      - so:libx.so.1=1\n"
            "  - name: second\n"
            "    provides:\n"
            "      - so:libx.so.1=1\n"
        )
        self.assertEqual(providers["so:libx.so.1"], "first")

    def test_provides_section_ends_on_non_list_line(self):
        _, providers = self._parse(
            "  - name: pkg\n"
            "    provides:\n"
            "      - so:libx.so.1=1\n"
            "    depend: so:liby.so.2\n"
            "      - so:libz.so.3=1\n"
        )
        self.assertEqual(providers, {"so:libx.so.1": "pkg"})


class FindTemplateDirTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.cports = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def test_direct_template(self):
        _write(self.cports / "main" / "openssh" / "template.py", "# tmpl\n")
        self.assertEqual(cm.find_template_dir(self.cports, "openssh"),
                         "main/openssh")

    def test_user_collection(self):
        _write(self.cports / "user" / "acme-app" / "template.py", "# tmpl\n")
        self.assertEqual(cm.find_template_dir(self.cports, "acme-app"),
                         "user/acme-app")

    def test_main_wins_the_category_race(self):
        _write(self.cports / "main" / "dup" / "template.py", "# main\n")
        _write(self.cports / "user" / "dup" / "template.py", "# user\n")
        self.assertEqual(cm.find_template_dir(self.cports, "dup"), "main/dup")

    def test_symlinked_template_resolves_to_real_name(self):
        # cports symlinks subpackage-sharing templates (libcxx -> llvm)
        _write(self.cports / "main" / "llvm" / "template.py", "# llvm\n")
        os.symlink(self.cports / "main" / "llvm",
                   self.cports / "main" / "libcxx")
        self.assertEqual(cm.find_template_dir(self.cports, "libcxx"),
                         "main/llvm")

    def test_missing_template_is_none(self):
        self.assertIsNone(cm.find_template_dir(self.cports, "nope"))

    def test_dir_without_template_py_is_none(self):
        (self.cports / "main" / "empty").mkdir(parents=True)
        self.assertIsNone(cm.find_template_dir(self.cports, "empty"))


class FindSubpackageTemplateTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.cports = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    def _tmpl(self, rel, text):
        _write(self.cports / rel, text)

    def test_double_quoted_declaration(self):
        self._tmpl("main/app/template.py",
                   '@subpackage("dhcpcd-dinit")\ndef sub():\n    pass\n')
        self.assertEqual(cm.find_subpackage_template(self.cports, "dhcpcd-dinit"),
                         "main/app")

    def test_single_quoted_and_whitespace(self):
        self._tmpl("user/app/template.py",
                   "@subpackage(  'sub-dep' )\n")
        self.assertEqual(cm.find_subpackage_template(self.cports, "sub-dep"),
                         "user/app")

    def test_prefix_is_not_a_match(self):
        self._tmpl("main/app/template.py", '@subpackage("name2")\n')
        self.assertIsNone(cm.find_subpackage_template(self.cports, "name"))

    def test_no_declaration_is_none(self):
        self._tmpl("main/app/template.py", "pkgver = \"1\"\n")
        self.assertIsNone(cm.find_subpackage_template(self.cports, "name"))


class CliTests(unittest.TestCase):
    """End-to-end runs of the module CLI (the build invokes it exactly so)."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        base = Path(self._tmp.name)
        self.cports = base / "cports"
        _write(self.cports / "main" / "pkg-a" / "template.py",
               '@subpackage("sub-a")\n')
        _write(self.cports / "main" / "zlib-ng" / "template.py", "# z\n")
        self.errors = base / "apk-errors.txt"

    def tearDown(self):
        self._tmp.cleanup()

    def _run(self, *extra):
        return subprocess.run(
            [sys.executable, str(_SCRIPT),
             "--errors", str(self.errors), "--cports", str(self.cports), *extra],
            capture_output=True, text=True)

    def test_direct_template_dir_maps(self):
        self.errors.write_text("ERROR:\n  pkg-a (no such package):\n")
        r = self._run()
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout.splitlines(), ["main/pkg-a"])
        self.assertIn("[closure-map] pkg-a -> main/pkg-a", r.stderr)

    def test_subpackage_search_maps_and_dedupes(self):
        # sub-a has no dir of its own; it resolves via @subpackage in pkg-a's
        # template — and dedupes against the direct pkg-a hit.
        self.errors.write_text(
            "  pkg-a (no such package):\n"
            "  sub-a (no such package):\n")
        r = self._run()
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout.splitlines(), ["main/pkg-a"])

    def test_provider_oracle_maps_so_deps(self):
        self.errors.write_text("  so:libz.so.9 (no such package):\n")
        dump = Path(self._tmp.name) / "index.txt"
        dump.write_text(
            "  - name: zlib-ng\n"
            "    origin: zlib-ng\n"
            "    provides:\n"
            "      - so:libz.so.9=1\n")
        r = self._run("--index-dump", str(dump))
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout.splitlines(), ["main/zlib-ng"])

    def test_version_constraint_is_stripped_before_lookup(self):
        self.errors.write_text("  pkg-a>=1.0 (no such package):\n")
        r = self._run()
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout.splitlines(), ["main/pkg-a"])

    def test_unresolved_only_exits_2(self):
        self.errors.write_text("  so:libmissing.so.1 (no such package):\n")
        r = self._run()
        self.assertEqual(r.returncode, 2)
        self.assertEqual(r.stdout, "")
        self.assertIn("UNRESOLVED: so:libmissing.so.1", r.stderr)

    def test_no_deps_exits_2(self):
        self.errors.write_text("ERROR: nothing useful\n")
        r = self._run()
        self.assertEqual(r.returncode, 2)
        self.assertEqual(r.stdout, "")

    def test_partial_resolution_maps_what_it_can(self):
        self.errors.write_text(
            "  pkg-a (no such package):\n"
            "  ghost-dep (no such package):\n")
        r = self._run()
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout.splitlines(), ["main/pkg-a"])
        self.assertIn("UNRESOLVED: ghost-dep", r.stderr)
        self.assertIn("1 dep(s) unresolved this round", r.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
