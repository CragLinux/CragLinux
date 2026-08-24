# 11 — Roadmap and Prototype Migration

**Status:** Draft for review · **Owns decisions:** none · **Read after:** everything else.

---

## 1. Milestones to v1.0

Each milestone is demo-able and gates the next; CI acquires its corresponding suite as the milestone lands.

| M | Name | Definition of done |
|---|---|---|
| **M0** | Repo bootstrap | This doc set approved; monorepo laid out per [10 §1](10-release-ci.md); clang-cross assets imported (§2 map); container builds; `crag build qemu-aarch64` reproduces the prototype's rootfs result inside the new tree |
| **M1** | Boots in QEMU | All three QEMU boards (`qemu-x86_64`, `qemu-aarch64`, `qemu-armv7`) boot to dinit over **real bootloaders** (GRUB/OVMF, U-Boot): RO squashfs root, `/data` grown+mounted, `/etc` overlay, dinit graph through `boot-success` (cragd stubbed as a health-check placeholder). `crag run` + boot-smoke CI live |
| **M2** | Updates itself | RAUC integrated end-to-end: image + bundle stages, system.conf per board, dinit glue, mark-good, poisoned-bundle rollback. **AD-020 CI gate turns on and stays on.** Dev PKI + `crag keys init-dev` |
| **M3** | Configures itself | cragd v1: system + network (ethernet, wifi station) + update endpoint groups, desired-state store, iwd/dhcpcd/RAUC backends, auth surfaces, cragctl, API integration suite in CI. Provisioning: wired path + mDNS. Then AP-mode captive portal ([07 §4](07-networking-provisioning.md)) |
| **M4** | Extensible | External-tree contract implemented and frozen ([08](08-external-trees.md)): tree merging, service manifests, code/config fence, SDK with image-derived sysroot; **`crag deploy` sideload loop working against dev-variant QEMU (AD-026)**; `examples/external-tree-acme` builds and runs in CI |
| **M5** | Hardware | `x86_64-efi`, `rpi4` (then rpi5), and `beaglebone-black` boot, update, and provision on real hardware; flashing docs; manual release smoke checklist |
| **v1.0** | Release criteria | All CI suites green on all boards · one full release cycle rehearsed (freeze → RC → resign-promote) with dev keys · prod PKI procedure documented and dry-run · docs updated to as-built · stability contract published · zero known data-loss or rollback-correctness bugs |

Sequencing rationale: update correctness (M2) lands *before* the API (M3) because rollback safety is the platform's spine — cragd then builds on a device that can already save itself.

## 2. clang-cross migration map

`../clang-cross` is the reference implementation; assets move by **copy + adapt** (its git history stays behind; two local commits, nothing to preserve).

| Prototype asset | → Destination | Action |
|---|---|---|
| `scripts/lib/config.py`, `schema.py` | `build/lib/` | import; extend schema: `[disk]`→`[partitions]`, add `[rauc]`, `[image]`, `[api]`, `grub-efi` bootloader type; reject `root=` in cmdline ([03 §6](03-build-system.md)) |
| `boards/*` (TOMLs, fragments, overlays, hooks), overlay/hook/packages.list engine | `boards/`, `build/` | import; add `qemu-x86_64`, `qemu-armv7`, `x86_64-efi`, `rpi5`; `beaglebone-black` (armv7) imports with the rest and returns at M5 |
| `build.sh`, `scripts/build-inner.sh`, `scripts/lib/*.sh` | `build/` (the `crag` CLI) | import; restructure into stage contracts; **add `image`, `bundle`, `test` stages** (new code — [04 §6](04-boards-images-boot.md), [05](05-updates.md)) |
| `podman/Containerfile` | `container/` | import; add RAUC host tools, grub2-tools/mkenvimage, qemu+OVMF, pinned Zig ([03 §4](03-build-system.md)) |
| `build-toolchain.sh`, wrapper/cmake generation | `sdk/` | repurpose as app SDK; fixes: parameterize kernel-header ARCH (drops `ARCH=arm` hardcode), drop riscv64 from v1, align header version with board kernels, CI-cover x86_64/aarch64 ([03 §3](03-build-system.md)) |
| vendored `cbuild/cports/` checkout + profiles | Harbormaster-managed `cports/` + `build/` profile generation | replace vendoring with `.harbormaster.toml` entry + lock pin (AD-001, [10 §1](10-release-ci.md)); regenerate arch profiles pointing at bldroot toolchain per AD-002 |
| musl/kernel patches + `patches.sh` | `build/patches/` | import; kernel clang patches stay; musl patches likely superseded by cports (verify against pin) |
| `scripts/setup-cbuild.sh` | `build/stages/bootstrap` | fold in |
| `docs/*.md` (6 files) | — | superseded by this doc set; mine for operational detail while implementing |
| `dist/` squashfs artifact, `build-old/`, logs, `.llvm-version` state, `tests/` | — | drop (stale clang-21 artifact; superseded) |
| `.github/workflows/build-toolchain.yml` | `.github/workflows/` | rewrite as thin `crag ci` wrappers (AD-024) |

