"""
Tests for the external-tree board/variant TOML deep-merge (docs/08 §4).

Covers the layering rules from the §4 table:
    * scalars       -> last writer (later layer) wins
    * lists         -> REPLACE, not append
    * [packages].install -> the ONE accumulate-and-dedupe exception
    * nested tables -> deep-merge recursively
    * two trees + board + variant precedence (ascending tree priority)
    * a tree cannot smuggle in invalid keys (the merged result is validated)
    * NO-TREE BYTE-IDENTITY: the merge path must reproduce config.load_config
      exactly for the single-file case (all current fleet CI stays green).

The deep-merge itself lives in build/lib/merge.py; the validate/default/derive
pipeline it reuses lives in build/lib/config.py (finalize_board_config /
finalize_variant_config). These tests exercise both.

Run (host or the astro-builder container), from the repo root:

    python3 build/lib/test_merge_board_variant.py          # verbose unittest
    python3 -m unittest build.lib.test_merge_board_variant  # (if run as pkg)

Container form (matches how the build validates python):
    ./build/astro-build.sh  ... is not needed; just:
    podman run --rm -v "$PWD:$PWD:Z" -w "$PWD" astro-builder \
        python3 build/lib/test_merge_board_variant.py
"""

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

_HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE))

import config as _config  # noqa: E402
import layers as _layers  # noqa: E402
import merge as _merge  # noqa: E402

_ROOT = _HERE.parents[1]  # repo root (build/lib/ -> parents[1])


# --------------------------------------------------------------------------- #
# Synthetic-tree helpers                                                       #
# --------------------------------------------------------------------------- #

def _write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def _make_tree(root, name, priority, board=None, variant=None):
    """Create a minimal external tree under `root`. Returns the tree root path.

    `board` / `variant` are raw TOML strings written to
    boards/testgw/board.toml and variants/dev.toml respectively.
    """
    troot = Path(root)
    _write(troot / "tree.toml", f'[tree]\nname = "{name}"\npriority = {priority}\n')
    if board is not None:
        _write(troot / "boards" / "testgw" / "board.toml", board)
    if variant is not None:
        _write(troot / "variants" / "dev.toml", variant)
    return str(troot)


# A complete, valid base board (all required fields present).
_BOARD_LOW = """\
[board]
name = "Test GW"
arch = "aarch64"

[kernel]
version = "6.12"
cmdline = "console=ttyS0"
config_fragments = ["a.cfg", "b.cfg"]

[bootloader]
type = "none"

[console]
device = "ttyLOW"
baud = 9600

[firmware]
packages = ["pkg-low"]
"""

# A higher-priority fragment that overrides some scalars and replaces lists.
_BOARD_HIGH = """\
[kernel]
config_fragments = ["c.cfg"]

[console]
baud = 19200

[firmware]
packages = ["pkg-high"]
"""

_VARIANT_LOW = """\
[variant]
name = "dev"

[packages]
install = ["p-low", "shared"]

[services]
enable = ["s-low"]
"""

_VARIANT_HIGH = """\
[variant]
name = "dev"

[packages]
install = ["p-high", "shared"]
"""


class DeepMergePrimitiveTests(unittest.TestCase):
    """The pure deep_merge(base, overlay) helper (docs/08 §4 rules)."""

    def test_scalar_last_wins(self):
        merged = _merge.deep_merge({"console": {"baud": 9600}},
                                   {"console": {"baud": 19200}})
        self.assertEqual(merged["console"]["baud"], 19200)

    def test_list_replaces_not_appends(self):
        merged = _merge.deep_merge({"kernel": {"config_fragments": ["a", "b"]}},
                                   {"kernel": {"config_fragments": ["c"]}})
        self.assertEqual(merged["kernel"]["config_fragments"], ["c"])

    def test_packages_install_accumulates_and_dedupes(self):
        merged = _merge.deep_merge({"packages": {"install": ["a", "b"]}},
                                   {"packages": {"install": ["b", "c"]}})
        # append + dedupe, first occurrence order preserved
        self.assertEqual(merged["packages"]["install"], ["a", "b", "c"])

    def test_only_packages_install_accumulates(self):
        # A same-named list elsewhere must still REPLACE.
        merged = _merge.deep_merge({"services": {"install": ["a"]}},
                                   {"services": {"install": ["b"]}})
        self.assertEqual(merged["services"]["install"], ["b"])

    def test_nested_table_deep_merge(self):
        merged = _merge.deep_merge(
            {"console": {"device": "ttyLOW", "baud": 9600}},
            {"console": {"baud": 19200}},
        )
        # device survives from base, baud overridden -> tables merge, not replace
        self.assertEqual(merged["console"], {"device": "ttyLOW", "baud": 19200})

    def test_deep_merge_does_not_mutate_inputs(self):
        base = {"a": {"x": 1}, "lst": [1]}
        overlay = {"a": {"y": 2}}
        _merge.deep_merge(base, overlay)
        self.assertEqual(base, {"a": {"x": 1}, "lst": [1]})


