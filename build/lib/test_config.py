"""
Tests for the config loader/validator (docs/03 §6, docs/08 §2/§4).

Covers the build/lib/config.py contracts:
    * validate_config rejects unknown sections/fields, wrong types, bad
      choices, and missing required fields (the fence against silent typos)
    * board-only rules: root= is banned in kernel.cmdline, partition sizes
      must be <int><K|M|G>, [kernel].source="git" conditionally requires
      git_repo/git_ref, kernel.package gets the migration hint
    * apply_defaults deep-copies mutable defaults (schema never poisoned)
    * flatten_to_env shell-safe KEY='VALUE' output
    * DEPRECATED [disk] -> [partitions] migration (one release of grace)
    * derive_board_defaults: [rauc] compatible/bootloader derivation +
      consistency check, qcow2 auto-add only for boards that declare [qemu]
    * compare_versions: numeric segments, zero-filled missing segments,
      the semver pre-release rule (port of cragd/src/version.zig)
    * check_crag_version: dev bypass, inclusive calver bounds
    * finalize_variant_config: rootfs.type keyed on the variant id
    * load_config: file-not-found and the end-to-end board/tree/variant paths

Run (host or the crag-builder container), from the repo root:

    python3 build/lib/test_config.py                     # verbose unittest
    python3 -m unittest build.lib.test_config            # (if run as pkg)
"""

import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

_HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE))

import config as cfg
from config import ConfigError

# A complete, valid minimal board (every required section + field present).
_MINIMAL_BOARD = {
    "board": {"name": "Test GW", "arch": "aarch64"},
    "kernel": {"version": "6.12", "cmdline": "console=ttyS0"},
    "bootloader": {"type": "none"},
}

_BOARD_TOML = """\
[board]
name = "Test GW"
arch = "aarch64"

[kernel]
version = "6.12"
cmdline = "console=ttyS0"

[bootloader]
type = "none"
"""


def _write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


class ValidateFieldTests(unittest.TestCase):
    def _field(self, value, schema):
        return cfg.validate_field("test", "field", value, schema)

    def test_wrong_type_rejected(self):
        errs = self._field("yes", {"type": bool, "required": False})
        self.assertEqual(len(errs), 1)
        self.assertIn("expected bool, got str", errs[0])

    def test_bad_choice_rejected(self):
        errs = self._field("riscv128", {"type": str, "required": False,
                                        "choices": ["aarch64", "x86_64"]})
        self.assertEqual(len(errs), 1)
        self.assertIn("not in allowed values", errs[0])

    def test_bad_list_item_choice_rejected(self):
        errs = self._field(["img", "vmdk"],
                           {"type": list, "required": False,
                            "item_choices": ["img", "qcow2"]})
        self.assertEqual(len(errs), 1)
        self.assertIn("'vmdk' not in allowed values", errs[0])

    def test_valid_value_passes(self):
        self.assertEqual(self._field("aarch64", {"type": str, "required": False,
                                                 "choices": ["aarch64"]}), [])


