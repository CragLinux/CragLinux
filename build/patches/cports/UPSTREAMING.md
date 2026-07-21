# Upstreaming draft: `main/fakeroot` checksum refresh

Status: **DRAFT** — carried as
`0002-fakeroot-refresh-checksum-salsa-archive-regen.patch`.

salsa.debian.org regenerated its auto-generated archive for the
`upstream/1.37.1.2` tag, so the sha256 pinned in `main/fakeroot` (still
current on cports master as of 2026-07-17) fails verification on any cold
fetch. Content was verified against a fresh git clone of the tag before
accepting the new hash: trees are identical modulo export-ignored
`.gitattributes`/`.gitignore`; only archive compression metadata changed.

Proposed commit: `main/fakeroot: update checksum` (matches the existing
"fix checksum" convention, e.g. cports commit `e3c9e1a0`). Note that
Chimera builders with a warm distfile cache will not see the failure,
which is likely why it is still latent upstream. Same process note as
below applies: a human contributor must verify and own the change.

---

# Upstreaming draft: `main/doctest` + `main/boost` armv7 self-build fixes

Status: **DRAFT** — carried as
`0003-doctest-disable-tests-clang22-c2y-werror.patch` and
`0004-boost-no-stacktrace-addr2line-basic-arm32.patch`. Both surfaced
while self-building the full armv7 repo (no Chimera binary repo for that
arch); details in each patch header. doctest: bundled examples compile
with -Werror and clang 22's new -Wc2y-extensions fires on __COUNTER__ —
latent upstream until their next doctest rebuild; fix disables
DOCTEST_WITH_TESTS (header-only package, nothing packaged from examples).
boost: b2 disables the stacktrace addr2line backend on arm_32 (the lib is
never built), but the template packages it unconditionally → take() error;
fix drops that _libs entry on armv7/armhf. Proposed commits:
`main/doctest: don't build tests, fixes build with clang 22` and
`main/boost: fix packaging on 32-bit arm`. Same human-ownership process
note as below.

M2 additions (2026-07-18): `0006-glib-no-introspection-cross.patch` and
`0007-json-glib-no-introspection-cross.patch` — gobject-introspection is
`!cross` in its own template, so any template with
`-Dintrospection=enabled` cannot cross-build; both patches append
`-Dintrospection=disabled` for cross profiles (meson: later -D wins).
Upstreamable as cross enablement. Also new in `astro-cports/main/`:
`rauc` (1.15.2) and `libubootenv` (0.3.7) — standard ports with no
Astro-specific content, upstreamable as new packages if Chimera wants
them; proposed commits `main/rauc: new package` etc.

Also carried, **not** upstreamable in its current form:
`0005-elfutils-no-debuginfod-arm32.patch` — disables debuginfod on
armv7/armhf because its closure dead-ends in `main/protobuf`, which is
marked broken for cross builds. The honest upstream fix is making
protobuf cross-buildable (its template carries the diagnosis); our patch
is an Astro-local port decision to keep the armv7 repo closable.

---

# Upstreaming draft: `main/dinit-dbus` cross service-provider fix

Status: **DRAFT** — carried as
`0008-dinit-dbus-cross-makedepends-dbus-dinit.patch` (M3 phase 3,
2026-07-20). The -dinit autopackage's service files depend-on
`dbus-daemon`; the 001_runtime_deps hook needs the provider (dbus-dinit)
installed at package time. Native builds get it by accident —
`checkdepends = ["dbus"]` installs dbus and trips dbus-dinit's
install_if — but cross builds skip checkdepends
(`core/dependencies.py:134` gates them on `not pkg.profile().cross`), so
cross-building dinit-dbus always dies with "usvc: dbus-daemon (unknown
provider)". Fix is exactly what the hook's own hint says: add
`dbus-dinit` to makedepends. Found cross-building main/iwd for the
self-built armv7 repo. Proposed commit:
`main/dinit-dbus: fix cross builds (dbus-daemon service provider)`.
Same human-ownership process note as below. (Latent upstream bug seen on
the way, not carried: 001_runtime_deps' `scan_svc` stores requirements
in a dict keyed by service name, so a name required as BOTH svc and usvc
— dbus-daemon here — records only the last-scanned prefix; the system
svc dependency is silently dropped from svc_requires.)

