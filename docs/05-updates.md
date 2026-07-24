# 05 — Updates: RAUC A/B Design

**Status:** Draft for review · **Owns decisions:** AD-010, AD-011, AD-021 · **Read after:** [04-boards-images-boot.md](04-boards-images-boot.md)

---

## 1. Invariants

1. Updates are **atomic whole-slot-group replacements** (kernel + rootfs together). There is no partial update state visible to applications.
2. **The running slot is never modified.** Installation always targets the inactive slot group.
3. **Rollback = boot the other slot.** The previous system remains intact until the *next* update overwrites it.
4. `/data` **survives updates** and is shared by both slots ([02-base-system.md §4](02-base-system.md)); cross-version compatibility of `/data` is a managed concern (§7).
5. **The only update authority is a signed RAUC bundle** verified against the device keyring. No unsigned side-loading, including in dev images (dev images trust the dev CA).

RAUC baseline: v1.15+; target-side dependencies (GLib, OpenSSL, libdbus, libcurl, libnl) are all in cports or added to the fork.

## 2. `system.conf`

Generated per board at image build (package `astro-rauc-conf`, template + board TOML values). Annotated example for `qemu-x86_64` / `x86_64-efi`:

```ini
[system]
compatible=astro-x86_64-efi        # per board family (§6); bundles must match
bootloader=grub                    # uboot on aarch64 boards
grubenv=/dev/disk/by-partlabel/bootenv   # (uboot boards: /etc/fw_env.config instead)
statusfile=/data/.astro/rauc.status      # slot status must persist: /data, not RO rootfs
bundle-formats=verity              # AD-010: plain not accepted

[keyring]
path=/etc/rauc/keyring.pem         # CA chain baked into the image (dev or prod CA)

[slot.boot.0]
device=/dev/disk/by-partlabel/boot.A
type=vfat
parent=rootfs.0                    # grouped: installs/activates with its rootfs

[slot.rootfs.0]
device=/dev/disk/by-partlabel/rootfs.A
type=raw                           # squashfs written as raw image
bootname=A

[slot.boot.1]
device=/dev/disk/by-partlabel/boot.B
type=vfat
parent=rootfs.1

[slot.rootfs.1]
device=/dev/disk/by-partlabel/rootfs.B
type=raw
bootname=B
```

Notes:
- `type=raw` for rootfs slots because we dd a finished squashfs; RAUC's adaptive-update block index works on raw block writes, which is exactly our case.
- `statusfile` on `/data` — the default (inside rootfs) is impossible on a read-only root.
- The bundle manifest carries `[image.rootfs]` + `[image.boot]` entries; RAUC installs the group transactionally and flips `BOOT_ORDER`/grubenv `ORDER` to prefer the new slot with fresh try counters.

## 3. AD-010 — Bundle format

> **AD-010 — Bundles use the `verity` format with adaptive updates enabled. `plain` is not accepted by devices; `crypt` is deferred.** *(Recommended)*

- **verity**: dm-verity hash tree over the payload; per-block authentication during install; prerequisite for HTTP(S) streaming installs (bundle served by any dumb HTTP server with Range support, streamed via NBD — no staging storage needed on-device). `bundle-formats=verity` in system.conf makes acceptance explicit.
- **Adaptive updates** (`--adaptive=block-hash-index` at bundle time): the installer compares block hashes against the target slot's current content and downloads only changed blocks. Near-free delta updates for minor releases (measured elsewhere at ~10 % of full-image transfer) with zero server-side delta infrastructure. casync chunking: not planned (adds a chunk-store service dependency for marginal gain over adaptive).
- **crypt** (encrypted bundles, per-device keys): deferred until a product needs confidential payloads; the PKI design (§6) does not block it.

## 4. AD-011 — Boot confirmation: the dinit integration we own

RAUC's documentation assumes systemd units. Astro owns this glue; it ships in `astro-base-update`.

> **AD-011 — The rauc daemon is dinit-supervised; a `rauc-mark-good` oneshot gated on the `boot-success` milestone confirms boots. Boot success is explicitly defined and app participation in it is opt-in.** *(Recommended)*

Service files (installed to `usr/lib/dinit.d/`):

```
# rauc
type = process
command = /usr/bin/rauc service
waits-for = dbus
restart = true

# boot-success            (definition of a good boot — see below)
type = internal
depends-on = astrod
depends-on = data.mount
# + generated depends-on lines for each opt-in app service

# rauc-mark-good
type = scripted
command = /usr/libexec/astro/mark-good   # rauc status mark-good; retries w/ backoff
depends-on = boot-success
```

- **Boot success =** dinit reached `boot-success`: `/data` mounted, astrod up and passing its own health check, and every *rollback-participating* app service started. Apps opt in via their external-tree service manifest ([08-external-trees.md §5](08-external-trees.md)); participation means **a crashing app can trigger rollback** — powerful, and explicitly a product decision, not a default.
- **Failure path:** if `rauc-mark-good` never runs, the bootloader's attempt counters (`BOOT_x_LEFT` / `TRY`) decrement on each boot; after 3 failed attempts the bootloader falls back to the previous slot. A kernel that never reaches dinit is caught by the same counters; a hang after dinit start is caught by a watchdog timeout on the `boot-success` milestone (dinit-monitored timer that forces reboot — value board-configurable, default 5 min).
- `rauc.service` D-Bus activation was considered and rejected: dinit supervision is simpler to reason about, and astrod talks to RAUC early in boot anyway.