class ValidateConfigTests(unittest.TestCase):
    def _errors(self, config, schema=cfg.BOARD_SCHEMA):
        with self.assertRaises(ConfigError) as cm:
            cfg.validate_config(config, schema, "test.toml")
        return str(cm.exception)

    def test_minimal_board_is_valid(self):
        cfg.validate_config(dict(_MINIMAL_BOARD), cfg.BOARD_SCHEMA, "test.toml")

    def test_unknown_section_rejected(self):
        msg = self._errors({**_MINIMAL_BOARD, "secret": {}})
        self.assertIn("Unknown section: [secret]", msg)

    def test_unknown_field_rejected(self):
        bad = {**_MINIMAL_BOARD,
               "board": {"name": "X", "arch": "aarch64", "bogus": 1}}
        msg = self._errors(bad)
        self.assertIn("unknown field 'bogus'", msg)

    def test_missing_required_section_rejected(self):
        msg = self._errors({"board": {"name": "X", "arch": "aarch64"}})
        self.assertIn("Missing required section: [kernel]", msg)

    def test_missing_required_field_rejected(self):
        bad = {**_MINIMAL_BOARD, "kernel": {"version": "6.12"}}
        msg = self._errors(bad)
        self.assertIn("missing required field 'cmdline'", msg)

    def test_arch_choice_rejected(self):
        bad = {**_MINIMAL_BOARD,
               "board": {"name": "X", "arch": "sparc"}}
        msg = self._errors(bad)
        self.assertIn("not in allowed values", msg)

    def test_root_arg_banned_in_board_cmdline(self):
        for cmdline in ("root=/dev/sda console=ttyS0", "console root=PARTLABEL=x"):
            with self.subTest(cmdline=cmdline):
                bad = {**_MINIMAL_BOARD,
                       "kernel": {"version": "6.12", "cmdline": cmdline}}
                msg = self._errors(bad)
                self.assertIn("must not contain 'root='", msg)

    def test_root_flags_style_args_are_fine(self):
        cfg.validate_config(
            {**_MINIMAL_BOARD,
             "kernel": {"version": "6.12", "cmdline": "console=ttyS0 rootflags=ro rw"}},
            cfg.BOARD_SCHEMA, "test.toml")

    def test_root_arg_banned_in_variant_cmdline_append(self):
        with self.assertRaises(ConfigError) as cm:
            cfg.validate_config(
                {"variant": {"name": "dev"},
                 "kernel": {"cmdline_append": "quiet root=/dev/x"}},
                cfg.VARIANT_SCHEMA, "dev.toml")
        self.assertIn("must not contain 'root='", str(cm.exception))

    def test_partition_sizes_must_match_int_suffix(self):
        for size in ("64MB", "0M", "64", "64g", "-1M"):
            with self.subTest(size=size):
                bad = {**_MINIMAL_BOARD,
                       "partitions": {"esp_size": size}}
                msg = self._errors(bad)
                self.assertIn("is not a valid size", msg)
        cfg.validate_config(
            {**_MINIMAL_BOARD, "partitions": {"esp_size": "64M", "rootfs_size": "1G"}},
            cfg.BOARD_SCHEMA, "test.toml")

    def test_git_source_conditionally_requires_repo_and_ref(self):
        bad = {**_MINIMAL_BOARD,
               "kernel": {"version": "6.12", "cmdline": "console=ttyS0",
                          "source": "git"}}
        msg = self._errors(bad)
        self.assertIn("[kernel].git_repo: required when [kernel].source = \"git\"", msg)
        self.assertIn("[kernel].git_ref: required when [kernel].source = \"git\"", msg)
        # With both present it validates.
        cfg.validate_config(
            {**bad, "kernel": {**bad["kernel"],
                               "git_repo": "https://example/k.git", "git_ref": "v1"}},
            cfg.BOARD_SCHEMA, "test.toml")

    def test_kernel_package_gets_migration_hint(self):
        bad = {**_MINIMAL_BOARD,
               "kernel": {"version": "6.12", "cmdline": "console=ttyS0",
                          "package": "linux-lts"}}
        msg = self._errors(bad)
        self.assertIn("kernel.package has been replaced with kernel.version", msg)

    def test_users_create_entries_validated(self):
        for entry, expect in (
            ("not-a-table", "expected table"),
            ({"name": "x"}, "missing required field 'uid'"),
            ({"name": "x", "uid": 1000, "bogus": 1}, "unknown field 'bogus'"),
            ({"name": "x", "uid": "1000"}, "expected int, got str"),
        ):
            with self.subTest(entry=entry):
                with self.assertRaises(ConfigError) as cm:
                    cfg.validate_config(
                        {"variant": {"name": "dev"},
                         "users": {"create": [entry]}},
                        cfg.VARIANT_SCHEMA, "dev.toml")
                self.assertIn(expect, str(cm.exception))
        # A full valid entry passes.
        cfg.validate_config(
            {"variant": {"name": "dev"},
             "users": {"create": [{"name": "x", "uid": 1000, "groups": ["crag-api"]}]}},
            cfg.VARIANT_SCHEMA, "dev.toml")


