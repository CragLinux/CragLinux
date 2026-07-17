"""
Astro Linux board and variant configuration schemas.

Defines the expected structure, types, and constraints for board.toml
and variant.toml configuration files.
"""

BOARD_SCHEMA = {
    "board": {
        "_required_section": True,
        "name": {"type": str, "required": True},
        "arch": {
            "type": str,
            "required": True,
            "choices": ["aarch64", "armv7hf", "x86_64", "riscv64"],
        },
    },
    "kernel": {
        "_required_section": True,
        "version": {"type": str, "required": True},
        "source": {
            "type": str,
            "required": False,
            "default": "upstream",
            "choices": ["upstream", "git"],
        },
        "git_repo": {"type": str, "required": False},
        "git_ref": {"type": str, "required": False},
        "defconfig": {"type": str, "required": False, "default": "defconfig"},
        "config_fragments": {"type": list, "required": False, "default": []},
        "cmdline": {"type": str, "required": True},
        "dtb": {"type": str, "required": False},
        "lto": {
            "type": str,
            "required": False,
            "default": "thin",
            "choices": ["none", "thin", "full"],
        },
        "clang_patches": {"type": bool, "required": False, "default": True},
    },
    "bootloader": {
        "_required_section": True,
        "type": {
            "type": str,
            "required": True,
            "choices": ["u-boot", "rpi-boot", "direct", "none"],
        },
        "u_boot_version": {"type": str, "required": False},
        "u_boot_defconfig": {"type": str, "required": False},
        "u_boot_source": {
            "type": str,
            "required": False,
            "default": "upstream",
            "choices": ["upstream", "git"],
        },
        "u_boot_compiler": {
            "type": str,
            "required": False,
            "default": "clang",
            "choices": ["clang", "gcc"],
        },
        "u_boot_binary": {"type": str, "required": False, "default": "u-boot.bin"},
        "u_boot_offset": {"type": int, "required": False},
        "atf_platform": {"type": str, "required": False},
        "atf_version": {"type": str, "required": False},
    },
    "disk": {
        "_required_section": True,
        "boot_size": {"type": str, "required": True},
        "root_size": {"type": str, "required": True},
        "boot_fs": {
            "type": str,
            "required": False,
            "default": "vfat",
            "choices": ["vfat", "ext4"],
        },
        "root_fs": {
            "type": str,
            "required": False,
            "default": "ext4",
            "choices": ["ext4", "f2fs", "btrfs"],
        },
    },
    "firmware": {
        "_required_section": False,
        "packages": {"type": list, "required": False, "default": []},
    },
    "console": {
        "_required_section": False,
        "device": {"type": str, "required": False, "default": "ttyS0"},
        "baud": {"type": int, "required": False, "default": 115200},
    },
    "qemu": {
        "_required_section": False,
        "machine": {"type": str, "required": False, "default": "virt"},
        "cpu": {"type": str, "required": False},
        "memory": {"type": str, "required": False, "default": "1G"},
        "extra_args": {"type": str, "required": False, "default": ""},
    },
}

# Conditional validation rules: (section.field == value) → require these fields
BOARD_CONDITIONAL_RULES = [
    {
        "when": ("kernel", "source", "git"),
        "require": [("kernel", "git_repo"), ("kernel", "git_ref")],
    },
]

VARIANT_SCHEMA = {
    "variant": {
        "_required_section": True,
        "name": {"type": str, "required": True},
        "description": {"type": str, "required": False, "default": ""},
    },
    "packages": {
        "_required_section": False,
        "install": {"type": list, "required": False, "default": []},
        # Packages-mode: "source" builds the full manifest from the pinned
        # cports templates (release/nightly path); "binary" builds only the
        # Astro-touched set and consumes Chimera's signed binary repo for the
        # rest (dev/PR path). Overridable per-invocation via
        # --packages-mode=binary|source.
        "mode": {
            "type": str,
            "required": False,
            "default": "source",
            "choices": ["source", "binary"],
        },
    },
    "services": {
        "_required_section": False,
        "enable": {"type": list, "required": False, "default": []},
        "disable": {"type": list, "required": False, "default": []},
    },
    "users": {
        "_required_section": False,
        "create": {"type": list, "required": False, "default": []},
    },
    "kernel": {
        "_required_section": False,
        "cmdline_append": {"type": str, "required": False, "default": ""},
    },
}

# User entry schema (for items in users.create list)
USER_ENTRY_SCHEMA = {
    "name": {"type": str, "required": True},
    "uid": {"type": int, "required": True},
    "groups": {"type": list, "required": False, "default": []},
    "shell": {"type": str, "required": False, "default": "/bin/sh"},
}
