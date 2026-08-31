# Crag

**An opinionated embedded Linux distro: fixed modern core, A/B updates baked in, and an on-device HTTP API so your application never has to learn Linux networking.**

Crag is a complete, working appliance OS for IoT devices and gateways — not a build-system kit. The core is fixed and curated, derived from [Chimera Linux](https://chimera-linux.org): **musl** libc, **FreeBSD userland** (chimerautils), **dinit** init, an all-**LLVM/Clang** toolchain, and **apk-tools v3** packaging. On top of that base, Crag adds what embedded products actually need out of the box:

- **A/B atomic updates** via [RAUC](https://rauc.io) — signed verity bundles, streaming installs, automatic rollback on failed boots.
- **cragd** — a local REST API (think Onics Squid.link) for WiFi/Ethernet config, update control, and system basics; AP-mode captive-portal provisioning included.
- **External trees** — teams ship their apps as real packages with supervised services, pinned against an Crag release, without ever forking the distro.
- **From-source, containerized builds** — the whole system builds reproducibly in one podman container, leveraging Chimera's cbuild.

Initial targets: **x86_64** (EFI), **aarch64** (Raspberry Pi 4/5), and first-class **QEMU** boards for both arches — the full update-and-rollback cycle runs in QEMU on a laptop.

Status: **design phase**. The design supersedes the `clang-cross` prototype, whose toolchain and build machinery Crag imports.

## Design documents

| Doc | Covers |
|---|---|
| [00 — Overview](docs/00-overview.md) | vision, four pillars, positioning, non-goals, glossary |
| [01 — Architecture](docs/01-architecture.md) | runtime + build architecture, invariants, **decision index (AD-001…AD-029)** |
| [02 — Base System](docs/02-base-system.md) | core packages, read-only rootfs, `/data`, dinit design, kernel policy |
| [03 — Build System](docs/03-build-system.md) | cbuild/cports strategy, SDK, container, pipeline stages, config schema |
| [04 — Boards, Images, Boot](docs/04-boards-images-boot.md) | partition layout, GRUB/U-Boot slot switching, image artifacts, QEMU workflow |
| [05 — Updates](docs/05-updates.md) | RAUC design, bundles, boot confirmation, signing, rollback |
| [06 — Config API](docs/06-config-api.md) | cragd (Zig): architecture, REST conventions, endpoint catalog, auth |
| [07 — Networking & Provisioning](docs/07-networking-provisioning.md) | iwd + dhcpcd, firstboot, captive portal, factory reset |
| [08 — External Trees](docs/08-external-trees.md) | customization contract, app packaging, service manifests, SDK workflow |
| [09 — Security](docs/09-security.md) | threat model, trust chain, PKI, hardening, secure-boot roadmap |
| [10 — Release & CI](docs/10-release-ci.md) | repo layout, versioning, channels, podman-based local-first CI |
| [11 — Roadmap & Migration](docs/11-roadmap-migration.md) | milestones to v1.0, clang-cross migration map, risk register |

Start with 00 and 01; the decision index in 01 is the review checklist.

## License

Apache-2.0 ([AD-022](docs/00-overview.md)).
