# 03 — Build System and Toolchain

**Status:** Draft for review · **Owns decisions:** AD-027 (supersedes AD-001), AD-002, AD-023 · **Read after:** [01-architecture.md](01-architecture.md)
**Supersedes** the prototype's `BUILD_SYSTEM.md`, `CBUILD.md`, `CONTAINER_BUILD.md`.

---

## 1. AD-027 (supersedes AD-001) — Relationship to Chimera: a maintained fork

> **AD-027 — Astro maintains a fork of Chimera's cports (`aka-mj/astro-cports`, branch `astro`), Harbormaster-pinned by the committed `.harbormaster.lock`. Astro's packages and fixes are ordinary in-fork commits; a scheduled update-report tracks currency.** *(Accepted; supersedes AD-001)*
>
> ~~**AD-001** — Astro consumes Chimera's cports as a pinned checkout and adds packages via a separate `astro-cports` collection; never forks.~~ Superseded — see the [AD-027 rationale in the index](01-architecture.md#ad-027). In short: our fixes and new packages were declined upstream, upstream forbids the AI-assisted contributions Astro uses, and pinned-template drift risked breaking reproducible builds. We forked **at the AD-001 pin `e3c9e1a0`**, so nothing about the produced artifacts changed at the cutover.

- **The fork** (Chimera's BSD license retained verbatim in `cports/COPYING.md`; provenance and the fork rationale in `cports/README.md`) contains the cbuild engine, Chimera's ~5000 templates, and Astro's delta on top: cross-build/toolchain fixes upstream had not taken (`main/llvm`, `main/glib`, …), new packages Astro needs (`rauc`, `libubootenv`, `basu`), and downstream overrides (`chrony`, `openssh`, `readline`). Each is a `main/<pkg>:` commit that explains itself. `hm sync --locked` materializes the pinned fork into `cports/`.
- **Astro-owned templates** are enumerated in `build/cports-owned.list` (regenerated from the fork delta by `build/lib/gen-owned-list.sh` after every re-pin), classified `new` (no Chimera equivalent — always built from source) or `mod` (we differ — built from source only when installed). This list replaces the old "derive from patch paths + `astro-cports` collection" mechanism.
- **Changing a template** is now a normal commit to the fork (`main/<pkg>: …`), tested via the Astro CI gates, following `cports/CONTRIBUTING.md` (which — unlike upstream — welcomes AI-assisted contributions gated on ownership + verification + honesty). A `build/patches/cports/` quilt patch or an `astro-cports/` shadow still works as a *local, uncommitted* escape hatch for experiments (the build applies any it finds and resets afterward), but the durable home for a change is a fork commit.
- **Currency** is Astro's responsibility now (the fork's cost): `./build/astro-update-report.sh` sweeps the tree with cbuild's own `update-check` and reports stale packages, prioritized by shipped/owned; a scheduled CI job (`.github/workflows/update-report.yml`) publishes it so re-pin/update work can be planned. Re-pins stay deliberate lock-file diffs (AD-023).
- **Rejected alternatives** (unchanged from AD-001): Alpine aports (gcc-built, different init/userland — Chimera's LLVM/musl work would be redone); hand-rolled build scripts (re-deriving cbuild's sandboxing/cross machinery is waste). The fork keeps all of cbuild's value; the only thing traded away vs AD-001 is upstream's maintenance of the templates we touch — which upstream was not going to accept anyway.

### Binary consumption for dev builds (AD-027 consequence)

Consuming pinned templates has a second dividend: for packages Astro does **not** touch, Chimera's own signed binaries are byte-equivalent in intent to what a from-source build of the pinned template produces — so dev and PR builds need not pay the from-source tax (the LLVM template alone is ~1.5 h) to validate Astro changes.

