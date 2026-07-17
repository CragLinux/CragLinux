"""
Astro Linux configuration loader and validator.

Loads TOML board/variant configs, validates against schemas,
and exports as JSON or shell-sourceable environment variables.

Usage:
    python3 build/lib/config.py board boards/rpi4/board.toml
    python3 build/lib/config.py variant boards/rpi4/variants/dev.toml
    python3 build/lib/config.py board boards/rpi4/board.toml --format=env
"""

import json
import sys
import tomllib
from pathlib import Path

# Add parent to path so we can import schema
sys.path.insert(0, str(Path(__file__).parent))
from schema import BOARD_SCHEMA, BOARD_CONDITIONAL_RULES, VARIANT_SCHEMA, USER_ENTRY_SCHEMA


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
                result_section[field_name] = field_schema["default"]

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


def load_config(config_path, config_type):
    """Load, validate, and return a config with defaults applied."""
    path = Path(config_path)
    if not path.exists():
        raise ConfigError(f"Config file not found: {config_path}")

    with open(path, "rb") as f:
        config = tomllib.load(f)

    schema = BOARD_SCHEMA if config_type == "board" else VARIANT_SCHEMA
    validate_config(config, schema, config_path)
    return apply_defaults(config, schema)


def main():
    import argparse

    parser = argparse.ArgumentParser(description="Astro Linux config loader")
    parser.add_argument("type", choices=["board", "variant"], help="Config type")
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
