"""
Tests for the image-stage partition layout calculator (docs/04 §2, AD-007).

Covers the build/lib/image_layout.py contract:
    * size_to_bytes: <int><K|M|G> parsing, everything else is a ValueError
    * align_up: 1 MiB partition alignment math
    * compute_layout: byte-exact offsets for the fixed AD-007 order
      (esp, bootenv, boot.A, rootfs.A, boot.B, rootfs.B, data), the esp's
      distinct GPT type GUID, the trailing backup-GPT slack, and the
      sfdisk script (sector units, PARTLABELs, optional label-id/uuid)
    * SOURCE_DATE_EPOCH determinism: identical inputs give identical GUIDs
      (UUIDv5 over board/partition/epoch); no epoch means no GUID fields
    * stamp_hybrid_mbr: the four MBR entry slots — FAT32-LBA esp entry +
      0xEE protective entry — and the 55AA signature, GPT untouched

Run (host or the crag-builder container), from the repo root:

    python3 build/lib/test_image_layout.py                # verbose unittest
    python3 -m unittest build.lib.test_image_layout       # (if run as pkg)
"""

import sys
import tempfile
import unittest
from pathlib import Path

_HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE))

import image_layout as il

MIB = il.MIB
SECTOR = il.SECTOR


class SizeToBytesTests(unittest.TestCase):
    def test_suffix_multipliers(self):
        self.assertEqual(il.size_to_bytes("1K"), 1024)
        self.assertEqual(il.size_to_bytes("64M"), 64 * MIB)
        self.assertEqual(il.size_to_bytes("2G"), 2 * 1024 * MIB)

    def test_multi_digit_values(self):
        self.assertEqual(il.size_to_bytes("512M"), 512 * MIB)
        self.assertEqual(il.size_to_bytes("10G"), 10 * 1024 * MIB)

    def test_invalid_sizes_raise(self):
        for s in ("64", "64MB", "0M", "-1M", "64m", "", "M", "1.5M", "0x40M"):
            with self.subTest(size=s):
                with self.assertRaises(ValueError):
                    il.size_to_bytes(s)


class AlignUpTests(unittest.TestCase):
    def test_align_up_to_mib(self):
        self.assertEqual(il.align_up(0), 0)
        self.assertEqual(il.align_up(1), MIB)
        self.assertEqual(il.align_up(MIB), MIB)
        self.assertEqual(il.align_up(MIB + 1), 2 * MIB)


