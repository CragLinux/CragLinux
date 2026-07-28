# M0 Migration Notes — clang-cross → Astro

Migration of the `../clang-cross` prototype into this monorepo per
[docs/11-roadmap-migration.md §2](docs/11-roadmap-migration.md) and the target
layout in [docs/10-release-ci.md §1](docs/10-release-ci.md). Copy + adapt; no
git history preserved. Nothing in the source tree was modified.

## 1. What was copied (source → destination)

| clang-cross source | Astro destination | Adaptation |
|---|---|---|
| `scripts/lib/config.py` | `build/lib/config.py` | verbatim; docstring example paths only (`scripts/lib/` → `build/lib/`) |
| `scripts/lib/schema.py` | `build/lib/schema.py` | verbatim (schema evolution is a later task) |
| `scripts/lib/common.sh` | `build/lib/common.sh` | `resolve_project_root()` marker changed from `<root>/build-toolchain.sh` to `<root>/sdk/build-toolchain.sh` |
| `scripts/lib/packages.sh` | `build/lib/packages.sh` | `cbuild/cports` → `cports`; profile path → `build/cbuild-profiles/`; help messages |
| `scripts/lib/rootfs.sh` | `build/lib/rootfs.sh` | pkg repo → `cports/packages/`; `scripts/lib/kernel.sh` → `build/lib/kernel.sh`; kernel build dir → `build/state/` |
| `scripts/lib/image.sh` | `build/lib/image.sh` | comment path only (still the prototype stub) |
| `scripts/lib/kernel.sh` | `build/lib/kernel.sh` | patch dir → `build/patches/kernel/`; build dir → `build/state/`; error message |
| `scripts/lib/bootloader.sh` | `build/lib/bootloader.sh` | verbatim (still the prototype stub) |
| `build.sh` | `build/astro-build.sh` | derives `PROJECT_ROOT` (repo root); `podman/` → `container/`; inner command → `./build/build-inner.sh`; usage examples |
| `scripts/build-inner.sh` | `build/build-inner.sh` | toolchain call → `sdk/build-toolchain.sh`; setup call → `build/setup-cbuild.sh`; `cbuild/cports` → `cports`; output dir → `build/state/images/` |
| `scripts/setup-cbuild.sh` | `build/setup-cbuild.sh` | **no longer clones cports** — checks for `<root>/cports` and fails with a `hm sync --locked` message; no longer generates profiles/device configs (verifies committed ones); no longer writes `docs/CBUILD.md`; apk-tools build dir → `build/state/apk-tools` |
| `scripts/build-base-system.sh` | `build/build-base-system.sh` | (not in migration map — kept runnable, judgment call) cports/profile/output paths, help messages |
| `scripts/create-system-image.sh` | `build/create-system-image.sh` | (not in map — judgment call) device confs → `build/cbuild-profiles/devices/`; outputs → `build/state/images/` |
| `scripts/run-qemu.sh` | `build/run-qemu.sh` | (not in map — judgment call) kernel/rootfs paths → `build/state/`; `qemu-arm64` → `qemu-aarch64` examples |
| `scripts/validate-config.py` | `build/validate-config.py` | (not in map — judgment call) docstring/comment only; root derivation still correct |
| `patches.sh` | `build/patches/patches.sh` | driver kept next to the patches; header comment documents layout; entries unchanged |
| `patches/musl/*.patch` (2 iconv CVE patches) | `build/patches/musl/` | verbatim |
| `patches/kernel/6.12/*.patch` (2 clang-build patches) | `build/patches/kernel/6.12/` | verbatim — kernel vs musl separation preserved |
| `podman/Containerfile` | `container/Containerfile` | verbatim except usage comment (version bumps / RAUC / Zig additions are a later task) |
| `podman/build-in-container.sh` | `container/build-in-container.sh` | (not in map — judgment call) `./build-toolchain.sh` → `./sdk/build-toolchain.sh`; output message |
| `build-toolchain.sh` | `sdk/build-toolchain.sh` | "verbatim" **except** the directory-configuration block: artifacts are rooted at `ASTRO_ROOT` (= repo root), outputs under `build/state/<arch>/`, patches sourced from `build/patches/patches.sh`; generated wrapper scripts go up 4 levels (were 3); generated `<arch>-toolchain.cmake` still lands at repo root but references `build/state/<arch>/`; test programs generated into `build/state/<arch>/tests` instead of a source-tree `tests/` |
| `package-toolchain.sh` | `sdk/package-toolchain.sh` | (not in map — judgment call, toolchain-adjacent) same `ASTRO_ROOT` treatment; `dist/` at repo root; archive layout uses `build/state/<arch>/`; dropped repo `README.md` from the archive (it is now the Astro doc-set README, not a toolchain README) |
| `boards/common/` | `boards/common/` | verbatim (hooks have no path assumptions) |
| `boards/rpi4/` | `boards/rpi4/` | verbatim |
| `boards/qemu-arm64/` | `boards/qemu-aarch64/` | **renamed** per docs; display name `"QEMU ARM64"` → `"QEMU AArch64"`, comment headers updated; no other references to the old name existed |
| `boards/*/variants/*.toml` | copied with their boards | the prototype has no top-level `variants/`; see §5 |
| `cbuild/config/profiles/{aarch64,armv7hf}.conf` | `build/cbuild-profiles/` | paths `/workspace/build/<arch>` → `/workspace/build/state/<arch>`; migration note + AD-002 TODO added. armv7hf profile retained — armv7 was later un-parked as a v1 target (2026-07-17 plan; qemu-armv7 at M1, beaglebone-black at M5) |
| `cbuild/config/devices/{generic-arm,rpi}.conf` | `build/cbuild-profiles/devices/` | (not in map — judgment call) verbatim; consumed by `build/create-system-image.sh` |

