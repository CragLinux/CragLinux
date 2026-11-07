"""
Tests for the schema tables (docs/03 §6, docs/04 §2, docs/08 §2/§5).

build/lib/schema.py is pure data — these tests pin its real contracts:
    * structural shape: every field spec declares type + required, defaults
      match their type, defaults live inside their choices
    * the pinned vocabularies: arch set, bootloader types, image formats
    * cross-table consistency: RAUC_BOOTLOADER_FOR_TYPE keys/values line up
      with the [bootloader].type and [rauc].bootloader choices
    * BOARD_CONDITIONAL_RULES only reference real sections/fields
    * the required-section flags (board/kernel/bootloader are mandatory,
      partitions/rauc/image/... are optional-with-defaults)
    * the schemas actually drive config.validate_config: choice rejections,
      unknown-field fences, and required-field errors fire as documented

Run (host or the crag-builder container), from the repo root:

    python3 build/lib/test_schema.py                      # verbose unittest
    python3 -m unittest build.lib.test_schema             # (if run as pkg)
"""

import sys
import unittest
from pathlib import Path

_HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE))

import config as _config
import schema as sch

_FIELD_TYPES = (str, int, bool, list)
_ALL_TABLES = (sch.BOARD_SCHEMA, sch.VARIANT_SCHEMA, sch.TREE_SCHEMA,
               sch.SERVICE_MANIFEST_SCHEMA)


def _field_specs():
    """Yield (table_name, section, field, spec) for every field in every table."""
    for table in _ALL_TABLES:
        for section, section_schema in table.items():
            for field, spec in section_schema.items():
                if not field.startswith("_"):
                    yield section, field, spec


class SchemaShapeTests(unittest.TestCase):
    def test_every_field_declares_type_and_required(self):
        for section, field, spec in _field_specs():
            with self.subTest(section=section, field=field):
                self.assertIn("type", spec)
                self.assertIn(spec["type"], _FIELD_TYPES)
                self.assertIsInstance(spec["required"], bool)

    def test_defaults_match_their_field_type(self):
        for section, field, spec in _field_specs():
            if "default" in spec:
                with self.subTest(section=section, field=field):
                    self.assertIsInstance(spec["default"], spec["type"])

    def test_defaults_satisfy_choices(self):
        for section, field, spec in _field_specs():
            if "default" in spec and "choices" in spec:
                with self.subTest(section=section, field=field):
                    self.assertIn(spec["default"], spec["choices"])

    def test_choice_tables_are_non_empty_lists(self):
        for section, field, spec in _field_specs():
            for key in ("choices", "item_choices"):
                if key in spec:
                    with self.subTest(section=section, field=field, key=key):
                        self.assertTrue(spec[key])
                        self.assertIsInstance(spec[key], list)

    def test_item_choices_only_on_list_fields(self):
        for section, field, spec in _field_specs():
            if "item_choices" in spec:
                with self.subTest(section=section, field=field):
                    self.assertIs(spec["type"], list)


class PinnedVocabularyTests(unittest.TestCase):
    def test_arch_choices_are_the_supported_set(self):
        self.assertEqual(sch.BOARD_SCHEMA["board"]["arch"]["choices"],
                         ["aarch64", "armv7hf", "x86_64", "riscv64"])

    def test_bootloader_type_choices(self):
        self.assertEqual(sch.BOARD_SCHEMA["bootloader"]["type"]["choices"],
                         ["u-boot", "rpi-boot", "grub-efi", "direct", "none"])

    def test_image_formats_item_choices(self):
        self.assertEqual(sch.BOARD_SCHEMA["image"]["formats"]["item_choices"],
                         ["img", "qcow2"])

    def test_partitions_table_is_gpt_only(self):
        self.assertEqual(sch.BOARD_SCHEMA["partitions"]["table"]["choices"],
                         ["gpt"])

    def test_rootfs_type_choices(self):
        self.assertEqual(sch.VARIANT_SCHEMA["rootfs"]["type"]["choices"],
                         ["ext4", "squashfs"])

    def test_packages_mode_choices(self):
        self.assertEqual(sch.VARIANT_SCHEMA["packages"]["mode"]["choices"],
                         ["source", "binary"])


class CrossTableConsistencyTests(unittest.TestCase):
    def test_rauc_bootloader_map_keys_are_bootloader_types(self):
        bl_types = set(sch.BOARD_SCHEMA["bootloader"]["type"]["choices"])
        self.assertTrue(set(sch.RAUC_BOOTLOADER_FOR_TYPE) <= bl_types)

    def test_rauc_bootloader_map_values_are_rauc_choices(self):
        rauc_choices = set(sch.BOARD_SCHEMA["rauc"]["bootloader"]["choices"])
        self.assertEqual(rauc_choices, {"grub", "uboot"})
        self.assertTrue(set(sch.RAUC_BOOTLOADER_FOR_TYPE.values()) <= rauc_choices)

    def test_conditional_rules_reference_real_sections_and_fields(self):
        for rule in sch.BOARD_CONDITIONAL_RULES:
            sec, field, _ = rule["when"]
            with self.subTest(rule=rule):
                self.assertIn(sec, sch.BOARD_SCHEMA)
                self.assertIn(field, sch.BOARD_SCHEMA[sec])
                for req_sec, req_field in rule["require"]:
                    self.assertIn(req_sec, sch.BOARD_SCHEMA)
                    self.assertIn(req_field, sch.BOARD_SCHEMA[req_sec])

    def test_deprecated_disk_schema_shape(self):
        self.assertTrue(sch.DEPRECATED_DISK_SCHEMA["boot_size"]["required"])
        self.assertTrue(sch.DEPRECATED_DISK_SCHEMA["root_size"]["required"])
        self.assertEqual(sch.DEPRECATED_DISK_SCHEMA["boot_fs"]["choices"],
                         ["vfat", "ext4"])
        self.assertEqual(sch.DEPRECATED_DISK_SCHEMA["root_fs"]["choices"],
                         ["ext4", "f2fs", "btrfs"])


