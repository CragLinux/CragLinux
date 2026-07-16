# 03 — Build System and Toolchain

**Status:** Draft for review · **Owns decisions:** AD-001, AD-002, AD-023 · **Read after:** [01-architecture.md](01-architecture.md)
**Supersedes** the prototype's `BUILD_SYSTEM.md`, `CBUILD.md`, `CONTAINER_BUILD.md`.

---

## 1. AD-001 — Relationship to Chimera: pin and overlay, never fork

> **AD-001 — Astro consumes Chimera's cports as a Harbormaster-managed checkout pinned by the committed `.harbormaster.lock`, and adds packages via a separate `astro-cports` collection. Astro never forks cports.** *(Accepted)*

- **cports** (BSD-2-Clause) contains both the cbuild engine and Chimera's ~5000 package templates, already patched for clang+musl. The lock-file pin is the single source of truth for "which Chimera" a given Astro release builds; `hm sync --locked` materializes it into `cports/` (repo management design: [10 §1](10-release-ci.md)).
- **`astro-cports/`** is a cbuild *collection* (cbuild natively supports multiple template collections) holding everything Astro-specific: `astrod`, `astro-base-*` metapackages, `rauc` + dinit glue, `astro-rauc-conf`, mdns responder, kernel packaging, U-Boot/GRUB assets, and any template Astro must carry ahead of or divergent from upstream.
- **Patching upstream**: when a cports template needs an Astro-local fix, prefer (in order): upstream the fix to Chimera → carry a same-name template in `astro-cports` that shadows it (collection precedence) → last resort, a quilt-style patch in `build/patches/cports/` applied to the cports checkout at build time (visible, versioned, loudly reported by the build; `hm status` will show the checkout as dirty, which is expected inside a build and reset afterwards).
- **Rejected**: forking cports (permanent rebase tax on thousands of templates); Alpine aports (glibc-free but gcc-built, different init/userland — the entire value of Chimera's LLVM/musl patching would be redone); building everything with hand-rolled scripts (the prototype proved cbuild integration works; re-deriving its sandboxing/cross machinery is pure waste).

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
| `packages` | collections (cports, astro-cports, external trees), packages.list closure | signed apk repo | cbuild invocations |
| `rootfs` | apk repo, overlays, hooks, variant TOML | squashfs (prod) / ext4 image (dev) | existing assembly engine + mksquashfs |
| `image` | rootfs, kernel, bootloader, `[partitions]` | `.img.zst`, `.qcow2` | **new** — spec in [04 §6](04-boards-images-boot.md) |
| `bundle` | rootfs, kernel, keys, `[rauc]` | `.raucb` | **new** — `rauc bundle` with verity + adaptive |
| `test` | image, bundle | junit-style report | **new** — QEMU smoke + A/B cycle (AD-020) |

Stage state lives under `build/state/<board>/<variant>/`; `--step` re-runs from a stage using cached upstream outputs (prototype behavior, kept).

## 6. Board/variant configuration schema

Imported from the prototype (`scripts/lib/config.py` + `schema.py`, TOML validated against a typed schema, merged common → external trees → board → variant) and evolved:

**Kept as-is:** `[board]` (name, arch — enum keeps armv7hf/riscv64 parked), `[kernel]` (version/source/defconfig/config_fragments/cmdline/dtb/lto/clang_patches), `[bootloader]` (add `grub-efi` to the type enum), `[console]`, `[firmware]`, `[qemu]`, variant schema (`[packages] install`, `[services] enable/disable`, `[users] create`, `[kernel] cmdline_append`).

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