class ApplyDefaultsTests(unittest.TestCase):
    def test_missing_fields_get_defaults(self):
        out = cfg.apply_defaults({"board": {"name": "X", "arch": "aarch64"}},
                                 cfg.BOARD_SCHEMA)
        self.assertEqual(out["kernel"]["lto"], "thin")
        self.assertTrue(out["kernel"]["clang_patches"])
        self.assertEqual(out["image"]["formats"], ["img"])
        self.assertEqual(out["console"], {"device": "ttyS0", "baud": 115200})

    def test_authored_values_win(self):
        out = cfg.apply_defaults({"console": {"baud": 9600}}, cfg.BOARD_SCHEMA)
        self.assertEqual(out["console"]["baud"], 9600)
        self.assertEqual(out["console"]["device"], "ttyS0")

    def test_mutable_defaults_never_shared_with_schema(self):
        # derive_board_defaults appends to formats in place; without the
        # deepcopy that would mutate BOARD_SCHEMA itself.
        out1 = cfg.apply_defaults({}, cfg.BOARD_SCHEMA)
        out1["image"]["formats"].append("poison")
        out2 = cfg.apply_defaults({}, cfg.BOARD_SCHEMA)
        self.assertEqual(out2["image"]["formats"], ["img"])
        self.assertEqual(cfg.BOARD_SCHEMA["image"]["formats"]["default"], ["img"])


class FlattenToEnvTests(unittest.TestCase):
    def test_shape_types_and_sorting(self):
        out = cfg.flatten_to_env({"b": {"y": [1, 2]}, "a": {"x": True, "s": "hi"}})
        self.assertEqual(out.splitlines(),
                         ["A_S='hi'", "A_X='true'", "B_Y='1 2'"])

    def test_bool_false_and_prefix(self):
        out = cfg.flatten_to_env({"a": {"x": False}}, prefix="P")
        self.assertEqual(out, "P_A_X='false'")

    def test_quotes_are_shell_escaped(self):
        out = cfg.flatten_to_env({"a": {"x": "it's"}})
        self.assertEqual(out, "A_X='it'\\''s'")


class MigrateDeprecatedDiskTests(unittest.TestCase):
    def test_maps_disk_to_partitions_and_warns(self):
        config = {"disk": {"boot_size": "64M", "root_size": "512M"}}
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            out = cfg.migrate_deprecated_disk(config, "board.toml")
        self.assertNotIn("disk", out)
        self.assertEqual(out["partitions"],
                         {"boot_size": "64M", "rootfs_size": "512M"})
        self.assertIn("DEPRECATED", err.getvalue())

    def test_disk_plus_partitions_rejected(self):
        with self.assertRaises(ConfigError) as cm:
            cfg.migrate_deprecated_disk(
                {"disk": {"boot_size": "64M", "root_size": "512M"},
                 "partitions": {"esp_size": "64M"}}, "board.toml")
        self.assertIn("both present", str(cm.exception))

    def test_missing_required_disk_field_rejected(self):
        with self.assertRaises(ConfigError) as cm:
            cfg.migrate_deprecated_disk({"disk": {"boot_size": "64M"}}, "board.toml")
        self.assertIn("missing required field 'root_size'", str(cm.exception))

    def test_unknown_disk_field_rejected(self):
        with self.assertRaises(ConfigError) as cm:
            cfg.migrate_deprecated_disk(
                {"disk": {"boot_size": "64M", "root_size": "512M", "swap": "1G"}},
                "board.toml")
        self.assertIn("unknown field 'swap'", str(cm.exception))

    def test_no_disk_is_noop(self):
        config = {"partitions": {"esp_size": "64M"}}
        self.assertEqual(cfg.migrate_deprecated_disk(config, "b.toml"), config)