- **Policy**: dev/PR builds may consume Chimera's official binary repository (`https://repo.chimera-linux.org/current/main`, apk appends `/<arch>`) for unmodified packages. **Release and the nightly source-bootstrap canary remain full-source under Astro keys** — no foreign binary ever enters a release artifact.
- **Selection**: per-invocation `--packages-mode=binary|source`, defaulting to the variant's `[packages].mode` (dev variants say `binary`; absent = `source`). In binary mode the `packages` stage builds from source only: the fork's `new` packages and `boards/common/source-packages.list` (always), plus any `mod` fork template the image actually installs (`build/cports-owned.list`, AD-027). The `rootfs` stage then installs from the local Astro repo *and* Chimera's repo.
- **Precedence** (apk-tools 3.x solver: newest version wins; on equal versions, the earlier-listed repository wins): the local repo is listed first, and manifest entries present in the local repo are installed with exact version pins, so an Astro-built or patched package deterministically beats Chimera's. A newer Chimera version of a *non-manifest* dependency can still be selected — which is exactly what the skew guard reports.
- **Trust statement**: Chimera's repo public keys are pinned in-repo at `build/keys/chimera/` (copied from the hm-locked cports checkout, so they trace to the same pin — no build-time TOFU) and are trusted **for dev artifacts only**. Binary-mode installs verify all signatures (no `--allow-untrusted`); the local repo is verified against the cbuild dev key. A prod-variant artifact must never be assembled against these keys (same spirit as the dev-CA refusal in [10 §4](10-release-ci.md)).
- **armv7 exception**: cports carries an armv7 build profile (`armv7-chimera-linux-musleabihf`), but Chimera publishes **no armv7 binary repository** (chimera-repo-main excludes it) — binary packages-mode is therefore unavailable for armv7, and armv7 builds always run in source mode regardless of variant. Mitigation: CI persists and publishes Astro's own built armv7 apk repo, which later builds consume as a warm cache (Astro keys, so the foreign-binary and skew concerns below don't arise). armv7 is Chimera's newest architecture; expect some upstream templates to need arch-gate loosening, carried via the shadow-template mechanism above.
- **Skew guard**: binary mode mixes Chimera-*current* binaries with the pinned cports templates. After every binary-mode rootfs assembly, `build/lib/skew_check.py` compares each installed package against its pinned template version and **warns (never fails)** into `build/state/logs/skew-report-<board>-<variant>.log`; it flags loudly if a binary repo ever shadows a source-built package. Release/nightly builds are full-source and cannot skew by construction; a persistent skew report is the signal to bump the cports pin (AD-023).
- **ccache**: all cbuild source builds (both modes) run with cbuild's transparent ccache support enabled (`ccache = yes` under `[build]` in `cports/etc/config.ini`, written idempotently by the packages stage; opt out with `ASTRO_CCACHE=0`). The cache persists at `cports/cbuild_cache/ccache` inside the workspace mount, alongside the §4 cache volumes.

> **AD-023 — cports tracking cadence: re-pin freely during development; each Astro release locks its pin.** *(Accepted)*
> A pin bump is a PR that updates `.harbormaster.lock` (`hm sync` to the new upstream state, commit the lock diff), gated by the full CI build+test pipeline. At release branch time the pin freezes; stable-branch pin bumps are allowed only for security backports, mirroring how the release consumes them.

## 2. cbuild primer (Astro-flavored)

What Astro relies on, so readers don't need the full upstream docs:

- **Templates**: one `template.py` per package — metadata variables (`pkgname`, `pkgver`, `pkgrel`, `hostmakedepends` vs `makedepends` vs `depends`, SPDX `license`) plus optional phase functions (`init_/pre_/post_` × `fetch, extract, prepare, patch, configure, build, check, install`). `build_style` wrappers: `cmake`, `meson`, `gnu_configure`, `makefile`, `cargo`, `go`, `python_pep517`, `meta`.
- **Automatic subpackages**: `-devel`, `-doc`, `-dbg`, `-static`, and crucially **`-dinit`** — service files installed to `usr/lib/dinit.d` are auto-split, which the external-tree app contract leans on (AD-017).
- **Automatic dependency scanning**: ELF `NEEDED` → `so:` deps, pkg-config → `pc:`, executables → `cmd:`; templates rarely list runtime deps by hand.
- **Sandbox**: builds run in a *bldroot* — a minimal container driven by bubblewrap with namespaces; network is cut after source fetch, the root goes read-only after dependency install, everything runs unprivileged. cbuild itself must run as a regular user.
- **Cross-compilation is transparent**: `./cbuild -a aarch64 pkg main/foo` — same profiles for native and cross. Astro's build container always cross-builds from x86_64 to the target arch (including "cross" x86_64→x86_64 for uniformity of the pipeline).
- **Bootstrap**: `./cbuild bootstrap` builds the bldroot from binary packages. Policy: **day-to-day and PR builds are binary-bootstrapped from Astro's own apk repo** (first from Chimera's repo until Astro's exists); **a source-bootstrap (4-stage, musl-host) canary runs nightly in CI** so the from-source story stays honest without taxing every build.
- **Signing**: cbuild signs packages at build; the repo signing key lives with the build (dev key in `keys/dev/`, prod in CI secrets — [09-security.md §4](09-security.md)).
- Host needs: Python 3.12+, apk-tools 3.x, git, bubblewrap — all provided by the build container, never by the host.