class TwoTreePrecedenceTests(unittest.TestCase):
    """Full deep_merge_board_variant across two trees + board + variant."""

    def setUp(self):
        self._env = os.environ.get("ASTRO_EXTERNAL")
        os.environ["ASTRO_EXTERNAL"] = ""  # only CLI externals in these tests
        self._tmp = tempfile.TemporaryDirectory()
        base = Path(self._tmp.name)
        self.low = _make_tree(base / "low", "acme-low", 10,
                              board=_BOARD_LOW, variant=_VARIANT_LOW)
        self.high = _make_tree(base / "high", "acme-high", 20,
                               board=_BOARD_HIGH, variant=_VARIANT_HIGH)

    def tearDown(self):
        self._tmp.cleanup()
        if self._env is None:
            os.environ.pop("ASTRO_EXTERNAL", None)
        else:
            os.environ["ASTRO_EXTERNAL"] = self._env

    def _layers(self):
        # Pass in reverse-priority CLI order to prove priority (not input order)
        # decides the tree band and the board/variant provider.
        return _layers.build_layers("testgw", "dev", [self.high, self.low])

    def test_board_merge_precedence(self):
        layer_list = self._layers()
        board = _merge.deep_merge_board_variant(layer_list, "board", "testgw", "dev")

        # scalar: higher-priority tree wins
        self.assertEqual(board["console"]["baud"], 19200)
        # nested table deep-merge: device only set by the low tree, survives
        self.assertEqual(board["console"]["device"], "ttyLOW")
        # lists REPLACE (not append): high tree's values only
        self.assertEqual(board["kernel"]["config_fragments"], ["c.cfg"])
        self.assertEqual(board["firmware"]["packages"], ["pkg-high"])
        # required field carried from the base (low) fragment
        self.assertEqual(board["board"]["arch"], "aarch64")
        # derived default keyed on the resolved board dir name
        self.assertEqual(board["rauc"]["compatible"], "astro-testgw")

    def test_variant_merge_precedence(self):
        layer_list = self._layers()
        var = _merge.deep_merge_board_variant(layer_list, "variant", "testgw", "dev")

        # packages.install ACCUMULATES + dedupes across layers (low then high)
        self.assertEqual(var["packages"]["install"], ["p-low", "shared", "p-high"])
        # a list that only the low tree sets survives (high tree replaces nothing)
        self.assertEqual(var["services"]["enable"], ["s-low"])
        # dev variant -> ext4 rootfs default
        self.assertEqual(var["rootfs"]["type"], "ext4")

    def test_resolution_picks_highest_priority_provider(self):
        layer_list = self._layers()
        board_layer = next(x for x in layer_list if x["kind"] == "board")
        variant_layer = next(x for x in layer_list if x["kind"] == "variant")
        self.assertIn("/high/", board_layer["path"] + "/")
        self.assertIn("/high/", variant_layer["path"] + "/")


class SchemaValidationTests(unittest.TestCase):
    """A tree cannot introduce keys the schema rejects (task item 2)."""

    def setUp(self):
        self._env = os.environ.get("ASTRO_EXTERNAL")
        os.environ["ASTRO_EXTERNAL"] = ""
        self._tmp = tempfile.TemporaryDirectory()
        base = Path(self._tmp.name)
        # Inline an unknown key into the existing [board] table (TOML forbids
        # duplicate table headers).
        bad_board = _BOARD_LOW.replace(
            '[board]\nname = "Test GW"',
            '[board]\nname = "Test GW"\nbogus_field = "nope"',
        )
        self.tree = _make_tree(base / "bad", "acme-bad", 10,
                               board=bad_board, variant=_VARIANT_LOW)

    def tearDown(self):
        self._tmp.cleanup()
        if self._env is None:
            os.environ.pop("ASTRO_EXTERNAL", None)
        else:
            os.environ["ASTRO_EXTERNAL"] = self._env

    def test_invalid_tree_key_is_rejected(self):
        layer_list = _layers.build_layers("testgw", "dev", [self.tree])
        with self.assertRaises(_config.ConfigError) as ctx:
            _merge.deep_merge_board_variant(layer_list, "board", "testgw", "dev")
        self.assertIn("bogus_field", str(ctx.exception))


