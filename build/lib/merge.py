"""
Astro external-tree board/variant TOML deep-merge (docs/08 §4).

Consumes the ordered layer list from build/lib/layers.py and produces the
merged, validated board (or variant) config as JSON, exactly as config.py does
for the single-file case — but folding in every layer that contributes a
fragment, in merge order.

Merge rules (docs/08 §4, "TOML (board/variant)"):
    * deep-merge per table (nested tables merge recursively);
    * scalars: LAST writer wins (later layer overrides earlier);
    * lists: REPLACE, not append (a tree that wants to extend e.g.
      config_fragments restates the whole list) — the ONE exception is
      [packages].install, which ACCUMULATES (concatenate + dedupe).

Which layers contribute, in array (merge) order:
    board   : each tree layer's boards/<board>/board.toml (ascending priority),
              then the resolved board layer's board.toml.
    variant : each tree layer's variants/<variant>.toml (ascending priority),
              then the resolved variant layer file.

The resolved board/variant layer is simply the top of that stack, so the
no-tree case is a single fragment and the merged result is identical to
config.load_config on that one file (validated + defaulted the same way).

STATUS (M4 phase 0): wired. build-inner.sh loads the board/variant config
through this module (`merge.py board|variant`), so tree fragments deep-merge in
live builds; with no --external tree the fragment stack is a single file and the
result is byte-identical to config.load_config on it (regression-tested).

Usage:
    python3 build/lib/merge.py board   --board B --variant V [--external P ...]
    python3 build/lib/merge.py variant --board B --variant V [--external P ...]
"""

import argparse
import json
import sys
import tomllib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import config as _config  # noqa: E402
import layers as _layers  # noqa: E402

ConfigError = _config.ConfigError

# The single list field that accumulates across layers instead of replacing.
_ACCUMULATE = {("packages", "install")}


def deep_merge(base, overlay, path=()):
    """Deep-merge `overlay` onto `base` per docs/08 §4. Returns a new dict.

    Tables merge recursively; scalars last-wins; lists replace — except the
    fields in _ACCUMULATE, which concatenate + dedupe (first occurrence kept).
    """
    result = dict(base)
    for key, ov in overlay.items():
        here = path + (key,)
        if key in result and isinstance(result[key], dict) and isinstance(ov, dict):
            result[key] = deep_merge(result[key], ov, here)
        elif here in _ACCUMULATE and isinstance(result.get(key), list) and isinstance(ov, list):
            merged = list(result[key])
            seen = set(merged)
            for item in ov:
                if item not in seen:
                    merged.append(item)
                    seen.add(item)
            result[key] = merged
        else:
            result[key] = ov
    return result


def _load_toml(path):
    with open(path, "rb") as f:
        return tomllib.load(f)


def _board_fragments(layer_list, board):
    """Board.toml fragment paths in merge order (tree providers, then board)."""
    frags = []
    board_dir = None
    for layer in layer_list:
        if layer["kind"] == "tree":
            cand = Path(layer["path"]) / "boards" / board / "board.toml"
            if cand.is_file():
                frags.append(str(cand))
        elif layer["kind"] == "board":
            board_dir = layer["path"]
    board_toml = str(Path(board_dir) / "board.toml")
    # The resolved board layer is authoritative + last; avoid double-adding it
    # if a tree provider IS the resolved board dir.
    frags = [f for f in frags if f != board_toml]
    frags.append(board_toml)
    return frags


def _variant_fragments(layer_list, variant):
    """Variant .toml fragment paths in merge order (tree providers, then variant)."""
    frags = []
    variant_file = None
    for layer in layer_list:
        if layer["kind"] == "tree":
            cand = Path(layer["path"]) / "variants" / f"{variant}.toml"
            if cand.is_file():
                frags.append(str(cand))
        elif layer["kind"] == "variant":
            variant_file = layer["path"]
    frags = [f for f in frags if f != variant_file]
    frags.append(variant_file)
    return frags


def deep_merge_board_variant(layer_list, kind, board, variant):
    """Merge + validate the board or variant config across layers (docs/08 §4).

    `kind` is "board" or "variant". Returns the validated, default-applied
    config dict — the same shape config.load_config returns, so downstream
    consumers are unchanged.
    """
    if kind == "board":
        frags = _board_fragments(layer_list, board)
    elif kind == "variant":
        frags = _variant_fragments(layer_list, variant)
    else:
        raise ConfigError(f"deep_merge_board_variant: unknown kind '{kind}'")

    merged = {}
    for frag in frags:
        merged = deep_merge(merged, _load_toml(frag))

    # `merged` is the PRE-defaults deep-merge of every contributing fragment.
    # Run the SAME per-type finalize pipeline config.load_config uses on a single
    # file (validate -> apply_defaults -> derive), single-sourced in config.py so
    # the layered path stays byte-identical to the single-file loader — including
    # the qcow2 auto-add, which depends on seeing the pre-defaults dict (a tree
    # that authors [qemu] gets qcow2; rpi4, which never does, must not). The
    # authoritative file path (board-id derivation, error messages, the variant
    # rootfs-type stem) is the resolved top-of-stack fragment.
    top = frags[-1]
    if kind == "board":
        merged = _config.finalize_board_config(merged, top)
    else:
        merged = _config.finalize_variant_config(merged, top)
    return merged


def main():
    parser = argparse.ArgumentParser(
        description="Astro board/variant deep-merge across external-tree layers"
    )
    parser.add_argument("kind", choices=["board", "variant"])
    parser.add_argument("--board", required=True)
    parser.add_argument("--variant", required=True)
    parser.add_argument("--external", action="append", default=[])
    args = parser.parse_args()

    try:
        layer_list = _layers.build_layers(args.board, args.variant, args.external)
        cfg = deep_merge_board_variant(layer_list, args.kind, args.board, args.variant)
    except ConfigError as e:
        print(str(e), file=sys.stderr)
        sys.exit(1)

    print(json.dumps(cfg, indent=2))


if __name__ == "__main__":
    main()