New files created at repo root: `.gitignore`, `LICENSE` (Apache-2.0, "Copyright
2026 TierOne Software"), this file, and scaffold dirs
`astro-cports/main/`, `astrod/src/`, `keys/dev/` (with README), `examples/`,
`tests/`, `variants/` (`.gitkeep` placeholders).

## 2. What was skipped, and why

| Item | Why |
|---|---|
| `cbuild/cports/` (~1.3 GB vendored checkout) | replaced by a Harbormaster-managed checkout at `<root>/cports` (AD-001/AD-003); manifest + lock is a later task. `cports/` is gitignored |
| `boards/beaglebone-black/` | not copied at M0; armv7 has since been un-parked (v1 target) — BBB board files return from ../clang-cross at the M5 hardware milestone |
| `build/`, `build-old/`, `toolchain/`, `dist/`, `sources/` | build outputs / caches, per DO-NOT-COPY list |
| `aarch64-toolchain.cmake`, `armv7hf-toolchain.cmake` (repo root) | generated by `build-toolchain.sh`; regenerated on first build, gitignored (`/*-toolchain.cmake`) |
| `bootstrap-final.log`, `bootstrap-retry.log`, `.bash_history` | logs / shell noise |
| `.llvm-version` | toolchain state; lives inside gitignored `toolchain/` |
| `tests/` | superseded; `sdk/build-toolchain.sh` generates its own smoke-test programs into `build/state/<arch>/tests` |
| `docs/` (6 files) | superseded by the Astro doc set; mine for operational detail while implementing |
| `.github/workflows/build-toolchain.yml` | to be rewritten as thin `astro ci` wrappers (AD-024) |
| `README.md` | Astro has its own (user-reviewed) |
| `.config/cbuild/config.ini` | generated cbuild user config (the container ran with HOME at the repo root); `setup-cbuild.sh` recreates it under `$HOME/.config/cbuild` |
| `configs/` | contained only an empty `configs/boot/` directory — nothing to copy |
| `.claude/settings.local.json`, `.git` | tooling/history |

## 3. Path-fix conventions applied

1. **`PROJECT_ROOT` derivation**: all orchestrator scripts live one level below
   the root (`build/` instead of `scripts/`), so `SCRIPT_DIR/..` still resolves
   to the repo root. `astro-build.sh` (formerly at the root) now derives
   `PROJECT_ROOT` explicitly. `resolve_project_root()` and the generated
   compiler wrappers key off `sdk/build-toolchain.sh` / a 4-level ascent.
2. **All build outputs → `build/state/`** (per docs/03 §5 "stage state lives
   under build/state/"): what was `build/<arch>/`, `build/images/`,
   `build/apk-tools/` is now `build/state/<arch>/`, `build/state/images/`,
   `build/state/apk-tools/`. Applied consistently across scripts, cbuild
   profiles, generated wrappers, and generated CMake toolchain files.
3. **Caches stay at the root, gitignored**: `toolchain/` (LLVM + local
   apk-tools install), `sources/` (kernel/musl/llvm downloads), `dist/`
   (packaged SDKs). This preserves the prototype's root-relative layout that
   several scripts and the container mount (`/workspace`) rely on.
4. **`cbuild/cports` → `cports`** everywhere; scripts that need it fail (or
   warn) with a "run `hm sync --locked`" message instead of cloning.
5. **`cbuild/config/profiles|devices` → `build/cbuild-profiles[/devices]`**.
6. **`podman/` → `container/`**, `scripts/lib/` → `build/lib/`,
   `patches/` → `build/patches/`.
7. **`qemu-arm64` → `qemu-aarch64`** (directory, display name, usage examples).

## 4. TODO(migration) markers left in the tree

| Location | TODO |
|---|---|
| `build/setup-cbuild.sh` (check_cports) | later task adds `.harbormaster.toml`/`.harbormaster.lock` with the pinned cports SHA |
| `build/setup-cbuild.sh` (verify_profiles) | per AD-002, regenerate profiles to point at the bldroot toolchain; profile generation moves into build stages |
| `build/cbuild-profiles/aarch64.conf`, `armv7hf.conf` | same AD-002 note (header comment) |
| `build/patches/patches.sh` | verify the musl iconv patches against the cports pin — likely superseded by cports' musl templates |
| `sdk/build-toolchain.sh` (install_kernel_headers) | `ARCH=arm` hardcode — parameterize per target arch and align header version with board kernels when repurposed as the app SDK |

## 5. Known broken / needs later work

- **`variants/` is an empty scaffold.** The prototype keeps variants per-board
  (`boards/<board>/variants/dev.toml`); the docs (10 §1) expect top-level
  `variants/prod.toml`, `dev.toml`. Reconciling variant layout is part of the
  schema/stage work — not attempted here.
- **Schema is unevolved** (deliberately): board TOMLs still use `[disk]` (not
  `[partitions]`), still carry `root=` in `[kernel].cmdline`, and there is no
  `[rauc]`/`[image]`/`[api]` or `grub-efi` bootloader type. `validate-config.py
  --all` passes against the prototype schema (verified).
- **`build/lib/image.sh` and `build/lib/bootloader.sh` are stubs** — unchanged
  from the prototype; image/bundle/test stages are new code (docs/03 §5).
- **cbuild profiles are container-absolute** (`/workspace/...`) and carry a
  host-specific `MAKEFLAGS=-j24` from generation on the original machine; only
  valid inside the astro-builder container until regenerated (AD-002).
- **Container image is behind the docs**: no RAUC host tools, grub2-tools,
  qemu+OVMF, or pinned Zig yet (docs/03 §4 — explicit later task).
- **`boards/common/overlay/etc/os-release`** still says
  `HOME_URL="https://github.com/tierone/clang-cross"` and `VERSION_ID=0.1.0` —
  image-content values left untouched; needs an Astro identity pass
  (docs/10 §2 versioning).
- **No `astro` CLI yet**: entry point is `./build/astro-build.sh <board>
  <variant>`; restructuring into the `astro` stage-contract CLI is the M0→M1
  work item, not this migration.
- **No `.github/workflows/`** — rewritten later as thin `astro ci` wrappers.
- **Boards missing vs docs**: `qemu-x86_64`, `x86_64-efi`, `rpi5` are additions
  scheduled by the map, not part of the prototype.
- **Untested end-to-end**: syntax (`bash -n`), Python compilation, config
  validation (`--all`), and `astro-build.sh` help/board-listing were verified;
  a full container build was not run as part of this migration.

## 6. Verification performed

- `bash -n` on every migrated shell script — clean.
- `python3 -m py_compile` on `config.py`, `schema.py`, `validate-config.py` — clean.
- `python3 build/validate-config.py --all` — 4 configs OK (qemu-aarch64 + rpi4, board + dev variant).
- `./build/astro-build.sh` (no args) lists `qemu-aarch64` and `rpi4`; `--help` renders.
- Grep sweep for stale `scripts/lib`, `podman/`, `qemu-arm64`, `cbuild/cports`,
  `cbuild/config`, `beaglebone`, `build/images`, `./build.sh` references — none
  remain (only "podman/docker" engine-name comments).

## 7. Phase 2: version updates (2026-07)

Harbormaster wiring plus a component-currency pass per docs/03 §3/§4 and
docs/10 §1. Resolves the §4 TODO(migration) rows for `check_cports`,
`patches.sh`, and the `install_kernel_headers` ARCH hardcode, and the §5
"container image is behind the docs" item.

### cports pin (Harbormaster)

- **`hm` binary**: built from `../harbormaster` (v1.2.0, `go build
  ./cmd/harbormaster`) into **`build/tools/hm`** (gitignored via new
  `/build/tools/` entry). `build/setup-cbuild.sh` gained `find_hm()` — looks
  on `PATH`, falls back to `build/tools/hm`, and prints build instructions
  if neither exists.
- **`.harbormaster.toml`** (committed): declares `cports` →
  `https://github.com/chimera-linux/cports.git`, branch `master`, path
  `cports/`, `work_dir = "./"` (repo root), shallow clone
  (`shallow_clone = true`, `clone_depth = 1`).
- **`.harbormaster.lock`** (committed): pins cports at
  **`e3c9e1a0c93dbdd4c2d1a83af0caa8cbbb7ddb68`** (upstream commit date
  2026-07-15, "user/soju: fix checksum"). `hm sync --locked` verified to
  reproduce it; `hm status` reports `ok`/`locked`.
- `.gitignore`: already ignored `/cports/`; added `/.harbormaster.lock.flock`
  (hm's runtime flock file) and `/build/tools/`. The `.toml`/`.lock` are
  intentionally NOT ignored.

### Version bumps (old → new, with evidence)

| Component | Old | New | Evidence / rationale |
|---|---|---|---|
| SDK LLVM (`sdk/build-toolchain.sh`) | 22.1.1 | **22.1.7** | cports `main/llvm` pins 22.1.7. Upstream latest is 22.1.8 (`git ls-remote` llvm-project tags), but per AD-002 the SDK follows the pinned cports, not newest upstream |
| SDK musl | 1.2.5 | **1.2.6** | musl latest tag v1.2.6; cports `main/musl` is 1.2.6 (git snapshot `9fa28ece` + mimalloc external allocator) |
| SDK kernel headers | 6.1.119 | **6.12.95** | aligned with board kernels' LTS line (the 6.1-headers-vs-6.12-kernels mismatch from §4/docs/03 §3 item 4); 6.12.95 is the latest 6.12.x per kernel.org releases.json (2026-07-04) |
| Board kernels (`boards/{qemu-aarch64,rpi4}/board.toml`) | 6.12.77 | **6.12.95** | latest patch of the 6.12 LTS line; `validate-config.py --all` passes |
| U-Boot | — | — (no pin) | rpi4 uses `bootloader.type = "rpi-boot"` (RPi firmware boot, no U-Boot); no board pins a U-Boot version yet. For reference: cports packages U-Boot 2025.10; upstream latest is v2026.07. A pin will land with the real bootloader stage |
| apk-tools (`build/setup-cbuild.sh`) | 3.0.5 | 3.0.5 (unchanged) | cports `main/apk-tools` still pins 3.0.5 — already in sync |
| Zig (new pin) | — | **0.16.0** | latest stable (released 2026-04-13, ziglang.org index); recorded in **`build/zig-version`**; Fedora 44 packages the same 0.16.0 but the container installs the sha256-verified release tarball so the pin can't drift |

**Kernel LTS line decision**: 6.12 is no longer the newest LTS — **6.18 is**
(kernel.org: longterm 6.18.38; cports `linux-lts` = 6.18.37, `linux-rpi` =
6.18.36, `linux-headers` = 7.0.12, latest stable 7.1.3). Boards stay on 6.12
for now because the clang-build patches under `build/patches/kernel/6.12/`
are keyed to that line (`kernel.sh` discovers by major.minor) and a major
bump needs requalification. Moving boards + SDK headers to 6.18 (re-basing
the two kernel patches) is a deliberate follow-up, ideally alongside the
kernel-stage rework.

Also: `sdk/package-toolchain.sh` had the component versions hardcoded a
second time in its generated `TOOLCHAIN_INFO.txt`; it now extracts
LLVM/musl/Linux versions from `sdk/build-toolchain.sh` (single source of
truth) so they can't drift again.

### ARCH fix (SDK)

`install_kernel_headers` no longer hardcodes `ARCH=arm`: each arch case in
`sdk/build-toolchain.sh` now sets `KERNEL_ARCH` (`arm64` for aarch64, `x86`
for x86_64, `arm` for armv7hf, `riscv` for riscv64) and the headers install
uses `make ARCH="${KERNEL_ARCH}" …`. TODO(migration) marker removed.

### musl iconv patches — verdict: superseded, disabled, kept on disk

Both `build/patches/musl/*.patch` are upstream musl commits (`e5adcd97`,
`c47ad25e`, the CVE-2025-26519 iconv fixes) that shipped **in musl 1.2.6** —
verified directly against `src/locale/iconv.c` at tag v1.2.6 (fixed EUC-KR
bounds check + `wctomb_utf8` hardening both present). cports' musl (1.2.6
snapshot) never needed them. Since the SDK now pins 1.2.6, the
`MUSL_PATCHES` entries in `build/patches/patches.sh` are commented out
(files kept for provenance); comment explains not to re-enable unless the
pin ever drops below 1.2.6.

### Containerfile (container/Containerfile)

- Base: `fedora:43` → **`fedora:44` pinned by digest**
  (`sha256:bf1977904d73dceee3f693ab77b025b352375a9d06345045ed22b0b1b232b836`),
  satisfying docs/03 §4 "pinned by digest"; bump recipe in header comment.
- Added host tools per docs/03 §4/§5 (all names verified against Fedora 44
  repos): `rauc`; `grub2-tools` + `grub2-efi-x64-modules` +
  `grub2-efi-aa64-modules`; `uboot-tools` (mkimage/mkenvimage);
  `util-linux` (sfdisk), `mtools`, `dosfstools`, `e2fsprogs`;
  `qemu-system-x86` + `qemu-system-aarch64` + `edk2-ovmf` + `edk2-aarch64`;
  and the pinned **Zig 0.16.0** (release tarball, sha256-verified, installed
  to `/opt/zig`, symlinked as `/usr/local/bin/zig`; `ARG ZIG_VERSION` /
  `ZIG_SHA256` kept in sync with `build/zig-version`).
- `squashfs-tools`, `zstd`, `openssl` were already present. All existing
  LLVM/kernel/cbuild build deps kept intact. Image **not** built (phase 3).

## 8. Phase 3: first containerized build (2026-07-16)

The full pipeline was exercised end-to-end for qemu-aarch64/dev inside the
astro-builder container, ending in a **from-source Astro/Chimera image that
boots in QEMU to a dinit login prompt** (udevd, dhcpcd, turnstiled, agetty
all up; direct kernel boot on a single rw ext4 disk — the M0 model). Twelve
recorded fixes were needed, notably: a kernel.sh stdout-capture bug, apk 3.x
`--usermode`/repo-path fixes in rootfs.sh, `INSTALL_MOD_STRIP=1` (1.3 GB →
86 MB of modules), a two-part `build/patches/cports/` patch that makes
`main/llvm` cross-buildable (libc++ et al.), and `nyagetty` +
`dinit-chimera-udev` added to the base package list. Open gaps: the packages
stage builds no runtime closure (~30 templates were cbuild-run by hand),
`main/heimdal` does not cross-build (openssh temporarily dropped from the
dev variant), the image/bundle/test stages remain stubs/missing as expected,
and gitlab.alpinelinux.org's Anubis blocks cbuild's fetcher (418). See
**`GAP-REPORT.md`** for the stage-by-stage results table, every
fix with rationale, open failures with diagnosis, and the "distance to M1"
list.

### cbuild bootstrap requirements check (cports Usage.md @ pin)

No breaking changes for Astro's flow: Python 3.12+ and apk-tools 3.x still
required (both satisfied); source bootstrap still requires a musl host —
irrelevant for the binary-bootstrap day-to-day path, matters only for the
nightly source-bootstrap canary (docs/03 §2), which was always
container-side.

## 9. Binary packages-mode for dev builds (2026-07-16)

Dev/PR builds no longer have to build every base package from source
(yesterday's bootstrap spent ~1.5 h on the LLVM template alone). New
per-invocation `--packages-mode=binary|source` (default = the variant's
`[packages].mode`; dev variants set `binary`, absent = `source`), per
docs/03 §1 "Binary consumption for dev builds".

**Mechanics** (docs/03 §1 has the policy, docs/10 §4 the CI mapping):

- **packages stage, binary mode** builds from source only: `astro-cports/`
  templates, templates patched via `build/patches/cports/` (auto-derived
  from patch paths — currently just `llvm`), and
  `boards/common/source-packages.list` overrides (new file, empty). The
  subset lands in `packages.source.manifest` next to the full manifest.
- **rootfs stage, binary mode** installs from the local Astro repo *plus*
  `https://repo.chimera-linux.org/current/main` (layout verified against
  cports `main/chimera-repo-main`), written as `v3` lines with the local
  repo first. apk-tools 3.x picks the newest version and breaks version
  ties toward the earlier-listed repo (verified in solver.c), so local
  precedence is made deterministic by listing local first **and**
  exact-version-pinning manifest entries that exist in the local repo.
  `ASTRO_LOCAL_REPO` / `ASTRO_CHIMERA_REPO` override the repo locations.
- **Keys**: Chimera's 8 repo pubkeys are pinned at `build/keys/chimera/`
  (copied from the hm-locked cports checkout — no TOFU; README documents
  provenance, dev-only trust scope, and rotation via pin bump). Binary-mode
  installs verify all signatures — `--allow-untrusted` is gone from that
  path (local packages verify against the cbuild dev pubkeys).
- **Skew guard** (warn-only): after binary-mode assembly,
  `build/lib/skew_check.py` maps every installed package to its template
  via the apk `origin` field and reports divergence from the pinned
  template version into `build/state/logs/skew-report-<board>-<variant>.log`;
  it flags loudly if a binary repo shadows a source-built package. Release/
  nightly (source mode) cannot skew by construction.
- **ccache**: cbuild's transparent ccache is now enabled idempotently
  (`[build] ccache = yes` in `cports/etc/config.ini`; disable with
  `ASTRO_CCACHE=0`); cache persists at `cports/cbuild_cache/ccache`.
- Source mode is byte-for-byte yesterday's behavior (regression-run: 61
  packages, 10.3 s rootfs, local repo only, `--allow-untrusted` path
  unchanged).

**Validation** (qemu-aarch64/dev, same container): rootfs consumption was
pointed at a filtered *copy* of the local repo (`ASTRO_LOCAL_REPO`) with all
llvm/musl/chimerautils-origin packages removed (46 of 323) and re-indexed/
re-signed, so the heavyweights genuinely came from Chimera. Binary-mode run:
packages stage **3.5 s** (nothing to build; the patched llvm was already
present — on a cold repo it is the only source build left) + rootfs **19.5 s**
(63 packages, 7 from Chimera incl. musl/chimerautils/libcxx, signatures
verified) vs the source baseline of **471 s + ~5 h** manual closure/llvm
(GAP-REPORT §1 rows 5–6) + 6–11 s rootfs. QEMU boot test passed identically
to the gap-report run: `qemu-aarch64-development login:` reached, only the
two known non-fatal failures (`early-sysctl`, `early-binfmt`). Skew report:
**zero skew** across all 63 installed packages (pin is 1 day old).
One incompatibility-class fix surfaced: the Chimera `shadow` trigger leaves
`/etc/shadow-` mode 000, which broke the unprivileged `mkfs.ext4 -d` image
path — `boards/common/hooks/10-create-users.sh` now normalizes the shadow
backup files like it already did `/etc/shadow` (GAP-REPORT fix #11
extension). No ABI/soname or apk-version incompatibilities encountered.

## 10. Phase 1: build correctness (2026-07-17)

Implements GAP-REPORT §3 (build-correctness backlog). All seven items; the
statuses are also annotated inline in GAP-REPORT §3.

1. **Automated cports patching** (`build/lib/packages.sh`
   `prepare_cports_tree`/`reset_cports_tree`, wired in `build-inner.sh`):
   before any cbuild call, every `build/patches/cports/*.patch` is applied
   idempotently (`git apply --check`, reverse-check to skip already-applied,
   hard error if neither); after the stage — success or failure, enforced by
   an EXIT trap — the checkout is reset with `git checkout -- . && git clean
   -fd -e keygen.log`. `clean` runs without `-x`, so the gitignored build
   state (`bldroot*`, `packages*`, `sources*`, `cbuild_cache`, `etc/keys`,
   `etc/config.ini`) is never touched. `hm status` sees a pristine pin
   outside the stage.
2. **Upstreaming draft**: `build/patches/cports/UPSTREAMING.md` — two-commit
   split (NATIVE-tools host compiler; mlir/flang off for cross) in cports
   commit style with verification evidence. Draft only; nothing submitted.
   Note: Chimera's CONTRIBUTING.md forbids AI-prepared contributions — a
   human must own/rewrite any actual submission.
3. **Kerberos-free openssh**: `astro-cports/main/openssh/` shadows the
   pinned template (drops `heimdal-devel` + `--with-kerberos5`, pkgrel 2,
   otherwise identical). Collection wiring: cbuild has **no out-of-tree
   collection support** (categories are subdirs of the checkout; symlinked
   dirs are defeated by `sanitize_pkgname()`'s `Path.resolve()`), so
   `prepare_cports_tree` overlays `astro-cports/<cat>/<pkg>/` onto
   `cports/<cat>/<pkg>/` for the duration of the packages stage — exact
   shadowing, reset restores the pin. Built for aarch64; `openssh` +
   `openssh-dinit` + `sshd` service re-enabled in the qemu-aarch64 dev
   variant; booted QEMU guest answers `SSH-2.0-OpenSSH_10.3` on the
   hostfwd port.
4. **Distfile fetch resilience**: all cbuild invocations go through
   `cbuild_pkg()`; on fetch-signature failures it resolves source URLs +
   sha256 via `./cbuild dump`, downloads with `curl -L` into
   `cports/sources/<name>-<ver>/` (`build/lib/fetch_distfiles.py`,
   checksum-verified, one attempt per distfile), and re-runs the build once.
5. **Dependency-closure resolution** (`resolve_dependency_closure` +
   `build/lib/closure_map.py`): per round — regenerate the signed local
   index *from scratch* (`./cbuild -a <arch> index packages/main` after
   deleting `Packages.adb`; two pitfalls: mkndx's `--index` merge keeps
   entries for deleted apks, and bare `cbuild index` discovers repos by
   their existing index files), `apk --simulate add <manifest>` against
   local(+Chimera in binary mode) with signature verification, map
   `(no such package)` deps to templates (template dir → Chimera-index
   provider/origin oracle for `so:`/`pc:`/`cmd:`/subpackage names →
   `@subpackage` grep), build, repeat (cap 10, hard fail listing
   unresolved). Verified: binary mode converges round 1; source mode with
   `libedit-*.apk` removed rebuilds `main/libedit` from the
   `so:libedit.so.0` error and converges round 2. rootfs installs verify
   signatures in both modes now — `--allow-untrusted` is gone.
6. **rootfs cleanups**: manual-extraction fallback deleted (apk failure =
   hard error; missing repo = hard error). `20-enable-services.sh`
   validated against the booted dinit-chimera layout (boot.d entries
   activate by *name* via `waits-for.d: /etc/dinit.d/boot.d`) and now links
   to the real service file like the packaged
   `/usr/lib/dinit.d/boot.d/*` links do.
7. **SDK fixes** (`sdk/build-toolchain.sh`): wrappers pass `-fuse-ld=lld`;
   builtins build enables `COMPILER_RT_BUILD_CRT=ON` and installs
   `clang_rt.crtbegin.o`/`crtend.o` into the per-triple clang resource dir;
   `headers_install` runs with `O=build/state/<arch>/kernel-headers-obj`,
   keeping `sources/linux-*` pristine (removes the gap fix #2 mrproper
   hack). Acceptance: boot-smoke init rebuilt as a plain libc program with
   `-static`, links and runs as `/init` in QEMU
   (`build/state/logs/p1-02-qemu-smoke-static.log`).

**Validation** (logs `build/state/logs/p1-0*.log`): full
`astro-build.sh qemu-aarch64 dev` from the reset pin (patches auto-applied
and auto-reset, closure automated, no manual cbuild calls), rootfs signed
(no `--allow-untrusted`), QEMU boot to `qemu-aarch64-development login:`
with sshd running (SSH banner on forwarded port 2222); source-mode packages
stage validated separately including a forced closure rebuild. Still open
from §3: heimdal itself does not cross-build (only matters for GSSAPI),
`--usermode` ownership for prod squashfs, and the known non-fatal
`early-sysctl`/`early-binfmt` boot failures (kernel fragment follow-up).

## 11. M1 wave 1: schema evolution, prod squashfs, kernel fragments (2026-07-17)

Plan items 8, 9, 14. Logs: `build/state/logs/w1-0*.log`.

### Item 8 — board/variant schema evolution (docs/03 §6)

`build/lib/schema.py` + `config.py`:

- **`[disk]` → `[partitions]`** (AD-007 layout): `table = "gpt"` (only
  value), `esp_size`/`bootenv_size`/`boot_size`/`rootfs_size`/
  `data_min_size` with the docs/04 §2 defaults (64M/1M/64M/512M/64M), all
  optional, size strings validated (`^[1-9][0-9]*[KMG]$`).
- **Deprecation choice: `[disk]` stays accepted for one release of grace**
  (external trees may carry board TOMLs). `migrate_deprecated_disk()`
  validates it against the old schema, maps `boot_size` →
  `partitions.boot_size`, `root_size` → `partitions.rootfs_size` (the
  per-slot semantics differ — the warning says so), drops
  `boot_fs`/`root_fs` (AD-007 fixes filesystems per partition), and prints
  a loud stderr WARNING; `[disk]` + `[partitions]` together is a hard
  error. Remove the shim after M2.
- **`[rauc]`**: `compatible` (defaults to `astro-<board-dir-name>`),
  `bootloader` (`grub`|`uboot`), default derived from and validated
  against `[bootloader].type` (`grub-efi`→`grub`, `u-boot`/`rpi-boot`→
  `uboot`; `direct`/`none` unconstrained, default `uboot`).
- **`[image]`**: `formats` list (`img`|`qcow2`, default `["img"]`),
  `qcow2` auto-added when the board declares `[qemu]` (checked against the
  raw TOML — `apply_defaults` materializes `[qemu]` for every board).
- **`[api]`**: `wifi`/`ap_provisioning`/`mdns` (default true),
  `lan_exposure` (default false, AD-025). Schema-only for now.
- **`grub-efi`** added to the `[bootloader].type` enum.
- **`root=` is rejected** in `[kernel].cmdline` (board) and
  `[kernel].cmdline_append` (variant): the image stage owns
  `root=PARTLABEL=…` per slot. Both in-tree boards were hard-migrated
  (`[partitions]`/`[rauc]`/`[image]`/`[api]` added, `root=` removed);
  beaglebone-black stays out until M5. The direct-boot dev flow now gets
  root= from **`build/run-qemu.sh`**, which injects per rootfs type:
  ext4 → `root=/dev/vda rw`, squashfs → `root=/dev/vda
  rootfstype=squashfs ro`. `validate-config.py --all` passes (5 configs).
- Variant schema gained **`[rootfs] type = "ext4"|"squashfs"`**; when
  absent it defaults by variant id (`prod` → squashfs, else ext4).

### Item 9 — prod rootfs variant (squashfs, correct ownership)

- **`boards/qemu-aarch64/variants/prod.toml`**: source packages-mode,
  minimal set (fixed base from `boards/common/packages.list` +
  `dhcpcd`/`dhcpcd-dinit` only — no openssh, no dev tools per docs/02 §2),
  `[rootfs] type = "squashfs"`, no users.
- **Ownership approach chosen: `unshare -r` user namespace** (option a).
  The rootfs stage now runs as a child process
  (**`build/lib/rootfs-stage.sh`**, launched by `build-inner.sh`); on the
  squashfs path it is wrapped in `unshare -r`, mapping the build uid to 0.
  apk then runs in **real root mode — `--usermode` is dropped**
  (`apk_user_flags()` in rootfs.sh keys off euid), applies package-metadata
  ownership/modes for real (triggers still run), and mksquashfs inside the
  same namespace records root-owned files. No sudo anywhere; the dev ext4
  path is byte-for-byte unchanged (still `--usermode` + `mkfs.ext4 -d`
  normalization). Why not the alternatives: **fakeroot** is not in the
  container image (adding it = image rebuild) and single-uid userns turned
  out sufficient; **`mksquashfs -all-root`** would also mask intentional
  non-root ownership but *without* the apk-warning audit trail.
  **Known limitation**: chowns to ids with no mapping in the namespace
  fail with EINVAL and degrade to root ownership — apk warns loudly; today
  that is exactly `/var/lib/dhcpcd` (dhcpcd user) and
  `/var/log/{btmp,lastlog,wtmp}` (`root:utmp` from dinit-chimera's
  tmpfiles `utmp.conf`, which re-applies at boot on mutable mounts).
  A full-range map needs `/etc/subuid` + newuidmap provisioning in the
  container — revisit with the image stage if it starts to matter.
- **`make_squashfs_image()`** (rootfs.sh): `mksquashfs -comp zstd
  -noappend`, plus `-mkfs-time`/`-all-time $SOURCE_DATE_EPOCH` when set
  (full repro plumbing is a later item; the env var is honored now).
  Fails the build if the squashfs exceeds `[partitions].rootfs_size`.
- **Shadow permissions**: `10-create-users.sh` now branches on
  `ROOTFS_TYPE` — prod restores the packaged `/etc/shadow` mode (000) and
  sets the shadow-suite backups to 600 root; the dev-only
  readable-for-mkfs chmod (gap fix #11) is unchanged on the ext4 path.
- Also fixed while validating: `kernel.sh` `modules_install` passed
  `LLVM=1` without `STRIP=`, so `INSTALL_MOD_STRIP=1` invoked bare
  `llvm-strip` (not on PATH in the container) → exit 127; it now passes
  the toolchain's llvm-strip by absolute path.
- **Validation** (`w1-04-rootfs-prod.log`): prod squashfs builds in the
  userns (51 MB vs the 512M slot limit); `unsquashfs -lln` full scan shows
  **zero non-root-owned entries**, `-lls`: `/etc/shadow` `----------
  root/root`, `/etc/shadow-` 600 root, setuid bits intact
  (`usr/bin/passwd`, `usr/bin/mount` `-rwsr-xr-x root/root`); superblock
  says zstd.

### Item 14 — kernel fragment fix (boot-failure diagnosis)

- **Diagnosis** (rootfs early scripts + helpers, p1-09 boot log):
  `early-binfmt` runs `binfmt.sh`, which mounts
  `/proc/sys/fs/binfmt_misc` and execs the binfmt helper —
  `CONFIG_BINFMT_MISC` was unset in the arm64 defconfig, so the helper
  exited 1. `early-sysctl` applies `/usr/lib/sysctl.d/*.conf`;
  `10-chimera-user.conf` sets `kernel.yama.ptrace_scope=1` but the
  defconfig does not enable the Yama LSM, so the key was missing (every
  other shipped key — `kexec_load_disabled`, `unprivileged_bpf_disabled`,
  `perf_event_paranoid`, `dmesg_restrict`, … — already existed). Fix:
  **`boards/common/kernel/dinit.fragment`** with `CONFIG_BINFMT_MISC=y` +
  `CONFIG_SECURITY_YAMA=y` (the default `CONFIG_LSM` string already lists
  yama).
- **`boards/common/kernel/rauc.fragment`** created per docs/02 §6 (also
  serves item 9's squashfs-as-root need): `SQUASHFS`+`SQUASHFS_ZSTD`+
  `SQUASHFS_XATTR`, `BLK_DEV_LOOP`, `MD`+`BLK_DEV_DM`+`DM_VERITY`,
  `BLK_DEV_NBD`, `CRYPTO_SHA256` — all `=y` (no initramfs, AD-006).
  EFI vars are deferred to the x86_64-efi board fragment. Common
  fragments are merged automatically by `build/lib/kernel.sh`; the
  qemu-aarch64 board.toml documents this next to `config_fragments`.
- **Validation**: kernel reconfigured + rebuilt (`w1-01-kernel.log`;
  merged .config verified to contain all new options), dev image rebuilt
  and booted (`w1-05-boot-dev.log`): **zero `[FAILED]` services**,
  `early-sysctl` and `early-binfmt` both `[ OK ]`, prompt
  `qemu-aarch64-development login:` reached.
- **Prod boot smoke** (optional part of item 9, `w1-06-boot-prod.log`):
  QEMU with the squashfs as `/dev/vda`, injected
  `root=/dev/vda rootfstype=squashfs ro` — kernel mounts the zstd
  squashfs read-only, boot reaches `qemu-aarch64-production login:`.
  Two expected RO-root failures remain (`early-rng` seed write,
  `early-machine-id` `/etc/machine-id` write): both need the mutable
  `/data`/tmpfiles layer that arrives with the image stage (wave 2 /
  AD-005) — not kernel or ownership issues.

## 12. M1 wave 2: A/B images, real bootloaders, new boards (2026-07-17)

Plan items 10, 11, 12. Logs: `build/state/logs/w2-*.log`; boot evidence per
board: `w2-boot-<board>-<variant>.log`.

### Item 10 — image stage (`build/lib/image.sh`, replaces the stub)

- **Fully unprivileged** AD-007 assembly (docs/04 §2/§6): no sudo, no
  losetup, no kernel mounts. `build/lib/image_layout.py` is a pure
  function board-config-JSON → byte-exact offsets + sfdisk script
  (1 MiB-aligned, canonical 7-partition order esp/bootenv/boot.A/rootfs.A/
  boot.B/rootfs.B/data, exact PARTLABELs, ESP/linux GPT type GUIDs);
  `truncate` sparse file → `sfdisk` (works on plain files) → per-partition
  population via `dd seek` at the computed offsets. vfat partitions
  (esp, bootenv, boot.A/B) are built as free-standing `mkfs.vfat` images
  populated with mtools (`mcopy`/`mmd`); rootfs slots take the prod
  squashfs verbatim (size re-checked against `[partitions].rootfs_size`)
  or, for dev variants, an ext4 built with `mkfs.ext4 -d`; the data
  partition is `mkfs.ext4 -L data -d <skeleton>` at `data_min_size` with
  the AD-005 §4.1 skeleton (`config/ overlay/etc overlay/.etc-work
  var/log apps keys/seedrng .astro/` + `.astro/data-version`). Both
  `mkfs.ext4 -d` invocations run under `unshare -r` (+`-E root_owner=0:0`)
  so trees are recorded root-owned without sudo.
- **Determinism**: with `SOURCE_DATE_EPOCH` set, disk GUID + partition
  GUIDs are UUIDv5 hashes of (board, partition, epoch) — byte-identical
  layout JSON verified across runs; `mkfs.vfat --invariant` is used when
  the variable is set. (Full image reproducibility is still the later
  docs/03 §7 item.)
- **Outputs** per docs/04 §6 into `build/state/images/<board>-<variant>/`:
  `astro-<board>-<version>.img` (kept raw for run-qemu), `.img.zst`,
  `.qcow2` (qemu-img, for `[qemu]` boards), `SHA256SUMS`, `manifest.json`
  (board/variant/version/arch/kernel/rootfs-type/cports-pin/RAUC
  compatible + artifact sha256s). Version is `${ASTRO_VERSION:-0.0.0-dev}`
  (docs/10 §2 versioning is later work).
- **Dev variants map onto the same A/B layout**: identical GPT, identical
  PARTLABELs; each rootfs slot carries a rw ext4 (built from the dev
  rootfs tree, sized exactly `rootfs_size`) instead of the squashfs, and
  the generated boot config uses `rw` instead of `ro` root flags. RAUC/
  bootloader behavior is therefore identical across variants.
- **Kernel/DTBs left the rootfs** (docs/02 §6): `install_kernel_to_rootfs`
  now installs only modules; the kernel image (+ board dtb when
  `[kernel].dtb` names one) goes into both boot slots at image time. The
  prod squashfs shrank 51 MB → 30 MB.
- **Deleted**: `build/create-system-image.sh` (sudo+losetup+parted
  prototype, contradicted the container design) and its only consumers
  `build/cbuild-profiles/devices/{generic-arm,rpi}.conf`.

### Item 10b — RO-root boot glue (mutable state, AD-005; docs/02 §4/§5)

- **`data-mount` early dinit service** (docs/02 §5.1 "data.mount" node,
  expressed in dinit-chimera early conventions):
  `boards/common/overlay/etc/dinit.d/data-mount` runs
  `/usr/lib/astro/data-mount.sh`, which mounts tmpfs on `/tmp`,
  `/var/tmp`, `/var/cache` (size-capped, harmless on dev), then — iff
  `findfs PARTLABEL=data` resolves — mounts `/data` (ext4), creates the
  AD-005 skeleton (factory-reset-safe), mounts the `/etc` overlayfs
  (upper `/data/overlay/etc`, work `/data/overlay/.etc-work`), and binds
  `/data/var/log` → `/var/log` and `/data/keys/seedrng` →
  `/var/lib/seedrng`. Without a data partition (direct-boot dev disks)
  everything /data-backed is skipped, exit 0.
- **Ordering** without patching packaged services: a 1-line shadow of
  `early-fs-local.target` in `/etc/dinit.d` (dinit's service-dirs order
  is /etc → /usr/lib, verified in the dinit binary) adds
  `waits-for: data-mount`. dinit-chimera's own graph does the rest:
  `early-rng` waits-for `early-fs-local.target` and `early-machine-id`
  depends-on `early-rng`, so the seed dir and writable `/etc` exist
  before either runs. `waits-for` (soft) keeps a failed/absent data
  partition from stopping boot. The shadow must be re-diffed when the
  cports pin moves (noted in the file).
- **machine-id**: factory `/etc/machine-id` is an EMPTY file in
  `boards/common/overlay`. Trace through dinit-chimera's scripts
  (`env.sh`/`machine-id.sh`/`done.sh`): empty-but-present means env.sh
  never flags first-boot (it runs before any mount, so it must see a
  stable answer from the squashfs); machine-id.sh generates into
  `/run/dinit/machine-id` and bind-mounts it over `/etc/machine-id`
  (works even on RO root); done.sh commits it through the /etc overlay at
  boot end → subsequent boots see a non-empty `/etc/machine-id` from the
  overlay upper and keep it stable. `/var/lib/seedrng` is a real
  directory in the rootfs (bind target; rootfs.sh base-structure list).
- **Kernel**: new `boards/common/kernel/state.fragment`
  (`CONFIG_EXT4_FS=y` + `CONFIG_OVERLAY_FS=y` — /data and the /etc
  overlay are pre-module, no initramfs); `dinit.fragment` gained
  `CONFIG_SECURITY=y` (multi_v7_defconfig has no LSM framework → YAMA
  silently dropped) and `CONFIG_BPF_SYSCALL=y`
  (`kernel.unprivileged_bpf_disabled` needs the syscall; x86_64/multi_v7
  defconfigs leave it off) from the new-board bring-up.

### Item 11 — bootloader stage (`build/lib/bootloader.sh`, replaces the stub)

- **U-Boot (qemu-aarch64 / qemu-armv7)**: pinned upstream release
  **2026.07** (tarball fetch like the kernel's, into `sources/`), board
  defconfigs `qemu_arm64_defconfig` / `qemu_arm_defconfig`, built
  out-of-tree into `build/state/<arch>/u-boot/<board>/`, artifact +
  `u-boot-initial-env` copied to `build/state/<arch>/bootloader/<board>/`.
  Board Kconfig fragments (`boards/<board>/uboot/*.fragment`) are merged
  by append+`olddefconfig` with a post-merge assertion that every `=y`/`=`
  option survived.
- **Boot logic** (docs/04 §4): `boards/common/uboot/boot.script.in` — the
  AD-009 loop over `${BOOT_ORDER}` with `BOOT_<slot>_LEFT` decrement +
  `saveenv` before each attempt, `part number virtio 0 boot.<slot>`
  (PARTLABEL lookup), `fatload` of the kernel, bootargs
  `root=PARTLABEL=rootfs.<slot>` + `ro|rw` + `rauc.slot=<slot>`,
  `booti`/`bootz` with QEMU's generated FDT (`${fdtcontroladdr}`),
  fall-through on any failure, `reset` when nothing boots. Compiled to
  `boot.scr` by the image stage (mkimage) and placed on the **ESP**,
  where U-Boot's standard-boot script bootmeth finds it scanning the
  virtio disk. Kept deliberately QEMU-specific; hardware boards get their
  own template at M5.
- **GRUB (qemu-x86_64)** (docs/04 §3): `grub2-mkimage -O x86_64-efi -p
  /EFI/BOOT` core image (GPT/FAT/loadenv/linux/serial modules compiled
  in) as `EFI/BOOT/BOOTX64.EFI`; static `boards/common/grub/grub.cfg.in`
  implements RAUC's documented ORDER/`<slot>_OK`/`<slot>_TRY` flow
  (mark-TRY before boot, `save_env`, pick first OK slot with no failed
  try), `load_env`/`save_env --file (hd0,gpt2)/grubenv`. Initial env via
  `grub2-editenv create` + `ORDER="A B" A_OK=1 B_OK=1 A_TRY=0 B_TRY=0`;
  U-Boot initial env `BOOT_ORDER="A B" BOOT_A_LEFT=3 BOOT_B_LEFT=3`
  (docs/04 §4) — seeded as **default-env + Astro vars** via the
  `u-boot-initial-env` make target, because an env file *replaces* the
  built-in environment wholesale (first attempt with only the BOOT_*
  vars lost `bootcmd`/`kernel_addr_r` and dropped to the prompt).
- **Note**: `rauc-mark-good` does not exist until the M2 bundle/astrod
  work, so `BOOT_x_LEFT`/`x_TRY` decay across boots by design (3 tries
  per slot, then fallback). Fine for CI-style boots; documented here so
  nobody wonders why counters shrink.

### Item 11 deviations (docs/04 §4 vs what QEMU allows)

1. **U-Boot env placement**: AD-009 wants a raw REDUNDANT env at fixed
   offsets in `bootenv`. U-Boot has **no raw-block env backend for
   virtio** storage (`ENV_IS_IN_MMC/SPI/FLASH...` only), so the QEMU
   boards use **env-in-FAT on bootenv-as-vfat** (`CONFIG_ENV_IS_IN_FAT`,
   `virtio 0:2`, file `uboot.env`, `CONFIG_ENV_SIZE=0x10000`,
   `CONFIG_FAT_WRITE`), single copy (no redundant-env support for FAT
   files here). Same BOOT_ORDER semantics; libubootenv/fw_env.config on
   the userspace side can point at the same FAT file (M2). Real hardware
   boards (eMMC/SD) can and should use the raw redundant env per AD-009.
   Recorded in `boards/*/uboot/env.fragment`.
2. **U-Boot compiler**: clang/lld-built U-Boot (SDK wrappers,
   `-fintegrated-as`; lld link passes `checkarmreloc` with only
   R_AARCH64_RELATIVE) **hangs at self-relocation on qemu virt** right
   after the `DRAM:` banner — reproduced on both 2026.07 and 2025.10,
   arm64. QEMU boards pin `u_boot_compiler = "gcc"` (schema field that
   existed for exactly this) using the container's Fedora cross-gcc
   (`gcc-aarch64-linux-gnu`/`gcc-arm-linux-gnu`); the clang path remains
   wired (integrated-as + `-Qunused-arguments` so U-Boot's `cc-option`
   probes work against the wrappers) for a future root-cause pass.
3. **TOOLS_LIBCRYPTO off**: Fedora 44's openssl-devel dropped the ENGINE
   headers U-Boot's host signing tools include; FIT signing is unused
   here (boot.scr is compiled by the container's own mkimage), so the
   fragments set `# CONFIG_TOOLS_LIBCRYPTO is not set`.

### Item 12 — new boards + arch wiring

- **`boards/qemu-armv7/`**: armv7hf, `-M virt -cpu cortex-a15`, ttyAMA0,
  kernel 6.12.95 `multi_v7_defconfig` + virtio qemu.fragment,
  `lto = "none"` (kernel clang-LTO is arm64/x86-only), U-Boot
  `qemu_arm_defconfig`, `[rauc] bootloader = "uboot"`. dev+prod variants,
  both **source** packages-mode (no Chimera armv7 binary repo). The
  container runs 32-bit guests via `qemu-system-aarch64 -cpu cortex-a15`
  (no qemu-system-arm package; run-qemu.sh falls back automatically).
- **`boards/qemu-x86_64/`**: x86_64, q35 + OVMF (`[qemu].firmware`, new
  schema field), ttyS0, kernel `defconfig` + virtio/EFI qemu.fragment
  (incl. `CONFIG_EFIVAR_FS`), `[bootloader] type = "grub-efi"`,
  `[rauc] bootloader = "grub"`. dev+prod variants both **binary**
  packages-mode — a recorded deviation for prod: a cold x86_64 source
  build re-runs the multi-hour llvm template natively before anything
  boots; flip to source (or `--packages-mode=source`) once CI seeds an
  x86_64 package cache.
- **Arch mapping** (`cbuild_arch_for` in `build/lib/common.sh`):
  board arch → cbuild/apk arch (`armv7hf` → `armv7`, else 1:1), used by
  the packages stage (`cbuild -a`), repo paths
  (`cports/packages/main/<arch>`) and `apk --arch`; kernel/toolchain
  paths keep the board arch (`build/state/armv7hf/...`,
  ARCH=arm/zImage via the existing `kernel_arch_map`).
- **SDK toolchains**: `build-toolchain.sh armv7hf` and `x86_64` both ran
  (first exercise of the x86_64 path — worked as-is; LLVM build is
  shared and skipped, per-arch musl/compiler-rt/libc++ built in minutes).
  Fixes: generated wrappers now include `<triple>-readelf` (llvm-readelf
  is an argv0-symlink to llvm-readobj — the LLVM install ships no
  llvm-readelf binary; U-Boot's `checkarmreloc` needs it), and
  `build-inner.sh`'s toolchain step checks per-arch wrappers instead of
  just the shared `toolchain/bin/clang`.
- **Kernel stage fix**: with `LLVM=1`, HOSTLD/HOSTAR default to bare
  `ld.lld`/`llvm-ar` (not on PATH in the container) — x86_64's objtool
  host build failed exit 127; `kernel.sh` now passes both by absolute
  path (same class as the earlier `STRIP=` fix).

### Container changes (both recorded in `container/Containerfile`)

1. `qemu-img` (qcow2 conversion), `swig`/`python3-devel`/
   `python3-setuptools` (U-Boot pylibfdt), `gnutls-devel`/`libuuid-devel`
   (U-Boot tools), `bzip2` (U-Boot tarballs).
2. `gcc-aarch64-linux-gnu`, `gcc-arm-linux-gnu` (+ binutils) — the
   U-Boot compiler deviation above.

### Packages-stage refinements (hit during the armv7/x86_64 runs)

- **Binary-mode source subset**: patch-derived templates (today: `llvm`)
  are now built only when the manifest actually lists them
  (`resolve_patched_templates` + intersection in `build-inner.sh`).
  Rationale: the llvm patch is a no-op for native profiles and *removes*
  mlir/flang on cross — building it for hours on boards that never
  install it (x86_64 prod) buys nothing, and Chimera's native binaries
  are strictly more complete for dev use; where a Chimera binary shadows
  a subset template the skew report still flags it loudly. astro-cports
  shadows and `boards/common/source-packages.list` keep unconditional
  forced-source semantics.
- **Dependency distfile fetch fallback generalized**: cbuild fetch
  failures are now mapped to the *failing template(s)* parsed from the
  log (`<name>-<ver>-r<rel>: ERROR: failed to fetch`), not just the
  top-level template — first hit: `readline` (a dinit-chimera → bash
  dependency) while git.savannah.gnu.org was down.
- **`astro-cports/main/readline` shadow** (recorded): savannah's cgit
  snapshot URL is unreachable (multi-minute stalls → HTTP 400) with no
  checksum-compatible mirror; the shadow builds the same code from the
  GNU release tarball (`readline-8.3` via `$(GNU_SITE)`) + the official
  `readline83-001` patch regenerated as an exact-context unified diff
  (pkgver stays `8.3.001`, pkgrel 2). Drop when the pin moves or
  savannah recovers.

### armv7 full source build (seeds `cports/packages/main/armv7`)

Completed 2026-07-17 (after a host reboot killed the first run mid-LLVM;
logs `w2-01-armv7-packages-r{3..9}.log`). The interrupted armv7 kernel
build dir had truncated objects from the power cut (`vmlinux.a: not an
ELF file`) and was rebuilt from scratch. LLVM finished on the ccache-warm
retry. Because Chimera publishes **no armv7 binary repo**, the runtime
closure of every subpackage must self-build — that surfaced a chain of
first-time-from-source breaks, each now handled:

- **`main/fakeroot` checksum**: salsa.debian.org regenerated its tag
  archive; pinned sha256 (still stale upstream) fails any cold fetch.
  Carried `build/patches/cports/0002-*` after content-verifying the new
  tarball against a git clone of the tag (trees identical).
- **`bootstrap:cbuild` unresolvable**: `-bootstrap` packages (here
  `gnutls-bootstrap`, wanted by curl/ngtcp2) auto-depend on the
  `bootstrap:cbuild` virtual, provided only by `base-cbuild` — present in
  Chimera's binary repos but never in a self-built armv7 repo. Fixed by
  building `main/base-cbuild` for armv7 (one-time seed, now in the repo;
  binary-repo arches never hit this).
- **`main/doctest`** (dep of ccache ← base-cbuild): bundled examples use
  `-Werror` and clang 22's new `-Wc2y-extensions` fires on `__COUNTER__`.
  Carried `0003-*` (disable DOCTEST_WITH_TESTS; header-only package).
- **`main/boost`** (dep of protobuf-c): b2 never builds the stacktrace
  addr2line backend on arm_32 but the template packages it → `take()`
  failure, then a parent-package lint failure when over-removing (basic
  *is* built). Carried `0004-*` (drop addr2line from `_libs` on
  armv7/armhf only).
- **`main/elfutils` → protobuf dead end**: debuginfod pulls
  libmicrohttpd → gnutls → unbound → protobuf-c → **protobuf, which is
  marked broken for cross in its own template**. Carried `0005-*`
  (Astro-local deviation, documented in UPSTREAMING.md): debuginfod off
  on armv7/armhf; libelf/libdw (needed by makedumpfile for
  dinit-chimera-kdump) unaffected. The honest upstream fix is making
  protobuf cross-buildable.
- **`main/gettext` parallel-make flake** (not patched): first build died
  with `error_at_line` undeclared in gnulib's *generated* `error.h`
  (half-written under `make -j24`); the second attempt in the same run
  passed. Cold rebuilds may trip it again — rerun before diagnosing.

Environment note: after the reboot, outbound **port 80 is blocked
host-wide** (HTTPS fine). Plain-http distfiles (e.g. libcap-ng from
people.redhat.com) were pre-fetched over HTTPS into `cports/sources/`
with checksum verification; the curl-fallback fetcher only helps when the
host is reachable at all, so http-only sources will keep failing until
the network block is lifted.

### Acceptance evidence (real-bootloader A/B boots)

All full-image boots go through the real bootloader (U-Boot boot.scr /
GRUB EFI), select slot A, mount `root=PARTLABEL=rootfs.A`, and reach a
login prompt with **zero failed services**:

- `qemu-aarch64` prod + dev: `w2-boot-qemu-aarch64-{prod,prod-2nd,dev}.log`
  (pre-reboot; kernel verified to already satisfy the final fragment set,
  no rebuild needed).
- `qemu-x86_64` prod: `w2-boot-qemu-x86_64-prod-sysctl.log` — kernel
  rebuilt with the sysctl fragments (the stage's `.kernel-version` skip
  check does not detect fragment changes; marker was removed by hand —
  known sharp edge), `early-sysctl`/`early-binfmt` now `[ OK ]`.
- `qemu-armv7` prod: `w2-boot-qemu-armv7-prod.log` — first boot cascaded
  38 service failures out of `early-cgroups`: `multi_v7_defconfig` has
  `CONFIG_CGROUPS` but **zero controllers**, so `cgroup.controllers` is
  empty and dinit-chimera's `read -r … < cgroup.controllers` under
  `set -e` exits 1. Fixed in `boards/common/kernel/dinit.fragment`
  (controller set matching arm64/x86_64 defconfigs); clean boot after
  kernel rebuild. x86_64's config gains MEMCG/CGROUP_BPF from the same
  fragment edit on its next rebuild (boots fine without them; parity
  refresh pending).

QEMU-boot capture note: `podman run … run-qemu.sh` must redirect output
*inside* the container (host-side redirection of the podman invocation
loses the serial stream under the CLI sandbox).

## 13. M1 close-out: boot-success, /data growth, boot-smoke stage (2026-07-18)

The remaining M1 definition-of-done items (docs/11 §1), verified by the
new boot-smoke stage across all six board/variant combos (junit results
in `build/state/test-results/`, serial logs `boot-smoke-<board>-<variant>.log`):

- **`boot-success` milestone + astrod stub** (docs/02 §5.1, AD-011):
  `astrod` is an M1 health-check placeholder (`/usr/lib/astro/astrod-stub.sh`,
  scripted: /data mounted + /etc overlay active when a data partition
  exists; the real Zig daemon takes over this graph position at M3).
  `boot-success` is `type = internal`, `depends-on: astrod` + `data-mount`,
  always enabled into `boot.d` by the common enable-services hook (soft
  from `boot`, so a failed health check surfaces without blocking login).
  `rauc-mark-good` gains `depends-on: boot-success` at M2.
- **`/data` grown + mounted** (docs/02 §4): `data-mount.sh` grows the
  last-partition GPT entry with sfdisk (`', +'`, `--force` relocates the
  backup header on reflashed-larger disks), updates the kernel view with
  `resizepart`, then `e2fsck -p` + `resize2fs`. Idempotent (no-op under
  ~1 MiB slack). New base packages: `util-linux-fdisk`, `e2fsprogs`
  (e2fsprogs cross-built clean for armv7 first try). The grow event is
  echoed to `/dev/console` — dinit does not forward early-script stdout
  to serial, and boot-smoke asserts on the line.
- **boot-smoke test stage** (GAP §4 item 8): `build/test-boot-smoke.sh
  <board> <variant>` — self-containerizing; boots the image via
  `run-qemu.sh --image --scratch=+1G`; polls the serial log and exits at
  verdict (~35-40 s) instead of a fixed timeout; asserts boot-success
  reached, login prompt, zero `[FAILED]`, growth ran; writes junit XML.
  `run-qemu.sh --scratch` also fixes a latent artifact-hygiene bug: a
  plain `--image` boot writes bootloader env + /data mutations INTO the
  built artifact; the scratch qcow2 overlay keeps it pristine.
- **Kernel stage staleness** (GAP §4 item 11): both skip markers now
  carry a hash of defconfig + all fragments (merge order) + LTO mode;
  fragment edits trigger reconfigure+rebuild automatically, unchanged
  inputs still skip. Validated in both directions on armv7.

## 14. M2: RAUC end-to-end — updates itself (2026-07-19)

Definition of done (docs/11 §1): image + bundle stages, per-board
system.conf, dinit glue, mark-good, poisoned-bundle rollback, AD-020
gate on, dev PKI. All landed; the AD-020 gate passes on all three QEMU
boards (junit in `build/state/test-results/ad020-<board>.xml`, serial
logs `ad020-<board>.log`):

| board | backend | flip verified | rollback verified |
|---|---|---|---|
| qemu-armv7 | uboot | 162 s | 517 s (3 watchdog reboots) |
| qemu-aarch64 | uboot | 117 s | 404 s (3 watchdog reboots) |
| qemu-x86_64 | grub | 103 s | 254 s (1 try — grub's x_TRY logic falls back faster than U-Boot's 3×LEFT counters, by design) |

All six board/variant boot-smokes remain green with the update stack
aboard (dbus-daemon, rauc, bootenv-mount, rauc-mark-good,
astro-boot-watchdog).

### What shipped

- **Dev PKI** (`build/astro-keys.sh init-dev`, docs/05 §6): committed
  dev RAUC CA + signing cert (EC P-256, "ASTRO DEV - DO NOT SHIP") and
  an SSH test keypair installed as root authorized_keys on DEV variants
  only (hook `30-dev-ssh-key.sh`) — the AD-020 harness and later `astro
  deploy` (M4) drive dev guests with it. Per-artifact idempotent.
- **Packages**: `astro-cports/main/rauc` (1.15.2: service+network+
  streaming+json+gpt on, verity; no -devel) and
  `astro-cports/main/libubootenv` (0.3.7). New base packages: dbus,
  rauc; per-board: libubootenv-progs (uboot boards), grub (grub boards,
  for grub-editenv — slim-subpackage optimization deferred).
- **system.conf** generated in the rootfs stage from `[rauc]` board TOML
  (compatible, backend; slots per AD-007; statusfile on /data;
  bundle-formats=verity) + dev keyring at /etc/rauc/keyring.pem +
  /etc/fw_env.config on uboot boards (env-in-FAT file, size read from
  the board's CONFIG_ENV_SIZE fragment).
- **dinit glue** (docs/05 §4): `rauc` (process, waits-for dbus-daemon),
  `bootenv-mount` (vfat bootenv at /run/astro/bootenv — both backends
  need the env as a file), `rauc-mark-good` (scripted, depends-on
  boot-success + bootenv-mount; retry w/ backoff; console line asserted
  by the gate), `astro-boot-watchdog` (docs/05 §4 watchdog: forces a
  reboot when boot-success is not reached — default 300 s, overridable
  via /data/.astro/boot-watchdog-timeout; detached via setsid so no
  process-exit bookkeeping surfaces as a service failure).
- **Bundle stage** (`build/lib/bundle.sh`, `--step=bundle`, in the
  default pipeline): verity + `adaptive=block-hash-index` on the rootfs
  image, boot slot vfat included, signed with the dev cert, verified
  against the device keyring at build time (`.raucb.info` evidence).
- **AD-020 harness** (`build/test-update-rollback.sh <board>`): SSH-driven
  against the dev variant on a +1G scratch overlay; phase 2 installs the
  current bundle and asserts the A→B flip + mark-good; phase 3 builds a
  poisoned bundle at test time (debugfs removes the astrod stub from a
  copy of the slot image → boot-success unreachable), installs it, and
  asserts automatic fallback to the good slot after watchdog-forced
  attempts. junit output.

### Bugs found by the gate (the reason AD-020 exists)

1. **libubootenv must be built with -DNDEBUG**: `libuboot_open()`
   prints "Environment OK, copy 0" to **stdout** when NDEBUG is unset
   (cbuild's buildtype=plain sets nothing). RAUC parses fw_printenv
   stdout, so the diagnostic was ingested into variable values and
   written back — after a few install/mark-good round-trips the env
   contained several junk `BOOT_ORDER=… OK, copy 0` variables and slot
   selection wedged (U-Boot looped loading the env without attempting
   any slot). Fixed in the template (tool_flags CFLAGS -DNDEBUG);
   upstreamable to libubootenv as "don't print to stdout from library
   open".
2. **sshd never started on any A/B dev image** (latent since M1 — a
   never-activated service produces no [FAILED] line, so zero-FAILED
   assertions can't see it): `ssh-keygen -A`'s RSA host key generation
   is effectively unbounded on TCG-emulated guests (observed stuck
   forever on qemu-armv7). The openssh shadow now generates an ed25519
   host key only (`files/gen-host-keys`, pkgrel 3) — instant everywhere,
   unique per device.
3. **QEMU default-NIC double-slirp**: a bare `-netdev` does NOT
   suppress QEMU's default NIC (only `-nic`/`-net` do) — with the boards'
   old hardcoded hostfwd NIC plus the launcher's, guests had two
   interfaces both claiming 10.0.2.15 and hostfwd replies died. Boards
   no longer declare NICs (host ports are a launcher concern);
   `run-qemu.sh --ssh-port=N` adds `-nic none` + one user netdev
   (mmio virtio-net-device on arm virt, pci on q35).
4. **glib/json-glib cannot cross-build as pinned** (rauc deps, first
   cross exercise): gobject-introspection is `!cross`, and glib's
   enabled sysprof leaves `Requires.private: sysprof-capture-4` in
   glib-2.0.pc that nothing in a self-built repo provides — carried
   patches 0006/0007 disable introspection (both) + sysprof (glib) for
   cross profiles.
5. **cross sysroot bootstrap residue**: glib's build leaves
   glib-bootstrap pinned in the cross sysroot world; the real glib then
   conflicts (`!glib`) on the next consumer. The cross dep-install path
   never rewrites the world — resetting the sysroot
   (`rm -rf cports/bldroot/usr/<triple>`) is the workaround; a proper
   fix belongs in cbuild (noted, not carried).

Also: `prepare_cports_tree` now runs `cbuild relink-subpkgs` after
applying shadows (new-package shadow templates have no committed
subpackage symlinks, and the tree reset removes generated ones);
Chimera's lint forbids /usr/libexec in packages (gen-host-keys lives in
/usr/lib/openssh; the overlay's /usr/libexec/astro/mark-good is
image-level, not packaged, per docs/05 §4).

## 15. M3 phase 1: real astrod aboard — walking skeleton on the image (2026-07-20)

The Zig daemon (astrod/ — see docs/06) replaces the M1 health-check stub
in the same graph position; `astroctl` ships as a multi-call symlink.
Build integration: `build/lib/astrod.sh` (`build_astrod`) cross-builds
ReleaseSafe static musl binaries with the container's pinned Zig inside
the rootfs stage (no nested container), asserts no-INTERP + the docs/06
§3 ≤ 8 MiB budget, and installs `/usr/bin/astrod` + `astroctl` symlink.
Observed sizes: armv7hf 3.62 MiB, aarch64 4.10 MiB, x86_64 4.16 MiB.
CI: `astrod-unit` now real (container `zig build test` + x86_64 budget
assertion); `astrod-api` stays skipped until the phase-3 rig.

Verified on qemu-armv7 dev in-guest (serial:
`build/state/logs/astrod-validate.log`): `astroctl system`, both API
surfaces (unix socket sans token; 127.0.0.1:8080 bearer token, 401
problem+json without), `GET /openapi.json`, and `astroctl reboot` →
clean dinit teardown → U-Boot → boot-success again. Boot-smoke green
(zero FAILED) with readiness-gated astrod.

### Deviations from the docs (recorded, revisit markers inline)

- **Socket path** `/run/astro/astrod.sock` (docs/06 says
  `/run/astrod.sock`): the tmpfiles.d-created parent dir
  (0750 astrod:astro-api) is the group gate an unprivileged daemon can
  own. `/run/astro` is shared with bootenv-mount's `bootenv/` mount —
  tmpfiles re-owns the dir it already created.
- **Localhost port 8080** (docs/06 says :80): uid 300 cannot bind 80;
  revisit via dinit socket passing if :80 matters.
- **`/run/dinitctl` group-opened to `astrod`** (dinit creates it 0600
  root): tmpfiles `z /run/dinitctl 0660 root astrod` — timing safe
  because dinit opens the socket at `early-root-rw.target`
  (options: starts-rwfs → rootfs_is_rw()), strictly before
  early-tmpfiles. Deliberately the daemon's primary group, NOT
  astro-api: app users in astro-api must not get direct init control
  (docs/06 §5.4).
- **Reboot mechanism is dinit's control-socket SHUTDOWN command**, not
  the docs/02 §7 `sys-reboot`/`sys-poweroff` oneshots: dinit-chimera
  ships no such services (`/usr/bin/reboot` IS dinit's shutdown
  client). The SHUTDOWN is issued *after* the 202 hits the wire
  (router Context.deferred): issued inline, dinit killed astrod before
  the response bytes left and every client saw a truncated reply.
- **Store ownership**: firstboot seeds `/data/config/astro.json` as
  astrod 0600 and chowns `/data/config` to astrod:astro-api 0710 so the
  unprivileged daemon can do atomic tmp+rename rewrites; api-token
  stays root:astro-api 0640 (astrod reads it via astro-api membership —
  dinit run-as does initgroups). docs/06's "0640 root:astro-api" for
  astro.json is superseded by daemon-owned 0600/0640.
- os-release is now stamped at rootfs assembly with
  ASTRO_BOARD/ASTRO_VARIANT/ASTRO_RELEASE (`stamp_os_release`,
  build/lib/rootfs.sh; ASTRO_RELEASE = the same ASTRO_VERSION the
  image/bundle stages use) — system.zig prefers these keys, so
  `GET /system` reports real identity instead of "unknown". Found while
  validating: base-files ships tmpfiles
  `L+ /etc/os-release -> ../usr/lib/os-release`, force-recreated in the
  /etc overlay every boot — the old common-overlay regular file at
  `etc/os-release` was silently shadowed at runtime and its "Astro
  Linux" identity never actually served. The Astro document moved to
  `boards/common/overlay/usr/lib/os-release` (the canonical path);
  /etc/os-release stays the packaged symlink.

## 16. M3 phase 2 spine: basu linkage, threaded astrod, stub surface (2026-07-20)

The D-Bus/update groundwork under docs/06 §2 and docs/05 §5.1: astrod
gains src/bus.zig (the ONLY file with C sd-bus types), a threaded HTTP
server, and the routed-but-501 update/events/operations surface so the
AD-013 conformance gate pins the v1 contract before stage 2 fills it in.

- **basu static lib rebuilt with `!lto` (pkgrel 1)**: cbuild's LTO put
  LLVM-bitcode members in libbasu.a (readelf: "LLVM bitcode file"),
  which zig's linker rejects ("not an ELF file"). astro-cports/main/basu
  sets `options=["!lto"]`; r0 apks were deleted from packages/main/*
  (the mkndx staleness trap in packages.sh notes). apks are apk-tools 3
  ADB archives, NOT gzip tars — extraction uses `apk extract`.
- **astrod-deps extraction**: build/lib/astrod.sh `extract_astrod_deps`
  apk-extracts basu-devel + basu-devel-static into
  build/state/<board_arch>/astrod-deps/ (armv7hf maps to the armv7
  repo); astrod/build.zig `-Dbasu-prefix` (default:
  build/state/x86_64/astrod-deps so `zig build test` needs no flags —
  astro-ci.sh astrod-unit extracts before testing).
- **Zig 0.16 moved Mutex/RwLock behind std.Io** (Io.Mutex.lock(io));
  astrod deliberately avoids std.Io, and links musl anyway for basu, so
  src/sync.zig wraps pthread mutex/rwlock (zero-init == musl static
  initializers). std.posix.getenv is gone → std.c.getenv;
  init.gpa is documented threadsafe in 0.16 (no wrapper needed).
- **Threading model**: accept loop spawns a detached std.Thread per
  connection, cap 16 (over-cap: precomputed static 503
  urn:astro:problem:overloaded, verified live with 16 idle conns + a
  17th). auth token cache is mutex-guarded, store is RwLock-guarded
  (beginMutate/endMutate + persistLocked for mutate+persist sequences),
  system.collect* now allocates per-request (module statics removed),
  deferred SHUTDOWN still runs on the connection thread after the
  response bytes (discipline unchanged).
- **bus.zig threading**: dedicated bus thread (sd_bus_process loop +
  poll on bus fd + eventfd wake), ALL sd-bus access under one mutex;
  signal callbacks run on the bus thread with the lock held (must not
  re-enter Bus). Marshaling tests run offline on a socketpair-backed
  never-connected bus — NOTE: test teardown must use sd_bus_close, not
  sd_bus_flush_close_unref (flush waits ~90 s for the auth handshake
  that never comes; cost 3 min of test time until found).
- **RAUC interface truth** (rauc-1.15.2
  src/de.pengutronix.rauc.Installer.xml): Progress is `(isi)` —
  percentage, message, depth — not the `(iis)` some notes claimed.
- **Deferred to stage 2**: D-Bus policy file
  (usr/share/dbus-1/system.d/astrod.conf), astrod dinit service deps
  (depends-on dbus-daemon, waits-for rauc) — they belong with the code
  that actually opens the bus at startup.

## 17. M3 phase 2 complete: the update endpoint group is live (2026-07-20)

Stage-2 fill reconciled into the shared files: rauc.zig / ops.zig /
update.zig / events.zig are wired through router.zig + main.zig, the
OpenAPI spec matches the implementation, the D-Bus policy + service-graph
pieces ship, and the whole docs/05 §5.1 API workflow is verified live on
qemu-armv7 and by the AD-020 gate.

### What landed

- **Routes live**: `/update/status|/update|/update/apply|/update/rollback`
  → update.zig handlers (503 urn:astro:problem:rauc-unavailable while the
  daemon has no D-Bus connection — the API stays healthy without
  dbus-daemon/rauc); `/events` → SSE (subscribe + serveStream on the
  connection thread: no Content-Length, `retry:` prelude, 15 s keepalives,
  Last-Event-ID replay from the 1024 ring, lap = `event: overflow` marker
  then continue); `/operations[/{id}]` → ops.Registry snapshots
  (ops.global module global set by main; pre-restart ids 404 by contract).
- **HTTP layer**: query strings are split and threaded
  (`POST /update?force=true` — the only channel the octet-stream form
  has; OR-ed with the JSON body field); Content-Type + Last-Event-ID
  extracted; `POST /api/v1/update` with application/octet-stream DIVERTS
  the body straight into /data/.astro/staging via fsutil.writeStreamSync
  (never buffered — bundles are 50+ MiB against a 16 MiB RSS budget; the
  64 KiB body cap still guards every other route; auth is checked BEFORE
  the sink so unauthorized bytes never touch /data); max_connections
  16 → 32 (the 16-subscriber SSE budget must never starve interactive
  requests); statusText knows 409/502/507.
- **Startup wiring** (before the listeners bind, so readiness implies the
  subsystems exist): ops.Registry + events.EventBus always;
  bus.connectSystemRetry(5) + update.Manager.init (signal watches +
  restart re-attach probe) when the system bus answers, warn-and-503
  otherwise.
- **Spec truth restored** (AD-013): problem URNs now match the code
  (update-downgrade-refused, no-pending-update, no-rollback-target,
  insufficient-storage as 507, rauc-error as 502 with the D-Bus error
  name); UpdateStatus gained running_release/pending/current_operation/
  history (AD-021 surfacing); Operation gained `result`; the SSE overflow
  semantics are documented as marker-then-continue (supersedes the
  stage-2 stub's drop-and-close comment).

### Traps found live (each cost a debug cycle; recorded so they stay found)

- **InspectBundle's reply is `"update" -> v(v(a{sv}))` — DOUBLE variant.**
  rauc's r_manifest_to_dict inserts the group dicts with GVariantDict's
  `"v"` format, which wraps the a{sv} in a second variant inside the
  entry's own value variant (scalar keys like "manifest-hash" are
  single-wrapped). The offline expectation scripts pinned v(a{sv}) per a
  source reading that missed the GLib gotcha; live the parse failed with
  InvalidReply. Corollary fix: a client-side parse failure no longer
  prints lastDbusError — that error was STALE (a Spawn.PermissionsInvalid
  from the boot-time re-attach probe racing rauc's bus-name claim) and
  sent the diagnosis chasing dbus activation for a whole cycle.
- **astrod cannot mkdir /data/.astro/staging** (parent is root-owned —
  rauc.status lives there). tmpfiles.d/astrod.conf now creates it every
  boot (`d /data/.astro/staging 0755 astrod astrod -`); ordering is safe
  (early-tmpfiles runs after data-mount's target). Uploads 500'd with
  staging-failed until this landed.
- **dinit console handover swallows late OK lines.** astrod's new
  depends-on dbus-daemon pushed astrod/boot-success past login.target
  (options: runs-on-console) — the milestone WAS reached (rauc-mark-good
  ran) but `[  OK  ] boot-success` never hit serial and boot-smoke
  failed on a healthy boot. Fix in the service graph, not the assertion:
  boot-success AND rauc-mark-good gained `before: login.target` (pure
  ordering; also the honest UX — the login prompt now appears only after
  the boot is confirmed good). On a bad slot the milestone fails and
  login proceeds; watchdog rules unchanged (AD-011).
- **astroctl uploads masked early server answers.** When astrod answers
  before the body is done (401/503/507/staging-failed) and closes its
  read side, the client's next body write dies with EPIPE — uploadBundle
  used to report a bogus "cannot reach astrod" transport error and hide
  the problem+json. It now falls through to READ the response after a
  send failure.

### Verified

- Container `zig build test`: 106 pass, 3 skip (spec↔route conformance
  11 ops ↔ 11 routes); `zig fmt --check` clean; shellcheck clean at the
  repo's severity/exclusion set.
- Cross ReleaseSafe, basu linked, static (no INTERP), ≤ 8 MiB budget:
  armv7hf 5,279,016 B · aarch64 6,158,568 B · x86_64 6,118,856 B.
- boot-smoke qemu-armv7 dev: PASS (45 s to verdict, zero FAILED).
- In-guest e2e (qemu-armv7 dev, scratch overlay, 180 s): update status
  shows 4 slots/booted A/compatible astro-qemu-armv7; API install of the
  build's own bundle → op-1 polled to "install operation succeeded" with
  live progress; update.progress + update.completed observed on a live
  SSE stream AND again via Last-Event-ID replay; consumed staged upload
  unlinked; apply → reboot into slot B, marked good; AD-021 downgrade
  (0.0.0-aaa < 0.0.0-dev) refused 409 update-downgrade-refused with the
  kept staged path named in the detail; astrod VmRSS after all of it:
  1136 kB (budget 16 MiB).
- AD-020 gate `./build/test-update-rollback.sh qemu-armv7`: PASS in
  529 s — API-driven good-bundle install/apply with slot flip A→B at
  171 s (phase 2, incl. the update.progress event-ring assert), then
  direct-rauc poisoned install and automatic bootloader rollback to B
  after 3 watchdog reboots (phase 3).

### Still open (phase-3 material)

- URL installs bypass the AD-021 gate (no pre-install metadata for
  streamed sources) — documented v1 limitation in the spec.
- Refused uploads are kept in staging for the force flow and never
  auto-GC'd (operator-bounded); consider a startup sweep while RAUC is
  idle.
- The SSE subscriber a client abandons is reclaimed by the failing
  keepalive write (≤ 15 s); no idle-session timeout beyond that.

## 18. M3 phase 3 complete: the network group is live (2026-07-20)

The docs/07 network group is implemented, unit-verified and — the work
of this section — validated at image level on qemu-armv7 and
qemu-x86_64, including the first full wifi end-to-end (iwd AP on a
mac80211_hwsim radio, astrod station flow through the API).

### What landed (phase-3 code, summarized)

- **src/link.zig** — read-only rtnetlink: pure parsers over
  RTM_GETLINK/GETADDR dumps + a live Monitor thread
  (RTMGRP_LINK|IPV4_IFADDR|IPV6_IFADDR) feeding GET /network and
  carrier/address events. Netlink is OBSERVATION ONLY; route policy is
  expressed as `metric` values in the rendered dhcpcd.conf, never by
  rtnetlink surgery.
- **src/netconf.zig** — desired state → daemon-native files:
  /run/astro/net/dhcpcd.conf (interface allowlist, static blocks,
  per-interface metrics implementing the WAN order) and
  /run/astro/resolv.conf (one writer; static DNS beats DHCP-learned,
  WAN-preferred interface first), tmp+rename installs, `dhcpcd -n`
  rebind over the control socket, an inotify LeaseWatcher on
  /run/astro/net/leases/, and the docs/06 §4 generation counters.
- **src/wifi.zig** — iwd backend: a signal-fed mirror of iwd's
  ObjectManager tree, scan as a tracked operation completed by the
  Station.Scanning true→false edge, GetOrderedNetworks (model
  fallback), connect = persist to store + render `<ssid>.psk` into
  /data/net/iwd (iwd's dir watch picks it up; autoconnect is the
  degraded path) + best-effort Network.Connect, forget, and
  network.wifi.state events.
- **Graph/overlay**: iwd + dhcpcd dinit shadows (iwd gets
  STATE_DIRECTORY=/data/net/iwd via env-file and depends-on
  dbus-daemon; dhcpcd runs -f /run/astro/net/dhcpcd.conf with a
  tmpfiles-symlinked fallback config so DHCP works before/without
  astrod), the root-run dhcpcd lease-export hook
  (usr/lib/astro/dhcpcd-hook.sh → leases/<iface>.json), AD-015
  /etc/iwd/main.conf (EnableNetworkConfiguration=false), the
  resolv.conf tmpfiles override, and boards/common/kernel/
  astro-net.fragment (CFG80211/MAC80211/CRYPTO_USER_API_* =y) +
  MAC80211_HWSIM=y on the qemu test boards.
- **build/test-api.sh** — the docs/10 §4 "astrod-api" suite: boot,
  AD-014 auth matrix, rtnetlink eth0 observation, rendered resolv.conf,
  update-status regression, the hwsim wifi e2e (iwctl AP with iwd's
  built-in DHCP on radio 1 via a test-scoped /etc/iwd bind-mount
  override, then scan/connect/lease/forget THROUGH THE API on radio 0),
  and the docs/06 §3 RSS budget.

### The build blocker: two cross-only cports bugs (carried patches)

Cross-building main/iwd for the self-built armv7 repo hit two latent
bugs Chimera's native builders can never see:

- **dinit-dbus: "usvc: dbus-daemon (unknown provider)"**
  (0008-dinit-dbus-cross-makedepends-dbus-dinit.patch). The -dinit
  subpackage's service files depend-on dbus-daemon; the provider
  (dbus-dinit) reaches a NATIVE build sysroot by accident —
  checkdepends=["dbus"] installs dbus, and dbus+dinit-chimera trip
  dbus-dinit's install_if. Cross builds skip checkdepends entirely
  (cbuild core/dependencies.py:134 gates them on
  `not pkg.profile().cross`), so no package provides
  svc:/usvc:dbus-daemon and the 001_runtime_deps hook errors out. Fix
  is the hook's own hint: dbus-dinit added to makedepends. (The
  armv7 dbus-dinit apk itself was fine — `apk adbdump` showed the
  auto-generated usvc:dbus-daemon provides; the diagnosis that
  is_installed/get_provider disagreed was wrong: the log's `hint:` line
  is printed only by the final "not installed at all" branch. Latent
  upstream oddity seen on the way: scan_svc keys requirements by
  service name, so a name required as both svc and usvc records only
  the last-scanned prefix.)
- **iwd: D-Bus policy packaged under the sysroot prefix**
  (0009-iwd-cross-dbus-datadir.patch, pkgrel 0→1). iwd's configure
  resolves the dbus-1 datadir via `$PKG_CONFIG --variable=datadir
  dbus-1` (configure.ac:216); cbuild's cross pkgconf answers
  sysroot-prefixed, so iwd-dbus.conf landed in
  usr/armv7-…/usr/share/dbus-1/system.d/ inside the apk. On the image
  dbus-daemon then had no policy allowing root to own net.connman.iwd
  → RequestName denied → iwd crash-looped ("Name request failed /
  D-Bus disconnected, quitting…", 3 starts then dinit gave up).
  Fixed by passing --with-dbus-datadir=/usr/share explicitly.

Both are UPSTREAMING.md drafts now.

### Bugs found during image-level validation (root causes)

- **arm32 has no 64-bit atomics** — netconf.zig's generation counters
  were `std.atomic.Value(u64)`; Zig rejects atomics wider than the
  target word ("expected 32-bit integer type or smaller") so armv7
  astrod would not compile. Counters are usize now (monotonic
  comparison only; JSON marshaling widens to u64).
- **`std.mem.trimRight` no longer exists in Zig 0.16** →
  astroctl.zig's passphrase-prompt path used it; first caught by the
  armv7 cross compile because `zig build test` doesn't compile the
  astroctl entry path. `trimEnd` now.
- **astrod had no D-Bus grant for iwd — and three of four call sites
  masked it.** The phase-2 policy file deliberately deferred the
  net.connman.iwd grant to phase 3, and phase 3 forgot it. iwd's own
  policy default-denies non-root senders, so every astrod→iwd method
  call died with org.freedesktop.DBus.Error.AccessDenied — but
  GET /network/wifi/networks fell back to the mirrored model,
  connect() fell back to iwd autoconnect from the rendered profile
  (both by design), and the startup GetManagedObjects failure was an
  expected-looking info line. Only POST /network/wifi/scan surfaced
  the truth as 502 iwd-error. usr/share/dbus-1/system.d/astrod.conf
  now grants exactly the interfaces wifi.zig calls (ObjectManager,
  Station, StationDiagnostic, Network, KnownNetwork + Properties/
  Introspectable/Peer). Verified live by SIGHUPing dbus-daemon in a
  guest: scan → op-2 → succeeded → networks lists astro-hwsim at
  -30 dBm. Lesson recorded: degraded-not-error paths hide permission
  bugs — when a subsystem "works" but one call 502s, read the failed
  operation's `error` field (the op registry kept the D-Bus error
  name; /var/log/astrod.log had nothing).
- **Scan raced iwd's own scan → 502.** Right after an iwd (re)start,
  its autoconnect/periodic scan owns the radio and Station.Scan
  answers net.connman.iwd.InProgress (dbus_error_busy,
  station.c:4537). That is not a contract failure: wifi.zig now rides
  the in-flight scan to its Scanning-edge completion when the model
  shows scanning, else completes the operation against current
  results.
- **qemu-x86_64 had no network at all under the suite: udev's
  predictable naming.** 80-net-name-slot.rules renamed the PCI
  virtio NIC to enp0s2; the dhcpcd fallback allowlists eth*, the store
  model speaks eth0 — so nothing DHCP'd the interface, and the
  astrod-api CI board could never reach SSH (TCP connect via slirp
  accepted, banner exchange timed out — slirp's accept says nothing
  about the guest). The arm -M virt boards were immune BY ACCIDENT:
  mmio virtio has no slot identity, ID_NET_NAME_SLOT stays unset, the
  name stays eth0. Deliberate policy fix, not a workaround: the common
  overlay masks the rule (empty /etc/udev/rules.d/80-net-name-slot
  .rules) — Astro's docs/07 model is written in kernel names, and slot
  names buy nothing on fixed embedded hardware. Diagnosed by direct
  kernel boot of the rootfs with init=/bin/sh over piped serial
  (ls /sys/class/net → eth0 present with the slirp MAC, so the kernel
  and virtio-net were fine; the rename happens only once udevd runs).
- **Harness bugs (the suite must only depend on what the image
  ships):** the wlan1-AP-address assertion shelled out to `ip` and the
  RSS probe to `pidof` — neither exists on the image (silently fatal:
  the poll loops just timed out). Both now go through what is actually
  there: GET /network for the address (it is the surface under test
  anyway) and a /proc/<pid>/comm walk for the RSS read.
  test-update-rollback.sh additionally could hang forever on its
  `ssh … reboot` when QEMU's user-net left the forwarded TCP
  connection half-open after guest teardown (observed once: the
  harness sat 10 min while the rollback had long completed on serial);
  the harness SSH now runs ServerAliveInterval=5/CountMax=2.

### Verified (evidence: build/state/logs/, test-results/)

- Container `zig build test`: 152 pass / 4 skip; `zig fmt --check`
  clean; astrod cross ReleaseSafe static: armv7hf 6,350,124 B ·
  x86_64 7,353,200 B (≤ 8 MiB budget).
- Built kernel .configs (armv7 + x86_64) carry MAC80211_HWSIM,
  CFG80211, MAC80211, CRYPTO_USER_API_HASH, CRYPTO_USER_API_SKCIPHER
  all =y.
- boot-smoke qemu-armv7 dev: PASS, zero FAILED, 32–33 s to verdict
  (68 s once on a loaded host) — iwd/dhcpcd/astrod all [ OK ] in the
  new graph. Re-run green on the final image (udev mask included).
- **astrod-api qemu-armv7: PASS 7/7 in 62 s** (63 s on the final
  image; api-qemu-armv7.log):
  AP up on wlan1 192.168.80.1 with iwd's DHCP pool, scan operation
  succeeded on attempt 1 with astro-hwsim visible, station →
  connected, wlan0 leased 192.168.80.2 from the AP pool via dhcpcd,
  forget → disconnected; astrod VmRSS after the suite 1460 kB.
- **astrod-api qemu-x86_64: PASS 7/7 in 46 s** (api-qemu-x86_64.log);
  VmRSS 1516 kB. No arch-specific netlink parsing issues surfaced —
  the x86 failure above was policy, not structs.
- **AD-020 regression `./build/test-update-rollback.sh qemu-armv7`:
  PASS in 528 s** with the new service graph — API install + apply
  flip A→B verified at 119 s; poisoned slot rolled back to B after 3
  watchdog reboots (ad020-qemu-armv7.log).

### Deviations / notes

- Predictable interface naming is now masked device-wide (see above) —
  an Astro policy decision recorded here; revisit only if a board ever
  ships multiple same-class NICs.
- The iwd apks for armv7 are r1; the broken r0 files remain in
  cports/packages/main/armv7 but the index prefers r1 (no mkndx trap:
  pkgrel moved, unlike the §16 basu case).
- iwd's AP DHCP rig behavior confirmed as the suite header documents:
  profile [IPv4] + global EnableNetworkConfiguration=true are BOTH
  required; the suite's bind-mount override + `dinitctl restart iwd`
  choreography works, and the shipped AD-015 posture stays off.
- The anticipated wifi.zig staleness across the suite's mid-test iwd
  restart did NOT materialize: hwsim device paths are stable across
  restarts, dbus-daemon matches on the well-known name keep firing for
  the new owner, and InterfacesAdded re-fills the mirror. No
  NameOwnerChanged re-sync was needed; if a future board hot-swaps
  radios, revisit.

## 19. M3 phase 4 spine: provisioning state machine, surfaces, time (2026-07-20)

The phase-4 skeleton (docs/07 §3–§6): every typed interface the fill
stage implements against, plus the boards/build plumbing, landed and
unit-verified (container 190 pass / 4 skip; live surface smoke green).

### What landed

- **src/provision.zig** — the docs/07 §4 state machine as a PURE
  transition function `step(state, ap_active, event, obs) → Decision`
  plus a `Machine` wrapper executing effect callbacks
  (enterAp/leaveAp/persistState/announceMdns). Full transition-table
  tests incl. the wired path, api.wired_provisions, the AP
  wrong-password loop, and factory-reset re-entry. DEVIATION recorded:
  "connectivity verified" v1 = address + default route (gateway ping
  deferred).
- **Surface awareness** — auth.Surface {unix, localhost, lan, ap} tags
  every listener; auth.authorize() per surface; router.Context.surface;
  the AP surface serves ONLY the AD-014 unauthenticated subset
  (router.ap_allowed_routes; 403 urn:astro:problem:forbidden otherwise,
  even with a valid token) plus router.portal_routes (portal page +
  captive probes, AP-only, deliberately OUTSIDE the AD-013 gate — a
  test pins that they never enter /api/). GET /system on the AP surface
  is redacted (system.RedactedSystemInfo: machine_id omitted; a
  field-parity test forces a redaction decision for every new field).
- **src/timekeep.zig (fully implemented)** — build-epoch/last-known
  floor (applyFloor via clock_settime; EPERM DEVIATION recorded: the
  capless daemon can only gate, firstboot roots the boot-time floor),
  hourly persist Keeper + persist before deferred shutdowns, adjtimex
  STA_UNSYNC → time.synced in GET /system (SystemInfo + spec), and the
  docs/07 §6 https gate wired into POST /update URL installs
  (503 urn:astro:problem:clock-not-set).
- **Stubs with tested interfaces** — src/mdns.zig (announce-only
  responder; instanceLabel/TXT/name-encoding pure + tested, socket loop
  NotImplemented; no probing/conflict resolution v1 — machine-id-derived
  names), src/portal.zig (embedded portal page + probe 302s are REAL and
  routed; DNS catch-all on :5354 stubbed), wifi.zig AP extension points
  (apStart/apStop signatures; deriveApSsid/deriveApPsk
  (hmac-sha256(key=machine-id, msg="astro-ap-psk-v1")[0..16] hex) and
  renderApProfile implemented + tested against iwd-3.12 src/ap.c
  mechanics: StartProfile loads STATE_DIR/ap/<ssid>.ap with
  [Security].Passphrase + the [IPv4] pool block; the [IPv4] block needs
  global EnableNetworkConfiguration=true — the fill must flip it for the
  AP window).
- **Routes/spec** — GET,PUT /network/wifi/ap + POST /system/factory-reset
  routed as 501 stubs and documented (schemas WifiApState/WifiApConfig/
  FactoryResetRequest, Forbidden component, AP-surface story in
  info.description).
- **Boards/build** — nftables + chrony(+-dinit) into common
  packages.list (pin verified; nftables-dinit deliberately NOT
  installed); portal-redirect-{up,down}.sh + astro-portal-redirect-
  {start,stop} + astro-factory-reset dinit oneshots (root, dispatched on
  demand via the dinit client — not in boot.d); data-mount.sh
  factory-reset executor (flag → rm -rf of /data contents except
  lost+found, before anything reads /data; blkdiscard secure path
  deferred); firstboot applies the time floor (root); rootfs stage bakes
  /etc/astro/build-epoch (SOURCE_DATE_EPOCH or build time) +
  /etc/astro/chrony.conf (pool + makestep); chronyd enabled platform-
  wide via an /etc/dinit.d shadow (-f /etc/astro/chrony.conf);
  mac80211_hwsim.radios=3 on all three qemu board cmdlines (module is
  =y, so the param must ride the cmdline).

### Traps found

- **CONFIG_NFT_NAT was silently missing from every built kernel.** The
  phase-3 fragment set NFT_NAT=y without NF_TABLES_IPV4; kconfig dropped
  it silently (depends on NF_TABLES_IPV4 || NF_TABLES_IPV6 —
  net/netfilter/Kconfig:565), verified in the built .configs. The
  fragment now sets NF_TABLES_IPV4=y + NFT_REDIR=y with every symbol
  cited against the actual portal ruleset. Kernel fragments need
  .config audits, not just fragment reviews.
- **chrony-dinit ships an ENABLED `chrony` waitsync gate** (chronyc
  waitsync 180 …) before time-sync.target — up to 180 s of boot stall
  per boot on an offline appliance. Neutralized by an /etc/dinit.d name
  shadow (/usr/bin/true); time-sync.target is reached immediately and
  consumers use astrod's time.synced instead.
- **Zig 0.16: std.Thread.sleep is gone** (Io rework) — sync.sleepMs
  (pthread-side nanosleep) is the house sleep; timekeep uses it.
- **dinit scripted oneshots stay "started"** after success: astrod
  restarting astro-portal-redirect-start on a second AP cycle is a no-op
  until the service is stopped — the fill needs a small STOPSERVICE
  addition to dinit.zig (recorded in the service files).

### Verified

- Container `zig build test`: 190 pass / 4 skip (38 new); zig fmt
  clean; shellcheck clean on all touched/new shell.
- Live container smoke (astrod --listen + new test-only --ap-listen):
  unix/localhost behavior unchanged (401/200, machine_id present,
  time_synced new), phase-4 routes 501 on authenticated surfaces,
  portal page + 302 probes on the AP surface only (404 elsewhere),
  AP-surface GET /system redacted, subset members dispatched, and
  everything else 403 forbidden even with a valid bearer token.
- Image rebuild/boot-smoke/test-api deliberately NOT run here: the
  spine changes packages + kernel config, so the fleet gates run with
  the phase-4 fill's image rebuild (next stage owns it).

## 20. M3 phase 4 complete: provisioning, AP portal, factory reset, time (2026-07-20)

The phase-4 fill is live end to end: mDNS announce, the wired path, the
AP captive portal with the single-radio flip, factory reset, and the
chrony/build-epoch time story — all green on the qemu fleet (details
under Verified; every number below is from the final runs).

### What landed (on top of the §19 spine)

- **dinit.zig** — STOPSERVICE (opcode 4, control-cmds.h) with gentle
  flags, and restart via dinitctl's own STOPSERVICE|restart|pre-ack
  flag combination (2|4|128, PREACK reply consumed; NAK maps to
  NotStarted and restartServiceByName degrades to a plain start).
  Re-arms the portal-redirect oneshots between AP cycles and restarts
  iwd for the netconfig window.
- **main.zig wiring** — constructs the phase-4 trio in serve():
  mdns.Responder (gated on api.mdns), portal.ApController (hooks into
  a dynamically bound AP listener: the accept loop owns the socket,
  the controller only flips an atomic + eventfd; IP_FREEBIND so
  192.168.223.1 binds before iwd's netconfig assigns it), and
  provision.Manager (ap_enter/ap_leave/ap_is_active wired to the
  controller). New DeferredActions: factory_reset (dispatch the root
  oneshot with the 202 already on the wire) and wifi_flip (the
  synchronous AP→station flip AFTER the 202 — the flip tears down the
  very listener the response leaves on).
- **Handlers filled** — GET/PUT /network/wifi/ap (WifiApState from the
  scoped wifi.apActive() + machine-id-derived ssid; PUT persists the
  tri-state override, strict body, pokes the machine) and POST
  /system/factory-reset (confirm-with-machine-id, probes dinit AND
  loads the astro-factory-reset service before answering 202).
  netconf.putWifiConnection: on the AP surface with the AP up it
  persists only (durable before the 202) and defers the flip;
  elsewhere it arms the provisioning connect-attempt window.
- **provision.zig** — startup edge moved onto the reconcile thread
  (AP bring-up at boot can take tens of seconds and must never delay
  listener bind/readiness); Observation gained ap_forced
  (enabled_override=true wants the AP even with ethernet carrier —
  the on-demand story and the only way to raise it on the slirp rig)
  and connect_in_flight (freezes both AP edges so observes racing the
  flip cannot bounce the radio); a leave edge tears down a
  no-longer-wanted AP (force-down, carrier appearing); flipConnect()
  is the synchronous flip executor; ap_is_active re-syncs the
  machine's optimistic ap_active with the controller so a failed
  enterAp retries instead of wedging.
- **system.zig/spec** — last_error (?string) on SystemInfo AND the
  redacted AP view (parity + conformance gates updated), sourced from
  the ApController through a fn-pointer hook (static strings; atomic
  tag mirror for cross-thread reads).
- **store.zig** — setApEnabledOverride (atomic persist).
- **Overlay** — iwd.env grows CONFIGURATION_DIRECTORY=
  /run/astro/iwd:/etc/iwd (first main.conf wins, iwd-3.12
  main.c:548-567; no override present = boot behavior unchanged);
  tmpfiles rule `d /run/astro/iwd 0755 astrod astrod` (the AP-window
  netconfig override dir — on /run so a crash can never make the
  split-brain config permanent).
- **astro-cports/main/chrony** — NEW shadow: the pinned chrony pulls
  gnutls-devel, and full gnutls cannot be cross-built (gnutls libdane
  → unbound → protobuf-c → protobuf, and protobuf is marked broken
  for cross in the pin). The shadow builds --disable-nts
  --without-gnutls (sechash/CMAC stay on nettle; Astro's baked config
  is pool+makestep, NTS was never in the docs/07 §6 story), pkgrel
  bumped (openssh-shadow rationale). Without it no image with chrony
  in packages.list could build at all.

### Traps found (all live, all fixed in the owning module)

- **events.zig @min type-narrowing overflow (CRASH).** `@min(timeout_ms,
  ms_per_day)` narrows the result to u27, so
  `(wait_ms % 1000) * ns_per_ms` overflowed for any timeout with a
  sub-second remainder ≥ 135 ms — provision.Manager's subscriber
  cadence next(500) aborted the daemon-side thread every time. Fixed
  with a load-bearing `: u64` annotation + regression test. Zig's @min
  result-range inference makes innocent-looking arithmetic overflow;
  annotate when mixing with comptime bounds.
- **D-Bus policy denied AccessPoint.StartProfile (docs/09 §5
  default-deny doing its job).** The astrod user policy whitelists
  interfaces; phase 4 added AccessPoint calls without adding the
  grant. Found live in provisioning-e2e as
  org.freedesktop.DBus.Error.AccessDenied — and the failure shape was
  nasty: Device.Mode="ap" rides org.freedesktop.DBus.Properties
  (already allowed), so the radio flipped into ap mode with no AP
  running. astrod.conf now grants net.connman.iwd.AccessPoint.
  Interface-scoped D-Bus policies must be re-audited whenever a new
  interface is called.
- **wifi.apActive() counted ANY AP in the iwd tree.** The hwsim rig
  runs its upstream test AP on wlan1 through the same iwd, so
  GET /network/wifi/ap said enabled=true before astrod ever touched a
  radio. Scoped to the v1 AP radio (first device alphabetically, same
  policy as apRadioPathZ).
- **mDNS responder died to the boot race.** astrod can start before
  dhcpcd's first lease; IP_ADD_MEMBERSHIP(224.0.0.251) then fails
  ENODEV and start() gave up for good. The join is now best-effort at
  start and retried from the responder loop (sends never needed the
  membership; only query reception waits).
- **timekeep on armv7: linux.timespec.sec is isize (y2038 ABI).**
  `.sec = floor` (i64) failed to compile 32-bit; clamped via
  std.math.cast. The native-container test build cannot catch 32-bit
  target breaks — the cross build is the gate that caught it (plus a
  stale astroctl/netconf state the incremental zig cache kept
  replaying until a manual rebuild flushed it).
- **iwd netconfig window vs the test rig.** apStart now checks the
  EFFECTIVE config (first main.conf along CONFIGURATION_DIRECTORY)
  and skips the override+restart when netconfig is already enabled —
  on the e2e rig the bind-mounted =true config means an iwd restart
  would have killed the upstream test AP on wlan1 mid-case.
- **A helper radio's Station masqueraded as the DUT's — the AP
  flapped every ~5 s and no phone could ever associate.** The
  nastiest live bug of the phase. wifi.zig's modelState/stationPathZ
  picked "the first device WITH a Station interface"; with wlan0 in
  AP mode its Station object is gone, so the model silently fell
  through to the rig's phone radio (wlan2). The phone's own
  association attempt then surfaced as network.wifi.state
  "connecting" → the provisioning machine read it as the portal flip
  starting (wifi_connect_started: leaveAp) → the AP went down mid-
  authentication → the phone's connect failed ("disconnected" →
  wifi_connect_failed) → the AP came back (wrong-password loop doing
  its job) → iwd autoconnect retried → forever. Symptoms were
  maximally misleading: iwctl said only "Operation failed", iwd.log
  showed probe responses but auth timeouts (reason 2) or EAPOL death
  (disassoc reason 4) depending on where in the ~5.5 s bounce cycle
  the handshake landed, GET /network/wifi/ap said enabled=true
  throughout (the sub-second down-windows dodge polling), and GET
  /network/wifi said mode "station" while the AP beaconed. Root
  cause nailed by elimination — SIGSTOP astrod made the association
  succeed instantly — then dbus-monitor showed astrod itself cycling
  Stop/Mode/StartProfile. Fix: one dutDevice() policy (first device
  alphabetically, the apRadioPathZ rule) now scopes EVERY station-
  facing surface (state snapshot, stationPathZ and with it
  scan/networks/tryConnect, the rssi read); a model test pins that a
  connecting helper Station never leaks into the snapshot. Same bug
  class as the earlier "apActive counted ANY AP" trap — multi-radio
  rigs punish every unscoped model read, and single-radio production
  boards can never catch this class in CI. A SECOND copy hid in
  publishStateEvent (its own first-has_station loop feeding the very
  network.wifi.state event the machine maps): after the snapshot
  paths were scoped the AP still bounced exactly once per phone
  Network.Connect. Both the payload and the publish TRIGGER are now
  dutDevice-scoped (helper-radio Station churn publishes nothing).
  Lesson: a selection POLICY that lives in more than one loop isn't a
  policy — hunt every duplicate the moment the first copy turns out
  wrong.
- **chronyd never clears STA_UNSYNC without `rtcsync` —
  time.synced was unreachable.** chronyc showed a selected source
  and sane tracking while GET /system time_synced stayed false
  forever: chrony only touches the kernel's synchronized flag
  (sys_linux.c, guarded by the rtcsync directive) when rtcsync is
  configured, and the baked config had deliberately omitted it ("no
  battery RTC on these boards"). astrod's adjtimex()-based
  time.synced reads exactly that flag. rtcsync is now in the baked
  /etc/astro/chrony.conf (rootfs.sh); the 11-minute kernel-to-RTC
  copy it enables is a no-op without an RTC driver. Verified live:
  restarting chronyd with rtcsync flipped time_synced true
  immediately.
- **test-api's resolv-conf case read the pre-move path.** The M3
  phase-4 /run/astro-resolv move (chronyd could not traverse the
  0750 /run/astro gate) left the case cat-ing /run/astro/resolv.conf
  — empty since the move, failing the marker grep. The case now
  reads the rendered file where the renderer actually puts it.
- **AP→station flip race on fast boards (one-in-two flake on
  qemu-x86_64).** After Device.Mode="station" the Station
  interface's InterfacesAdded can lag astrod's immediate connect
  attempt: tryConnect saw no station, gave up the direct attempt,
  and that run's iwd autoconnect happened not to converge inside the
  e2e's 90 s window — station stuck "disconnected", AP correctly
  gone (override already cleared). armv7's slower TCG never hit it.
  tryConnect now waits up to 3 s (station_register_wait_ms) for the
  Station to (re)register before concluding the radio is
  station-less.

### Recorded deviations (docs/07)

- "Connectivity verified" v1 = some interface has a global address AND
  an IPv4 default route (/proc/net/route; gateway ping deferred, §19).
  Consequence: on a wired+wifi device the ethernet path can satisfy
  promotion the moment a wifi config is persisted — the e2e relies on
  this ("wifi-e2e promoted the device").
- Portal HTTP rides 192.168.223.1:8080 with a root nft redirect pair
  for :80/:53 (astrod stays capless); DNS catch-all on :5354.
- The AP auto-trigger stays "no ethernet carrier" (docs/07 §4); the
  slirp rig always has carrier, so the e2e raises the AP via the
  manual override (enabled_override=true = forced, carrier
  notwithstanding) and returns control with `wifi ap auto`.
- mDNS v1: IPv4-only socket (no ff02::fb), uniform TTL 120, no
  probing/known-answer suppression, host label == instance label
  (§19); multicast not asserted on-air (slirp does not bridge guest
  multicast) — GET /system carries the TXT source of truth.
- provision.Manager consumes one events.max_subscribers slot: the SSE
  client budget is effectively 15 (main.zig comment updated).

### Verified

- Container `zig build test`: 237 pass / 4 skip; zig fmt clean;
  shellcheck clean (overlay scripts, test-api.sh, hooks); astrod
  cross-compiles ReleaseSafe for all three arches (static, <8 MiB).
- qemu-armv7 dev image rebuilt from scratch inputs: chrony 4.8-r1
  (shadow) + nftables in the manifest, chronyd/nft/astrod on the
  rootfs, kernel .config carries NF_TABLES_IPV4/NFT_NAT/NFT_REDIR.
- boot-smoke qemu-armv7: PASS, zero FAILED, 44–48 s to verdict —
  chronyd, iwd, astrod all [ OK ]; nothing portal-related activates at
  boot with eth carrier present (the state machine decides), and
  boot-success/mark-good never depended on being provisioned (the
  boot-success graph gates on astrod healthy, not provisioned — the
  dev image entering provisioning at boot changes nothing there).
- test-api qemu-armv7: PASS 10/10 (423 s final run; provisioning-e2e
  269 s incl. two factory-reset reboots). Full AP story observed
  live: AP down by default with eth carrier → `wifi ap enable` →
  wlan0 at 192.168.223.1 with the iwd [IPv4] DHCP pool → wlan2
  associates over the air with the derived SSID/PSK and leases from
  the pool → portal surface (302 probes, page, redacted /system, 403
  wall with a valid token, scan 202, cached networks) → nft
  astro_portal 80→8080/53→5354 → portal PUT → flip → station
  connected to the upstream AP → provisioned → AP gone, listener
  dead. astrod VmRSS after the whole AP/portal cycle: 1756 kB
  (budget 16 MiB).
- test-api qemu-x86_64: PASS 10/10 (359 s final run) — same story on
  the fast board after the station_register_wait_ms hardening (the
  one flip-race flake above reproduced once in three runs before it).
- time case both boards: floor_ok immediately (build-epoch floor),
  time.synced true within the 120 s window through slirp UDP once
  rtcsync landed.
- AD-020 update+rollback qemu-armv7: PASS (535 s final) — API update
  A→B flip verified, then poisoned-bundle automatic rollback after 3
  watchdog reboots; the provisioning-AP-at-boot behavior disturbs
  neither mark-good nor the watchdog path.

## 21. Test-suite hardening pass (2026-07-22)

The three QEMU harnesses moved onto a shared library and grew an
adversarial API tier; green means the same thing it did before — every
existing assertion kept its strength, cases were only added.

- **build/lib/testlib.sh** — the duplicated plumbing extracted once:
  self-containerize preamble (in-container serial redirect, §12), the
  hardened SSH array (ServerAlive*, §14/§18 lessons), QEMU start/stop,
  event-driven waits (`tl_wait_for/_ssh/_ssh_down/_serial` — bounded
  polls, no bare sleeps; the two genuinely unavoidable sleeps left in
  the suites are commented as retry pacing / negative dwell), per-case
  junit bookkeeping, and `tl_finish`. Per-board deadline multiplier
  (`tl_scale`: armv7 150 %, aarch64 125 % of x86_64) applied inside the
  wait helpers instead of scattered magic numbers.
- **Stale-QEMU preflight** (`tl_qemu_lock_check`): a leftover qemu from
  an aborted run write-locks scratch.qcow2/OVMF_VARS.fd and the next
  boot used to die mid-suite with an obscure "Failed to get 'write'
  lock". `qemu-img info` (shared lock) now probes those files before
  boot and refuses crisply, naming the host-side pgrep/pkill to run.
  Verified live against a running guest from a second container.
- **junit upgrade**: every writer now emits one `<testcase>` per case
  with per-case wall time (`time=` on testcase); test-update-rollback
  was split into four phases (boot-slot-a, api-install, api-apply-flip,
  poison-rollback), boot-smoke keeps its single case. Suite/artifact
  file names unchanged.
- **test-api.sh**: linear flow rebuilt as a case registry +
  `--case=NAME[,NAME]` selector and `--list-cases` (boots the guest
  once, runs only the selection; registry order preserved). The old
  fixed `sleep 10` reboot handling in the rollback gate became
  wait-down-then-wait-up (the sleep raced a still-answering old boot).
- **New adversarial cases** (api-negative, auth-matrix, concurrency,
  fuzz-lite — 33 s added on armv7, 23 s on x86_64): strict-body 400s,
  64 KiB-cap 413, forged-Content-Length 507 (stageStream's statvfs check
  fires before any body byte is read — no tmpfs rig needed, and no
  staging residue; the declared length must be 2.8 GiB, NOT tens of GiB:
  32-bit astrod's `content_length: usize` is u32, so an unrepresentable
  Content-Length fails header parsing and correctly answers 400 —
  caught live on qemu-armv7), bearer mutations (trailing garbage/empty/bare/wrong
  scheme), token rotation mid-session (old token 401s on the next
  request — the auth cache keys on inode/size/mtime), astro-api socket
  group gate (member 200 / non-member ECONNREFUSED via doas), 20-way
  parallel GETs + racing scans under an attached SSE client (no 5xx,
  ids monotonic, RSS stable), and a dozen wrong-method/path probes
  asserting 404/405 problem+json shape with no connection drops.
- **astrod fixes found by the new cases** (container `zig build test`
  still green, budgets hold):
  1. *HTTP-layer problem types were all "bad-request"*: 405 (unknown
     method), 413 and 431 answered problem+json with the wrong `type`
     urn. `writeProblem` now maps method-not-allowed /
     content-too-large / headers-too-large.
  2. *413 could be RST-discarded on the TCP surfaces*: the oversized-
     body path answered and closed with the request body still unread —
     on 127.0.0.1:8080 the close RSTs and the client can see a
     connection error instead of the 413. main.zig now drains the
     remainder (bounded, 1 MiB cap) after writing the response. Unix-
     socket clients never saw it (AF_UNIX has no RST), which is why the
     suite had not caught it.

### Verified (all foreground-observed, final runs)

- Container `zig build test` green after the astrod fixes; shellcheck
  clean at the repo severity/exclusions over the three suites + testlib.
- boot-smoke qemu-armv7 dev: PASS 48 s (was 48 s).
- test-api qemu-armv7: PASS 14/14 in 441 s (was 10/10 in 423 s — the
  four new cases cost 33 s; the event-driven waits clawed back roughly
  half of that from the old fixed polls).
- test-api qemu-x86_64: PASS 14/14 in 357 s (was 10/10 in 355 s — flat
  despite 23 s of new cases, same mechanism).
- AD-020 qemu-armv7: PASS in 535 s (was 545 s), now four junit phases
  (boot-slot-a 54 s / api-install 62 s / api-apply-flip 54 s /
  poison-rollback 365 s, 3 watchdog reboots).
- `--case` selector spot-runs (x86_64): boot + selected case only, e.g.
  `--case=api-negative` verdict in 40 s.
- Stale-QEMU preflight verified live: probing a board dir while its
  guest ran refused with the crisp §20 message from a second container.

## 22. M4 phase 0: the external-tree merge engine (2026-07-24)

The foundation of the M4 "Extensible" milestone (docs/08): products stop
forking Astro and instead compose it with pinned external trees. Phase 0
is the full §4 layering contract — multi-tree composition with explicit
priority, all layering rules, provenance logging — wired into the live
build. The fence, service manifests, SDK and `astro deploy` (phases 1–3)
are deliberately out of scope; the overlay merge carries a marked
PHASE-1 FENCE SEAM where the code/config check slots in.

### The spine: one ordered layer list, everyone walks it

`build/lib/layers.py` is the single source of truth. Given the board,
the variant, and zero or more `--external` trees (+ `$ASTRO_EXTERNAL`,
colon-separated), it emits the **ordered layer list** — a JSON array
ALREADY in final merge order (`boards/common → trees ascending
tree.toml priority → board → variant`), persisted at
`$LAYERS_JSON = build/state/images/<board>-<variant>/layers.json`.
`array[0]` applies first (lowest precedence), `array[-1]` wins. Every
consumer — shell and Python — walks it in order and never re-sorts.
Tree band ties break by input order (env before CLI) then path; a tree
may PROVIDE a board/variant (`<tree>/boards/<b>/`, `<tree>/variants/<v>.toml`,
highest-priority wins) or LAYER onto an in-tree one.

### What got wired (the phase-0 fills were reference impls; this connected them)

- **Config load** (`build-inner.sh`) now goes through
  `merge.py board|variant` instead of `config.py`: it deep-merges every
  contributing board.toml / variant .toml fragment across layers (deep
  merge per table, scalars last-wins, **lists REPLACE** except
  `[packages].install` which **accumulates**+dedupes) then runs the SAME
  validate/apply_defaults/derive pipeline `config.py` uses — single-sourced
  in `config.py:finalize_board_config/finalize_variant_config` so the two
  paths cannot drift.
- **Package manifest** (`build-inner.sh`) now comes from
  `merge_packages_list` (merge.sh): additive-only concatenation across
  `boards/common` + every tree's + the board's `packages.list`, then
  board `[firmware].packages` and variant `[packages].install`, deduped
  keeping first occurrence. **No removal syntax** — masking a base
  package is forbidden (docs/08 §4; the docs/02 tiers are the way to ship
  less). The old `resolve_package_list` was deleted.
- **Overlays + hooks** (rootfs stage): `apply_overlays`/`run_hooks` in
  `rootfs.sh` delegate to `merge_overlays`/`merge_hooks`. Overlays apply
  file-by-file, LAST-WRITER-WINS, and LOG every override with provenance
  (`overlay: acme-product/etc/acme/foo overrides acme-common/…`). Hooks
  from all layers interleave by numeric filename prefix ACROSS layers
  (`10-core … 15-treeB … 30-treeA … 90-board`), tie → layer order.
- **cports collections**: each tree's `cports/` is an additional cbuild
  collection layered on the fork (AD-027). `merge_cports_collections`
  (merge.sh) is the authoritative detector — ascending priority, loudly
  flags a tree template shadowing a fork template, HARD-ERRORS when two
  trees provide the same template name with differing bytes (byte-
  identical → warn+allow). `packages.sh:overlay_tree_cports` consumes its
  plan, copies each template over the materialized fork, relinks
  subpackages, and `reset_cports_tree` restores the pin. Tree templates
  have no binary equivalent, so they are always source-built.

### Traps / decisions (recorded)

- **The qcow2 by-reference bug** (found by the config.py fill's tests,
  fixed here on the live path): `apply_defaults` handed out schema
  default lists BY REFERENCE and `derive_board_defaults` did
  `formats.append("qcow2")` in place — mutating `BOARD_SCHEMA` and
  poisoning every later board in the same interpreter. Invisible in the
  one-board-per-process CLI; the merge engine loads many boards per run.
  Now deep-copies mutable defaults. The delegation to `finalize_*` also
  fixed a divergence where `merge.py` fed the POST-defaults dict to
  `derive_board_defaults` and wrongly added qcow2 to rpi4 (no `[qemu]`).
- **Byte-identity is the contract for the no-tree path**: with no
  `--external`, the layer list collapses to `[core, board(, variant)]` and
  every merge function reduces to exactly the pre-phase-0 behavior. This
  was the hard constraint (all fleet CI must stay green) and is proven,
  not asserted (below).
- `EXTERNAL_DIR` (the primitive single-overlay var) is fully removed —
  its overlay path is superseded by `$LAYERS_JSON`.

### Verified (all foreground-observed)

- **No-tree byte-identity** (astro-builder container): `config.py` vs
  `merge.py` board+variant JSON identical for all four boards ×
  dev/prod; `resolve_package_list` (git HEAD) vs `merge_packages_list`
  identical for qemu-armv7/aarch64/x86_64 dev, rpi4 dev, qemu-armv7 prod;
  `merge_hooks` for rpi4/dev yields the historical common-00→30-then-
  board-50 order.
- **Full no-tree build** `./build/astro-build.sh qemu-armv7 dev`:
  completes green through rootfs → ext4 image → qcow2 → RAUC bundle;
  `layers.json` = `[core, board, variant]`, 27-package manifest, 5 hooks.
- **boot-smoke qemu-armv7 dev: PASS 46 s, zero [FAILED]** (was 48 s in
  §21) — the no-tree image boots to boot-success + login unchanged.
- **Multi-tree fixture** (two throwaway trees, acme-common@30 +
  acme-product@60, passed to `--external` in REVERSE priority order to
  prove priority — not CLI order — decides): layer order
  `core → acme-common → acme-product → board → variant`; both trees'
  sentinel packages present with treeA before treeB and base `musl`
  deduped; `defaults.conf` resolves to treeB with the provenance line
  logged and treeA-only files surviving; hooks interleave
  `…10, 15-treeB, 20, 30-common, 30-treeA, 60-treeB`; version gate
  bypassed for `0.0.0-dev`, passes at `ASTRO_VERSION=2026.10` (≥ min
  2026.05), fails fast at `2026.01`; cports plan resolves
  `main/acme-meta → acme-common`, the template is source-build-listed,
  two differing same-name trees hard-error, byte-identical dup warns.
- shellcheck clean (repo severity/exclusions) over all touched shell;
  ruff clean on `build/lib`; `test_merge_board_variant.py` 15/15 green
  (now including rpi4 through the merge wrapper).

## 23. M4 phase 1: the code/config fence, service manifests, /services (2026-07-28)

Phase 1 makes the docs/08 contract *mean something*: the fence turns
AD-017 from prose into a build failure, and the §5 service-manifest
pipeline turns an app's declared integration (user, data dir, rollback
participation, API control) into image wiring. Fills the PHASE-1 FENCE
SEAM left marked in §22. With zero manifests present — every current
fleet image — all of it is a proven no-op: the image stays
byte-identical and fleet CI stays green.

### The fence (merge.sh `fence_check`, AD-017, docs/08 §3)

Every incoming overlay file from EVERY layer (core, tree, board,
variant) is checked at merge time; a violation dies the build with the
file, the layer, the reason, and the fix (ship it as an apk template).
Two independent rules:

- **Path**: `usr/bin`/`usr/sbin` always rejected; `usr/lib` rejected
  unless inside `FENCE_USR_LIB_ALLOW` (astro, dinit.d, tmpfiles.d,
  sysctl.d, modules-load.d, os-release.d, udev/rules.d, firmware,
  dhcpcd-hooks) or the exact file `usr/lib/os-release`. **Merged-/usr
  evasion is closed**: a leading `bin/`, `sbin/`, `lib/`, `lib64/`
  segment canonicalizes to its `usr/` spelling BEFORE the test (an
  overlay's `bin/evil` IS `usr/bin/evil` on the live image). The
  allowlist prefix match is `/`-anchored so `usr/lib/astro-evil/…`
  cannot ride the `astro` entry.
- **ELF**: any regular file starting `7f 45 4c 46`, anywhere in the
  overlay. Symlinks are path-checked but never ELF-probed (the bytes
  read would be the target's, which passed the fence in its own
  location).

Audit of the existing fleet: 34 overlay entries (boards/common is the
only populated overlay tree), ALL pass; zero ELF. One real finding
recorded in the code: `usr/lib/dhcpcd-hooks/60-astro-lease` is a
symlink into allowlisted `usr/lib/astro/` — dhcpcd only sources its
compiled-in hook dir, so the wiring legitimately lives under usr/lib;
`dhcpcd-hooks` is allowlisted as a platform mechanism dir, not a
carve-out. Documented gap, NOT actioned: `usr/local/{bin,sbin,lib}` and
`opt/` are executable-capable but outside AD-017's enumeration; no
overlay uses them; growing the path set is a future AD decision.

### Service manifests: schema → reader → assembly hook → boot replay

- `schema.py:SERVICE_MANIFEST_SCHEMA` + `service_manifest.py`: the one
  validated reader (config.py's validate/apply_defaults pipeline, same
  errors as board/variant configs). Name must be fs-/dinit-safe and
  match the file stem. CLI: `read <rootfs>` → JSON array, `uid <name>`.
- **Deterministic app uids**: `400 + sha256(name) % 500` (range
  400–899: above platform uids 300/301, below human 1000). The reader
  owns the deterministic STARTING uid; the hook resolves hash
  collisions by probing upward and owns the FINAL assignment — same
  app, same uid, every build, regardless of build order.
- `boards/common/hooks/40-service-manifests.sh` (runs after
  05-platform-users/10-create-users/20-enable-services) applies the
  per-manifest effects, each idempotent: (a) system user+group+shadow
  (shadow-mode dance as 10-create-users); (b) `data_dir=true` recorded
  in `/etc/astro/app-data-dirs` — /data is a RUNTIME mount, so
  `data-mount.sh` replays the record right after mounting (`mkdir -p
  /data/apps/<name>` + chown), which also survives factory-reset wipes;
  (c) env file `/etc/astro/services/<name>.env` with
  `ASTRO_API_SOCKET` (+`ASTRO_DATA_DIR` when data_dir) — the app's OWN
  service description must say `env-file = /etc/astro/services/
  <name>.env`; the hook never edits service files; (d)
  `boot_success=true` appends `depends-on: <name>` to the assembled
  boot-success milestone (AD-011 rollback opt-in; dies if the milestone
  file is missing); (e) `api_client=true` joins the user to the
  astro-api group; (f) enablement into boot.d mirroring
  20-enable-services' symlink shapes; (g) a JSON sidecar per manifest
  (below). Zero manifests ⇒ the hook exits before touching anything.

### astrod: the /services group (docs/06 §5.4)

- **Sidecars, not TOML**: std has no TOML parser and astrod does not
  shell out (AD-016), so effect (g) emits
  `usr/lib/astro/services/<name>.json` (the reader's `to_dict()`,
  minus `source_path` — a build-host path that would leak into the
  image). `services.zig` reads the sidecars at startup via raw
  getdents64 (std.Io avoidance, same as fsutil/netconf), keeping only
  `name` + `api_controllable`.
- **Deliberately narrow**: GET /services lists ONLY api_controllable
  services; the three POST verbs (`restart|stop|start`) are gated on
  the same set; an unknown OR non-controllable name answers **404, not
  403** (whether a service exists is itself withheld). No dinitctl
  passthrough. Per-service query failure degrades that entry to state
  "unknown"; only an unreachable dinit socket is 503.
- **dinit protocol**: SERVICESTATUS5 added to dinit.zig — v5 chosen
  over v6 because its status buffer is a fixed 14 bytes on every arch
  (v6 trails an arch-sized `struct timespec`). State + pid decode from
  the flags byte; dinit's protocol carries NO automatic-restart
  counter, so `restart_count` is astrod's own count of API-initiated
  restarts this daemon run — the honest reading of docs/06 §5.4.
- **Router**: `matchPath` generalized from trailing-`{param}`-only to
  segment-wise matching (single param, any position) for the interior
  `services/{name}/restart` shape; existing routes' semantics
  reproduced exactly. openapi.yaml + docs/06 §5.4 document the four
  endpoints; the conformance test parses the updated spec.

### Verified

- `build/lib/test_fence.sh` **25/25** — both rules, merged-usr aliases,
  anchored-prefix adversarial (`astro-evil`), symlink handling,
  non-fenced dirs (usr/share, usr/libexec), plus the live-overlay audit
  case asserting every existing fleet overlay passes.
- `build/lib/test_service_manifest.py` **14/14** — schema violations,
  stem mismatch, uid determinism/range, sorted read, bad-manifest
  fail-fast.
- `build/lib/test_service_manifests_hook.sh` **28/28** — full-wiring
  scenario (user/uid, group, env file, boot-success dep, sidecar,
  boot.d link, app-data-dirs record), uid-collision probing,
  idempotent re-run (no duplicate lines), and the no-manifest run
  asserted **byte-identical** (find|sort|md5 over the whole rootfs).
- astrod `zig build test` (pinned 0.16.0, astro-builder container):
  **246 pass / 4 skip** — includes SERVICESTATUS5 frame/decode against
  scripted replies, registry load/gate/list shaping, router 501/404/405
  contract for the group, interior-param binding.
- **CI wiring**: new `build-lib-unit` step in `astro-ci.sh` runs all
  four build/lib suites (merge engine + the three above) in the
  container — they existed but nothing ran them in the pr suite.
  Verified green in-container. The full CI lint pass (shellcheck over
  every touched hook/lib script, ruff over build/lib, `zig fmt --check
  astrod/`) is clean on the phase-1 tree.
- **Full build `qemu-armv7 dev`: PASS** (warm, ~29 s) through rootfs →
  A/B image → RAUC bundle. Zero fence lines in the 374-line log (the
  fence only speaks on rejection — every live overlay passes on the
  real path, not just in the audit test); `40-service-manifests.sh` ran
  and printed nothing (no-op path); astrod cross-compiled
  arm-linux-musleabihf ReleaseSafe at 6959 KiB (inside the docs/06 §3
  8 MiB budget) with the phase-1 sources in.
- **boot-smoke qemu-armv7 dev: PASS 46 s** — boot-success milestone +
  login prompt, zero `[FAILED]`, and no `/data/apps` replay lines at
  boot (the data-mount block is a no-op without the record file).
