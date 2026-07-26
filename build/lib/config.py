"""
Astro Linux configuration loader and validator.

Loads TOML board/variant configs, validates against schemas,
and exports as JSON or shell-sourceable environment variables.

Usage:
    python3 build/lib/config.py board boards/rpi4/board.toml
    python3 build/lib/config.py variant boards/rpi4/variants/dev.toml
    python3 build/lib/config.py board boards/rpi4/board.toml --format=env
"""

import copy
import json
import os
import re
import sys
import tomllib
from pathlib import Path

# Add parent to path so we can import schema
sys.path.insert(0, str(Path(__file__).parent))
from schema import (
    BOARD_SCHEMA,
    BOARD_CONDITIONAL_RULES,
    DEPRECATED_DISK_SCHEMA,
    RAUC_BOOTLOADER_FOR_TYPE,
    TREE_SCHEMA,
    VARIANT_SCHEMA,
    USER_ENTRY_SCHEMA,
)

# The dev/unversioned sentinel (docs/10 §2 — the same fallback image.sh,
# bundle.sh and os-release stamping use for ASTRO_VERSION). A working-tree
# build reports this; it is treated as "not a release" and bypasses the
# external-tree version gate (see check_astro_version).
DEV_VERSION = "0.0.0-dev"

# Partition sizes: integer + K/M/G suffix (docs/04 §2)
SIZE_RE = re.compile(r"^[1-9][0-9]*[KMG]$")
# root= anywhere in a kernel command line (start or after whitespace)
ROOT_ARG_RE = re.compile(r"(^|\s)root=")


class ConfigError(Exception):
    pass


def validate_field(section_name, field_name, value, field_schema):
    """Validate a single field against its schema."""
    errors = []
    expected_type = field_schema["type"]

    if not isinstance(value, expected_type):
        errors.append(
            f"  [{section_name}].{field_name}: expected {expected_type.__name__}, "
            f"got {type(value).__name__}"
        )
        return errors

    if "choices" in field_schema and value not in field_schema["choices"]:
        errors.append(
            f"  [{section_name}].{field_name}: '{value}' not in "
            f"allowed values {field_schema['choices']}"
        )

    # Per-item choices for list fields (e.g. [image].formats)
    if "item_choices" in field_schema and isinstance(value, list):
        for item in value:
            if item not in field_schema["item_choices"]:
                errors.append(
                    f"  [{section_name}].{field_name}: '{item}' not in "
                    f"allowed values {field_schema['item_choices']}"
                )

    return errors


def validate_user_entry(entry, index):
    """Validate a single user entry in users.create."""
    errors = []
    if not isinstance(entry, dict):
        errors.append(f"  [users].create[{index}]: expected table, got {type(entry).__name__}")
        return errors

    for field_name, field_schema in USER_ENTRY_SCHEMA.items():
        if field_name in entry:
            errors.extend(validate_field("users.create", field_name, entry[field_name], field_schema))
        elif field_schema["required"]:
            errors.append(f"  [users].create[{index}]: missing required field '{field_name}'")

    unknown = set(entry.keys()) - set(USER_ENTRY_SCHEMA.keys())
    for key in sorted(unknown):
        errors.append(f"  [users].create[{index}]: unknown field '{key}'")

    return errors


