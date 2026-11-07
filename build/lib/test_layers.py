"""
Tests for the external-tree discovery and layer ordering (docs/08 §2, §4).

Covers the build/lib/layers.py contract:
    * _collect_externals: $CRAG_EXTERNAL first, then --external in CLI order,
      de-duplicated by resolved path (first occurrence keeps the tie-break slot)
    * _load_tree fails fast: missing tree root, missing tree.toml, invalid
      tree identity, and the crag_min/crag_max version gate
    * build_layers emits the canonical merge order:
      core -> trees (ASCENDING priority, ties by input order) -> board -> variant
    * board/variant resolution: a tree provider outranks the in-tree board,
      the HIGHEST-priority providing tree wins, in-tree is the fallback,
      and a missing board/variant is a hard error
    * the emitted layer objects carry exactly kind/name/path/priority and the
      resolved board dir / variant file are recoverable from the array

Run (host or the crag-builder container), from the repo root:

    python3 build/lib/test_layers.py                      # verbose unittest
    python3 -m unittest build.lib.test_layers             # (if run as pkg)
"""

import os
import sys
import tempfile
import unittest
from pathlib import Path

_HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE))

import layers as lay
from config import ConfigError

_ROOT = lay.crag_root()
# An in-tree board + variant used for the fallback-resolution cases.
_IN_TREE_BOARD = "qemu-armv7"
_IN_TREE_VARIANT = "dev"


def _write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def _make_tree(root, name, priority=50, board=None, variant=None, extra=""):
    """Minimal external tree under `root` (tree.toml + optional providers).

    `board` is a (board_id, board.toml text) tuple; `variant` is a
    (variant_id, variant .toml text) tuple. Either may be None.
    """
    troot = Path(root)
    _write(troot / "tree.toml",
           f'[tree]\nname = "{name}"\npriority = {priority}\n{extra}')
    if board is not None:
        bname, btext = board
        _write(troot / "boards" / bname / "board.toml", btext)
    if variant is not None:
        vname, vtext = variant
        _write(troot / "variants" / f"{vname}.toml", vtext)
    return str(troot)


class ExternalsEnvIsolationMixin:
    def setUp(self):
        self._env = os.environ.get("CRAG_EXTERNAL")
        os.environ["CRAG_EXTERNAL"] = ""
        self._tmp = tempfile.TemporaryDirectory()
        self.base = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()
        if self._env is None:
            os.environ.pop("CRAG_EXTERNAL", None)
        else:
            os.environ["CRAG_EXTERNAL"] = self._env