## 3. Deferred feature register

Consolidated from all docs; each entry names its design hook so deferral ≠ dead end.

| Feature | Design hook | Doc |
|---|---|---|
| Cellular WAN (ModemManager) | reserved API namespace `/network/cellular` (501); WAN policy already interface-ordered | [06 §5.2](06-config-api.md) |
| hawkBit fleet client | `rauc-hawkbit-updater` coexists as a second RAUC D-Bus client | [05 §5.3](05-updates.md) |
| App-only OTA | RAUC artifact repositories; apps are already apk packages (AD-017) | [05 §8](05-updates.md) |
| Verified boot stages 2–3 | verity-ready slots, initramfs spec, per-slot boot partitions | [09 §3](09-security.md) |
| Encrypted (crypt) bundles | PKI supports recipient certs | [05 §3](05-updates.md) |
| Bootloader self-update | `boot-gpt-switch` slot types; small single ESP kept pending | [05 §8](05-updates.md) |
| riscv64 targets | arch enum parked; SDK triple exists; re-enable = profile + boards + LLVM_TARGETS | [04 §1](04-boards-images-boot.md) |
| MAC (SELinux/AppArmor) | per-app users + RO root as v1 containment | [09 §5](09-security.md) |
| Key-separated channels; NTS time | noted at decision sites | [10 §3](10-release-ci.md), [07 §6](07-networking-provisioning.md) |
| EAP/enterprise WiFi | reserved fields on wifi connection object | [06 §5.2](06-config-api.md) |
| Factory/eMMC mass flashing | out of scope v1 | [04 §8](04-boards-images-boot.md) |
| Field-debug "dev mode" toggle on prod-shaped images (sideload beyond the dev variant) | sideload tooling exists (AD-026); enabling it on prod images punctures immutability and needs its own security review first | [08 §6](08-external-trees.md) |

## 4. Risk register

| Risk | Impact | Mitigation |
|---|---|---|
| **cports drift** — pin bumps break Crag glue (template renames, base reorganization) | build breakage, stalled releases | nightly pin-bump trial build reports early ([10 §4](10-release-ci.md)); shadow-template mechanism localizes fixes; release pins freeze exposure |
| **Zig churn / D-Bus binding** — pre-1.0 std changes; basu-under-musl unknowns | cragd schedule risk | pinned compiler per release; single `bus.zig` seam with libdbus-1 fallback; QEMU integration tests against real daemons from M3 day one ([06 §3](06-config-api.md)) |
| **iwd AP-mode edge cases** — single-radio AP↔station flip, scan-while-AP chipset quirks | provisioning UX failures | cached pre-AP scans; survivable wrong-password loop specified; wired path always exists; captive portal lands late in M3 after station-mode hardening ([07 §4](07-networking-provisioning.md)) |
| **U-Boot env redundancy subtleties** — `saveenv`-per-boot wear, offset/board variance, non-atomic env on some media | rollback correctness on aarch64 | redundant-env config mandatory; per-board offsets in board dir; poisoned-bundle CI runs on qemu-aarch64 with real U-Boot every PR (AD-020); eMMC boot-partition variant documented as later option ([04 §4](04-boards-images-boot.md)) |
| **squashfs-root-without-initramfs** on odd storage (late-probing controllers) | boot hangs on some x86 hardware | `rootwait` everywhere; storage drivers `=y` per board; x86_64-efi board targets standard AHCI/NVMe; escape hatch = the already-specified tiny initramfs pulled forward if M5 hardware demands it ([04 §5](04-boards-images-boot.md)) |
| **GRUB env write atomicity** on power cut | x86 slot-selection corruption | grubenv is a fixed 1 KiB block (single-sector write); mark-good rewrites promptly after boot; bootenv partition isolated from all fs journals |
| **Image-stage loop-device work in CI containers** | flaky CI | image stage isolates all privileged ops behind one small module; fallback path via `mtools`/`e2tools` (no-loop assembly) documented if runner privileges tighten ([04 §6](04-boards-images-boot.md)) |
| **Scope creep in cragd** — "just one more endpoint" | API sprawl pre-freeze | v1 catalog is closed ([06 §5](06-config-api.md)); additions post-freeze are additive-only by AD-013; anything bigger goes through the RFC path ([10 §6](10-release-ci.md)) |
