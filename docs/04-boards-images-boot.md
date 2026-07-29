# 04 — Targets, Partitioning, and Boot

**Status:** Draft for review · **Owns decisions:** AD-006, AD-007, AD-008, AD-009 · **Read after:** [02-base-system.md](02-base-system.md)

---

## 1. Target matrix (v1)

| Board id | Arch | Machine | Bootloader path | Storage | Console |
|---|---|---|---|---|---|
| `qemu-x86_64` | x86_64 | QEMU q35 | OVMF (EFI) → GRUB | virtio-blk | ttyS0 |
| `qemu-aarch64` | aarch64 | QEMU virt | U-Boot (`-bios u-boot.bin`) | virtio-blk | ttyAMA0 |
| `qemu-armv7` | armv7hf | QEMU virt (cortex-a15) | U-Boot (`-bios u-boot.bin`) | virtio-blk | ttyAMA0 |
| `x86_64-efi` | x86_64 | generic EFI PC/gateway | firmware → GRUB | NVMe/SATA/eMMC | ttyS0 + fb |
| `rpi4`, `rpi5` | aarch64 | Raspberry Pi 4/CM4/5 | RPi firmware → U-Boot | SD/eMMC/USB | serial + HDMI |
| `beaglebone-black` | armv7hf | BeagleBone Black (AM335x) | ROM → SPL → U-Boot | SD/eMMC | ttyS0 |

Parked (schema keeps the arch enum entry; no boards, untested): `riscv64`.

**QEMU boards are first-class and boot through real bootloaders.** This is deliberate: RAUC slot switching lives in the bootloader, so only a real-bootloader boot exercises the A/B state machine. The prototype's `bootloader.type = "direct"` (direct kernel boot) is retained as a variant-level fast-iteration flag (`[qemu] direct_boot = true` in the dev workflow), never used by the update tests.

## 2. AD-007 — Partition layout

> **AD-007 — All targets use GPT with a canonical 7-partition layout addressed by `PARTLABEL`. Kernels live in per-slot boot partitions grouped to their rootfs via RAUC `parent=`.** *(Recommended)*

```
#  PARTLABEL   type     fs        size (default)   content
1  esp         ESP      vfat      64 MiB           bootloader only (GRUB EFI binary / U-Boot boot.scr stage)
2  bootenv     linux    raw/vfat  1 MiB            bootloader environment (grubenv / U-Boot redundant env)
3  boot.A      linux    vfat      64 MiB           kernel + DTBs + (rpi: cmdline fragment) for slot A
4  rootfs.A    linux    squashfs  ≥ 512 MiB        root filesystem A (read-only)
5  boot.B      linux    vfat      64 MiB           kernel + DTBs for slot B
6  rootfs.B    linux    squashfs  ≥ 512 MiB        root filesystem B
7  data        linux    ext4      rest of disk     /data (grown on first boot)
```

