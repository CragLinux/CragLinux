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
