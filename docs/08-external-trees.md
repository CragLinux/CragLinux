# 08 — Customization: External Trees and Team Apps

**Status:** Draft for review · **Owns decisions:** AD-017, AD-026 · **Read after:** [03-build-system.md](03-build-system.md)
**Supersedes** the prototype's `EXTERNAL_TREES.md`.

---

## 1. Philosophy

Astro's core is fixed; **everything product-specific lives in external trees.** A product is fully described by:

```
product = Astro @ pinned release  +  external tree(s) @ pinned commit  +  signing keys
```

The mechanism descends from Buildroot's `BR2_EXTERNAL` as prototyped in clang-cross (`--external <path>`), hardened into a versioned contract (§8). Multiple trees compose (e.g. a company-common tree + a product tree), ordered by explicit priority.

Teams **never** fork Astro, patch cports, or hand-edit images. If a product needs something the contract can't express, that's a gap to fix in Astro — file it, don't fork it.

## 2. Tree layout

```
acme-product-tree/
├── tree.toml                    # identity + compatibility
├── cports/                      # a cbuild collection: the team's packages
│   └── main/
│       ├── acme-sensord/template.py
│       └── acme-branding/template.py
├── boards/                      # new boards, or additions to Astro boards
│   └── acme-gateway-v2/…        # (board.toml, fragments, overlays, hooks)
├── variants/
│   └── acme-prod.toml
├── overlay/                     # rootfs overlay files (config only — §3)
│   └── etc/acme/defaults.toml
├── hooks/
│   └── 60-acme-enable-services.sh
└── packages.list                # packages added to every image built with this tree
```

`tree.toml`:

```toml
[tree]
name = "acme-product"
priority = 50                    # merge order among trees; lower merges first
astro_min = "2026.10"            # build fails fast on incompatible Astro
astro_max = ""                   # optional ceiling
```

## 3. AD-017 — Apps ship as apk packages, not overlay files

> **AD-017 — Team applications must be cbuild templates in the tree's `cports/` collection, built into the image's apk world. Rootfs overlays are restricted to non-executable configuration.** *(Recommended)*

Why packages and not "drop a binary in overlay/":

1. **Dependency resolution against the base** — cbuild's automatic ELF/pkg-config scanning ties the app to the exact `so:` versions in the image; an ABI break becomes a build failure, not a field crash.
2. **Service integration for free** — a service file installed to `usr/lib/dinit.d/` is auto-split into the `-dinit` subpackage and follows the packaging conventions of the whole distro.
3. **Auditability** — `apk query` on a device describes *everything*, including team software, with versions; `manifest.json` inherits that.
4. **Reproducibility** — packages build in cbuild's sandbox from pinned sources; overlays are opaque blobs.
5. **Future app-only OTA** — RAUC artifact repositories will deliver *packages*, not loose files ([05 §8](05-updates.md)); conforming now means that path opens without repackaging.

**Overlays remain** for what they're good at: certificates, app config templates, branding assets, `os-release` fragments. The rootfs stage **fails the build if an overlay introduces files under `usr/bin`, `usr/lib` (excluding `usr/lib/os-release.d`-style data dirs), or any ELF anywhere** — the fence is mechanical, not honor-system.

A minimal app template (Zig/Go/C apps all reduce to this shape):

```python
pkgname = "acme-sensord"
pkgver = "1.4.2"
pkgrel = 0
build_style = "cmake"
hostmakedepends = ["cmake", "ninja"]
makedepends = ["sqlite-devel"]
pkgdesc = "ACME plant-floor sensor daemon"
license = "Proprietary"
url = "https://git.acme.example/sensord"
source = f"git+https://git.acme.example/sensord#v{pkgver}"

def post_install(self):
    self.install_service(self.files_path / "acme-sensord")   # → usr/lib/dinit.d/, auto -dinit split
    self.install_file(self.files_path / "acme-sensord.manifest",
                      "usr/lib/astro/services", name="acme-sensord.toml")
```

## 4. Layering and precedence

Merge order everywhere: **`boards/common` → external trees (ascending priority) → board → variant.**

| Artifact | Merge rule |
|---|---|
| `packages.list` | **additive only.** No removal syntax against the core: masking base packages would fork the tested base ([02 §2](02-base-system.md) tiers are the supported way to get less) |
| overlays | file-level, last writer wins; the build logs every override (`overlay: acme-product/etc/foo overrides boards/common/etc/foo`) |
| TOML (board/variant) | deep merge per table; scalars: last wins; lists: **replace, not append** (append hides intent; a tree that wants to extend `config_fragments` restates it) — the one exception: `packages.install` accumulates |
| hooks | interleaved by numeric prefix across all layers (`10-core… 60-acme… 90-board…`); same number → layer order |
| cports collections | cbuild collection precedence: astro-cports shadows cports; tree collections shadow both (same-name template override is allowed but build-flagged loudly) |

Worked conflict example (documented in the tree author guide): two trees both providing `etc/acme/defaults.toml` → higher-priority tree wins, build log carries both provenance lines; two trees providing template `acme-common` → hard error unless versions identical.

## 5. dinit service integration

Each app package may install a **service manifest** (`usr/lib/astro/services/<name>.toml`) alongside its dinit service file:

```toml
[service]
name = "acme-sensord"
user = "acme"                  # system user, created at image assembly from this declaration
data_dir = true                # → /data/apps/acme-sensord, owned by 'acme', $ASTRO_DATA_DIR

[integration]
boot_success = true            # opt-in: rollback participation (AD-011)
api_controllable = true        # opt-in: POST /services/acme-sensord/restart allowed (06 §5.4)
api_client = true              # join astro-api group → unix socket access
```

- **`boot_success = true` is powerful and explicit**: the service becomes a dependency of the `boot-success` milestone, so if it fails to start after an update, `rauc-mark-good` never runs and the device rolls back ([05 §4](05-updates.md)). Default **false** — a crashing app should usually page someone, not revert the OS.
- Service files use plain dinit syntax (`type = process`, `restart = true`, `logfile = /data/var/log/…`); the image assembly hook reads manifests to: create users, create data dirs, wire `boot-success` dependencies, emit the env file (`ASTRO_DATA_DIR`, `ASTRO_API_SOCKET`), and enable the service (or the tree's hook enables conditionally).

## 6. App developer workflow and sideloading

> **AD-026 — Developer sideloading is a first-class, tooled flow: `astro deploy` pushes a rebuilt app (binary or package) to a running dev-variant device and restarts its service in seconds. Production images never accept sideloads.** *(Recommended)*

Fast app iteration on a live target is a make-or-break developer experience (prior art: AvocadoOS's dev-mode app sideload on Yocto). Astro tools it explicitly rather than leaving developers to hand-roll scp incantations. Three loops, fastest first:

**Sideload loop (seconds):** rebuild against the **SDK** ([03 §3](03-build-system.md)) — cross clang + sysroot generated from the exact target image — and deploy in one step:

```
. astro-sdk-aarch64/environment          # CC, CMAKE_TOOLCHAIN_FILE, SYSROOT
ninja -C build
astro deploy acme-sensord --to dev-device        # or --to qemu (default port-forwarded local VM)
```

`astro deploy` (SDK-shipped, also usable from an external-tree checkout) does, over ssh to a **dev-variant** device:
1. **Binary mode** (default when given a built artifact): copy the new binary/assets over the installed paths (it knows them from the package's file list), `dinitctl restart <service>`, then stream the service log back to the terminal until Ctrl-C. Round-trip target: **< 5 s** on QEMU.
2. **Package mode** (`--pkg`): build the app's cbuild template into an apk (warm bldroot), push it, `apk add` it on the device (dev variant runs full apk against a rw rootfs), restart the service. Slower, but exercises the real packaging — recommended before pushing a PR.
3. `--watch`: re-run the deploy on local file change, for tight edit-compile-run cycles.

**Why this works and where it stops:** the dev variant has a rw ext4 rootfs, ssh, and full apk ([02 §3](02-base-system.md)) — sideloading is ordinary file replacement there, and `apk query` still tells the truth in package mode (binary mode marks the package as locally-modified so drift is visible). **Prod images are read-only squashfs with no ssh — there is no sideload path to them, by design** (AD-004; the update bundle is the only way software reaches production). A field-debug "dev mode" toggle on prod-shaped images is explicitly deferred, not designed-in casually — it would puncture the immutability story and needs its own security review ([11 §3](11-roadmap-migration.md)).

**Outer loop (CI, ~tens of minutes warm):** template + `astro build acme-gateway-v2 acme-prod --external ../acme-product-tree` → image + bundle with the app baked in → `astro test update` against it. The sideload loop never replaces this: what ships is always the image-built package.

**Product repo CI shape** (documented example in `examples/`): the tree is its own git repo; its CI pins an Astro release (container image + git tag), runs `astro build/test`, publishes signed bundles with the *product's* RAUC keys.

## 7. Worked example: `acme-sensord`

`examples/external-tree-acme/` in the Astro repo is a **complete, buildable** reference tree kept green in CI ([10 §4](10-release-ci.md)): a ~200-line C sensor daemon that (a) reads its config from `$ASTRO_DATA_DIR`, (b) calls `GET /network` and `GET /update/status` over the unix socket at startup (demonstrating the API-client pattern), (c) ships a dinit service + manifest with `boot_success = false`, `api_controllable = true`, and (d) an `acme-branding` overlay-only package counterpart showing the config-vs-code fence. The tree also adds a `variants/acme-prod.toml` enabling it. Every section of this document points at a file in that tree.

## 8. Stability contract

What Astro guarantees to external trees, per major direction ([10 §2](10-release-ci.md) versioning):

**Stable within a release line, deprecation-cycled across lines:**
- `tree.toml` schema; tree directory layout
- board/variant TOML schema (additive evolution; removals go through deprecation warnings for one release)
- hook execution env: documented variables (`ASTRO_ROOTFS`, `ASTRO_BOARD`, `ASTRO_VARIANT`, layer paths), execution order semantics
- overlay semantics + the code/config fence rule
- service manifest schema; env vars `ASTRO_DATA_DIR`, `ASTRO_API_SOCKET`, `ASTRO_PREV_VERSION`
- astrod `/api/v1` (frozen once shipped — [06 §4](06-config-api.md))
- `/data` path conventions (`/data/apps/<name>`)

**Explicitly not stable:** cports/cbuild internals, base package *set* composition (only the tier metapackage names are contract), kernel config beyond the documented fragments, anything under `build/` not named above. Trees reaching into non-contract surfaces get to keep both pieces.