---

# Upstreaming draft: `main/llvm` cross-build fixes for Chimera cports

Status: **DRAFT — nothing has been submitted anywhere.** This is a
ready-to-review internal draft for a future Chimera cports pull request
covering the two cross-build bugs currently carried as
`0001-llvm-cross-native-tools-host-compiler.patch` in this directory.

> **Process note (read before submitting):** Chimera's `CONTRIBUTING.md`
> explicitly forbids AI-prepared contributions. This draft was
> machine-assisted; a human contributor must independently verify, rewrite
> and own the analysis and the patch before anything is sent upstream. The
> draft exists to capture the diagnosis and evidence while they are fresh.
> Also verify first whether Chimera even exercises this path — their CI
> appears to build `main/llvm` natively per-arch (the template carries a
> "FIXME: make it build for cross" note for MLIR), so the right venue may
> be an issue/discussion rather than a straight PR.

## Contribution norms (from cports `CONTRIBUTING.md` at the pin)

- GitHub fork + custom branch + pull request; no CLA.
- One commit per template-change; atomic commits, each must build on its own.
- Commit message format: `main/llvm: <message>` (American English).
- It is the submitter's responsibility to verify the changes build; CI
  failures must be addressed by the submitter.

Because both changes touch the same template but fix two independent bugs,
the PR should carry **two logical commits**, ordered so each builds on its
own (commit 1 first: it fixes the failure that currently hides bug 2).

---

## Problem statement

Cross-compiling `main/llvm` (e.g. `./cbuild -a aarch64 pkg main/llvm` from
an x86_64 bldroot) fails twice, at two different stages. Environment:
cports @ `e3c9e1a0` ("user/soju: fix checksum"), LLVM 22.1.7, apk-tools
3.0.5, unprivileged bwrap-based bldroot inside a container.

### Bug 1: the NATIVE tools sub-build inherits the cross compiler

For cross builds the template points CMake at host tools:

```
"-DLLVM_NATIVE_TOOL_DIR=/usr/bin",
"-DLLVM_CONFIG_PATH=/usr/bin/llvm-config",
"-DLLVM_TABLEGEN=/usr/bin/llvm-tblgen",
...
```

but LLVM 22 needs *build-only* tools the host llvm package does **not**
ship — `llvm-min-tblgen`, `mlir-irdl-to-cpp` (and the bldroot carries no
`mlir-*` tools at all; verified against `bldroot/usr/bin`). CMake therefore
schedules them in LLVM's NATIVE sub-build (`<build>/NATIVE`), which
configures with the **cross** `CC`/`CXX` from the environment. The result:
"native" tablegen binaries are aarch64 ELF, and every tblgen invocation
dies. With a binfmt qemu-aarch64-static handler on the build host the
symptom is:

```
FAILED: [code=255] include/llvm/IR/IntrinsicsPowerPC.h ... llvm-min-tblgen ...
qemu-aarch64-static: Could not open '/lib/ld-musl-aarch64.so.1': No such file or directory
```

(without binfmt it would be a plain exec format error). This costs ~2.5 h
of build time before failing.

**Fix rationale:** explicitly pin the NATIVE sub-build to the bldroot host
compiler via `CROSS_TOOLCHAIN_FLAGS_NATIVE` (the upstream-supported knob
for exactly this), next to the existing host-tool hints in the template's
cross branch. With this, the NATIVE sub-build (1308 targets) completes and
the cross build proceeds past the original failure point.

### Bug 2: flang-rt configure requires a *running* flang

With bug 1 fixed, the build then fails at `runtimes-configure`:

```
flang-rt/CMakeLists.txt: ... No CMAKE_Fortran_COMPILER could be found
```

