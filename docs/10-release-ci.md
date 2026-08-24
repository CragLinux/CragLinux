# 10 — Repos, Versioning, Releases, and CI

**Status:** Draft for review · **Owns decisions:** AD-003, AD-019, AD-020, AD-024 · **Read after:** [03-build-system.md](03-build-system.md)

---

## 1. AD-003 — Repository structure

> **AD-003 — Crag is a monorepo; companion repositories (cports, and any future split-outs) are managed with Harbormaster, pinned via its committed lock file. External trees are always separate repositories.** *(Recommended)*

```
crag/                           # THE repo (this one)
├── README.md   LICENSE (Apache-2.0)   docs/          # this doc set
├── build/                       # orchestrator: `crag` CLI, lib/ (config.py, schema.py), stages/
├── container/                   # Containerfile → crag-builder image
├── .harbormaster.toml           # companion-repo manifest (cports, …)  ─┐ AD-001/023
├── .harbormaster.lock           # exact SHA pins, committed             ─┘
├── cports/                      # hm-managed checkout → chimera-linux/cports (gitignored)
├── astro-cports/                # Crag's cbuild collection (cragd, crag-base-*, rauc glue, …)
├── boards/                      # common/ + per-board dirs (TOML, fragments, overlays, hooks, uboot/grub assets)
├── variants/                    # prod.toml, dev.toml
├── cragd/                       # Zig: src/, api/openapi.yaml, web/ (provisioning page), cragctl/
├── sdk/                         # build-toolchain.sh (repurposed), sysroot generator, cmake files
├── keys/dev/                    # dev-only PKI (loud naming; 09 §4)
├── examples/external-tree-acme/ # buildable reference tree (08 §7)
├── tests/                       # boot-smoke, A/B update, api suites (test-stage payloads)
└── .github/workflows/           # thin wrappers around `crag …` in the container (AD-024)
```

Rationale: the orchestrator, schema, cragd API, board definitions and docs version **together** — a monorepo makes cross-cutting changes (schema + stage + doc) one reviewable PR. cports stays its own upstream repo (AD-001), materialized into the workspace by Harbormaster. cragd stays in-tree until its release cadence demonstrably diverges (splitting later is cheap; premature split costs every API-schema-orchestrator sync). External trees are separate by *definition* — they belong to product teams with their own keys and cadence ([08 §1](08-external-trees.md)).