class DeriveBoardDefaultsTests(unittest.TestCase):
    _PATH = "/tmp/x/myboard/board.toml"

    def _derive(self, raw):
        config = cfg.apply_defaults(raw, cfg.BOARD_SCHEMA)
        return cfg.derive_board_defaults(config, raw, self._PATH)

    def test_rauc_compatible_defaults_to_board_dir_name(self):
        out = self._derive(dict(_MINIMAL_BOARD))
        self.assertEqual(out["rauc"]["compatible"], "crag-myboard")

    def test_explicit_rauc_compatible_kept(self):
        raw = {**_MINIMAL_BOARD, "rauc": {"compatible": "acme-gw"}}
        self.assertEqual(self._derive(raw)["rauc"]["compatible"], "acme-gw")

    def test_rauc_bootloader_derived_from_bootloader_type(self):
        for bl_type, expected in (("grub-efi", "grub"), ("u-boot", "uboot"),
                                  ("rpi-boot", "uboot"), ("none", "uboot"),
                                  ("direct", "uboot")):
            with self.subTest(bl_type=bl_type):
                raw = {**_MINIMAL_BOARD,
                       "bootloader": {"type": bl_type}}
                out = self._derive(raw)
                self.assertEqual(out["rauc"]["bootloader"], expected)

    def test_inconsistent_explicit_rauc_bootloader_rejected(self):
        raw = {**_MINIMAL_BOARD,
               "bootloader": {"type": "grub-efi"},
               "rauc": {"bootloader": "uboot"}}
        with self.assertRaises(ConfigError) as cm:
            self._derive(raw)
        self.assertIn("is inconsistent", str(cm.exception))

    def test_qcow2_added_only_with_declared_qemu(self):
        raw = dict(_MINIMAL_BOARD)
        self.assertEqual(self._derive(raw)["image"]["formats"], ["img"])
        raw_qemu = {**_MINIMAL_BOARD, "qemu": {"machine": "virt"}}
        self.assertEqual(self._derive(raw_qemu)["image"]["formats"],
                         ["img", "qcow2"])

    def test_qcow2_not_duplicated_when_already_listed(self):
        raw = {**_MINIMAL_BOARD, "qemu": {}, "image": {"formats": ["img", "qcow2"]}}
        self.assertEqual(self._derive(raw)["image"]["formats"], ["img", "qcow2"])


class VersionCompareTests(unittest.TestCase):
    def test_numeric_segments_compare_numerically(self):
        self.assertEqual(cfg.compare_versions("1.10.0", "1.9.9"), 1)
        self.assertEqual(cfg.compare_versions("1.2.3", "1.2.4"), -1)
        self.assertEqual(cfg.compare_versions("2026.10", "2026.9"), 1)

    def test_missing_segments_count_as_zero(self):
        self.assertEqual(cfg.compare_versions("2026.10", "2026.10.0"), 0)
        self.assertEqual(cfg.compare_versions("1.2.0.1", "1.2"), 1)
        self.assertEqual(cfg.compare_versions("1.2", "1.2.1"), -1)

    def test_suffix_rules(self):
        # no-suffix outranks any suffix (semver pre-release rule)
        self.assertEqual(cfg.compare_versions("1.0.0", "1.0.0-rc1"), 1)
        self.assertEqual(cfg.compare_versions("1.0.0-rc1", "1.0.0"), -1)
        # two suffixes compare bytewise ("rc10" < "rc9" is documented)
        self.assertEqual(cfg.compare_versions("1.0.0-rc10", "1.0.0-rc9"), -1)
        self.assertEqual(cfg.compare_versions("1.0.0-rc1", "1.0.0-rc1"), 0)
        # a higher base beats any suffix state
        self.assertEqual(cfg.compare_versions("1.0.1-dev", "1.0.0"), 1)

    def test_non_numeric_segments_fall_back_to_bytewise(self):
        self.assertEqual(cfg.compare_versions("1.a.0", "1.b.0"), -1)
        self.assertEqual(cfg.compare_versions("abc", "abc"), 0)

    def test_never_raises_on_garbage(self):
        # Total order: any two strings compare without raising.
        samples = ["", "1", "1.0", "1.0.0", "1.0.0-rc1", "junk!!", "-", "..",
                   "2026.10.5", "0.0.0-dev"]
        for a in samples:
            for b in samples:
                r = cfg.compare_versions(a, b)
                self.assertIn(r, (-1, 0, 1))
                self.assertEqual(r, -cfg.compare_versions(b, a))