## 5. Update workflows

### 5.1 API-driven (primary) — via astrod

```
app / operator                astrod                      rauc (D-Bus)
     │  POST /api/v1/update       │                            │
     │  {url: https://…/N.raucb}  │                            │
     │─────────────────────────►  │  policy checks (§6, AD-021)│
     │  202 {operation id}        │  InstallBundle(url)        │
     │◄─────────────────────────  │──────────────────────────► │
     │  GET /api/v1/events (SSE)  │  ◄── progress signals ──── │  (streams
     │◄══ update.progress ══════  │                            │   via NBD)
     │◄══ update.completed ═════  │  marks new slot primary    │
     │  POST /api/v1/update/apply │                            │
     │─────────────────────────►  │  reboot via sys-reboot     │
                    … device boots new slot; boot-success → mark-good;
                      astrod emits update.confirmed on next connect …
```

- Reboot is **never automatic** by default; `POST /update` accepts `"apply": "auto"` for products that want install-and-reboot in one call.
- `POST /update` also accepts a multipart upload for air-gapped/local pushes; astrod stages it under `/data/.astro/staging` (size-checked against free space) and hands RAUC a local path.
- `POST /update/rollback`: `rauc status mark-bad` + make the other slot primary + reboot — only valid while the previous slot still holds the prior release.

### 5.2 USB / offline

A dinit-triggered udev hook (opt-in per product, off by default) detects a vfat volume containing `astro-update.raucb`, and calls the same astrod endpoint locally — one code path, same signature checks, same policy. Progress on whatever HMI the product has (via SSE).

### 5.3 Fleet (deferred, designed-for)

`rauc-hawkbit-updater` packaged in the fork as an optional add-on (post-v1): bridges RAUC's D-Bus API to a hawkBit server's DDI API. It coexists with astrod untouched — both are D-Bus clients of RAUC; astrod remains the status surface. No Astro-hosted fleet server, ever ([00-overview.md §4](00-overview.md)).

## 6. Signing and PKI

| Item | Dev | Prod |
|---|---|---|
| CA | `keys/dev/rauc-ca.pem` — **committed to the repo**, generated by `astro keys init-dev`, CN literally `ASTRO DEV — DO NOT SHIP` | offline/HSM-held root CA, never in the repo or CI |
| Signing cert | dev cert signed by dev CA, in-repo | release signing certs (1-year), issued by prod root, held in CI secret store; PKCS#11 path supported by `rauc bundle` |
| Device keyring | dev CA (dev + CI images) | prod CA chain (release images) |
| Rotation | regenerate at will | new release-signing certs issued under the same root; root rotation via keyring containing old+new during a transition release |
| Resigning | — | `rauc resign` supported for promoting a tested bundle from testing to stable **without rebuilding** (channel = repo URL, not key — AD-019) |

Bundle `compatible` string: `astro-<board-family>` (e.g. `astro-rpi`, covering rpi4/rpi5 if and only if one image serves both). Prevents cross-flashing a gateway with a pi image at the RAUC layer regardless of operator error.

> **AD-021 — astrod enforces monotonic update versions.** *(Recommended)*
> RAUC itself doesn't refuse downgrades. astrod compares the bundle's version (from `rauc info` pre-install) against the running release and rejects lower versions unless the request carries `"force": true` (logged, and surfaced in `GET /update/status.history`). Rationale: downgrade attacks and accidental stale-artifact pushes are both real; the override keeps field recovery possible. Verification is signature-first: `rauc info` runs with the keyring, so even the version check only trusts signed metadata.

## 7. `/data` compatibility across updates

- `/data/.astro/schema-version` records the data-layout generation.
- **Migration runs in astrod at startup** (forward-only, idempotent, before the API binds): astrod knows its own config format and owns `/data/config`. Bundle-embedded RAUC hooks were rejected for this: they run in the *pre-reboot* context against a *not-yet-running* new system — the wrong side of the boundary to reason about.
- App state under `/data/apps/<name>` is each app's responsibility; the external-tree contract documents the same forward-only pattern and provides `ASTRO_PREV_VERSION` in the service environment on first boot after an update.
- Breaking `/data` changes across a release require a migration in astrod **and** a release-notes flag; the roadmap reserves "compatibility floor" bumps (oldest release you can update *from*) as an explicit release-notes item.

## 8. Deferred (designed-for, not in v1)

| Feature | Design hook already in place |
|---|---|
| Bootloader self-update | move ESP/bootloader into a RAUC slot with `boot-gpt-switch`/`boot-mbr-switch` atomic types; current layout keeps ESP single and small pending this |
| Encrypted (`crypt`) bundles | PKI supports adding recipient certs; format switch is a bundle-time flag + keyring addition |
| App-only updates | RAUC artifact repositories (`[artifacts.*]`) targeting `/data`-adjacent app slots — natural synergy with external trees; needs its own design pass |
| hawkBit fleet client | §5.3 |