def validate_config(config, schema, config_path):
    """Validate a parsed TOML config against a schema."""
    errors = []

    # Check for unknown top-level sections
    known_sections = set(schema.keys())
    for section in config:
        if section not in known_sections:
            errors.append(f"  Unknown section: [{section}]")

    # Validate each section
    for section_name, section_schema in schema.items():
        is_required = section_schema.get("_required_section", False)

        if section_name not in config:
            if is_required:
                errors.append(f"  Missing required section: [{section_name}]")
            continue

        section_data = config[section_name]
        if not isinstance(section_data, dict):
            errors.append(f"  [{section_name}]: expected table, got {type(section_data).__name__}")
            continue

        # Check fields in this section
        for field_name, field_schema in section_schema.items():
            if field_name.startswith("_"):
                continue

            if field_name in section_data:
                value = section_data[field_name]
                errors.extend(validate_field(section_name, field_name, value, field_schema))

                # Special validation for users.create entries
                if section_name == "users" and field_name == "create" and isinstance(value, list):
                    for i, entry in enumerate(value):
                        errors.extend(validate_user_entry(entry, i))
            elif field_schema["required"]:
                errors.append(f"  [{section_name}]: missing required field '{field_name}'")

        # Check for unknown fields in section
        known_fields = {k for k in section_schema if not k.startswith("_")}
        for field in section_data:
            if field not in known_fields:
                errors.append(f"  [{section_name}]: unknown field '{field}'")

    # root= must never appear in a configured kernel command line: the image
    # stage owns root=PARTLABEL=... per A/B slot (docs/03 §6). run-qemu.sh
    # injects root= itself for the direct-boot developer flow.
    if schema is BOARD_SCHEMA:
        cmdline = config.get("kernel", {}).get("cmdline", "")
        if isinstance(cmdline, str) and ROOT_ARG_RE.search(cmdline):
            errors.append(
                "  [kernel].cmdline: must not contain 'root=' — the image "
                "stage sets root= per A/B slot (docs/03 §6); direct QEMU "
                "boots get root= from run-qemu.sh"
            )
    else:
        cmdline_append = config.get("kernel", {}).get("cmdline_append", "")
        if isinstance(cmdline_append, str) and ROOT_ARG_RE.search(cmdline_append):
            errors.append(
                "  [kernel].cmdline_append: must not contain 'root=' — the "
                "image stage sets root= per A/B slot (docs/03 §6)"
            )

    # Partition sizes must be <int><K|M|G>
    if schema is BOARD_SCHEMA:
        for field, value in config.get("partitions", {}).items():
            if field.endswith("_size") and isinstance(value, str) and not SIZE_RE.match(value):
                errors.append(
                    f"  [partitions].{field}: '{value}' is not a valid size "
                    "(expected e.g. '64M', '1G')"
                )

    # Conditional validation (e.g., git_repo required when source="git")
    if schema is BOARD_SCHEMA:
        for rule in BOARD_CONDITIONAL_RULES:
            section, field, value = rule["when"]
            if config.get(section, {}).get(field) == value:
                for req_section, req_field in rule["require"]:
                    if not config.get(req_section, {}).get(req_field):
                        errors.append(
                            f"  [{req_section}].{req_field}: required when "
                            f"[{section}].{field} = \"{value}\""
                        )

    # Migration hint for removed fields
    if "kernel" in config and "package" in config.get("kernel", {}):
        errors.append(
            "  [kernel]: unknown field 'package'\n"
            "    Hint: kernel.package has been replaced with kernel.version.\n"
            "    See docs/BOARDS.md for the new kernel source build configuration."
        )

    if errors:
        raise ConfigError(
            f"Configuration errors in {config_path}:\n" + "\n".join(errors)
        )

    return config


def apply_defaults(config, schema):
    """Apply default values for missing optional fields."""
    result = {}
    for section_name, section_schema in schema.items():
        section_data = config.get(section_name, {})
        if not isinstance(section_data, dict):
            continue

        result_section = dict(section_data)
        for field_name, field_schema in section_schema.items():
            if field_name.startswith("_"):
                continue
            if field_name not in result_section and "default" in field_schema:
                # deepcopy so mutable defaults (e.g. [image].formats == ["img"])
                # are never shared with the schema. derive_board_defaults
                # appends to formats in place; without the copy that would
                # mutate BOARD_SCHEMA and poison every later board processed in
                # the same interpreter (the external-tree merge engine loads
                # many boards per run — one CLI process no longer isolates it).
                result_section[field_name] = copy.deepcopy(field_schema["default"])

        result[section_name] = result_section

    return result