Sizes come from board TOML (`[partitions]`, replacing the prototype's `[disk]` — see [03-build-system.md §6](03-build-system.md)).

**Why this shape:**
- **PARTLABEL, never filesystem UUID**: A/B slot copies have identical fs UUIDs; RAUC explicitly warns against fs-UUID addressing. Kernel cmdline uses `root=PARTLABEL=rootfs.A`; RAUC `system.conf` uses `/dev/disk/by-partlabel/...`.
- **Kernel in per-slot boot partitions**: neither GRUB nor U-Boot needs to read squashfs; kernel+rootfs update as one grouped RAUC transaction (`parent=`), so a slot is never half-updated (new rootfs + old kernel).
- **Separate 1 MiB `bootenv`**: the slot-selection state (grubenv / U-Boot env, redundant A/B env copies for power-cut safety) must live *outside* the replaceable slots and outside the ESP (which may be updated someday).
- **One shared ESP in v1** holds only the bootloader itself; it is *not* RAUC-updated in v1 (bootloader self-update is deferred — [05-updates.md §8](05-updates.md)). The layout leaves room to move to RAUC's `boot-gpt-switch` atomic bootloader update later without repartitioning.
- **RPi note**: partition 1 doubles as the RPi firmware boot partition (config.txt, start*.elf, U-Boot binary); same layout otherwise.

## 3. AD-008 — x86_64 boot: GRUB on EFI

> **AD-008 — x86_64 targets boot via GRUB on a single ESP, with RAUC's GRUB backend using `grubenv` on the `bootenv` partition.** *(Recommended)*

Mechanics:
- ESP contains `EFI/BOOT/BOOTX64.EFI` (GRUB) and a static `grub.cfg` that loads the environment block from `bootenv` and implements RAUC's documented GRUB flow: variables `ORDER`, `A_TRY`/`B_TRY`, `A_OK`/`B_OK`; it picks the first slot in `ORDER` that is `OK` or has tries left, increments `TRY` before booting, and loads `/vmlinuz` from that slot's boot partition with `root=PARTLABEL=rootfs.<slot>`.
- Userspace side: `grub-editenv` writes the env block; RAUC's `grub` bootloader backend and `rauc-mark-good` reset `TRY`/set `OK` after a successful boot.
- `grub.cfg` is generated at image build from a template in `boards/x86_64-efi/`; it is deliberately static (no os-prober, no dynamic menus) and identical across devices.

**Documented alternative (secure-boot end-state):** dual ESPs + Unified Kernel Images + `efibootmgr` backend — cleaner for Secure Boot (one signed UKI per slot, no unsigned grubenv logic), but EFI variable handling is flaky on low-end firmware and it complicates QEMU/OVMF CI. It is the intended stage-2 shape when verified boot lands (AD-018, [09-security.md](09-security.md)); the partition layout already reserves nothing that blocks it (boot.A/boot.B become the per-slot ESPs).

## 4. AD-009 — ARM boot (aarch64 + armv7): U-Boot

> **AD-009 — ARM targets (aarch64 and armv7) boot via U-Boot with RAUC's `uboot` backend: `BOOT_ORDER`/`BOOT_<slot>_LEFT` variables in a redundant environment on `bootenv`, driven by a boot script.** *(Recommended)*

Mechanics:
- U-Boot built per board (existing prototype machinery: `u_boot_defconfig`, clang build, ATF where needed; RPi chain-loads U-Boot from the vendor firmware).
- **armv7 boards**: `qemu-armv7` runs QEMU `-M virt` with a cortex-a15 CPU, booting U-Boot via `-bios` exactly like `qemu-aarch64`; `beaglebone-black` (AM335x, board files exist in the clang-cross prototype) boots ROM → SPL → U-Boot and returns at the M5 hardware milestone ([11-roadmap-migration.md §1](11-roadmap-migration.md)). The boot-script/env logic below is identical across both ARM arches (`booti` vs `bootz` aside).
- Environment: **redundant env** (two copies, CRC, `CONFIG_SYS_REDUNDAND_ENVIRONMENT`) at fixed offsets in the `bootenv` partition; userspace access via `fw_setenv`/`fw_printenv` (libubootenv) with `/etc/fw_env.config` generated per board.
- Boot logic, compiled to `boot.scr` from this pseudocode (kept in `boards/common/uboot/boot.script.in`):

```
# defaults installed at image time: BOOT_ORDER="A B"; BOOT_A_LEFT=3; BOOT_B_LEFT=3
for slot in ${BOOT_ORDER}:
    if BOOT_${slot}_LEFT > 0:
        setenv BOOT_${slot}_LEFT (BOOT_${slot}_LEFT - 1); saveenv
        load kernel + dtb from PARTLABEL boot.${slot}
        setenv bootargs "console=… root=PARTLABEL=rootfs.${slot} rootflags=ro …"
        booti / bootm            # falls through on load failure → next slot
reset                            # nothing bootable: reset and retry
```

- RAUC's `uboot` backend maintains `BOOT_ORDER`/`BOOT_x_LEFT` on install; `rauc-mark-good` restores the booted slot's counter to 3.
- **Known subtlety (risk register, [11-roadmap-migration.md §4](11-roadmap-migration.md)):** `saveenv` before boot is a flash write on every boot; on SD-card products this is acceptable (1 MiB partition, wear-leveled media), but the design isolates it so an eMMC boot-partition variant can move the env later.

## 5. AD-006 — No initramfs (v1)

> **AD-006 — v1 images boot the squashfs root directly (`root=PARTLABEL=…`), with no initramfs. A tiny custom initramfs is specified—but not built—for the future verity stage.** *(Recommended)*

- Requirements this imposes: squashfs, its compression, and the board's storage driver are built into the kernel (`=y`); `rootwait` on removable media. Both are enforced by the shared `rauc.fragment` + per-board fragments.
- **Rejected: dracut** (Chimera's choice) — heavy, glibc/systemd-leaning assumptions, solves problems (LVM, LUKS prompts, hostonly detection) that a fixed-function appliance does not have.
- **Rejected: busybox initramfs** — Astro has no busybox, and importing one only for an initramfs contradicts the fixed-core principle.
- **Future (stage 2 of AD-018):** dm-verity-verified rootfs requires an initramfs to open the verity device. Specified shape: a single static binary (Zig or C, linked against the SDK's static musl) as `/init` doing exactly: mount devtmpfs → read verity root hash from kernel cmdline → `veritysetup open` (via libcryptsetup or direct dm ioctls) → `switch_root`. No shell, no modules, generated by the `image` stage. Kept out of v1 to avoid carrying unverified complexity.

## 6. Image artifacts

Per `(board, variant)` build, the `image`/`bundle` stages emit into `out/<board>/<variant>/`:

| Artifact | Description |
|---|---|
| `astro-<board>-<version>.img.zst` | full GPT disk image, **both slots populated identically**, `data` partition minimal (grows on first boot); flashable with `dd`/bmaptool |
| `astro-<board>-<version>.raucb` | RAUC verity bundle updating `boot` + `rootfs` slot group ([05-updates.md](05-updates.md)) |
| `astro-<board>-<version>.qcow2` | QEMU-native conversion of the .img (QEMU boards) |
| `astro-sdk-<arch>-<version>.tar.zst` | app SDK: cross clang wrappers + sysroot generated from this image's package set ([03-build-system.md §3](03-build-system.md)) |
| `manifest.json` | versions (astro, kernel, cports pin, external trees), artifact SHA512s, RAUC compatible string, apk world list |

### Image-stage implementation spec (new code — the prototype stub)

Prior art: chimera-live's `mkimage.sh`/`mkpart.sh`. Astro's implementation (in `build/stages/image`):

1. Compute the sfdisk script from board TOML `[partitions]` (sizes, PARTLABELs per AD-007) — pure function, unit-testable.
2. `truncate` sparse image file → `sfdisk` → attach loop device (`losetup -P`, inside the build container).
3. Format: `mkfs.vfat` (esp, boot.A/B), `mkfs.ext4 -L data` (data); write grubenv/U-Boot env defaults into `bootenv` (`grub-editenv create` / `mkenvimage`).
4. Populate esp (bootloader), boot.A and boot.B (kernel+dtb from the kernel stage), write the squashfs rootfs (already produced by the rootfs stage via `mksquashfs -comp zstd -noappend` with reproducibility flags) into both rootfs partitions with `dd`.
5. Detach, compress (`zstd -T0`), checksum, emit manifest.

Everything runs unprivileged where possible; loop-device work is why the container keeps its existing privilege requirements ([03-build-system.md §4](03-build-system.md)).

## 7. QEMU developer workflow

`astro run <board> [variant]` (evolution of the prototype's run scripts):

- Boots the qcow2 with the board's `[qemu]` settings; virtio-net with hostfwd for **API (2280→80 dev-LAN mode), SSH (2222→22, dev variant)**; serial on stdio.
- `--snapshot` for throwaway boots; `--fresh` to reset the qcow2 from the last build.
- **Worked example — full A/B update cycle locally (< 5 min), which is also the CI gate (AD-020):**

```
astro build qemu-x86_64 prod                # build image + bundle, version N
astro run qemu-x86_64 --detach              # boots slot A
astro test update qemu-x86_64 \
     --bundle out/…/astro-qemu-x86_64-N+1.raucb
# the test harness, via astrod API on the forwarded port:
#   GET /update/status         → assert booted=A, marked good
#   POST /update  (bundle)     → SSE progress to completion
#   POST /update/apply         → reboot
#   GET /update/status         → assert booted=B, pending mark-good…
#   …wait for boot-success     → assert marked good
# rollback leg:
#   install intentionally-broken bundle (test asset: rootfs whose
#   boot-success milestone can't be reached) → apply → observe
#   BOOT_x_LEFT exhaustion → assert device came back on slot B
```

## 8. Flashing and provisioning media

- v1: `dd`/`bmaptool copy` of the `.img.zst` to SD/USB/disk; RPi via SD; x86_64 via USB stick dd'd, or PXE later. Practical instructions, serial-console wiring, and the manual smoke checklist live in [12-hardware-bringup.md](12-hardware-bringup.md).
- Factory/eMMC mass-flashing (USB gadget, fastboot, etc.): out of scope v1; noted in the deferred register.
