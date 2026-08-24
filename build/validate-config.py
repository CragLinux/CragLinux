#!/usr/bin/env python3
"""
Validate Crag Linux board and variant configuration files.

Usage:
    build/validate-config.py boards/rpi4/board.toml
    build/validate-config.py boards/rpi4/variants/dev.toml --variant
    build/validate-config.py --all
"""

import argparse
import sys
from pathlib import Path

# Add lib to path
sys.path.insert(0, str(Path(__file__).parent / "lib"))
from config import load_config, ConfigError


def validate_file(path, config_type):
    """Validate a single config file. Returns True on success."""
    try:
        load_config(path, config_type)
        print(f"  OK: {path}")
        return True
    except ConfigError as e:
        print(f"  FAIL: {path}")
        print(str(e))
        return False


def validate_all(project_root):
    """Validate all board and variant configs in the project."""
    boards_dir = project_root / "boards"
    ok = True
    count = 0

    for board_dir in sorted(boards_dir.iterdir()):
        if not board_dir.is_dir() or board_dir.name == "common":
            continue

        board_toml = board_dir / "board.toml"
        if board_toml.exists():
            count += 1
            if not validate_file(board_toml, "board"):
                ok = False

        variants_dir = board_dir / "variants"
        if variants_dir.is_dir():
            for variant_file in sorted(variants_dir.glob("*.toml")):
                count += 1
                if not validate_file(variant_file, "variant"):
                    ok = False

    print(f"\nValidated {count} config files.")
    return ok


def main():
    parser = argparse.ArgumentParser(description="Validate Crag Linux configs")
    parser.add_argument("path", nargs="?", help="Path to .toml config file")
    parser.add_argument(
        "--variant",
        action="store_true",
        help="Treat file as variant config (default: auto-detect from path)",
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="Validate all configs in boards/",
    )
    args = parser.parse_args()

    if args.all:
        # Find project root (script is in build/)
        project_root = Path(__file__).parent.parent
        ok = validate_all(project_root)
        sys.exit(0 if ok else 1)

    if not args.path:
        parser.error("Either provide a config path or use --all")

    # Auto-detect type from path if --variant not specified
    if args.variant or "variants" in str(args.path):
        config_type = "variant"
    else:
        config_type = "board"

    try:
        load_config(args.path, config_type)
        print(f"OK: {args.path}")
    except ConfigError as e:
        print(str(e), file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
