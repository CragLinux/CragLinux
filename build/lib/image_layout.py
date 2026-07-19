"""
Astro image-stage partition layout calculator (docs/04 §2, AD-007).

Pure computation: board [partitions] sizes in -> byte-exact offsets, an
sfdisk script, and per-partition population parameters out. No I/O beyond
stdin/stdout so it is trivially unit-testable:

    echo "$BOARD_CONFIG_JSON" | python3 build/lib/image_layout.py

emits JSON:

    {
      "sector_size": 512,
      "total_bytes": ...,
      "sfdisk_script": "label: gpt\\n...",
      "partitions": [
        {"name": "esp", "offset": ..., "size": ..., "type": "...",
         "uuid": "..." | null},
        ... (esp, bootenv, boot.A, rootfs.A, boot.B, rootfs.B, data)
      ]
    }

Determinism: when SOURCE_DATE_EPOCH is set in the environment, the disk
GUID and every partition GUID are derived as UUIDv5 hashes of
(board-name, partition-name, SOURCE_DATE_EPOCH) so identical inputs give
identical GPTs; otherwise sfdisk picks random GUIDs.

The AD-007 canonical order and PARTLABELs are fixed here:
    1 esp  2 bootenv  3 boot.A  4 rootfs.A  5 boot.B  6 rootfs.B  7 data
"""

import json
import os
import re
import sys
import uuid

# GPT partition type GUIDs
TYPE_ESP = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
TYPE_LINUX = "0FC63DAF-8483-4772-8E79-3D69D8477DE4"

MIB = 1024 * 1024
ALIGN = MIB  # 1 MiB partition alignment
SECTOR = 512

# UUIDv5 namespace for deterministic GUIDs (random fixed value, Astro-local)
ASTRO_UUID_NS = uuid.UUID("5aa50a25-66cb-45b7-8b4f-8b7a2e4d95d1")

SIZE_RE = re.compile(r"^([1-9][0-9]*)([KMG])$")
MULT = {"K": 1024, "M": 1024**2, "G": 1024**3}


def size_to_bytes(s):
    m = SIZE_RE.match(s)
    if not m:
        raise ValueError(f"invalid partition size: {s!r}")
    return int(m.group(1)) * MULT[m.group(2)]


def align_up(n, align=ALIGN):
    return (n + align - 1) // align * align


def compute_layout(board_config, source_date_epoch=None):
    """Compute the AD-007 layout from a board config dict.

    Returns the dict described in the module docstring.
    """
    parts_cfg = board_config.get("partitions", {})
    board_id = board_config.get("board", {}).get("name", "astro")

    esp = size_to_bytes(parts_cfg.get("esp_size", "64M"))
    bootenv = size_to_bytes(parts_cfg.get("bootenv_size", "1M"))
    boot = size_to_bytes(parts_cfg.get("boot_size", "64M"))
    rootfs = size_to_bytes(parts_cfg.get("rootfs_size", "512M"))
    data = size_to_bytes(parts_cfg.get("data_min_size", "64M"))

    order = [
        ("esp", esp, TYPE_ESP),
        ("bootenv", bootenv, TYPE_LINUX),
        ("boot.A", boot, TYPE_LINUX),
        ("rootfs.A", rootfs, TYPE_LINUX),
        ("boot.B", boot, TYPE_LINUX),
        ("rootfs.B", rootfs, TYPE_LINUX),
        ("data", data, TYPE_LINUX),
    ]

    def det_uuid(name):
        if source_date_epoch is None:
            return None
        return str(
            uuid.uuid5(ASTRO_UUID_NS, f"{board_id}/{name}/{source_date_epoch}")
        ).upper()

    partitions = []
    offset = ALIGN  # first usable aligned offset; GPT header/entries fit below
    for name, size, type_guid in order:
        size = align_up(size)
        partitions.append(
            {
                "name": name,
                "offset": offset,
                "size": size,
                "type": type_guid,
                "uuid": det_uuid(name),
            }
        )
        offset += size

    # Backup GPT lives at the end of the disk; 1 MiB of slack covers the
    # 33-sector backup structure with alignment to spare.
    total_bytes = offset + MIB

    lines = ["label: gpt", f"sector-size: {SECTOR}"]
    disk_guid = det_uuid("disk")
    if disk_guid:
        lines.append(f"label-id: {disk_guid}")
    lines.append("")
    for p in partitions:
        fields = [
            f"start={p['offset'] // SECTOR}",
            f"size={p['size'] // SECTOR}",
            f"type={p['type']}",
            f'name="{p["name"]}"',
        ]
        if p["uuid"]:
            fields.append(f"uuid={p['uuid']}")
        lines.append(", ".join(fields))
    sfdisk_script = "\n".join(lines) + "\n"

    return {
        "sector_size": SECTOR,
        "total_bytes": total_bytes,
        "sfdisk_script": sfdisk_script,
        "partitions": partitions,
    }


def main():
    board_config = json.load(sys.stdin)
    sde = os.environ.get("SOURCE_DATE_EPOCH")
    layout = compute_layout(board_config, sde)
    json.dump(layout, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