class ByteIdenticalRegressionTests(unittest.TestCase):
    """No-tree case must be byte-identical to config.load_config."""

    def setUp(self):
        self._env = os.environ.get("ASTRO_EXTERNAL")
        os.environ["ASTRO_EXTERNAL"] = ""

    def tearDown(self):
        if self._env is None:
            os.environ.pop("ASTRO_EXTERNAL", None)
        else:
            os.environ["ASTRO_EXTERNAL"] = self._env

    # Every in-tree board. Since merge.py now delegates to config.py's shared
    # finalize_* pipeline, the merge-module wrapper is byte-identical to
    # config.load_config for ALL boards — including rpi4 (no [qemu]), whose
    # qcow2 divergence the delegation fixed.
    _QEMU_BOARDS = ["qemu-armv7", "qemu-aarch64", "qemu-x86_64"]
    _ALL_BOARDS = _QEMU_BOARDS + ["rpi4"]

    def test_no_tree_board_matches_loader(self):
        # The specifically-required regression (task item 3): qemu-armv7/dev,
        # plus every other in-tree board, through merge.deep_merge_board_variant.
        for b in self._ALL_BOARDS:
            with self.subTest(board=b):
                layer_list = _layers.build_layers(b, "dev", [])
                got = _merge.deep_merge_board_variant(layer_list, "board", b, "dev")
                want = _config.load_config(
                    str(_ROOT / "boards" / b / "board.toml"), "board")
                self.assertEqual(json.dumps(got, sort_keys=True),
                                 json.dumps(want, sort_keys=True))

    def test_no_tree_variant_matches_loader(self):
        for b in self._ALL_BOARDS:
            for v in ("dev", "prod"):
                vf = _ROOT / "boards" / b / "variants" / f"{v}.toml"
                if not vf.is_file():
                    continue
                with self.subTest(board=b, variant=v):
                    layer_list = _layers.build_layers(b, v, [])
                    got = _merge.deep_merge_board_variant(
                        layer_list, "variant", b, v)
                    want = _config.load_config(str(vf), "variant")
                    self.assertEqual(json.dumps(got, sort_keys=True),
                                     json.dumps(want, sort_keys=True))

    def test_finalize_pipeline_byte_identical_all_boards(self):
        # The shared finalize_* pipeline (what the fixed merge.py delegates to)
        # reproduces load_config for EVERY in-tree board/variant, including
        # rpi4 (no [qemu]). This is the byte-identity guarantee at the pipeline
        # level, independent of the merge.py wrapper's current qcow2 bug.
        import tomllib
        for b in self._ALL_BOARDS:
            bt = _ROOT / "boards" / b / "board.toml"
            if not bt.is_file():
                continue
            with self.subTest(board=b):
                with open(bt, "rb") as f:
                    raw = tomllib.load(f)
                got = _config.finalize_board_config(raw, str(bt))
                want = _config.load_config(str(bt), "board")
                self.assertEqual(json.dumps(got, sort_keys=True),
                                 json.dumps(want, sort_keys=True))
            for v in ("dev", "prod"):
                vf = _ROOT / "boards" / b / "variants" / f"{v}.toml"
                if not vf.is_file():
                    continue
                with self.subTest(board=b, variant=v):
                    with open(vf, "rb") as f:
                        raw = tomllib.load(f)
                    got = _config.finalize_variant_config(raw, str(vf))
                    want = _config.load_config(str(vf), "variant")
                    self.assertEqual(json.dumps(got, sort_keys=True),
                                     json.dumps(want, sort_keys=True))

    def test_qcow2_not_added_without_qemu(self):
        # A board that never declared [qemu] must NOT gain the qcow2 output
        # format. finalize_board_config sees the pre-defaults dict, so the
        # qcow2 auto-add stays off.
        raw = {
            "board": {"name": "NoQemu", "arch": "aarch64"},
            "kernel": {"version": "6.12", "cmdline": "console=ttyS0"},
            "bootloader": {"type": "none"},
        }
        cfg = _config.finalize_board_config(
            raw, str(_ROOT / "boards" / "noqemu" / "board.toml"))
        self.assertEqual(cfg["image"]["formats"], ["img"])

    def test_qcow2_added_with_qemu(self):
        raw = {
            "board": {"name": "WithQemu", "arch": "aarch64"},
            "kernel": {"version": "6.12", "cmdline": "console=ttyS0"},
            "bootloader": {"type": "none"},
            "qemu": {"machine": "virt"},
        }
        cfg = _config.finalize_board_config(
            raw, str(_ROOT / "boards" / "withqemu" / "board.toml"))
        self.assertIn("qcow2", cfg["image"]["formats"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