## 3. AD-002 — Two toolchains, two jobs

> **AD-002 — cbuild's own in-bldroot LLVM toolchain builds every distro package. The prototype's standalone `build-toolchain.sh` toolchain is repurposed as the Astro app SDK.** *(Recommended)*

The prototype conflated these; Astro separates them:

| | Distro toolchain | App SDK |
|---|---|---|
| Built by | cbuild (cports `main/llvm` etc., inside bldroot) | `sdk/build-toolchain.sh` (imported from clang-cross) |
| Used for | every apk package, kernel, bootloader | team application code, out-of-tree, against a sysroot |
| Character | full distro toolchain, ThinLTO/hardening profiles | relocatable tarball: static clang/lld, per-arch wrapper scripts (`<triple>-clang`), CMake toolchain files, musl sysroot |
| Sysroot | cbuild-managed per-arch sysroots | **generated from the built image's package set**: apk-install `*-devel` of everything in the image into a staging sysroot, so apps compile against exactly what ships |

SDK fix list carried from the prototype exploration:
1. Drop `riscv64` from v1 (its triple exists but `LLVM_TARGETS_TO_BUILD` never included RISCV — enable both together when the target un-parks).
2. Fix `install_kernel_headers` hardcoding `ARCH=arm` — parameterize per arch (`arm64`, `x86`).
3. Exercise and CI-cover x86_64 and aarch64 SDK builds (only ARM was ever run).
4. Align kernel-header version with the kernel the boards actually ship (prototype had 6.1 headers vs 6.12 kernels).
5. The SDK also pins and ships nothing Zig-related — Zig is its own self-contained cross toolchain; the build container pins the Zig version for astrod ([06-config-api.md §3](06-config-api.md)).

## 4. Build container

- `container/Containerfile` (imported from prototype `podman/`): Fedora base, pinned by digest; adds LLVM/kernel build deps, Python 3.12+, apk-tools, bubblewrap, **RAUC host tools (rauc, mksquashfs, openssl)**, `grub2-tools`/`mkenvimage`, sfdisk/mtools, zstd, qemu-system-{x86_64,aarch64} + OVMF (for the test stage), and the **pinned Zig toolchain**.
- Runs rootless podman; `--privileged` remains required (bubblewrap needs namespace privileges inside the container, loop devices for the image stage). Revisit if podman/user-ns evolution allows narrowing.
- Caches mounted as named volumes: `sources` (distfiles), `bldroot`, `ccache`, `zig-cache`, `apk-repo`. A fully-offline rebuild works once caches are warm (network only in fetch phases).
- The container is the **only supported build environment** — host installs are explicitly unsupported. This is also the CI story (AD-024): CI runs the same container.

## 5. Orchestrator and pipeline

