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
            "choices": ["u-boot", "rpi-boot", "grub-efi", "direct", "none"],
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
    # AD-007 canonical GPT layout (docs/04 §2): esp / bootenv / boot.A /
    # rootfs.A / boot.B / rootfs.B / data. Sizes are strings like "64M"/"1G".
    # Defaults are the docs/04 §2 defaults, so the section may be omitted
    # entirely. Replaces the prototype's [disk] (see DEPRECATED_DISK_SCHEMA).
    "partitions": {
        "_required_section": False,
        "table": {
            "type": str,
            "required": False,
            "default": "gpt",
            "choices": ["gpt"],  # only value in v1
        },
        "esp_size": {"type": str, "required": False, "default": "64M"},
        "bootenv_size": {"type": str, "required": False, "default": "1M"},
        # Per-slot sizes (the layout has two boot and two rootfs partitions)
        "boot_size": {"type": str, "required": False, "default": "64M"},
        # Per slot; the image stage fails the build if the built squashfs
        # exceeds this (the rootfs stage already pre-checks on the prod path).
        "rootfs_size": {"type": str, "required": False, "default": "512M"},
        # Minimum size of /data in the image file; grown to fill the disk
        # on first boot.
        "data_min_size": {"type": str, "required": False, "default": "64M"},
    },
    # RAUC update configuration (docs/04, docs/05). Defaults are derived in
    # config.py: compatible -> "astro-<board-dir-name>", bootloader -> from
    # [bootloader].type (grub-efi -> "grub", everything else -> "uboot").
    "rauc": {
        "_required_section": False,
        "compatible": {"type": str, "required": False},
        "bootloader": {
            "type": str,
            "required": False,
            "choices": ["grub", "uboot"],
        },
    },
    # Image output formats (docs/03 §6). "qcow2" is auto-added by config.py
    # for boards that declare a [qemu] section.
    "image": {
        "_required_section": False,
        "formats": {
            "type": list,
            "required": False,
            "default": ["img"],
            "item_choices": ["img", "qcow2"],
        },
    },
    # astrod feature flags baked into image defaults (docs/03 §6).
    # Schema-only for now — consumed by later astrod/image work.
    "api": {
        "_required_section": False,
        "wifi": {"type": bool, "required": False, "default": True},
        "ap_provisioning": {"type": bool, "required": False, "default": True},
        "mdns": {"type": bool, "required": False, "default": True},
        "lan_exposure": {"type": bool, "required": False, "default": False},  # AD-025
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
        # EFI firmware image for full-image boots (grub-efi boards):
        # path to OVMF_CODE.fd inside the build container. U-Boot boards
        # don't set this — u-boot.bin from the bootloader stage is used
        # as -bios instead (docs/04 §1).
        "firmware": {"type": str, "required": False},
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

# [rauc].bootloader consistency with [bootloader].type (docs/03 §6).
# "direct"/"none" boards have no real bootloader yet; either backend is
# accepted there (qemu boards move to a real bootloader at M1).
RAUC_BOOTLOADER_FOR_TYPE = {
    "grub-efi": "grub",
    "u-boot": "uboot",
    "rpi-boot": "uboot",
    # "direct", "none": unconstrained (default "uboot" applied in config.py)
}

# DEPRECATED prototype [disk] section — accepted for one release of grace.
# config.py maps it to [partitions] (boot_size -> partitions.boot_size,
# root_size -> partitions.rootfs_size; boot_fs/root_fs are dropped — the
# AD-007 layout fixes filesystems: ESP/boot vfat, rootfs squashfs (prod) /
# ext4 (dev), data ext4) and emits a loud warning. Remove after M2.
DEPRECATED_DISK_SCHEMA = {
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
}

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
    # Rootfs filesystem type (docs/02 §3, AD-004): prod variants produce a
    # read-only squashfs, dev variants a read-write ext4. When omitted,
    # config.py defaults by variant id: "prod" -> squashfs, else ext4.
    "rootfs": {
        "_required_section": False,
        "type": {
            "type": str,
            "required": False,
            "choices": ["ext4", "squashfs"],
        },
    },
}

# External-tree identity schema (docs/08 §2). One [tree] section at the root
# of every external tree's tree.toml. `priority` orders trees among each
# other (lower merges first, higher wins — docs/08 §4). `astro_min`/`astro_max`
# are inclusive calver bounds ("2026.10"); an empty string means unbounded.
# The version gate is enforced in config.py (check_astro_version).
TREE_SCHEMA = {
    "tree": {
        "_required_section": True,
        "name": {"type": str, "required": True},
        "priority": {"type": int, "required": False, "default": 50},
        "astro_min": {"type": str, "required": False, "default": ""},
        "astro_max": {"type": str, "required": False, "default": ""},
    },
}

# User entry schema (for items in users.create list)
USER_ENTRY_SCHEMA = {
    "name": {"type": str, "required": True},
    "uid": {"type": int, "required": True},
    "groups": {"type": list, "required": False, "default": []},
    "shell": {"type": str, "required": False, "default": "/bin/sh"},
}