**Companion-repo management: Harbormaster, not git submodules.** [Harbormaster](https://github.com/TierOne-Software/HarborMaster) (`hm`, TierOne's multi-repo tool in the `repo`/`jiri` family) declares companion repos in `.harbormaster.toml` and records exact commit SHAs in a committed `.harbormaster.lock`; `hm sync --locked` reproduces the pinned workspace, `hm status` shows drift, and pin bumps are a lock-file diff in a normal PR. This gives submodule-grade reproducibility without submodule ergonomics (no detached-HEAD confusion, no `--recurse` footguns, no gitlink/`.gitmodules` dance on clone). The `cports/` checkout itself is gitignored; the lock file is the source of truth. Setup is two commands: `hm sync --locked` after clone, and everything else is `crag …`. As a bonus, developers hacking on Crag alongside external trees or Harbormaster-managed product repos can use `hm work` sessions for coordinated branches across repos — a workflow convenience, not something the build depends on.

## 2. AD-019 — Versioning

> **AD-019 — Crag releases use calendar versioning `YYYY.MM[.patch]`. The cragd API is versioned independently (`/api/v1`). Channels are repo URLs, not signing keys.** *(Recommended)*

- **Release version** `2026.10`, patches `2026.10.1` — for an appliance OS, "what am I running" should read as a date; there is no meaningful semver "breaking" axis for a whole distro (the stability contract in [08 §8](08-external-trees.md) plays that role).
- Identity carried in: `/etc/os-release` (`ID=crag`, `VERSION_ID=2026.10.1`, `VARIANT=prod|dev`), RAUC bundle version (drives AD-021 monotonicity), `manifest.json`, `GET /system`.
- **cragd API**: `/api/v1` frozen once shipped, additive-only; `/api/v2` would ship alongside for ≥ 2 release lines ([06 §4](06-config-api.md)).
- apk repos are per release train: `repo.crag…/2026.10/{main,crag}/<arch>`.

## 3. Branches and channels

```
main ──────────────► every green commit ⇒ channel: dev
  └─ release/2026.10 (branched at freeze; cports pin locked — AD-023)
        ├─ RC bundles         ⇒ channel: testing
        └─ tagged 2026.10.x   ⇒ channel: stable   (promotion = `rauc resign` of the tested
                                                    bundle + repo publish; no rebuild)
```

Channel = **URL** a device's update source points at. One keyring trusts all channels in v1 (simplicity; a device can be pointed at testing deliberately). Key-separated channels are a documented later hardening if products demand it.

## 4. AD-024 / AD-020 — CI design

> **AD-024 — CI is container-based via rootless podman and local-first: every pipeline step is an `crag …` command inside `crag-builder`, runnable identically on a laptop. Hosted CI is a thin wrapper, added when needed.** *(Accepted)*

> **AD-020 — The QEMU full A/B update-and-rollback test is a required gate on every PR.** *(Recommended)*

Consequences of local-first: no pipeline logic lives in workflow YAML — workflows only checkout, `hm sync --locked`, restore caches, and invoke `crag ci <suite>`; a developer reproduces any CI failure with the same command; the future hosted runner choice (GitHub-hosted vs self-hosted) becomes a capacity decision, not an architecture one. Heavy caches (bldroot, distfiles, ccache, apk repo) are content-addressed volumes restorable from any object store.

**Packages-mode per pipeline** ([03 §1](03-build-system.md) "Binary consumption for dev builds"): PR builds run `--packages-mode=binary` — only Crag-touched templates are built from source, everything else comes from Chimera's signed binary repo (keys pinned in `build/keys/chimera/`, trusted for dev artifacts only). Exception: armv7 has no Chimera binary repo, so `qemu-armv7` builds in source mode on every pipeline, warmed by Crag's own published CI-built armv7 repo ([03 §1](03-build-system.md)). Nightly and release pipelines run `--packages-mode=source` — full-source under Crag keys, immune to the binary-mode version-skew that the warn-only skew report tracks on PRs.

**Per-PR** (target: warm ≤ 60 min):
1. Lint: shellcheck, ruff (build/lib), `zig fmt --check`, TOML schema self-tests, template lint for astro-cports.
2. cragd unit tests (`zig build test`) + OpenAPI ↔ router conformance check.
3. Full build of **one QEMU board per arch** (`qemu-x86_64` + `qemu-aarch64` + `qemu-armv7`, prod variant, warm caches) through image + bundle stages — `qemu-armv7` in source mode per the exception above, kept inside the time budget by the published armv7 repo cache.
4. **The AD-020 gate**, per board: boot smoke (reaches `boot-success`, cragd healthy) → install current-build bundle over previous-release image → verify slot flip + mark-good → install a poisoned test bundle (boot-success unreachable) → verify automatic rollback to the good slot ([04 §7](04-boards-images-boot.md) sequence).
5. cragd API integration suite against the booted QEMU device (provisioning state machine driven via QMP-simulated conditions).
6. `examples/external-tree-acme` build — keeps the external-tree contract and the SDK green.

**Nightly:** all boards (incl. rpi/x86_64-efi images) from clean cache; **source-bootstrap canary** (cbuild 4-stage — keeps the from-source story honest, [03 §2](03-build-system.md)); reproducibility check (double build, compare squashfs SHA512, [03 §7](03-build-system.md)); cports pin-bump trial build (report, no auto-merge).

**Release:** freeze pin → RC build all boards → full test matrix + manual hardware smoke (rpi, one EFI box) → sign with prod keys (CI secret store / PKCS#11; the only pipeline with access) → publish → promote via resign per §3. A CI check refuses any `prod`-variant artifact whose keyring contains the dev CA ([09 §4](09-security.md)).

## 5. Artifact hosting and layout

```
dl.crag…/
├── releases/<version>/<board>/     # .img.zst, .raucb, .qcow2, manifest.json, SHA512SUMS(.sig)
├── repo/<train>/{main,crag}/<arch>/   # apk repositories (APKINDEX, signed)
├── sdk/<version>/                  # per-arch SDK tarballs
└── channels/{dev,testing,stable}/<board>/latest.raucb   # stable-URL pointers devices poll
```

Retention: `dev` channel artifacts 30 days; `testing` until superseded + 90 days; `stable` releases indefinitely (they are rollback targets). All hosting is dumb-HTTPS-with-Range — a requirement, not a convenience, since RAUC streaming installs need only Range requests ([05 §3](05-updates.md)); any object store + CDN qualifies. v1 development phase: a local directory + `python -m http.server`-grade serving works because of the same property.

## 6. Decision and change process

- **ADs**: amended by PR touching the owning doc + the index in [01](01-architecture.md); "Recommended → Accepted" requires project-owner sign-off recorded in the PR; superseded ADs stay in the doc, struck through, with a pointer forward.
- **Stability-contract changes** ([08 §8](08-external-trees.md)): deprecation warning in release N's notes and build output, removal earliest N+1.
- **RFCs**: designs bigger than an AD amendment (e.g., app-only updates) get a `docs/rfc/` markdown with the same review flow, graduating into the numbered docs on acceptance.