def flatten_to_env(config, prefix=""):
    """Flatten a nested config dict into KEY=VALUE environment variables."""
    lines = []
    for section_name, section_data in sorted(config.items()):
        if not isinstance(section_data, dict):
            continue
        for field_name, value in sorted(section_data.items()):
            env_key = f"{section_name}_{field_name}".upper()
            if prefix:
                env_key = f"{prefix}_{env_key}"

            if isinstance(value, list):
                # Export lists as space-separated strings
                env_value = " ".join(str(v) for v in value)
            elif isinstance(value, bool):
                env_value = "true" if value else "false"
            else:
                env_value = str(value)

            # Shell-safe quoting
            env_value = env_value.replace("'", "'\\''")
            lines.append(f"{env_key}='{env_value}'")

    return "\n".join(lines)


def migrate_deprecated_disk(config, config_path):
    """DEPRECATED [disk] → [partitions] mapping (one release of grace).

    boot_size → partitions.boot_size, root_size → partitions.rootfs_size;
    boot_fs/root_fs are dropped (the AD-007 layout fixes the filesystems).
    Emits a loud warning on stderr. Remove after M2.
    """
    if "disk" not in config:
        return config
    if "partitions" in config:
        raise ConfigError(
            f"Configuration errors in {config_path}:\n"
            "  [disk] and [partitions] are both present — [disk] is "
            "deprecated; remove it and keep [partitions] (docs/03 §6)"
        )

    disk = config["disk"]
    errors = []
    if not isinstance(disk, dict):
        errors.append(f"  [disk]: expected table, got {type(disk).__name__}")
    else:
        for field_name, field_schema in DEPRECATED_DISK_SCHEMA.items():
            if field_name in disk:
                errors.extend(validate_field("disk", field_name, disk[field_name], field_schema))
            elif field_schema["required"]:
                errors.append(f"  [disk]: missing required field '{field_name}'")
        for field in set(disk) - set(DEPRECATED_DISK_SCHEMA):
            errors.append(f"  [disk]: unknown field '{field}'")
    if errors:
        raise ConfigError(f"Configuration errors in {config_path}:\n" + "\n".join(errors))

    print(
        f"WARNING: {config_path}: [disk] is DEPRECATED and will be removed "
        "after M2.\n"
        "         Replace it with the AD-007 [partitions] section "
        "(docs/03 §6, docs/04 §2).\n"
        f"         Mapping applied: boot_size={disk['boot_size']} -> "
        f"partitions.boot_size, root_size={disk['root_size']} -> "
        "partitions.rootfs_size;\n"
        "         boot_fs/root_fs are ignored (AD-007 fixes the "
        "filesystems per partition).",
        file=sys.stderr,
    )
    config = dict(config)
    del config["disk"]
    config["partitions"] = {
        "boot_size": disk["boot_size"],
        "rootfs_size": disk["root_size"],
    }
    return config


def derive_board_defaults(config, raw_config, config_path):
    """Post-defaults derivations + cross-section validation for boards.

    - [rauc].compatible defaults to "astro-<board-dir-name>"
    - [rauc].bootloader defaults from [bootloader].type and, when explicit,
      must be consistent with it (docs/03 §6)
    - [image].formats gains "qcow2" for boards that declare [qemu]
    """
    board_id = Path(config_path).resolve().parent.name

    rauc = config.setdefault("rauc", {})
    if not rauc.get("compatible"):
        rauc["compatible"] = f"astro-{board_id}"

    bl_type = config.get("bootloader", {}).get("type", "")
    expected = RAUC_BOOTLOADER_FOR_TYPE.get(bl_type)
    if not rauc.get("bootloader"):
        rauc["bootloader"] = expected or "uboot"
    elif expected and rauc["bootloader"] != expected:
        raise ConfigError(
            f"Configuration errors in {config_path}:\n"
            f"  [rauc].bootloader: '{rauc['bootloader']}' is inconsistent "
            f"with [bootloader].type = \"{bl_type}\" (expected '{expected}')"
        )

    # qcow2 auto-added for QEMU-capable boards ([qemu] present in the TOML;
    # apply_defaults materializes [qemu] for every board, so check the raw
    # config).
    if "qemu" in raw_config:
        formats = config.setdefault("image", {}).setdefault("formats", ["img"])
        if "qcow2" not in formats:
            formats.append("qcow2")

    return config