class CragVersionGateTests(unittest.TestCase):
    def _check(self, version, crag_min, crag_max):
        cfg.check_crag_version(version, crag_min, crag_max, "acme", "tree.toml")

    def test_dev_version_bypasses_the_gate(self):
        self._check(cfg.DEV_VERSION, "2099.1", "")
        self._check(cfg.DEV_VERSION, "", "2000.1")

    def test_inclusive_bounds(self):
        self._check("2026.10", "2026.10", "2026.10")
        self._check("2026.10.1", "2026.10", "2026.11")

    def test_below_min_rejected(self):
        with self.assertRaises(ConfigError) as cm:
            self._check("2026.9", "2026.10", "")
        msg = str(cm.exception)
        self.assertIn("acme", msg)
        self.assertIn("requires Crag >= 2026.10", msg)

    def test_above_max_rejected(self):
        with self.assertRaises(ConfigError) as cm:
            self._check("2027.1", "", "2026.10")
        self.assertIn("requires Crag <= 2026.10", str(cm.exception))

    def test_empty_bounds_unbounded(self):
        self._check("9999.1", "", "")
        self._check("0.0.1", "", "")


class FinalizeVariantConfigTests(unittest.TestCase):
    def _finalize(self, raw, filename):
        return cfg.finalize_variant_config(raw, f"/x/{filename}")

    def test_rootfs_type_default_by_variant_id(self):
        self.assertEqual(self._finalize({"variant": {"name": "p"}}, "prod.toml")
                         ["rootfs"]["type"], "squashfs")
        self.assertEqual(self._finalize({"variant": {"name": "d"}}, "dev.toml")
                         ["rootfs"]["type"], "ext4")

    def test_explicit_rootfs_type_wins(self):
        out = self._finalize({"variant": {"name": "p"},
                              "rootfs": {"type": "ext4"}}, "prod.toml")
        self.assertEqual(out["rootfs"]["type"], "ext4")

    def test_validation_error_propagates(self):
        with self.assertRaises(ConfigError):
            self._finalize({"variant": {"name": "d"},
                            "rootfs": {"type": "btrfs"}}, "dev.toml")


class LoadConfigTests(unittest.TestCase):
    def test_missing_file_rejected(self):
        with self.assertRaises(ConfigError) as cm:
            cfg.load_config("/nonexistent/board.toml", "board")
        self.assertIn("Config file not found", str(cm.exception))

    def test_board_end_to_end(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "myboard" / "board.toml"
            _write(p, _BOARD_TOML)
            out = cfg.load_config(str(p), "board")
        self.assertEqual(out["board"]["arch"], "aarch64")
        self.assertEqual(out["rauc"]["compatible"], "crag-myboard")
        self.assertEqual(out["image"]["formats"], ["img"])
        # JSON-serializable (the --format=json contract)
        json.dumps(out)

    def test_tree_end_to_end_with_defaults(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "tree.toml"
            _write(p, '[tree]\nname = "acme"\n')
            out = cfg.load_config(str(p), "tree")
        self.assertEqual(out["tree"]["name"], "acme")
        self.assertEqual(out["tree"]["priority"], 50)
        self.assertEqual(out["tree"]["crag_min"], "")

    def test_tree_version_gate_enforced_for_real_versions(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "tree.toml"
            _write(p, '[tree]\nname = "acme"\ncrag_min = "2027.1"\n')
            saved = os.environ.get("CRAG_VERSION")
            os.environ["CRAG_VERSION"] = "2026.10"
            try:
                with self.assertRaises(ConfigError):
                    cfg.load_config(str(p), "tree")
            finally:
                if saved is None:
                    os.environ.pop("CRAG_VERSION", None)
                else:
                    os.environ["CRAG_VERSION"] = saved

    def test_variant_end_to_end(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "prod.toml"
            _write(p, '[variant]\nname = "prod"\n')
            out = cfg.load_config(str(p), "variant")
        self.assertEqual(out["rootfs"]["type"], "squashfs")


if __name__ == "__main__":
    unittest.main(verbosity=2)
