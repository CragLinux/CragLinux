"""
Astro external-tree discovery and layer ordering (docs/08 §2, §4).

THE CONTRACT. This module is the single source of truth for the order in which
every build stage composes its inputs. Given the board, the variant, and zero
or more external trees, it emits the **ordered layer list** — a JSON array that
the whole build (shell and Python consumers alike) walks in order.

Canonical merge order (docs/08 §4):

    boards/common (core)  ->  external trees (ASCENDING priority)  ->  board  ->  variant

The array is ALREADY in final merge order. Consumers MUST preserve array order
and MUST NOT re-sort:

    * array[0] is applied FIRST  = lowest precedence
    * array[-1] is applied LAST  = wins (last-writer-wins overlays, scalars, …)

Layer object shape (every element):

    {
      "kind":     "core" | "tree" | "board" | "variant",
      "name":     "<identifier>",   # common | tree.name | board id | variant id
      "path":     "<absolute path>",# see per-kind meaning below
      "priority": <int>             # tree.toml priority; 0 for non-tree layers
    }

`path` per kind:
    core     -> <astro-root>/boards/common          (directory)
    tree     -> the tree root (the dir holding tree.toml)
    board    -> the resolved board directory (the dir holding board.toml)
    variant  -> the resolved variant .toml FILE

Because the array carries the resolved board/variant, downstream shell needs no
second resolver:
    board_dir    = (.[] | select(.kind=="board")).path
    variant_file = (.[] | select(.kind=="variant")).path

Tree band ordering (docs/08 §4): ascending tree.toml `priority` (lower merges
first); ties broken by input order (ASTRO_EXTERNAL entries first in colon order,
then --external in CLI order), then by path. `priority` is informational on the
emitted layers — the array order is authoritative.

Board / variant resolution (docs/08 §2, §4):
    * a board may be provided by a tree (<tree>/boards/<board>/board.toml) or
      in-tree (<astro-root>/boards/<board>/board.toml). When several trees
      provide it, the HIGHEST-priority tree wins (tie -> later input order); a
      tree provider outranks the in-tree board. Trees may also LAYER onto the
      resolved board (fragments/overlay/hooks under <tree>/boards/<board>/) —
      that finer merge is the deep_merge / merge_* consumers' job (they walk
      this same layer list); resolution here only picks the primary board dir.
    * a variant may be provided by a tree (<tree>/variants/<variant>.toml) or
      alongside the resolved board (<board_dir>/variants/<variant>.toml), with
      the same highest-priority-tree-wins rule.

Usage:
    python3 build/lib/layers.py --board qemu-armv7 --variant dev
    python3 build/lib/layers.py --board my-gw --variant prod \\
        --external /trees/acme-common --external /trees/acme-product

$ASTRO_EXTERNAL (colon-separated) is honored in addition to --external.
"""

import argparse
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import config as _config  # noqa: E402  (path insert must precede import)

ConfigError = _config.ConfigError


def astro_root():
    """Repo root = build/lib/layers.py -> parents[2]."""
    return Path(__file__).resolve().parents[2]


def _collect_externals(cli_externals):
    """Ordered, de-duplicated external tree paths.

    Order: $ASTRO_EXTERNAL entries (colon-separated) first, then --external in
    CLI order. De-dup is by resolved absolute path, keeping first occurrence
    (so the earliest input index — the tie-break key — is stable).
    """
    raw = []
    env = os.environ.get("ASTRO_EXTERNAL", "")
    if env:
        raw.extend(p for p in env.split(":") if p)
    raw.extend(cli_externals or [])

    seen = set()
    ordered = []
    for p in raw:
        rp = str(Path(p).resolve())
        if rp in seen:
            continue
        seen.add(rp)
        ordered.append(rp)
    return ordered


def _load_tree(path):
    """Validate a tree root and return (name, priority). Fails fast (docs/08 §2).

    The version gate (astro_min/astro_max) is enforced inside config.load_config.
    """
    root = Path(path)
    tree_toml = root / "tree.toml"
    if not root.is_dir():
        raise ConfigError(f"External tree not found: {path}")
    if not tree_toml.is_file():
        raise ConfigError(
            f"External tree missing tree.toml: {path}\n"
            "  Every external tree must declare identity in tree.toml "
            "(docs/08 §2)."
        )
    cfg = _config.load_config(str(tree_toml), "tree")["tree"]
    return cfg["name"], cfg["priority"]


def build_layers(board, variant, cli_externals):
    """Produce the ordered layer list (see module docstring)."""
    root = astro_root()

    # --- tree band: ascending priority, ties by input order then path --------
    tree_layers = []
    for order, path in enumerate(_collect_externals(cli_externals)):
        name, priority = _load_tree(path)
        tree_layers.append({
            "kind": "tree",
            "name": name,
            "path": path,
            "priority": priority,
            "_order": order,
        })
    tree_layers.sort(key=lambda t: (t["priority"], t["_order"], t["path"]))

    # --- board resolution: highest-priority providing tree, else in-tree -----
    board_dir = _resolve_board_dir(root, board, tree_layers)
    # --- variant resolution: same rule, else alongside the resolved board ----
    variant_file = _resolve_variant_file(board_dir, board, variant, tree_layers)

    layers = [{
        "kind": "core",
        "name": "common",
        "path": str(root / "boards" / "common"),
        "priority": 0,
    }]
    for t in tree_layers:
        layers.append({k: t[k] for k in ("kind", "name", "path", "priority")})
    layers.append({
        "kind": "board",
        "name": board,
        "path": board_dir,
        "priority": 0,
    })
    layers.append({
        "kind": "variant",
        "name": variant,
        "path": variant_file,
        "priority": 0,
    })
    return layers


def _resolve_board_dir(root, board, tree_layers):
    # Highest priority wins; tie -> later input order (_order). A tree provider
    # outranks the in-tree board.
    providers = [
        t for t in tree_layers
        if (Path(t["path"]) / "boards" / board / "board.toml").is_file()
    ]
    if providers:
        best = max(providers, key=lambda t: (t["priority"], t["_order"]))
        return str(Path(best["path"]) / "boards" / board)

    in_tree = root / "boards" / board
    if (in_tree / "board.toml").is_file():
        return str(in_tree)

    raise ConfigError(f"Board not found: {board}")


def _resolve_variant_file(board_dir, board, variant, tree_layers):
    providers = [
        t for t in tree_layers
        if (Path(t["path"]) / "variants" / f"{variant}.toml").is_file()
    ]
    if providers:
        best = max(providers, key=lambda t: (t["priority"], t["_order"]))
        return str(Path(best["path"]) / "variants" / f"{variant}.toml")

    in_board = Path(board_dir) / "variants" / f"{variant}.toml"
    if in_board.is_file():
        return str(in_board)

    raise ConfigError(
        f"Variant not found: {variant} "
        f"(looked in tree variants/ and {board_dir}/variants/)"
    )


def main():
    parser = argparse.ArgumentParser(
        description="Astro external-tree layer ordering (docs/08 §4)"
    )
    parser.add_argument("--board", required=True)
    parser.add_argument("--variant", required=True)
    parser.add_argument(
        "--external", action="append", default=[],
        help="External tree root (repeatable). $ASTRO_EXTERNAL is also honored.",
    )
    args = parser.parse_args()

    try:
        layers = build_layers(args.board, args.variant, args.external)
    except ConfigError as e:
        print(str(e), file=sys.stderr)
        sys.exit(1)

    print(json.dumps(layers, indent=2))


if __name__ == "__main__":
    main()
