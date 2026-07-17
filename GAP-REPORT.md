# Astro M0 Phase 3 — Containerized Build Gap Report

Date: 2026-07-16 · Board/variant: **qemu-aarch64 / dev** · Host: Fedora (24 cores), rootless podman 5.8.4
Entry point: `./build/astro-build.sh qemu-aarch64 dev --step=<stage>` (astro-builder container, `--privileged --userns=keep-id`, repo mounted at `/workspace`).

> **Bottom line: the pipeline now produces a from-source Astro/Chimera rootfs that boots in QEMU to a dinit login prompt** (`qemu-aarch64-development login:`), with udevd, dhcpcd and turnstiled running — via direct kernel boot on a single rw ext4 disk (the M0 model; A/B, squashfs and real bootloader are M1+). Everything in the image was built from the pinned cports checkout — no foreign binary packages.

## 1. Stage-by-stage results

| # | Stage | Result | Duration | Notes |
|---|-------|--------|----------|-------|
| 0 | Container image (`container/Containerfile`) | PASS | ~45 min (slow mirror; mostly dnf downloads) | Built as-committed — **zero fixes needed**: all Fedora 44 package names valid, Zig 0.16.0 URL + sha256 verified, image 2.21 GB. `--userns=keep-id` gives `HOME=/workspace` inside the container (cbuild config lands at repo root, same as prototype). |
| 1 | toolchain (SDK LLVM 22.1.7 + musl 1.2.6 + headers 6.12.95) | PASS | ~29 min | Cold build. Sources prefetched host-side into `sources/` (same layout the script expects). Toolchain at `toolchain/`, per-arch wrappers at `build/state/aarch64/bin/`. |
| 2 | kernel (6.12.95, ThinLTO, clang) | PASS (after 2 fixes) | 14.5 min compile | Failures first: (a) log-pollution bug corrupted the captured source path (fix #1), (b) "source tree is not clean" — the SDK's `headers_install` dirties the shared `sources/linux-6.12.95` tree (fix #2 = one-time `mrproper`; root cause open, see §4). Image: `build/state/aarch64/kernel/qemu-aarch64/arch/arm64/boot/Image` (39 MB). |
| 3 | bootloader | PASS (no-op) | 1 s | `type = "direct"` → nothing to build, by design. Real bootloader stage (U-Boot/GRUB) does not exist yet (stub). |
| 4 | cbuild bootstrap (inside packages step) | PASS | ~8 min total | apk-tools 3.0.5 built from source via meson; bldroot binary-bootstrapped from Chimera repo (57 pkgs); dev signing key generated. Worked unprivileged with bwrap inside `--privileged` container. |
| 5 | packages (12 leaf pkgs from lists) | PASS (after 1 fix) | 471 s + 58 s rerun | `main/apk-tools` distfile fetch got **HTTP 418** from gitlab.alpinelinux.org (Anubis anti-bot blocks cbuild's urllib UA; plain `curl` passes). Fix #3: pre-fetched distfile into `cports/sources/`. All 12 built+signed into `cports/packages/main/aarch64`. |
| 6 | packages — runtime closure | PASS-WITH-GAP (manual) | ~5 h total (llvm cross = 2×~2 h + 1×1.5 h; rest ~1 h) | **Design gap:** the stage builds only *listed* packages, not their runtime dependency closure. ~30 extra templates built by hand across 5 rounds: base-files, ca-certificates, openssl3, zlib-ng-compat, zstd, debianutils, ncurses, libedit, acl, attr, bzip2, xz, kmod, file, linux-pam(+base), libxo, tzdb, openresolv, resolvconf, snooze, sd-tools, util-linux, udev, chimera-repo-main, libcap, shadow, ldns, libfido2, libcbor, base-shells, dns-root-data, nyagetty, dinit-chimera-udev, libdinitctl, **and `main/llvm`** (libc++/libc++abi/libunwind are its subpackages) which needed a 2-part cports patch to cross-build at all (§3.1). `main/heimdal` still fails (§3.2) → openssh dropped from the dev variant for now. |
| 7 | rootfs | **PASS** (after 5 fixes) | 6–11 s once repo complete | apk installs 60+ packages (~37 MB, --usermode), overlays, stripped kernel modules + 1191 dtbs, hooks (hostname, dev user, dhcpcd service). Fixes: repo path, repo base vs arch dir, `--usermode`, base-structure vs base-files symlinks, shadow-file permissions in hooks (see §2). The manual-extraction fallback is dead code with apk-tools 3.x ADB packages (silently produces an empty rootfs — §3.5). |
| 8 | image | FAIL (not implemented) | — | `build/lib/image.sh` is the prototype stub; prints "not implemented". Expected per docs/11 §1 (M1 work). `build/create-system-image.sh` exists but needs sudo+losetup+parted (parted **not** in the container; new design wants sfdisk+mtools instead). |
| 9 | bundle (RAUC) / test stages | MISSING | — | Do not exist anywhere yet (docs/03 §5 marks them "new"). Container already ships `rauc`, qemu, OVMF for them. |
| 10a | QEMU boot — kernel smoke | **PASS** | boot→userspace 2.8 s | Fully-local artifacts: clang/ThinLTO 6.12.95 Image + freestanding static init built with the Astro SDK toolchain, 16 MB ext4, `qemu-system-aarch64 -M virt` inside the container. Kernel boots, PL011 console works, virtio-blk root mounts (`root=/dev/vda`), init executes. Log: `build/state/logs/07-qemu-smoke.log`. |
| 10b | QEMU boot — full dinit rootfs | **PASS — login prompt** | ~10 s to `login:` | `build/run-qemu.sh qemu-aarch64 dev` inside the container (host has no qemu): mkfs.ext4 -d rootfs image, direct kernel boot. dinit runs the whole Chimera early chain — udevd, fsck, network (dhcpcd), turnstiled, agetty — ending at `qemu-aarch64-development login:`. Only `early-sysctl` and `early-binfmt` fail (non-fatal; likely missing `CONFIG_BINFMT_MISC` + sysctl bits in the kernel fragment — small follow-up). Log: `build/state/logs/07-qemu-boot.log` (attempt 3). |

## 2. Fixes applied (file, change, why)

1. **`build/lib/kernel.sh`** — `download_kernel_source()`: all `log_info` calls now `>&2`, + comment. Its stdout is captured by `build_kernel` via `$( )`; log lines corrupted the returned source path, breaking `cd` (and would silently break patch/config steps). Prototype bug exposed on first kernel run.
2. **`sources/linux-6.12.95` state** (no code change): one-time `make ARCH=arm64 mrproper` in the container. The SDK toolchain stage runs `headers_install` in the same extracted tree the kernel stage builds from with `O=`; the leftover generated files make Kbuild refuse to build. Root-cause fix belongs in `sdk/build-toolchain.sh` (use a private copy or `O=` for headers) — left open, see §4.
3. **`cports/sources/apk-tools-3.0.5/`, `cports/sources/ca-certificates-20260413/`** (no code change): pre-fetched distfiles with `curl` (default UA) because gitlab.alpinelinux.org's Anubis returns **418** to cbuild's Python fetcher. sha256 verified against templates. Open design item: distfile mirror/proxy, §4.
4. **`build/lib/rootfs.sh`** — package repo path `cports/packages/${arch}` → `cports/packages/main/${arch}` (cbuild writes per-collection repos), and `/etc/apk/repositories` now gets the repo *base* (`packages/main`) because apk appends `/<arch>` itself.
5. **`build/lib/rootfs.sh`** — added `--usermode` to the `apk ... --initdb add` call: apk-tools 3.x refuses to create a DB as non-root without it (the container build is unprivileged by design).
6. **`build/lib/kernel.sh`** — `modules_install` now passes `INSTALL_MOD_STRIP=1`: unstripped ThinLTO modules were **1.3 GB**; stripped: 86 MB.
7. **`boards/qemu-aarch64/board.toml`** — kernel cmdline `root=/dev/vda2` → `root=/dev/vda` (+comment): `run-qemu.sh` attaches `rootfs.ext4` as the whole unpartitioned virtio disk. The image stage will own `root=` per-slot later (docs/03 §6 removes `root=` from board cmdline entirely).
8. **`boards/qemu-aarch64/variants/dev.toml`** — added `dhcpcd-dinit` (dinit service files are auto-split into `-dinit` subpackages, docs/03 §2); **temporarily disabled `openssh`/`openssh-dinit` + the `sshd` service** because heimdal does not cross-build yet (§3.2) — commented with a TODO, re-enable when fixed.
9. **`build/patches/cports/0001-llvm-cross-native-tools-host-compiler.patch`** (applied to the cports checkout) — two-part fix making `main/llvm` cross-buildable: NATIVE tools sub-build uses the host compiler; mlir/flang disabled for cross profiles. See §3.1. `git -C cports checkout .` restores the pristine pin.
10. **`build/lib/rootfs.sh`** — base-directory scaffolding no longer stomps the apk-installed layout: `mkdir -p` fails on base-files' dangling symlinks (`var/lock -> ../run/lock` before `/run` exists); each entry is now created only if absent.
11. **`boards/common/hooks/10-create-users.sh`** — `/etc/shadow` ships mode 000; the hook now makes it writable for the append and leaves it 600 (owner-readable) because the unprivileged `mkfs.ext4 -d` dev-image path must read every file (`shadow-` too). Prod squashfs path should restore 000/fakeroot (§3.5).
12. **`boards/common/packages.list`** — added `nyagetty` (Chimera's standalone agetty + dinit service; without it there is no login prompt) and `dinit-chimera-udev` (provides `/usr/lib/dinit-devd`; without it `early-devd` exits 127 and dinit declares boot failure, stopping everything). Both are in Chimera's own base-full-core set.

(Manually-built closure packages in §1 row 6 are build-state, not source changes.)

## 3. Failures left open

### 3.1 `main/llvm` cross-build failed as pinned → fixed by a 2-part cports patch (now builds; patch needs upstreaming)

- `libunwind`, `libcxxabi`, `libcxx` are **symlinks to `main/llvm`** in cports — getting `libc++.so.1` means cross-building the entire LLVM template (clang+lld+mlir+flang, 9552 ninja targets, ~2.5 h on 24 cores).
- First attempt failed after ~2.5 h in the nested **NATIVE tools sub-build**:
  ```
  FAILED: [code=255] include/llvm/IR/IntrinsicsPowerPC.h ... llvm-min-tblgen ...
  qemu-aarch64-static: Could not open '/lib/ld-musl-aarch64.so.1': No such file or directory
  ```
  Diagnosis: for cross builds the template points cmake at host tools (`-DLLVM_TABLEGEN=/usr/bin/llvm-tblgen` etc.), but LLVM 22 needs build-only tools the host llvm does **not** ship (`llvm-min-tblgen`, `mlir-irdl-to-cpp`, and the bldroot has no `mlir-*` tools at all — verified in `bldroot/usr/bin`). Those get built in LLVM's NATIVE sub-build, which inherits the **cross** CC from the environment → aarch64 binaries → the host's binfmt qemu-aarch64-static fires without a musl-loader prefix → exit 255 for every tblgen invocation.
  (Open question: Chimera's own CI likely builds llvm **natively on aarch64 builders**, so this cross path may be unexercised upstream — the template even carries a "FIXME: make it build for cross" note for MLIR.)
- **Fix applied and verified** (docs/03 §1 last-resort path): `build/patches/cports/0001-llvm-cross-native-tools-host-compiler.patch`, part 1 — adds `-DCROSS_TOOLCHAIN_FLAGS_NATIVE=-DCMAKE_C_COMPILER=/usr/bin/clang;-DCMAKE_CXX_COMPILER=/usr/bin/clang++` in the template's cross branch so NATIVE tools build with the bldroot host compiler. On the rebuild, the NATIVE sub-build (1308 targets) completed cleanly past the exact point where the unpatched build died.
- **Second cross bug found behind the first**: with NATIVE tools fixed, the build then failed at `runtimes-configure` — `flang-rt/CMakeLists.txt: No CMAKE_Fortran_COMPILER could be found`. flang-rt needs a *running* flang; the freshly cross-built flang is target-arch. Patch part 2 disables mlir/flang for cross profiles (`_enable_mlir = ... and not self.profile().cross` — the template already carries a "FIXME: make it build for cross" for mlir). **With both parts, the cross llvm build completed (rc=0, ~1.5 h without mlir/flang)** and libcxx/libcxxabi/libunwind/clang/lld landed in the repo (`build/state/logs/04g-llvm3.log`).
- The patch is applied to the cports checkout (tree shows dirty in `hm status`, expected per docs/03 §1; `git -C cports checkout .` restores the pin).
- Suggested next steps: (1) upstream both halves to Chimera (or confirm they only build llvm natively per-arch); (2) fold build-time cports patch application into the packages stage so patches are applied/reset automatically.

### 3.2 `main/heimdal` cross-build fails → openssh runtime deps unsatisfiable (`so:libkrb5.so.26`, `so:libgssapi.so.3`, `so:libkafs.so.0`)

- `asn1_compile: not found` during build — heimdal builds its own generator tools and then executes them; in a cross build they are aarch64 binaries (same native-tool class of failure as llvm). Log: `build/state/logs/04e-closure4.log`.
- Impact: `openssh` cannot be installed by apk until heimdal exists. Workaround for a boot-only image: drop `openssh`/`openssh-dinit` from the dev variant. Suggested fix: investigate how Chimera CI builds heimdal for aarch64 (native builders again?), or add host-heimdal native tools to the bldroot.

### 3.3 Anubis (HTTP 418) blocks cbuild's distfile fetcher for gitlab.alpinelinux.org

- cbuild's Python urllib fetcher gets `418 I'm a teapot` from gitlab.alpinelinux.org (Anubis anti-bot challenges "Mozilla-ish" UAs; plain `curl` passes). Hit twice (apk-tools, ca-certificates); will recur for every alpinelinux-hosted distfile.
- Suggested fix: distfile mirror/cache (the `sources` named volume from docs/03 §4, warmed by CI), or teach cbuild a curl-compatible UA, or carry the distfiles.

### 3.4 Packages stage builds no dependency closure (design gap, worked around manually)

- `build/lib/packages.sh` builds exactly the listed packages; the rootfs needs the full **runtime** closure (~25 extra templates were built by hand this run: base-files, ca-certificates, openssl3, zlib-ng-compat, zstd, debianutils, ncurses, libedit, acl, bzip2, xz, kmod, file, linux-pam, libxo, tzdb, openresolv, snooze, sd-tools, util-linux, udev, chimera-repo-main, libcap, shadow, resolvconf, ldns, libfido2…).
- Suggested fix: resolve the closure via apk against the repo index and `cbuild pkg` anything missing (or use `cbuild`'s bulk facilities) — belongs in the `packages` stage rework of the `astro` CLI (docs/03 §5).

### 3.5 rootfs stage smaller gaps

- The **manual-extraction fallback is dead code**: apk-tools 3.x `.apk` files are ADB, not gzip tarballs; `tar -xzf` silently extracts nothing and the build "passes" with an empty rootfs. Should be deleted or made a hard error.
- `apk --usermode` files are owned by the build uid, not root — fine for dev ext4 images (and `mkfs.ext4 -d` normalizes to root), but the prod squashfs path must own files correctly (fakeroot or apk in a userns).
- dinit service enablement hook (`20-enable-services.sh`) symlinks into `/etc/dinit.d/boot.d/` — needs validation against dinit-chimera 0.99.x conventions once a full rootfs boots.

### 3.6 SDK toolchain gaps (hit while building the boot-smoke init)

- The generated `<triple>-clang` wrappers do not pass `-fuse-ld=lld`; on a GNU-ld host the link fails (`unrecognised emulation mode: aarch64linux`).
- The SDK sysroot ships no compiler-rt `crt*.o` for `-static` linking (`cannot open crtbeginT.o`); freestanding `-nostdlib` was needed for the smoke-test init.

### 3.7 Process notes (build-environment data)

- The kernel stage and the SDK share `sources/linux-<ver>`; the SDK's `headers_install` leaves the tree unclean and breaks the kernel's `O=` build (fix #2 was a one-time `mrproper`; real fix: SDK should install headers from a pristine copy or its own `O=` dir).
- zsh `noclobber` on the host bit twice (`>` and `>>` to fresh files); build scripts themselves are bash and unaffected.

## 4. Distance to M1 (per docs/11 §1 and docs/03/04)

What M0/M1 need that this run showed is still missing, in rough order:

1. **Upstream/productize the llvm cross patch** (§3.1) and fix heimdal cross (§3.2) so a clean `hm sync --locked` tree builds unmodified; wire quilt-style `build/patches/cports/` application into the packages stage.
2. **`image` stage** — `build/lib/image.sh` is a stub. Needs the docs/04 §6 layout: GPT via sfdisk, ESP population via mtools (no loop devices/sudo — `create-system-image.sh`'s parted+losetup+sudo approach contradicts the container design and parted isn't installed), per-slot `root=PARTLABEL=`, `.img.zst` + `.qcow2` outputs. Schema still has `[disk]`, needs `[partitions]`.
3. **Packages-stage closure resolution** (§3.4) so a green build is reproducible from `astro build` alone, plus signed-index verification instead of `--allow-untrusted`.
4. **Bootloader stage** — stub today; qemu-aarch64 uses direct kernel boot (fine for M0 smoke, docs/11 M1 wants real U-Boot; `qemu-x86_64`/`x86_64-efi` boards + GRUB path don't exist yet).
5. **RO squashfs rootfs + A/B layout** — current rootfs is the rw-ext4 single-partition dev model; prod squashfs assembly (mksquashfs is already in the container) and the A/B `[partitions]`/RAUC `bundle` stage are M1/M2 work. RAUC host tools are already in the container.
6. **`astro` CLI stage contract** — this run drove `astro-build.sh --step=...` + hand-run cbuild; stage contracts with cache keys (docs/03 §5) would have avoided most manual glue.
7. **Reproducibility plumbing** (docs/03 §7): SOURCE_DATE_EPOCH, deterministic apk ordering, lock-drift refusal (`hm status` gate is not wired into the build yet).
8. **Boot-smoke test stage** — the QEMU tests in §1 rows 10a/10b should become `astro test boot-smoke <board>` (junit output per docs/03 §5), with a login-prompt assertion and timeout instead of hand-run timeouts.
9. **Small kernel-fragment follow-up** — `early-sysctl` and `early-binfmt` fail on boot (only non-OK services): add `CONFIG_BINFMT_MISC` (+ whatever sysctl needs) to `boards/common/kernel/` fragments.
10. **Ownership correctness** — `--usermode` apk leaves all files owned by the build uid; acceptable for the dev ext4 path, wrong for prod squashfs (needs fakeroot or rootless uid-mapping in the image stage).

## 5. Artifacts and logs

- Logs: `build/state/logs/` (`00-container-build`, `01-toolchain`, `02-kernel`, `03-bootloader`, `04-packages*`, `04b–04k` closure/llvm rounds, `05-rootfs*`, `06-image`, `07-qemu-smoke`, `07-qemu-boot` — attempt 3 is the login-prompt run).
- Kernel: `build/state/aarch64/kernel/qemu-aarch64/arch/arm64/boot/Image` (+ stripped modules in `modules_install/`).
- Toolchain/SDK: `toolchain/`, wrappers in `build/state/aarch64/bin/`.
- Package repo: `cports/packages/main/aarch64/` (~140 package names, signed with the dev key).
- Boot smoke: `build/state/mini-init.c`, `build/state/smoke.ext4`, log `build/state/logs/07-qemu-smoke.log`.
- cports patch (in flight): `build/patches/cports/0001-llvm-cross-native-tools-host-compiler.patch`.
