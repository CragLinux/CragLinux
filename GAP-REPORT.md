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

> **Phase 1 (2026-07-17): FIXED (automation + upstreaming draft).** The
> packages stage now applies every `build/patches/cports/*.patch` before any
> cbuild invocation (idempotent: `git apply --check` / `--reverse --check`)
> and resets the checkout afterwards — success or failure — via
> `git checkout -- . && git clean -fd` (scoped: `clean` without `-x` never
> touches the gitignored `bldroot*`, `packages*`, `sources*`, `cbuild_cache`,
> `etc/keys`; see `prepare_cports_tree`/`reset_cports_tree` in
> `build/lib/packages.sh`). `hm status` shows a clean pin outside the stage.
> An upstream PR draft (two-commit split, cports commit-style, verification
> evidence) is at `build/patches/cports/UPSTREAMING.md` — draft only,
> nothing submitted.

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

> **Phase 1 (2026-07-17): WORKED AROUND (openssh restored); heimdal itself
> still does not cross-build.** `astro-cports/main/openssh` shadows the
> pinned template with GSSAPI/Kerberos removed (drops `heimdal-devel` +
> `--with-kerberos5`, `pkgrel` bumped to 2, everything else identical incl.
> subpackages/`-dinit`). The packages stage overlays astro-cports templates
> onto the cports tree alongside the patches (cbuild has no out-of-tree
> collection mechanism — categories are subdirs of the checkout, and
> symlinks are defeated by `sanitize_pkgname()`'s `Path.resolve()`).
> `openssh`/`openssh-dinit` + the `sshd` service are re-enabled in
> `boards/qemu-aarch64/variants/dev.toml`; verified: cross-built
> `openssh-10.3_p1-r2` (deps: libc/crypto/edit/fido2/ldns/pam/z only),
> installed into the dev rootfs, sshd answers `SSH-2.0-OpenSSH_10.3` on the
> forwarded port in the QEMU boot test. Cross-building heimdal (native-tool
> class failure) remains open — only needed if a package must have GSSAPI.

- `asn1_compile: not found` during build — heimdal builds its own generator tools and then executes them; in a cross build they are aarch64 binaries (same native-tool class of failure as llvm). Log: `build/state/logs/04e-closure4.log`.
- Impact: `openssh` cannot be installed by apk until heimdal exists. Workaround for a boot-only image: drop `openssh`/`openssh-dinit` from the dev variant. Suggested fix: investigate how Chimera CI builds heimdal for aarch64 (native builders again?), or add host-heimdal native tools to the bldroot.

### 3.3 Anubis (HTTP 418) blocks cbuild's distfile fetcher for gitlab.alpinelinux.org

> **Phase 1 (2026-07-17): FIXED (bounded curl fallback).** Every cbuild
> invocation now goes through `cbuild_pkg()` (`build/lib/packages.sh`): on
> failure whose log matches cbuild's fetch-error signatures, the template's
> source URLs + sha256 are resolved via `./cbuild dump` and fetched with
> `curl -L` (default UA passes Anubis) into `cports/sources/<name>-<ver>/`
> by `build/lib/fetch_distfiles.py` (checksum-verified, one attempt per
> distfile), then the build is re-run exactly once. Generic for any
> 4xx/fetch error, loudly logged. A distfile mirror/cache stays the better
> long-term answer (docs/03 §4).

- cbuild's Python urllib fetcher gets `418 I'm a teapot` from gitlab.alpinelinux.org (Anubis anti-bot challenges "Mozilla-ish" UAs; plain `curl` passes). Hit twice (apk-tools, ca-certificates); will recur for every alpinelinux-hosted distfile.
- Suggested fix: distfile mirror/cache (the `sources` named volume from docs/03 §4, warmed by CI), or teach cbuild a curl-compatible UA, or carry the distfiles.

### 3.4 Packages stage builds no dependency closure (design gap, worked around manually)

> **Phase 1 (2026-07-17): FIXED (automated closure loop).** After the listed
> templates are built, the packages stage now iterates (max 10 rounds):
> regenerate the signed local index **from scratch** (`cbuild index
> packages/main` after deleting the old `Packages.adb` — mkndx's `--index`
> merge keeps entries for deleted .apk files, which masked missing packages;
> raw `apk mkndx` without a key exits 127 silently, so cbuild's signing
> wrapper is used), dry-run the full manifest (`apk --simulate add` against
> the local repo, plus Chimera's repo in binary mode, keys verified), parse
> `(no such package)` deps and map them to templates
> (`build/lib/closure_map.py`: template dirs → index provider/origin oracle
> for `so:`/`pc:`/`cmd:` → `@subpackage(...)` search), `cbuild pkg` the
> missing templates, repeat; hard failure listing unresolved deps on
> no-progress/cap. Verified both modes: binary (converges round 1, only
> Astro-touched templates built) and source (removed `libedit-*.apk` from
> the repo → round 1 detects `so:libedit.so.0`, maps to `main/libedit`,
> rebuilds it, round 2 converges). `--allow-untrusted` is gone from the
> rootfs stage in both modes (source installs verify against the cbuild dev
> pubkeys, binary additionally against the pinned Chimera keys).

- `build/lib/packages.sh` builds exactly the listed packages; the rootfs needs the full **runtime** closure (~25 extra templates were built by hand this run: base-files, ca-certificates, openssl3, zlib-ng-compat, zstd, debianutils, ncurses, libedit, acl, bzip2, xz, kmod, file, linux-pam, libxo, tzdb, openresolv, snooze, sd-tools, util-linux, udev, chimera-repo-main, libcap, shadow, resolvconf, ldns, libfido2…).
- Suggested fix: resolve the closure via apk against the repo index and `cbuild pkg` anything missing (or use `cbuild`'s bulk facilities) — belongs in the `packages` stage rework of the `astro` CLI (docs/03 §5).

### 3.5 rootfs stage smaller gaps

> **Phase 1 (2026-07-17): FIXED (except ownership, still open).**
> The manual-extraction fallback was deleted; apk failures are now hard
> errors (`die`) in both packages modes, and a missing repo dir is a hard
> error too. `20-enable-services.sh` was validated against the booted
> rootfs: dinit-chimera's `boot` service uses `waits-for.d:
> /etc/dinit.d/boot.d`, where entries activate services **by name** (even a
> dangling link works — the old `../dhcpcd` link pointed at a nonexistent
> `/etc/dinit.d/dhcpcd` yet dhcpcd ran); the hook now mirrors the packaged
> convention and links to the real service file
> (`../../../usr/lib/dinit.d/<svc>` for packaged services, `../<svc>` for
> /etc-local ones). The `--usermode` ownership caveat below remains open
> (prod squashfs work).

- ~~The **manual-extraction fallback is dead code**: apk-tools 3.x `.apk` files are ADB, not gzip tarballs; `tar -xzf` silently extracts nothing and the build "passes" with an empty rootfs. Should be deleted or made a hard error.~~ (fixed, see above)
- ~~`apk --usermode` files are owned by the build uid, not root — fine for dev ext4 images (and `mkfs.ext4 -d` normalizes to root), but the prod squashfs path must own files correctly (fakeroot or apk in a userns). **(still open)**~~ **M1 wave 1 (2026-07-17): FIXED (apk in a userns).** The rootfs stage runs as a child process (`build/lib/rootfs-stage.sh`); the prod squashfs path wraps it in `unshare -r` (build uid → 0), apk drops `--usermode` and applies real package ownership/modes, and mksquashfs runs in the same namespace — root-owned squashfs without sudo, `/etc/shadow` back at packaged 000. Verified via `unsquashfs -lln` (zero non-root entries, setuid intact). Known limitation: chowns to unmapped ids (`/var/log/{wtmp,btmp,lastlog}` root:utmp, `/var/lib/dhcpcd`) degrade to root with a loud apk warning; the shipped tmpfiles.d entries re-apply them at boot on mutable mounts. See MIGRATION-NOTES §11.
- ~~dinit service enablement hook (`20-enable-services.sh`) symlinks into `/etc/dinit.d/boot.d/` — needs validation against dinit-chimera 0.99.x conventions once a full rootfs boots.~~ (validated + fixed, see above)

### 3.6 SDK toolchain gaps (hit while building the boot-smoke init)

> **Phase 1 (2026-07-17): FIXED.** The generated wrappers now pass
> `-fuse-ld=lld`, and the compiler-rt builtins build enables
> `COMPILER_RT_BUILD_CRT=ON` (verified present in LLVM 22's standalone
> builtins cmake, gated on `COMPILER_RT_HAS_CRT`); the resulting
> `clang_rt.crtbegin.o`/`clang_rt.crtend.o` are installed into the clang
> resource dir per-triple (plus arch-suffixed copies in
> `sysroot/lib/linux/`). Acceptance test passed: the boot-smoke init was
> rebuilt as a normal libc program with `-static` (not `-nostdlib`), linked
> clean, and printed its banner from `/init` in QEMU
> (`build/state/logs/p1-02-qemu-smoke-static.log`).

- ~~The generated `<triple>-clang` wrappers do not pass `-fuse-ld=lld`; on a GNU-ld host the link fails (`unrecognised emulation mode: aarch64linux`).~~ (fixed)
- ~~The SDK sysroot ships no compiler-rt `crt*.o` for `-static` linking (`cannot open crtbeginT.o`); freestanding `-nostdlib` was needed for the smoke-test init.~~ (fixed)

### 3.7 Process notes (build-environment data)

> **Phase 1 (2026-07-17): headers issue FIXED.** `install_kernel_headers`
> now runs `make O=build/state/<arch>/kernel-headers-obj headers_install`
> so all generated state lands outside the shared source tree; verified the
> tree stays pristine (no `include/generated`, no `.config`) after a full
> headers reinstall, and the kernel stage builds from it unchanged.

- ~~The kernel stage and the SDK share `sources/linux-<ver>`; the SDK's `headers_install` leaves the tree unclean and breaks the kernel's `O=` build (fix #2 was a one-time `mrproper`; real fix: SDK should install headers from a pristine copy or its own `O=` dir).~~ (fixed via `O=`)
- zsh `noclobber` on the host bit twice (`>` and `>>` to fresh files); build scripts themselves are bash and unaffected.

## 4. Distance to M1 (per docs/11 §1 and docs/03/04)

What M0/M1 need that this run showed is still missing, in rough order:

1. **Upstream/productize the llvm cross patch** (§3.1) and fix heimdal cross (§3.2) so a clean `hm sync --locked` tree builds unmodified; wire quilt-style `build/patches/cports/` application into the packages stage.
2. ~~**`image` stage** — `build/lib/image.sh` is a stub. Needs the docs/04 §6 layout: GPT via sfdisk, ESP population via mtools (no loop devices/sudo — `create-system-image.sh`'s parted+losetup+sudo approach contradicts the container design and parted isn't installed), per-slot `root=PARTLABEL=`, `.img.zst` + `.qcow2` outputs.~~ ~~Schema still has `[disk]`, needs `[partitions]`.~~ **M1 wave 1 (2026-07-17): schema DONE** — `[partitions]`/`[rauc]`/`[image]`/`[api]` + `grub-efi` landed, `root=` is rejected in board cmdlines (run-qemu.sh injects it for direct boots), `[disk]` maps with a deprecation warning for one release; boards migrated. **M1 wave 2 (2026-07-17): image stage DONE** — fully unprivileged AD-007 A/B GPT assembly (sfdisk on plain files, mtools-populated vfat, `mkfs.ext4 -d` under `unshare -r`, per-slot `root=PARTLABEL=`, `.img.zst` + `.qcow2` + SHA256SUMS + manifest.json); layout math in `build/lib/image_layout.py` (pure, SOURCE_DATE_EPOCH-deterministic GUIDs); `create-system-image.sh` + `cbuild-profiles/devices/` deleted. See MIGRATION-NOTES §12.
3. **Packages-stage closure resolution** (§3.4) so a green build is reproducible from `astro build` alone, plus signed-index verification instead of `--allow-untrusted`.
4. ~~**Bootloader stage** — stub today; qemu-aarch64 uses direct kernel boot (fine for M0 smoke, docs/11 M1 wants real U-Boot; `qemu-x86_64`/`x86_64-efi` boards + GRUB path don't exist yet).~~ **M1 wave 2 (2026-07-17): DONE** — U-Boot 2026.07 built from source per board (Fedora cross-gcc; the clang/lld build hangs at self-relocation — deviation recorded), boot.scr implements the AD-009 BOOT_ORDER/BOOT_x_LEFT flow, env-in-FAT on the bootenv partition (AD-009 raw-redundant-env deviation recorded — no U-Boot raw-block env backend for virtio); GRUB EFI core image via grub2-mkimage + static AD-008 ORDER/x_OK/x_TRY grub.cfg + grubenv on bootenv; new boards `qemu-x86_64` (OVMF) and `qemu-armv7` exist and boot through them. See MIGRATION-NOTES §12.
5. **RO squashfs rootfs + A/B layout** — ~~current rootfs is the rw-ext4 single-partition dev model; prod squashfs assembly (mksquashfs is already in the container)~~ **M1 wave 1 (2026-07-17): prod squashfs assembly DONE** — `qemu-aarch64/prod` variant (`[rootfs] type = "squashfs"`, minimal package set) produces a root-owned zstd squashfs (51 MB, checked against `[partitions].rootfs_size`) via the userns path, honors `SOURCE_DATE_EPOCH` (`-mkfs-time`/`-all-time`), and boot-smokes to `qemu-aarch64-production login:` on a RO squashfs root. **M1 wave 2 (2026-07-17): A/B image assembly DONE** (item 2 above) — both slots populated, real-bootloader boots select slot A and mount `root=PARTLABEL=rootfs.A` RO with `/data` mounted and zero failed services (`build/state/logs/w2-boot-*.log`). The RAUC `bundle` stage remains M2 work; RAUC host tools are already in the container.
6. **`astro` CLI stage contract** — this run drove `astro-build.sh --step=...` + hand-run cbuild; stage contracts with cache keys (docs/03 §5) would have avoided most manual glue.
7. **Reproducibility plumbing** (docs/03 §7): SOURCE_DATE_EPOCH, deterministic apk ordering, lock-drift refusal (`hm status` gate is not wired into the build yet).
8. **Boot-smoke test stage** — the QEMU tests in §1 rows 10a/10b should become `astro test boot-smoke <board>` (junit output per docs/03 §5), with a login-prompt assertion and timeout instead of hand-run timeouts.
9. ~~**Small kernel-fragment follow-up** — `early-sysctl` and `early-binfmt` fail on boot (only non-OK services): add `CONFIG_BINFMT_MISC` (+ whatever sysctl needs) to `boards/common/kernel/` fragments.~~ **M1 wave 1 (2026-07-17): FIXED.** Diagnosis: binfmt needed `CONFIG_BINFMT_MISC` (mount of /proc/sys/fs/binfmt_misc failed); sysctl needed `CONFIG_SECURITY_YAMA` (`kernel.yama.ptrace_scope` from 10-chimera-user.conf had no /proc/sys node). New `boards/common/kernel/dinit.fragment` + `rauc.fragment` (SQUASHFS+zstd+xattr, LOOP, DM_VERITY+DM+MD, NBD, SHA256 — all =y per AD-006); dev boot now has **zero failed services** (`build/state/logs/w1-05-boot-dev.log`).
10. ~~**Ownership correctness** — `--usermode` apk leaves all files owned by the build uid; acceptable for the dev ext4 path, wrong for prod squashfs (needs fakeroot or rootless uid-mapping in the image stage).~~ **M1 wave 1 (2026-07-17): FIXED** via `unshare -r` userns around the prod rootfs stage (§3.5 above; MIGRATION-NOTES §11).
11. **Kernel stage staleness detection** (found during the post-reboot resume, 2026-07-17): the skip check is `.kernel-version` marker + built image only — changing `boards/common/kernel/*.fragment` (or a board fragment/defconfig) does NOT trigger a rebuild; both the x86_64 sysctl refresh and the armv7 cgroup fix required deleting the markers by hand. The stage should hash its config inputs (defconfig + ordered fragment list) into the marker. Same class of gap: `configure_kernel` skips on `.astro-kernel-configured` and would keep a stale `.config` even after a forced build.
12. **gettext parallel-make flake on cross armv7** (MIGRATION-NOTES §12 armv7 notes): gnulib's generated `error.h` can be compiled against half-written under `make -j24` (`error_at_line` undeclared); succeeded on retry, no patch carried. If it recurs, cap gettext's build jobs or patch the gnulib-lib Makefile dependency.

## 5. Artifacts and logs

- Logs: `build/state/logs/` (`00-container-build`, `01-toolchain`, `02-kernel`, `03-bootloader`, `04-packages*`, `04b–04k` closure/llvm rounds, `05-rootfs*`, `06-image`, `07-qemu-smoke`, `07-qemu-boot` — attempt 3 is the login-prompt run).
- Kernel: `build/state/aarch64/kernel/qemu-aarch64/arch/arm64/boot/Image` (+ stripped modules in `modules_install/`).
- Toolchain/SDK: `toolchain/`, wrappers in `build/state/aarch64/bin/`.
- Package repo: `cports/packages/main/aarch64/` (~140 package names, signed with the dev key).
- Boot smoke: `build/state/mini-init.c`, `build/state/smoke.ext4`, log `build/state/logs/07-qemu-smoke.log`.
- cports patch (in flight): `build/patches/cports/0001-llvm-cross-native-tools-host-compiler.patch`.
