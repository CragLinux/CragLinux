# 12 — Hardware Flashing and Bring-up (M5)

**Status:** Living document · **Owns decisions:** none · **Read after:** [04-boards-images-boot.md](04-boards-images-boot.md)

The practical companion to docs/04: how an image gets onto a device,
what the first boot looks like on the wire, and the manual release
smoke checklist the roadmap requires ([11 §1](11-roadmap-migration.md) M5).

---

## 1. Flashing (docs/04 §8: dd of the .img.zst)

Every board build emits `build/state/images/<board>-<variant>/crag-<board>-<ver>.img.zst`
(a compressed full-disk A/B image: GPT, esp, bootenv, boot.A/B,
rootfs.A/B, data). Flash = decompress onto the whole target disk:

```sh
# 1. Identify the SD/USB device NODE (not a partition). Triple-check:
lsblk -do NAME,SIZE,MODEL,TRAN

# 2. Write (destroys the device's contents):
zstdcat build/state/images/rpi4-dev/crag-rpi4-0.0.0-dev.img.zst \
    | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress

# 3. Let the kernel settle, then remove:
sync && sudo eject /dev/sdX
```

- The image is small (~1.5 G); the `data` partition grows to fill the
  card on first boot (data-mount.sh, same path the QEMU scratch
  exercises).
- `bmaptool` support (sparse-aware fast flashing) is a recorded
  follow-up — no `.bmap` is emitted yet.
- Verify a flash by re-reading: `sudo sfdisk -l /dev/sdX` should show
  the seven-partition GPT (and on rpi: `sudo fdisk -l /dev/sdX` shows
  the hybrid-MBR FAT32 entry first).

## 2. Serial console

USB-UART (3.3 V!) per board; 115200 8N1 everywhere. Attach with
`picocom -b 115200 /dev/ttyUSB0` (or minicom/screen).

| Board | Console | Wiring |
|---|---|---|
| `rpi4` | `ttyS0` (mini-UART, GPIO header) | pin 6 GND, pin 8 TXD (GPIO14) → adapter RX, pin 10 RXD (GPIO15) → adapter TX. `enable_uart=1` (fixes the VPU clock so the mini-UART baud is stable) + `uart_2ndstage=1` are baked into config.txt. The PL011 (`ttyAMA0`) is wired to Bluetooth — with no disable-bt overlay, the header UART is the mini-UART |
| `x86_64-efi` | `ttyS0` + framebuffer | motherboard/COM header or IPMI SoL; a screen also works |
| `beaglebone-black` | `ttyS0` (J1 header) | J1.1 GND, J1.4 RX, J1.5 TX |

**Dev images allow root console login with an empty password**
(35-dev-console-login.sh) so a serial shell exists before networking is
up; ssh remains key-only (`keys/dev/ssh-test`). Prod-shaped images
(squashfs) have no unlocked users and no ssh — serial shows boot logs
and a login prompt nothing can pass, by design (AD-004).

## 3. What a healthy rpi4 first boot looks like (serial)

1. EEPROM + `start4.elf` chatter (`uart_2ndstage=1`) — firmware reads
   config.txt from the esp (hybrid-MBR partition 1), loads the DTB +
   `u-boot.bin`.
2. `U-Boot 2026.07` banner → `Crag: trying slot A (2 attempts left)`
   (boards/rpi4/uboot/boot.script.in; the count decrements
   power-cut-safely and rauc-mark-good restores it after boot-success).
3. Kernel messages on `ttyS0` (the same header pins) → dinit early
   chain → `data-mount: growing` (first boot only) → service bring-up
   → `[  OK  ] boot-success` → `<host> login:`.
4. Log in as `root` (empty password, dev image), or ssh once dhcpcd has
   a lease: `ssh -i keys/dev/ssh-test root@<addr>` (mDNS:
   `crag-<serial>.local`).

If nothing appears at all: swap TX/RX; check the adapter is 3.3 V;
confirm the esp is partition 1 FAT32 (`fdisk -l`). If firmware chatter
appears but no U-Boot: EEPROM too old for the boot path — update with
`rpi-eeprom-update` from Raspberry Pi OS once, then reflash Crag.

## 4. Manual release smoke checklist (per hardware board)

Run per board, per release candidate; record results in the release
notes. QEMU CI covers the same flows continuously — this list exists
because real hardware adds firmware, storage, and PHY variables CI
cannot see.

- [ ] **Flash + first boot**: image flashes; boots to `boot-success` +
      login with zero `[FAILED]` services; `/data` grew to the card.
- [ ] **Identity**: `cragctl status` (or `GET /system`) shows the
      right board, release, slot A, marked good.
- [ ] **Networking**: ethernet lease + `GET /network` interfaces sane;
      wifi scan/join on boards with radios (rpi: brcmfmac firmware
      loads, `iwctl station wlan0 scan`).
- [ ] **Provisioning**: mDNS announce visible; AP-mode portal comes up
      on wifi boards and serves the captive page (docs/07 §4).
- [ ] **Update (AD-020 on metal)**: install the release bundle over
      the API from slot A; reboot lands slot B marked good. Then the
      poisoned-bundle drill: apply, watch three failed attempts, U-Boot
      falls back to the known-good slot, device re-marks it good.
- [ ] **Power-cut**: pull power mid-update-download and mid-boot once
      each; device recovers to a bootable slot without manual help.
- [ ] **Factory reset**: `POST /system/factory-reset`; /data is wiped,
      provisioning state returns to first-boot.
- [ ] **App surface** (when the release ships external-tree apps):
      `GET /services` lists them running; `crag deploy` round-trips on
      a dev-variant flash.

## 5. Board bring-up status

| Board | Image builds | Booted on metal | Update cycle | Provisioning |
|---|---|---|---|---|
| `rpi4` | ✓ dev + prod | ✓ 2026-07-29 (dev: boot-success, mark-good, both slots good, root shell on ttyS1) | — | — |
| `rpi5` | board not yet defined | — | — | — |
| `beaglebone-black` | board not yet defined | — | — | — |
| `x86_64-efi` | board not yet defined | — | — | — |

Update this table as bring-up progresses; it feeds the M5 exit review.