`flang-rt` (new in the LLVM 22 layout) is configured as a runtime and
probes for a working Fortran compiler — the freshly cross-built `flang` is
target-arch and cannot run on the build host, and the bldroot ships no host
flang. This is independent of bug 1: it is the "runtimes need a running
compiler" class of cross problem.

**Fix rationale:** disable mlir (and thereby flang/flang-rt, which depend
on it) for cross profiles. The template already carries
`# FIXME: make it build for cross` on the MLIR distribution components, so
this makes the existing limitation explicit instead of failing 2 h into
the build. Cross-built llvm then completes (rc=0, ~1.5 h on 24 cores
without mlir/flang) and produces the clang/lld/libc++/libc++abi/libunwind
packages. A more ambitious alternative — building a host flang in the
NATIVE sub-build or depending on a host flang package — is upstream's call
and out of scope for a minimal fix.

---

## Proposed commit split

### Commit 1: `main/llvm: build NATIVE tools with the host compiler when cross-compiling`

```
main/llvm: build NATIVE tools with the host compiler when cross-compiling

LLVM 22 needs build-only tools that the host llvm package does not ship
(llvm-min-tblgen, mlir-irdl-to-cpp, ...). These are generated in the
NATIVE tools sub-build, which inherits the cross CC/CXX and thus emits
target-arch binaries that cannot run on the builder, killing every
tblgen invocation. Pin the NATIVE sub-build to the container's host
clang via CROSS_TOOLCHAIN_FLAGS_NATIVE.
```

Diff (against the pinned template's `init_configure`, without the
Astro-local comment carried in our build-time patch):

```diff
     # grab these from the host
     self.configure_args += [
+        "-DCROSS_TOOLCHAIN_FLAGS_NATIVE=-DCMAKE_C_COMPILER=/usr/bin/clang;-DCMAKE_CXX_COMPILER=/usr/bin/clang++",
         "-DLLVM_NATIVE_TOOL_DIR=/usr/bin",
         "-DLLVM_CONFIG_PATH=/usr/bin/llvm-config",
         "-DLLVM_TABLEGEN=/usr/bin/llvm-tblgen",
```

(Note for review: this addition belongs in the `self.profile().cross`
branch of `init_configure`, where the other host-tool hints live, so
native builds are unaffected.)

### Commit 2: `main/llvm: disable mlir/flang for cross builds`

```
main/llvm: disable mlir/flang for cross builds

flang-rt is configured as a runtime and requires a running flang; in a
cross build the freshly built flang is target-arch and the builder has
none, so runtimes-configure fails with "No CMAKE_Fortran_COMPILER could
be found". MLIR cross support is already marked FIXME in the template.
Disable both for cross profiles so the build fails no more; native
builds are unchanged.
```

```diff
 # from stage 2 only, pointless to build before
-_enable_mlir = self.stage >= 2
+# FIXME: make it build for cross (flang-rt needs a host-runnable flang)
+_enable_mlir = self.stage >= 2 and not self.profile().cross
 _enable_flang = _enable_mlir and self.profile().wordsize == 64
```

**Packaging consequence to disclose in the PR:** with mlir/flang disabled
for cross, the `mlir*`/`flang*` subpackages are not produced by
cross-built llvm. Cross-building `main/llvm` appears unexercised by
Chimera CI today (their builders are native per-arch), so this should not
regress any produced repo — but reviewers should confirm.

## Verification evidence (Astro build logs)

- Unpatched: ~2.5 h in, NATIVE sub-build fails on `llvm-min-tblgen`
  (aarch64 binary, musl loader missing on host).
- Commit 1 only: NATIVE sub-build (1308 targets) completes; build then
  fails at `runtimes-configure` in `flang-rt` (bug 2).
- Both commits: full cross build rc=0 in ~1.5 h (24 cores), packages
  produced: llvm, clang, lld, libcxx, libcxxabi, libunwind, ...
  (log: `build/state/logs/04g-llvm3.log` in the Astro workspace).
