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
| `cbuild/config/profiles/{aarch64,armv7hf}.conf` | `build/cbuild-profiles/` | paths `/workspace/build/<arch>` → `/workspace/build/state/<arch>`; migration note + AD-002 TODO added. armv7hf kept even though armv7 is parked (it is inert config; the board that used it was not migrated) |
| `cbuild/config/devices/{generic-arm,rpi}.conf` | `build/cbuild-profiles/devices/` | (not in map — judgment call) verbatim; consumed by `build/create-system-image.sh` |

New files created at repo root: `.gitignore`, `LICENSE` (Apache-2.0, "Copyright
2026 TierOne Software"), this file, and scaffold dirs
`astro-cports/main/`, `astrod/src/`, `keys/dev/` (with README), `examples/`,
`tests/`, `variants/` (`.gitkeep` placeholders).

## 2. What was skipped, and why

| Item | Why |
|---|---|
| `cbuild/cports/` (~1.3 GB vendored checkout) | replaced by a Harbormaster-managed checkout at `<root>/cports` (AD-001/AD-003); manifest + lock is a later task. `cports/` is gitignored |
| `boards/beaglebone-black/` | armv7 parked out of tree per the migration map |
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
