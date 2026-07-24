# 01 — System Architecture

**Status:** Draft for review · **Owns decisions:** none (indexes all) · **Read after:** [00-overview.md](00-overview.md)

---

## 1. Two architectures

Astro is two cleanly separated systems:

1. **The build architecture** — a containerized pipeline that turns source + configuration into images, update bundles, package repositories, and an SDK. It runs on developer machines and CI, always inside the `astro-builder` container.
2. **The runtime architecture** — what actually runs on a device: bootloader, kernel, dinit, the system daemons, and the team's applications.

The contract between them is the **image**: the build side produces immutable, signed artifacts; the runtime side never modifies itself except through whole-slot RAUC updates and the `/data` partition.

## 2. Runtime architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Team application(s)                      │
│            (native dinit services from external trees)          │
│                                                                 │
│        HTTP/JSON  ──────────────►  unix socket / 127.0.0.1      │
└──────────────┬──────────────────────────────────────────────────┘
               ▼
┌──────────────────────────┐   ┌──────────────────────────────────┐
│         astrod           │   │  provisioning UI (captive portal │
│  config API + reconciler │   │  page, served by astrod in AP    │
│  desired state: /data    │   │  mode only)                      │
└─────┬──────┬──────┬──────┘   └──────────────────────────────────┘
      │      │      │  D-Bus (system bus)          direct config
      ▼      ▼      ▼                                    │
┌────────┐ ┌──────┐ ┌───────┐  ┌─────────┐  ┌──────────┐ ▼
│  iwd   │ │ rauc │ │ dinit │  │ dhcpcd  │  │ mdns     │ files in
│ (WiFi) │ │(OTA) │ │(ctl   │  │ (DHCP)  │  │ (_astro. │ /data,
│        │ │      │ │ sock) │  │         │  │  _tcp)   │ /etc ovl
└────────┘ └──────┘ └───────┘  └─────────┘  └──────────┘
      ▲      ▲      ▲      supervision & dependency ordering
┌─────┴──────┴──────┴─────────────────────────────────────────────┐
│                       dinit (PID 1)                              │
├──────────────────────────────────────────────────────────────────┤
│   Linux kernel (LTS, Clang-built, board fragments)               │
├──────────────────────────────────────────────────────────────────┤
│   Bootloader: GRUB-on-EFI (x86_64) / U-Boot (aarch64, armv7)     │
│   with RAUC slot selection (BOOT_ORDER / grubenv)                │
├──────────────────────────────────────────────────────────────────┤
│   Hardware / QEMU                                                │
└──────────────────────────────────────────────────────────────────┘
```

Key structural rules:

- **D-Bus is the internal spine; HTTP is the external surface** (AD-016). System daemons (iwd, RAUC) already require D-Bus; astrod is a D-Bus *client* and never shells out to CLI tools for state-changing operations. Team apps use HTTP only — D-Bus is not part of the supported app contract.
- **astrod is control plane, not data plane.** If astrod dies, packets keep flowing, updates in progress continue in RAUC, services keep running; dinit restarts astrod and it re-reads desired state from `/data`.
- **One policy brain.** astrod owns network policy (which interface is WAN, when AP mode is active). iwd, dhcpcd, RAUC are mechanisms. This is why ConnMan/NetworkManager were rejected (AD-015, [07-networking-provisioning.md](07-networking-provisioning.md)).

## 3. Build architecture

```
 host (developer laptop / CI runner)
 └── podman (rootless)  ── astro-builder container (Fedora, pinned digest)
      └── astro CLI  (build/ orchestrator, imported from clang-cross)
           │  reads: boards/<board>/board.toml + variants/<v>.toml
           │         + external trees (--external), merged & schema-validated
           │
           ├─ stage: sdk        → LLVM+musl cross toolchain (app SDK)
           ├─ stage: kernel     → Clang-built LTS kernel + fragments + dtbs
           ├─ stage: bootloader → U-Boot / GRUB artifacts + env tooling
           ├─ stage: bootstrap  → cbuild bldroot (bubblewrap sandbox)
           ├─ stage: packages   → cbuild builds: cports (hm-pinned checkout)
           │                      + fork templates + external-tree collections
           │                      ⇒ signed apk repository
           ├─ stage: rootfs     → apk-installed rootfs + overlays + hooks
           │                      ⇒ squashfs (prod) / ext4 (dev)
           ├─ stage: image      → GPT disk image (both slots), per AD-007
           ├─ stage: bundle     → signed RAUC verity bundle (.raucb)
           └─ stage: test       → QEMU boot smoke + A/B update/rollback