# ---------------------------------------------------------------------------
# Version comparison for the external-tree compatibility gate (docs/08 §2/§4)
#
# Algorithm (a faithful Python port of astrod/src/version.zig so the build-time
# gate and the on-device AD-021 update gate order versions identically):
#   1. Split off an optional suffix at the FIRST '-'. The base is compared as
#      '.'-separated segments; a segment pair is compared NUMERICALLY when both
#      are all-digits, otherwise bytewise (lexicographically). Missing trailing
#      segments count as "0", so "2026.10" == "2026.10.0" < "2026.10.1".
#   2. Equal bases: a version WITHOUT a suffix outranks one WITH a suffix
#      ("1.0.0" > "1.0.0-rc1", the semver pre-release rule); two suffixes
#      compare bytewise.
# Never raises: any string orders (garbage sorts lexicographically), so a
# malformed bound can only mis-order, never crash the build.
# ---------------------------------------------------------------------------


def _split_version(v):
    """Return (base, suffix) splitting at the first '-'; suffix is None if none."""
    idx = v.find("-")
    if idx == -1:
        return v, None
    return v[:idx], v[idx + 1:]


def _cmp(a, b):
    """Three-way compare of two scalars: -1, 0, or 1."""
    return (a > b) - (a < b)


def _cmp_segment(a, b):
    """Compare one dotted segment: numeric if both all-digits, else bytewise."""
    if a.isdigit() and b.isdigit():
        return _cmp(int(a), int(b))
    return _cmp(a, b)


def compare_versions(a, b):
    """Total order over version strings. Returns -1, 0, or 1 (a vs b)."""
    base_a, suffix_a = _split_version(a)
    base_b, suffix_b = _split_version(b)

    seg_a = base_a.split(".")
    seg_b = base_b.split(".")
    for i in range(max(len(seg_a), len(seg_b))):
        x = seg_a[i] if i < len(seg_a) else "0"
        y = seg_b[i] if i < len(seg_b) else "0"
        ord_ = _cmp_segment(x, y)
        if ord_ != 0:
            return ord_

    # Bases equal: no-suffix outranks any suffix; two suffixes are bytewise.
    if suffix_a is None and suffix_b is None:
        return 0
    if suffix_a is None:
        return 1
    if suffix_b is None:
        return -1
    return _cmp(suffix_a, suffix_b)


def astro_version():
    """The running Astro release version, from $ASTRO_VERSION (docs/10 §2).

    Falls back to the dev sentinel, exactly like image.sh/bundle.sh.
    """
    return os.environ.get("ASTRO_VERSION") or DEV_VERSION


def check_astro_version(version, astro_min, astro_max, tree_name, config_path):
    """Fail fast when the running Astro version is outside [min, max] (docs/08 §2).

    Bounds are inclusive; an empty bound means unbounded. A dev/unversioned
    build (version == DEV_VERSION) bypasses the gate: a working-tree build is
    not a release, and enforcing calver bounds against "0.0.0-dev" would
    spuriously fail every local build. A real calver release is enforced.
    """
    if version == DEV_VERSION:
        return
    if astro_min and compare_versions(version, astro_min) < 0:
        raise ConfigError(
            f"Configuration errors in {config_path}:\n"
            f"  [tree] '{tree_name}' requires Astro >= {astro_min}, "
            f"but this is Astro {version} (astro_min gate, docs/08 §2)"
        )
    if astro_max and compare_versions(version, astro_max) > 0:
        raise ConfigError(
            f"Configuration errors in {config_path}:\n"
            f"  [tree] '{tree_name}' requires Astro <= {astro_max}, "
            f"but this is Astro {version} (astro_max gate, docs/08 §2)"
        )