class RequiredSectionTests(unittest.TestCase):
    def _required(self, table, section):
        return table[section].get("_required_section", False)

    def test_board_mandatory_sections(self):
        for section in ("board", "kernel", "bootloader"):
            with self.subTest(section=section):
                self.assertTrue(self._required(sch.BOARD_SCHEMA, section))

    def test_board_optional_sections(self):
        for section in ("partitions", "rauc", "image", "api", "firmware",
                        "console", "qemu"):
            with self.subTest(section=section):
                self.assertFalse(self._required(sch.BOARD_SCHEMA, section))

    def test_variant_tree_and_manifest_required_sections(self):
        self.assertTrue(self._required(sch.VARIANT_SCHEMA, "variant"))
        self.assertFalse(self._required(sch.VARIANT_SCHEMA, "packages"))
        self.assertTrue(self._required(sch.TREE_SCHEMA, "tree"))
        self.assertTrue(self._required(sch.SERVICE_MANIFEST_SCHEMA, "service"))
        self.assertFalse(self._required(sch.SERVICE_MANIFEST_SCHEMA, "integration"))


class DefaultsContractTests(unittest.TestCase):
    def test_tree_identity_defaults(self):
        tree = sch.TREE_SCHEMA["tree"]
        self.assertTrue(tree["name"]["required"])
        self.assertEqual(tree["priority"]["default"], 50)
        self.assertEqual(tree["crag_min"]["default"], "")
        self.assertEqual(tree["crag_max"]["default"], "")

    def test_service_manifest_defaults(self):
        svc = sch.SERVICE_MANIFEST_SCHEMA["service"]
        integ = sch.SERVICE_MANIFEST_SCHEMA["integration"]
        self.assertEqual(svc["user"]["default"], "")
        self.assertFalse(svc["data_dir"]["default"])
        self.assertFalse(integ["boot_success"]["default"])
        self.assertFalse(integ["api_controllable"]["default"])
        self.assertFalse(integ["api_client"]["default"])

    def test_user_entry_defaults(self):
        user = sch.USER_ENTRY_SCHEMA
        self.assertTrue(user["name"]["required"])
        self.assertTrue(user["uid"]["required"])
        self.assertEqual(user["shell"]["default"], "/bin/sh")
        self.assertEqual(user["groups"]["default"], [])

    def test_ad007_partition_defaults(self):
        parts = sch.BOARD_SCHEMA["partitions"]
        self.assertEqual(parts["esp_size"]["default"], "64M")
        self.assertEqual(parts["bootenv_size"]["default"], "1M")
        self.assertEqual(parts["boot_size"]["default"], "64M")
        self.assertEqual(parts["rootfs_size"]["default"], "512M")
        self.assertEqual(parts["data_min_size"]["default"], "64M")
        self.assertFalse(parts["hybrid_mbr"]["default"])


class SchemaDrivesValidationTests(unittest.TestCase):
    """The tables reject bad configs exactly as documented (via config.py)."""

    def test_bad_arch_rejected_with_choices_message(self):
        with self.assertRaises(_config.ConfigError) as cm:
            _config.validate_config(
                {"board": {"name": "X", "arch": "sparc"},
                 "kernel": {"version": "6.12", "cmdline": "console"},
                 "bootloader": {"type": "none"}},
                sch.BOARD_SCHEMA, "b.toml")
        self.assertIn("not in allowed values", str(cm.exception))

    def test_unknown_field_rejected(self):
        with self.assertRaises(_config.ConfigError) as cm:
            _config.validate_config({"tree": {"name": "t", "priorty": 5}},
                                    sch.TREE_SCHEMA, "tree.toml")
        self.assertIn("unknown field 'priorty'", str(cm.exception))

    def test_missing_required_field_rejected(self):
        with self.assertRaises(_config.ConfigError) as cm:
            _config.validate_config({"service": {"user": "x"}},
                                    sch.SERVICE_MANIFEST_SCHEMA, "s.toml")
        self.assertIn("missing required field 'name'", str(cm.exception))

    def test_wrong_type_rejected(self):
        with self.assertRaises(_config.ConfigError) as cm:
            _config.validate_config({"tree": {"name": "t", "priority": "high"}},
                                    sch.TREE_SCHEMA, "tree.toml")
        self.assertIn("expected int, got str", str(cm.exception))


if __name__ == "__main__":
    unittest.main(verbosity=2)