```

Stage contracts (inputs/outputs/caching) are specified in [03-build-system.md](03-build-system.md). The `image`, `bundle`, and `test` stages are new relative to the clang-cross prototype.

## 4. Partition and update model — the invariants

Details live in [04-boards-images-boot.md](04-boards-images-boot.md) and [05-updates.md](05-updates.md); the following are system-wide invariants every component may rely on:

```
GPT:  esp │ bootenv │ boot.A │ rootfs.A │ boot.B │ rootfs.B │ data
           (grubenv/           squashfs            squashfs    ext4,
            uboot-env)         read-only           read-only   grows on
                                                               first boot
```

1. **The root filesystem is immutable.** Production rootfs is squashfs, mounted read-only. Its content is exactly the built artifact — bit-for-bit.
2. **All mutable state lives in `/data`.** One ext4 partition, shared across slots, surviving updates. Factory reset = wipe `/data`.
3. **Updates replace whole slots atomically.** No package-level runtime updates in production. Rollback boots the other slot.
4. **Partitions are addressed by GPT `PARTLABEL`**, never filesystem UUID (A/B copies duplicate fs UUIDs).
5. **Kernels live in per-slot boot partitions** (`boot.A`/`boot.B`), updated together with their rootfs via RAUC slot grouping — the bootloader never reads squashfs.

## 5. Trust and signing summary

Two independent signature domains (full design: [09-security.md](09-security.md)):

| Domain | Signs | Verified by | Keys |
|---|---|---|---|
| **apk** | package repositories (ADB, SHA512) | apk at image-build time | build signing key |
| **RAUC** | update bundles (verity format) | rauc daemon on device against keyring CA | dev CA (in-repo, non-prod) / prod CA (external) |

v1 has **no verified boot**: the boot chain is not attested. This is stated, not hidden; the staged path to verity + signed UKI/FIT is AD-018.

## 6. Component ownership matrix

| Component | Upstream | Astro's role | Lives in |
|---|---|---|---|
| musl, chimerautils, dinit, apk-tools, LLVM | Chimera cports | consume pinned templates | `cports/` (Harbormaster-pinned checkout) |
| kernel | kernel.org LTS | config fragments, Clang build, per-board | `boards/`, `build/` |
| U-Boot / GRUB | upstream | defconfigs, env layout, boot scripts | `boards/`, fork |
| RAUC | rauc.io | package template + dinit services + system.conf per board | fork `main/rauc*`, `boards/` |
| iwd, dhcpcd, dbus | upstream/cports | fork templates + dinit services + D-Bus policy | fork, `boards/` |
| mdns responder | — | built into astrod (announce-only) | `astrod/` |
| **astrod** | — | 100 % Astro (Zig) | `astrod/` |
| **astroctl** CLI | — | 100 % Astro | `astrod/` |
| orchestrator (`astro` CLI) | clang-cross prototype | import, extend | `build/` |
| SDK toolchain | clang-cross `build-toolchain.sh` | import, fix, repurpose | `sdk/` |
| board/variant schema | clang-cross `scripts/lib/{config,schema}.py` | import, extend | `build/lib/` |
| external-tree engine | clang-cross | import, harden contract | `build/`, spec in doc 08 |

## 7. Architectural decision index

Status: **Accepted** = confirmed by project owner · **Recommended** = design's choice, open to challenge during doc review.

| ID | Decision | Choice | Status | Owner doc |
|---|---|---|---|---|
| AD-001 | Build model vs Chimera | ~~cports pinned via Harbormaster lock + `astro-cports` overlay collection; never fork~~ **superseded by [AD-027](#ad-027)** | Superseded | [03](03-build-system.md) |
| AD-002 | Toolchain roles | cbuild's toolchain builds the distro; standalone LLVM toolchain becomes the app SDK | Recommended | [03](03-build-system.md) |
| AD-003 | Repo structure | Monorepo; companion repos (cports) via Harbormaster lock; external trees separate repos | Recommended | [10](10-release-ci.md) |
| AD-004 | Rootfs mutability | RO squashfs in prod, package set frozen at image time; rw dev variant | Recommended | [02](02-base-system.md) |
| AD-005 | Mutable state | Single `/data` ext4; `/etc` overlay with astrod-write-only policy; factory reset = wipe `/data` | Recommended | [02](02-base-system.md) |
| AD-006 | Initramfs | None in v1; direct squashfs root; tiny custom initramfs reserved for verity | Recommended | [04](04-boards-images-boot.md) |
| AD-007 | Partition layout | GPT, PARTLABEL-addressed: esp/bootenv/boot.A/rootfs.A/boot.B/rootfs.B/data | Recommended | [04](04-boards-images-boot.md) |
| AD-008 | x86_64 boot | GRUB-on-EFI + grub-editenv; dual-ESP+UKI documented as secure-boot end-state | Recommended | [04](04-boards-images-boot.md) |
| AD-009 | ARM boot (aarch64 + armv7) | U-Boot + redundant env + BOOT_ORDER script; QEMU uses real bootloaders | Recommended | [04](04-boards-images-boot.md) |
| AD-010 | Bundle format | RAUC verity bundles + adaptive updates; plain rejected, crypt deferred | Recommended | [05](05-updates.md) |
| AD-011 | Boot confirmation | dinit-supervised rauc + `rauc-mark-good` gated on boot-success milestone; opt-in app participation | Recommended | [05](05-updates.md) |
| AD-012 | astrod language | **Zig** (static musl binaries, C interop for D-Bus, pinned compiler) | Accepted | [06](06-config-api.md) |
| AD-013 | API style | REST/JSON, `/api/v1`, OpenAPI 3.1 as source of truth, operations + SSE | Recommended | [06](06-config-api.md) |
| AD-014 | API auth & exposure | Unix socket group + localhost bearer token; LAN opt-in; unauthenticated subset only in AP provisioning mode | Recommended | [06](06-config-api.md) |
| AD-015 | Network stack | **iwd + dhcpcd**; astrod owns policy; ConnMan/NM rejected | Accepted | [07](07-networking-provisioning.md) |
| AD-016 | Internal bus | D-Bus is the internal spine; astrod is a D-Bus client, never shells out | Recommended | [06](06-config-api.md) |
| AD-017 | App delivery | External-tree apps ship as apk packages (cbuild templates); overlays for config only | Recommended | [08](08-external-trees.md) |
| AD-018 | Secure boot posture | v1 = signed updates only; staged roadmap to verity + UKI/FIT; layout is verity-ready now | Recommended | [09](09-security.md) |
| AD-019 | Versioning | Calendar `YYYY.MM.patch`; API versioned independently; channel = repo URL, not key | Recommended | [10](10-release-ci.md) |
| AD-020 | CI gate | QEMU full A/B update+rollback test required on every PR | Recommended | [10](10-release-ci.md) |
| AD-021 | Downgrade policy | astrod enforces monotonic bundle versions (explicit force override); compatible string per board family | Recommended | [05](05-updates.md) |
| AD-022 | License | Apache-2.0 for all original Astro work | Accepted | [00](00-overview.md) |
| AD-023 | cports tracking | Re-pin during development; lock the pin for each Astro release | Accepted | [03](03-build-system.md) |
| AD-024 | CI infrastructure | Podman container-based, local-first; hosted CI is a thin wrapper added later | Accepted | [10](10-release-ci.md) |
| AD-025 | LAN API exposure | Default **off** after provisioning; unix socket + localhost token are the default surface | Accepted | [06](06-config-api.md) |
| AD-026 | Developer sideload | `astro deploy` pushes app binaries/packages to dev-variant devices in seconds; prod images never accept sideloads | Recommended | [08](08-external-trees.md) |
| <a id="ad-027"></a>AD-027 | cports fork (supersedes AD-001) | Astro maintains a **fork** of cports (`aka-mj/astro-cports`, branch `astro`), Harbormaster-pinned; Astro changes are ordinary in-fork commits, not an overlay collection; a scheduled update-report tracks currency | Accepted | [03](03-build-system.md) |

Amendment process: ADs change via PR to the owning doc plus this index; a "Recommended" AD becomes "Accepted" when the project owner signs off in review ([10-release-ci.md §6](10-release-ci.md)).

> **AD-027 rationale (supersedes AD-001).** AD-001 chose to pin upstream
> cports and carry Astro's changes as out-of-tree patches + an
> `astro-cports` overlay, explicitly avoiding a fork. Experience reversed
> that: our cross-build and new-package changes were declined upstream,
> upstream does not accept AI-assisted contributions (which Astro uses),
> and an independent review flagged that upstream changes to pinned
> templates could silently break our reproducible builds. Forking removes
> that coupling and lets us set our own contribution policy. The cost —
> owning version and security currency for the tree — is mitigated by the
> scheduled `astro update-report` sweep and its CI job. We fork at the
> AD-001 pin (`e3c9e1a0`), so no build behavior changes at the cutover;
> re-pins remain deliberate lock diffs (AD-023 unchanged). Fork provenance,
> attribution, and the AI-contribution policy live in `cports/README.md`
> and `cports/CONTRIBUTING.md`; Chimera's BSD license is retained verbatim.