# ---------------------------------------------------------------------------
# Per-type finalize pipelines (validate + defaults + derivations).
#
# These take an ALREADY-PARSED dict — either a single parsed board.toml /
# variant .toml, or the pre-defaults deep-merge of several such fragments
# across external-tree layers (docs/08 §4) — and run the same
# validate/apply_defaults/derive steps on it. Single-sourcing the pipeline
# here keeps load_config (one file) and merge.py:deep_merge_board_variant
# (layered) behaviourally IDENTICAL; historically each inlined its own copy
# and they drifted.
#
# CONTRACT: `raw_config` MUST be the PRE-DEFAULTS dict. derive_board_defaults
# inspects it to decide whether [qemu] was actually authored (the qcow2
# auto-add). Passing a post-apply_defaults dict — where every optional section
# is materialised — would make that test always true and wrongly add "qcow2"
# to boards that never declared [qemu].
# ---------------------------------------------------------------------------


def finalize_board_config(raw_config, config_path):
    """Validate + default + derive a board config from a parsed (pre-defaults) dict."""
    config = migrate_deprecated_disk(raw_config, config_path)
    validate_config(config, BOARD_SCHEMA, config_path)
    config = apply_defaults(config, BOARD_SCHEMA)
    config = derive_board_defaults(config, raw_config, config_path)
    return config


def finalize_variant_config(raw_config, config_path):
    """Validate + default a variant config from a parsed (pre-defaults) dict.

    The [rootfs].type default is keyed on the variant id (the .toml stem):
    "prod" → squashfs (AD-004 read-only root), everything else → ext4.
    config_path is the resolved variant FILE, so its stem is the variant id.
    """
    validate_config(raw_config, VARIANT_SCHEMA, config_path)
    config = apply_defaults(raw_config, VARIANT_SCHEMA)
    if not config.setdefault("rootfs", {}).get("type"):
        variant_id = Path(config_path).stem
        config["rootfs"]["type"] = "squashfs" if variant_id == "prod" else "ext4"
    return config


def load_config(config_path, config_type):
    """Load, validate, and return a config with defaults applied."""
    path = Path(config_path)
    if not path.exists():
        raise ConfigError(f"Config file not found: {config_path}")

    with open(path, "rb") as f:
        raw_config = tomllib.load(f)

    if config_type == "board":
        config = finalize_board_config(raw_config, config_path)
    elif config_type == "tree":
        validate_config(raw_config, TREE_SCHEMA, config_path)
        config = apply_defaults(raw_config, TREE_SCHEMA)
        tree = config["tree"]
        check_astro_version(
            astro_version(), tree["astro_min"], tree["astro_max"],
            tree["name"], config_path,
        )
    else:
        config = finalize_variant_config(raw_config, config_path)
    return config


def main():
    import argparse

    parser = argparse.ArgumentParser(description="Astro Linux config loader")
    parser.add_argument("type", choices=["board", "variant", "tree"], help="Config type")
    parser.add_argument("path", help="Path to .toml config file")
    parser.add_argument(
        "--format",
        choices=["json", "env"],
        default="json",
        help="Output format (default: json)",
    )
    parser.add_argument(
        "--validate-only",
        action="store_true",
        help="Only validate, don't output",
    )
    args = parser.parse_args()

    try:
        config = load_config(args.path, args.type)
    except ConfigError as e:
        print(str(e), file=sys.stderr)
        sys.exit(1)

    if args.validate_only:
        print(f"OK: {args.path}", file=sys.stderr)
        sys.exit(0)

    if args.format == "json":
        print(json.dumps(config, indent=2))
    elif args.format == "env":
        print(flatten_to_env(config))


if __name__ == "__main__":
    main()