class ComputeLayoutTests(unittest.TestCase):
    _DEFAULT_SIZES = [64 * MIB, 1 * MIB, 64 * MIB, 512 * MIB,
                      64 * MIB, 512 * MIB, 64 * MIB]

    def _layout(self, config=None, sde=None):
        return il.compute_layout(config or {"board": {"name": "Test"}}, sde)

    def test_default_offsets_are_byte_exact(self):
        layout = self._layout()
        parts = layout["partitions"]
        self.assertEqual([p["name"] for p in parts],
                         ["esp", "bootenv", "boot.A", "rootfs.A",
                          "boot.B", "rootfs.B", "data"])
        # 1 MiB first offset, then chained: 1, 65, 66, 130, 642, 706, 1218 MiB
        self.assertEqual([p["offset"] for p in parts],
                         [1 * MIB, 65 * MIB, 66 * MIB, 130 * MIB,
                          642 * MIB, 706 * MIB, 1218 * MIB])
        self.assertEqual([p["size"] for p in parts], self._DEFAULT_SIZES)
        # total = end of data + 1 MiB backup-GPT slack
        self.assertEqual(layout["total_bytes"], 1283 * MIB)
        self.assertEqual(layout["sector_size"], SECTOR)

    def test_partition_type_guids(self):
        parts = self._layout()["partitions"]
        self.assertEqual(parts[0]["type"], il.TYPE_ESP)
        for p in parts[1:]:
            self.assertEqual(p["type"], il.TYPE_LINUX)

    def test_custom_sizes_flow_through(self):
        config = {"board": {"name": "T"},
                  "partitions": {"esp_size": "32M", "bootenv_size": "2M",
                                 "boot_size": "8M", "rootfs_size": "100M",
                                 "data_min_size": "7M"}}
        parts = self._layout(config)["partitions"]
        self.assertEqual([p["offset"] for p in parts],
                         [1 * MIB, 33 * MIB, 35 * MIB, 43 * MIB,
                          143 * MIB, 151 * MIB, 251 * MIB])
        self.assertEqual([p["size"] for p in parts],
                         [32 * MIB, 2 * MIB, 8 * MIB, 100 * MIB,
                          8 * MIB, 100 * MIB, 7 * MIB])
        self.assertEqual(self._layout(config)["total_bytes"], 259 * MIB)

    def test_unaligned_sizes_round_up(self):
        config = {"board": {"name": "T"},
                  "partitions": {"esp_size": "1K"}}
        esp = self._layout(config)["partitions"][0]
        self.assertEqual(esp["size"], MIB)  # 1K rounds up to 1 MiB

    def test_no_epoch_means_no_guid_fields(self):
        layout = self._layout()
        self.assertIsNone(layout["partitions"][0]["uuid"])
        self.assertNotIn("label-id", layout["sfdisk_script"])

    def test_sfdisk_script_shape(self):
        script = self._layout()["sfdisk_script"]
        lines = script.splitlines()
        self.assertEqual(lines[0], "label: gpt")
        self.assertEqual(lines[1], "sector-size: 512")
        self.assertEqual(lines[2], "")
        entries = lines[3:]
        self.assertEqual(len(entries), 7)
        # start/size are in SECTORS: esp at 1 MiB = 2048 sectors, 64M = 131072
        self.assertEqual(entries[0],
                         'start=2048, size=131072, type=%s, name="esp"' % il.TYPE_ESP)
        self.assertIn('name="rootfs.A"', entries[3])
        self.assertIn('name="data"', entries[6])
        for e in entries:
            self.assertIn("type=", e)
            self.assertNotIn("uuid=", e)

    def test_deterministic_guids_with_epoch(self):
        layout = self._layout(sde="1700000000")
        for p in layout["partitions"]:
            self.assertIsNotNone(p["uuid"])
            self.assertEqual(p["uuid"], p["uuid"].upper())
        # same inputs -> identical output
        again = self._layout(sde="1700000000")
        self.assertEqual(layout, again)
        # the disk GUID is the script's label-id (uuid5 over board/disk/epoch)
        import uuid
        disk_guid = str(uuid.uuid5(
            il.CRAG_UUID_NS, "Test/disk/1700000000")).upper()
        self.assertIn(f"label-id: {disk_guid}", layout["sfdisk_script"])
        # every partition uuid appears in the script
        for p in layout["partitions"]:
            self.assertIn(f"uuid={p['uuid']}", layout["sfdisk_script"])

    def test_different_epochs_give_different_guids(self):
        a = self._layout(sde="1")["partitions"][0]["uuid"]
        b = self._layout(sde="2")["partitions"][0]["uuid"]
        self.assertNotEqual(a, b)

    def test_guids_depend_on_board_name(self):
        cfg_a = {"board": {"name": "board-a"}}
        cfg_b = {"board": {"name": "board-b"}}
        self.assertNotEqual(
            il.compute_layout(cfg_a, "1700000000")["partitions"][0]["uuid"],
            il.compute_layout(cfg_b, "1700000000")["partitions"][0]["uuid"])


class HybridMbrTests(unittest.TestCase):
    def _stamp(self, config=None):
        layout = il.compute_layout(config or {"board": {"name": "T"}}, None)
        with tempfile.TemporaryDirectory() as d:
            img = Path(d) / "disk.img"
            img.write_bytes(b"\x00" * (2 * MIB))
            il.stamp_hybrid_mbr(str(img), layout)
            data = img.read_bytes()
        return data, layout

    def test_entry_one_is_fat32_lba_esp(self):
        data, layout = self._stamp()
        esp = layout["partitions"][0]
        entry = data[446:462]
        self.assertEqual(entry[0], 0x80)  # active
        self.assertEqual(entry[1:4], b"\xff\xff\xff")  # CHS sentinel
        self.assertEqual(entry[4], 0x0C)  # FAT32-LBA
        self.assertEqual(int.from_bytes(entry[8:12], "little"),
                         esp["offset"] // SECTOR)
        self.assertEqual(int.from_bytes(entry[12:16], "little"),
                         esp["size"] // SECTOR)

    def test_entry_two_is_protective_ee(self):
        data, layout = self._stamp()
        esp = layout["partitions"][0]
        entry = data[462:478]
        self.assertEqual(entry[0], 0x00)  # not active
        self.assertEqual(entry[4], 0xEE)
        self.assertEqual(int.from_bytes(entry[8:12], "little"), 1)
        self.assertEqual(int.from_bytes(entry[12:16], "little"),
                         esp["offset"] // SECTOR - 1)

    def test_entries_three_and_four_are_zero(self):
        data, _ = self._stamp()
        self.assertEqual(data[478:510], b"\x00" * 32)

    def test_boot_signature_written(self):
        data, _ = self._stamp()
        self.assertEqual(data[510:512], b"\x55\xaa")

    def test_custom_esp_size_reflected(self):
        config = {"board": {"name": "T"},
                  "partitions": {"esp_size": "32M"}}
        data, layout = self._stamp(config)
        esp = layout["partitions"][0]
        self.assertEqual(esp["size"], 32 * MIB)
        entry = data[446:462]
        self.assertEqual(int.from_bytes(entry[12:16], "little"),
                         32 * MIB // SECTOR)
        # protective entry covers 1 .. esp_start-1
        self.assertEqual(int.from_bytes(data[474:478], "little"),
                         esp["offset"] // SECTOR - 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
