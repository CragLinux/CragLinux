# 00 — Astro: Vision and Positioning

**Status:** Draft for review · **Owns decisions:** AD-022 · **Audience:** everyone — read this first.

---

## 1. What Astro is

Astro is a **highly opinionated embedded Linux distribution** for IoT devices and gateways. It is a *complete, working* distro — not a meta-build-system, not a kit of parts. The core system is fixed and curated:

| Layer | Component | Why |
|---|---|---|
| libc | **musl** (Chimera's build, mimalloc allocator) | small, correct, static-friendly |
| Userland | **chimerautils** (FreeBSD tools ported by Chimera) | clean, consistent, complete — no busybox-vs-coreutils debate |
| Init / supervision | **dinit** | dependency-based, supervising, tiny; no systemd |
| Toolchain | **LLVM/Clang + lld + compiler-rt + libc++** | one modern toolchain, ThinLTO + hardening distro-wide |
| Packaging | **apk-tools v3** | signed ADB packages, fast, small |
| Updates | **RAUC** A/B slots | atomic full-image updates with rollback, out of the box |
| Config surface | **astrod** — on-device HTTP API | apps configure networking/updates/system over REST, never touch Linux internals |

There is no menuconfig for the core. If you want to choose your own libc, init, or shell, Astro is the wrong tool — and that is deliberate. Astro's bet is that embedded teams don't want a distro construction kit; they want a **solid, updatable appliance OS** plus a clean way to put *their* software on it.

## 2. The four pillars

### 2.1 A fixed, opinionated core

Everything in the table above is non-negotiable per release. The payoff: every Astro device in the field runs the same audited base, every team's knowledge transfers between products, and the update/security story is tractable. The distro is the product; the core is maintained *for* you, not *by* you.

### 2.2 Extension through external trees — not forks

Teams never patch Astro itself. A product is:

```
product = Astro @ pinned release  +  external tree(s) @ pinned version
```

An **external tree** (see [08-external-trees.md](08-external-trees.md)) is a directory containing the team's packages (built as apk packages by cbuild), dinit services, board additions, and configuration overlays. The mechanism descends from Buildroot's `BR2_EXTERNAL`, but with a stronger contract: apps are real packages with dependency resolution, not files dumped into a rootfs.

### 2.3 The configuration API (`astrod`)

Networking on embedded Linux is foreign territory for most embedded developers. Following the model proven by Onics' Squid.link gateways — where a layered platform puts a local API between apps and the OS — Astro ships **astrod**, an HTTP/JSON API on every device:

```
POST /api/v1/network/wifi/scan
PUT  /api/v1/network/wifi/connection   {"ssid": "plant-floor", "psk": "…"}
GET  /api/v1/update/status
POST /api/v1/system/reboot
```

The team's application makes local HTTP calls; astrod translates them into iwd/RAUC/dinit operations over D-Bus. App code never runs `ip`, edits `wpa_supplicant.conf`, or learns what a routing table is. Full design: [06-config-api.md](06-config-api.md).

### 2.4 A/B updates out of the box

Every Astro image is built for RAUC A/B slot updates: two read-only root filesystems, atomic switch-over, automatic rollback if the new image fails to boot. Signed verity bundles, HTTP streaming, and delta-friendly adaptive updates are configured by default. Teams get a production-grade OTA story on day one instead of in month nine. Full design: [05-updates.md](05-updates.md).

## 3. Positioning

| | **Astro** | Yocto | Buildroot | Chimera | balenaOS |
|---|---|---|---|---|---|
| Core configurability | none (fixed) | total | high | fixed | fixed |
| Update story | RAUC A/B built in | DIY (meta-rauc etc.) | DIY | apk upgrade | A/B, container-centric |
| From-source builds | yes (cbuild) | yes | yes | yes | partially |
| App delivery | apk pkgs via external trees | recipes | packages/overlay | apk | Docker containers |
| Device config API | **yes (astrod)** | no | no | no | Supervisor API |
| Dev app sideload | **yes (`astro deploy`)** | DIY (devtool) | DIY | apk | balena push |
| Init | dinit | choice | choice | dinit | systemd |
| libc | musl | choice | choice | musl | glibc |

The one-line version: **Astro is to Chimera roughly what balenaOS is to Yocto — an opinionated, updatable appliance OS derived from a general-purpose base — minus the container-only religion.** Team apps run as native, supervised dinit services, not mandatory containers.

## 4. Non-goals (v1)

Explicitly out of scope for the first release. Some are "never", some are "later" (see [11-roadmap-migration.md](11-roadmap-migration.md)):

- **Desktop or interactive use.** No graphics stack, no user sessions beyond debug shells.
- **glibc compatibility.** musl only. Prebuilt glibc binaries are not a target.
- **Core package choice.** No alternative shells/init/libc — ever.
- **Runtime `apk add` on production images.** The package set is frozen at image build time; the production rootfs is read-only (AD-004, [02-base-system.md](02-base-system.md)). A read-write dev variant exists for development.
- **Cellular WAN** — architected for (API namespace reserved), not implemented in v1.
- **Verified/secure boot** — v1 signs updates and packages; it does not attest the boot chain. Staged roadmap in [09-security.md](09-security.md).
- **Fleet management server.** RAUC's hawkBit client is a planned optional package; Astro does not host or ship a fleet server.
- **riscv64 targets** — future, just not initial.

## 5. Supported targets (v1)

| Board | Arch | Boot | Role |
|---|---|---|---|
| `qemu-x86_64` | x86_64 | OVMF EFI + GRUB | first-class dev/CI board |
| `qemu-aarch64` | aarch64 | U-Boot (`-bios`) | first-class dev/CI board |
| `qemu-armv7` | armv7hf | U-Boot (`-bios`) | first-class dev/CI board |
| `x86_64-efi` | x86_64 | GRUB on EFI | generic industrial PC / gateway |
| `rpi4` / `rpi5` | aarch64 | RPi firmware → U-Boot | accessible reference hardware |
| `beaglebone-black` | armv7hf | ROM → SPL → U-Boot | accessible reference hardware (M5) |

QEMU boards are not second-class: they boot through the **real bootloaders**, so the complete A/B update-and-rollback cycle runs in CI and on a laptop in minutes ([04-boards-images-boot.md](04-boards-images-boot.md), [10-release-ci.md](10-release-ci.md)).

## 6. Heritage

**Chimera Linux** is Astro's upstream. Astro consumes Chimera's cports/cbuild (BSD-2-Clause) as a pinned checkout (managed with Harbormaster — [10-release-ci.md](10-release-ci.md)) and builds Chimera's packages unmodified wherever possible; Astro-specific packages live in an overlay collection ([03-build-system.md](03-build-system.md)). Astro tracks Chimera deliberately, re-pinning per Astro release — it does not fork it.

**The `clang-cross` prototype** is Astro's direct ancestor: an LLVM 22 + musl cross-toolchain builder that grew a containerized board/variant build system around vendored cbuild, and whose later scripts already called themselves "Astro Linux". Its orchestrator, TOML config schema, overlay/hook engine, and container environment are imported and extended; its standalone toolchain becomes the Astro **app SDK**. The migration map is in [11-roadmap-migration.md](11-roadmap-migration.md).

## 7. License

> **AD-022 — Astro is licensed Apache-2.0.**
> All original Astro code and documentation (orchestrator, astrod, astro-cports templates, docs) are Apache-2.0. This is compatible with our key dependencies: cbuild/cports is BSD-2-Clause, dinit is Apache-2.0, RAUC is LGPL-2.1 (consumed as a distinct work, not linked into Astro code), iwd is LGPL-2.1, Zig and its stdlib are MIT. Per-package licenses are carried in apk metadata as SPDX expressions, as cbuild already enforces.

## 8. Glossary

| Term | Meaning |
|---|---|
| **board** | A hardware (or QEMU) target definition: `boards/<name>/board.toml` + kernel fragments + overlays + hooks |
| **variant** | An image flavor orthogonal to boards (e.g. `prod`, `dev`): `variants/<name>.toml` |
| **external tree** | A team-owned directory of packages/boards/overlays layered onto the build (`--external`) |
| **collection** | cbuild term: a repository of package templates (cports `main/`, `user/`; Astro adds `astro-cports`) |
| **template** | cbuild term: a `template.py` file defining one package |
| **overlay** | Files copied verbatim (after templating) into the rootfs during assembly |
| **slot** | RAUC term: an updatable partition (rootfs.A, rootfs.B, boot.A, …) |
| **bundle** | RAUC term: a signed squashfs container holding update images (`.raucb`) |
| **compatible string** | RAUC identifier tying bundles to a board family (`astro-<board>`) |
| **world file** | apk's record of explicitly requested packages (frozen into the image) |
| **`/data`** | The single persistent read-write partition; everything mutable lives here |
| **astrod** | Astro's on-device configuration API daemon |
| **AD-NNN** | An architectural decision, recorded in its owning doc, indexed in [01-architecture.md](01-architecture.md) |