Single entrypoint: **`astro`** (in `build/`, evolving the prototype's `build.sh` + `build-inner.sh`):

```
astro build  <board> [variant] [--external <tree>…] [--step <stage>…]
astro run    <board> [variant] [--snapshot|--fresh|--detach]
astro deploy <app> --to <host|qemu> [--pkg|--watch]   # dev sideload (AD-026, 08 §6)
astro test   <suite> <board>       # boot-smoke | update | api
astro keys   init-dev
astro clean  [--all|--stage <s>]
```

Stages, each with a declared contract (inputs → outputs, cache key = hash of inputs + tool versions):

| Stage | Inputs | Outputs | Notes |
|---|---|---|---|
| `sdk` | LLVM/musl versions, arch | SDK tarball | optional for image builds; needed for `test api` app fixtures |
| `kernel` | board TOML `[kernel]`, fragments | `vmlinuz`, dtbs, modules pkg | existing prototype code |
| `bootloader` | board TOML `[bootloader]` | u-boot.bin/boot.scr or GRUB EFI + grub.cfg | existing + new GRUB path |
| `bootstrap` | cports pin | bldroot | binary bootstrap (§2) |
| `packages` | fork templates (cports, AD-027) + external trees, packages.list closure | signed apk repo | cbuild invocations |
| `rootfs` | apk repo, overlays, hooks, variant TOML | squashfs (prod) / ext4 image (dev) | existing assembly engine + mksquashfs |
| `image` | rootfs, kernel, bootloader, `[partitions]` | `.img.zst`, `.qcow2` | **new** — spec in [04 §6](04-boards-images-boot.md) |
| `bundle` | rootfs, kernel, keys, `[rauc]` | `.raucb` | **new** — `rauc bundle` with verity + adaptive |
| `test` | image, bundle | junit-style report | **new** — QEMU smoke + A/B cycle (AD-020) |

Stage state lives under `build/state/<board>/<variant>/`; `--step` re-runs from a stage using cached upstream outputs (prototype behavior, kept).

## 6. Board/variant configuration schema

Imported from the prototype (`scripts/lib/config.py` + `schema.py`, TOML validated against a typed schema, merged common → external trees → board → variant) and evolved:

**Kept as-is:** `[board]` (name, arch — enum keeps riscv64 parked), `[kernel]` (version/source/defconfig/config_fragments/cmdline/dtb/lto/clang_patches), `[bootloader]` (add `grub-efi` to the type enum), `[console]`, `[firmware]`, `[qemu]`, variant schema (`[packages] install`, `[services] enable/disable`, `[users] create`, `[kernel] cmdline_append`).

**Replaced:** `[disk]` → **`[partitions]`**:

```toml
[partitions]
table = "gpt"              # only value in v1
esp_size = "64M"
bootenv_size = "1M"
boot_size = "64M"          # per slot
rootfs_size = "512M"       # per slot; build fails if squashfs exceeds it
data_min_size = "64M"      # image-file size; grows to disk on firstboot
```

**Added:**

```toml
[rauc]
compatible = "astro-x86_64-efi"     # defaults to "astro-<board>"
bootloader = "grub"                 # grub | uboot (validated against [bootloader].type)

[image]
formats = ["img", "qcow2"]          # qcow2 auto-added for qemu boards

[api]                               # astrod feature flags baked into image defaults
wifi = true
ap_provisioning = true              # AP-mode captive portal enabled at factory state
mdns = true
lan_exposure = false                # AD-025 default
```

`[kernel].cmdline` drops `root=` (the image stage owns `root=PARTLABEL=…` per slot); the schema validator rejects a `root=` in board cmdline to prevent drift.

## 7. Reproducibility

Goal: **bit-for-bit reproducible rootfs squashfs** per (git tree, cports pin); best-effort for bootloader binaries.

- All inputs pinned: cports SHA from `.harbormaster.lock` (the build refuses to run if `hm status` reports lock drift, unless `--allow-drift` for local experiments), source tarball hashes (cports templates already pin), container image digest, Zig version, SDK LLVM/musl versions.
- `SOURCE_DATE_EPOCH` = commit timestamp of the Astro tree, exported through cbuild and mksquashfs (`-mkfs-time`, `-all-time`), sfdisk (no random disk GUIDs — derived from build id), and grubenv/env images.
- apk installs with deterministic ordering; overlay copy preserves sorted order and fixed mtimes.
- CI asserts reproducibility on the nightly: build twice from clean cache, compare squashfs SHA512 ([10-release-ci.md §4](10-release-ci.md)).
- Known non-reproducible v1 leftovers get tracked in the manifest (`reproducible: false` flags per artifact) rather than hidden.