class CollectExternalsTests(ExternalsEnvIsolationMixin, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.t1 = _make_tree(self.base / "t1", "t1")
        self.t2 = _make_tree(self.base / "t2", "t2")

    def test_env_entries_come_before_cli_entries(self):
        os.environ["CRAG_EXTERNAL"] = self.t1
        got = lay._collect_externals([self.t2])
        self.assertEqual(got, [str(Path(self.t1).resolve()),
                               str(Path(self.t2).resolve())])

    def test_colon_order_and_cli_order_preserved(self):
        os.environ["CRAG_EXTERNAL"] = f"{self.t1}:{self.t2}"
        self.assertEqual(lay._collect_externals([]),
                         [str(Path(self.t1).resolve()),
                          str(Path(self.t2).resolve())])

    def test_duplicates_dropped_keeping_first_occurrence(self):
        os.environ["CRAG_EXTERNAL"] = f"{self.t1}:{self.t2}:{self.t1}"
        # a CLI repeat (even spelled differently) must not re-enter
        got = lay._collect_externals([str(Path(self.t2) / ".." / "t2")])
        self.assertEqual(got, [str(Path(self.t1).resolve()),
                               str(Path(self.t2).resolve())])

    def test_empty_env_entries_ignored(self):
        os.environ["CRAG_EXTERNAL"] = ":::"
        self.assertEqual(lay._collect_externals([]), [])


class LoadTreeTests(ExternalsEnvIsolationMixin, unittest.TestCase):
    def test_valid_tree_returns_name_and_priority(self):
        t = _make_tree(self.base / "ok", "acme", priority=25)
        self.assertEqual(lay._load_tree(t), ("acme", 25))

    def test_missing_root_rejected(self):
        with self.assertRaises(ConfigError) as cm:
            lay._load_tree(str(self.base / "nope"))
        self.assertIn("External tree not found", str(cm.exception))

    def test_missing_tree_toml_rejected(self):
        d = self.base / "empty"
        d.mkdir()
        with self.assertRaises(ConfigError) as cm:
            lay._load_tree(str(d))
        self.assertIn("missing tree.toml", str(cm.exception))

    def test_invalid_identity_rejected(self):
        t = self.base / "bad"
        _write(t / "tree.toml", '[tree]\npriority = 5\n')  # no name
        with self.assertRaises(ConfigError):
            lay._load_tree(str(t))

    def test_version_gate_rejects_out_of_range_tree(self):
        t = _make_tree(self.base / "future", "future",
                       extra='crag_min = "2027.1"\n')
        saved = os.environ.get("CRAG_VERSION")
        os.environ["CRAG_VERSION"] = "2026.10"
        try:
            with self.assertRaises(ConfigError) as cm:
                lay._load_tree(t)
            self.assertIn("requires Crag >= 2027.1", str(cm.exception))
        finally:
            if saved is None:
                os.environ.pop("CRAG_VERSION", None)
            else:
                os.environ["CRAG_VERSION"] = saved

    def test_dev_build_bypasses_the_version_gate(self):
        t = _make_tree(self.base / "future", "future",
                       extra='crag_min = "2027.1"\n')
        saved = os.environ.pop("CRAG_VERSION", None)
        try:
            self.assertEqual(lay._load_tree(t), ("future", 50))
        finally:
            if saved is not None:
                os.environ["CRAG_VERSION"] = saved


class BuildLayersTests(ExternalsEnvIsolationMixin, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.low = _make_tree(self.base / "low", "acme-low", priority=10,
                              board=(_IN_TREE_BOARD,
                                     '[board]\nname = "TG"\narch = "aarch64"\n'),
                              variant=("dev", '[variant]\nname = "dev"\n'))
        self.high = _make_tree(self.base / "high", "acme-high", priority=20,
                               board=(_IN_TREE_BOARD,
                                      '[board]\nname = "TG"\narch = "aarch64"\n'),
                               variant=("dev", '[variant]\nname = "dev"\n'))

    def test_no_externals_core_board_variant(self):
        layers = lay.build_layers(_IN_TREE_BOARD, _IN_TREE_VARIANT, [])
        self.assertEqual([x["kind"] for x in layers],
                         ["core", "board", "variant"])
        self.assertEqual(layers[0]["path"], str(_ROOT / "boards" / "common"))
        self.assertEqual(layers[1]["path"],
                         str(_ROOT / "boards" / _IN_TREE_BOARD))
        self.assertTrue(layers[2]["path"].endswith(
            f"boards/{_IN_TREE_BOARD}/variants/{_IN_TREE_VARIANT}.toml"))

    def test_layer_objects_carry_exactly_the_documented_keys(self):
        layers = lay.build_layers(_IN_TREE_BOARD, _IN_TREE_VARIANT, [self.low])
        for layer in layers:
            self.assertEqual(set(layer), {"kind", "name", "path", "priority"})

    def test_tree_band_is_ascending_priority_not_input_order(self):
        # CLI order is high, low — the array must still be low then high.
        layers = lay.build_layers(_IN_TREE_BOARD, _IN_TREE_VARIANT,
                                  [self.high, self.low])
        kinds = [x["kind"] for x in layers]
        self.assertEqual(kinds, ["core", "tree", "tree", "board", "variant"])
        self.assertEqual([x["name"] for x in layers[1:3]],
                         ["acme-low", "acme-high"])
        self.assertEqual([x["priority"] for x in layers[1:3]], [10, 20])

    def test_priority_ties_keep_input_order(self):
        t1 = _make_tree(self.base / "tie1", "tie1", priority=10)
        t2 = _make_tree(self.base / "tie2", "tie2", priority=10)
        os.environ["CRAG_EXTERNAL"] = f"{t1}:{t2}"
        layers = lay.build_layers(_IN_TREE_BOARD, _IN_TREE_VARIANT, [])
        self.assertEqual([x["name"] for x in layers if x["kind"] == "tree"],
                         ["tie1", "tie2"])

    def test_tree_board_provider_outranks_in_tree_board(self):
        layers = lay.build_layers(_IN_TREE_BOARD, _IN_TREE_VARIANT, [self.low])
        board = next(x for x in layers if x["kind"] == "board")
        self.assertIn(f"{os.sep}low{os.sep}", board["path"] + os.sep)

    def test_highest_priority_tree_provides_the_board(self):
        layers = lay.build_layers(_IN_TREE_BOARD, _IN_TREE_VARIANT,
                                  [self.low, self.high])
        board = next(x for x in layers if x["kind"] == "board")
        variant = next(x for x in layers if x["kind"] == "variant")
        self.assertIn(f"{os.sep}high{os.sep}", board["path"] + os.sep)
        self.assertIn(f"{os.sep}high{os.sep}", variant["path"] + os.sep)

    def test_tree_variant_provider_outranks_board_variant(self):
        # A tree that provides ONLY the variant: the board still resolves
        # in-tree, but the variant .toml comes from the tree.
        varonly = _make_tree(self.base / "varonly", "varonly", priority=5,
                             variant=("dev", '[variant]\nname = "dev"\n'))
        layers = lay.build_layers(_IN_TREE_BOARD, _IN_TREE_VARIANT, [varonly])
        board = next(x for x in layers if x["kind"] == "board")
        variant = next(x for x in layers if x["kind"] == "variant")
        self.assertEqual(board["path"], str(_ROOT / "boards" / _IN_TREE_BOARD))
        self.assertIn(f"{os.sep}varonly{os.sep}", variant["path"] + os.sep)

    def test_missing_board_is_a_hard_error(self):
        with self.assertRaises(ConfigError) as cm:
            lay.build_layers("no-such-board", "dev", [])
        self.assertIn("Board not found: no-such-board", str(cm.exception))

    def test_missing_variant_is_a_hard_error(self):
        with self.assertRaises(ConfigError) as cm:
            lay.build_layers(_IN_TREE_BOARD, "no-such-variant", [])
        self.assertIn("Variant not found: no-such-variant", str(cm.exception))

    def test_board_and_variant_names_are_carried(self):
        layers = lay.build_layers(_IN_TREE_BOARD, _IN_TREE_VARIANT, [])
        board = next(x for x in layers if x["kind"] == "board")
        variant = next(x for x in layers if x["kind"] == "variant")
        self.assertEqual(board["name"], _IN_TREE_BOARD)
        self.assertEqual(variant["name"], _IN_TREE_VARIANT)


if __name__ == "__main__":
    unittest.main(verbosity=2)
