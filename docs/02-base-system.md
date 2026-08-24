# 02 — Base System and Runtime Design

**Status:** Draft for review · **Owns decisions:** AD-004, AD-005 · **Read after:** [01-architecture.md](01-architecture.md)

---

## 1. Core components

The fixed core, inherited from Chimera Linux via cports (versions track the cports pin in `.harbormaster.lock`; those below are the current baseline):

| Component | Baseline | Notes |
|---|---|---|
| musl | 1.2.5+ | Chimera's build, patched to use the **mimalloc** allocator — better multithreaded allocation for every binary on the system |
| chimerautils | rolling | FreeBSD userland ported by Chimera: coreutils/findutils/grep/sed/awk/gzip equivalents plus `sh`, `vi`, `nc`, `fetch`. Real separate binaries, not a multicall busybox. Meson-built; requires libxo |
| dinit + dinit-chimera | rolling | init (PID 1), service supervision, Chimera's early-boot service set |
| apk-tools | 3.x | package format ADB, SHA512-signed repos; used at image build time (see AD-004) |
| LLVM runtimes | 20+ | libc++, libc++abi, libunwind, compiler-rt — no GNU runtime libs anywhere |
| turnstile | rolling | session/rundir tracking (Chimera's logind-adjacent piece); kept because dinit-chimera expects it |
| dbus | 1.x | system bus only; required by RAUC and iwd regardless |

Distro-wide build hardening comes free from cbuild: ThinLTO, PIE, stack canaries, `_FORTIFY_SOURCE`, and (per-package where enabled by Chimera) CFI/UBSan subsets. Crag does not weaken any of these defaults.

### What Crag deliberately does *not* include in the base

- No busybox (chimerautils is the userland).
- No GNU coreutils/bash (chimerautils `sh` is the shell; bash available in `dev` variant only if pulled explicitly).
- No systemd, elogind, polkit, udisks. Device management is `udevd` from Chimera's base (currently systemd-udevd built standalone; whatever cports ships as `device-mapper`/udev stays as-is).
- No Python/Perl on production images. Build-time only.

## 2. Base package sets

Crag defines tiered metapackages in `astro-cports` (see [03-build-system.md](03-build-system.md)); boards and variants compose them via `packages.list` layering as in the prototype:

| Metapackage | Contents | Included in |
|---|---|---|
| `crag-base-core` | musl, chimerautils, dinit, dinit-chimera, apk-tools (db only, see §3), turnstile, udev, kernel modules pkg | every image |
| `crag-base-net` | iwd, dhcpcd, dbus, mdns responder, ca-certificates, crag D-Bus policy files | every image |
| `crag-base-update` | rauc, rauc dinit services, bootloader env tools (`grub-editenv` or `libubootenv`'s `fw_setenv`), crag-rauc-conf (per-board system.conf) | every image |
| `crag-base-api` | cragd, cragctl, provisioning web assets (embedded in cragd binary — this pkg is cragd + policy files) | every image |
| `crag-base-dev` | openssh, doas, tmux, strace, htop, curl, apk-tools (full), debug symbols repos enabled | `dev` variant only |

**OpenSSH vs dropbear:** OpenSSH, from cports, dev variant only. Production images ship no SSH daemon by default; product teams can add it via their external tree if their threat model allows.

## 3. AD-004 — Read-only rootfs and apk semantics

> **AD-004 — The production root filesystem is a read-only squashfs whose package set is frozen at image build time. `apk add` at runtime is not supported on production images.** *(Recommended)*

**Design.**
- The `prod` variant produces a squashfs rootfs, mounted read-only. The apk database (`/lib/apk/db`, world file) is *inside* the image, describing exactly what was installed at build time. It exists for auditability (`apk query` works read-only) — not for mutation.
- The `dev` variant produces an ext4 read-write rootfs with full apk against the Crag repos — same partition layout, so RAUC updates still function. It is also the target for **developer sideloading** (`crag deploy` — AD-026, [08 §6](08-external-trees.md)): push a rebuilt app binary or package to a running device and restart its service in seconds. Dev images are loudly labeled (motd, os-release `VARIANT=dev`, cragd `GET /system` reports it) and must never ship on products.

**Rationale.**
1. **A/B atomicity is only meaningful if a slot's content is exactly the built artifact.** If devices mutate their rootfs, "rollback to slot A" no longer returns to a known state, and two devices on the same release are no longer the same system.
2. **Reproducibility and support**: a device is fully described by (release version, external tree version, `/data` contents).
3. **Security**: an immutable root removes the most common persistence surface.

**What apps do instead.**
- Ship software as apk packages baked into the image via external trees ([08-external-trees.md](08-external-trees.md)).
- Put runtime-mutable assets (models, media, config) in `/data`.
- Future app-only OTA: RAUC *artifact repositories* are the planned mechanism (deferred; [05-updates.md §8](05-updates.md)).

**Rejected alternative — Alpine-style overlayfs over `/` with runtime apk writing to `/data`:** after an A/B update the new rootfs would boot under a *stale* package overlay built against the old base — a split-brain rollback nightmare (which layer wins? which was tested?). Rejecting runtime mutation entirely is the simpler, more honest contract.

## 4. AD-005 — Mutable state: the `/data` partition

> **AD-005 — All mutable state lives in a single ext4 `/data` partition, shared across slots, grown to fill the disk on first boot. `/etc` is writable only through a thin overlay with a strict write policy. Factory reset = wipe `/data`.** *(Recommended)*

### 4.1 Layout

```
/data
├── config/            # cragd desired-state store (crag.json, api-token)
├── overlay/
│   ├── etc/           # overlayfs upperdir for /etc
│   └── .etc-work/     # overlayfs workdir
├── var/
│   └── log/           # persistent logs (dinit service logfiles)
├── apps/<name>/       # per-app state dirs (created by app packages' firstboot hooks)
├── keys/              # device-generated: ssh host keys (dev), machine-id seed
└── .crag/            # provisioning state, firstboot markers, data schema version
```

### 4.2 Mutable-path table

Every path a running system writes, and where it really lives:

| Path | Backing | Mechanism |
|---|---|---|
| `/etc` | `/data/overlay/etc` upper over RO lower | overlayfs, mounted by early dinit service |
| `/var/run`, `/run` | RAM | tmpfs |
| `/var/tmp`, `/tmp` | RAM | tmpfs (size-capped) |
| `/var/log` | `/data/var/log` | bind mount |
| `/var/cache` | RAM | tmpfs (nothing on prod needs persistent cache) |
| `/root`, `/home` | `/data` (dev variant only) | bind mount; prod has no interactive users |
| app state | `/data/apps/<name>` | convention, exported as `$CRAG_DATA_DIR` in service env |

### 4.3 The `/etc` write policy

`/etc` overlay exists because some upstream daemons insist on config in `/etc` (e.g. `resolv.conf` conventions, dropped-in trust anchors). Policy:

- **Only cragd and the firstboot service write to `/etc`.** Team apps must not; their configuration belongs in `/data/apps/<name>` or in cragd's config API.
- cragd treats `/etc` overlay content as *rendered output* of its desired-state store in `/data/config` — it can always be regenerated. This keeps factory reset trivially correct: wipe `/data`, and the next boot re-renders defaults.
- Enforcement is by convention plus permissions (upperdir owned root:root, app services run unprivileged — §7), not by MAC in v1.

### 4.4 Factory reset

Semantics: **wipe `/data`, reboot, firstboot runs again** ([07-networking-provisioning.md §5](07-networking-provisioning.md) owns the flow and triggers). Slots are untouched — the device keeps its current firmware version. Nothing outside `/data` can hold device-local state, which makes this guarantee checkable: CI boots an image, provisions it, factory-resets it, and asserts the system is byte-identical in behavior to first boot.

## 5. dinit service design

### 5.1 Boot service graph (prod variant)

```
(dinit-chimera early: devfs, sysfs, udevd, hostname, mounts…)
        │
        ▼
   data.mount          # /data fsck+mount, grow on firstboot
        │
   etc-overlay         # overlayfs for /etc, tmpfs for /var pieces
        │
   firstboot           # oneshot, only if /data/.crag/firstboot absent
        │
   dbus                # system bus
      ├────────────► iwd            (waits-for: dbus)
      ├────────────► dhcpcd
      ├────────────► rauc           (waits-for: dbus)
      └────────────► cragd         (depends-on: dbus; waits-for: iwd, dhcpcd, rauc)
                        │
                     mdns           (waits-for: cragd — advertises only when API is up)
                        │
                   [apps milestone]  # team services from external trees attach here
                        │
                 boot-success        # internal milestone; see below
                        │
                 rauc-mark-good      # oneshot: rauc status mark-good
```

- **`boot-success`** is an `internal`-type dinit service. Its dependencies define "this boot is good": base set = `cragd` started + `data.mount` + all *rollback-participating* app services (opt-in, [08-external-trees.md §5](08-external-trees.md)). `rauc-mark-good` depends on `boot-success`; if it never runs, the bootloader's attempts counter eventually falls back to the other slot ([05-updates.md §4](05-updates.md)).
- Services use dinit's native `depends-on` (hard) vs `waits-for` (soft) distinction exactly as upstream defines them; we do not invent orthogonal ordering machinery.

### 5.2 Conventions

| Concern | Convention |
|---|---|
| Service file location | packages install to `usr/lib/dinit.d/` (cbuild auto-splits into `-dinit` subpackages); enabled services are symlinked into the boot set by image hooks or `services.enable` in variant TOML |
| Naming | Crag system services: bare names (`cragd`, `rauc`); team apps: vendor-prefixed (`acme-sensord`) |
| Logging | `type = process` services set `logfile = /data/var/log/<name>.log`; log rotation via a small `crag-logrotate` timer service (size-based, embedded-friendly) |
| Restart policy | system daemons: `restart = true` with dinit's default backoff; team apps: `restart = true` recommended default in the external-tree template |
| Environment | app services get `CRAG_DATA_DIR`, `CRAG_API_SOCKET` (`/run/cragd.sock`) via dinit `env-file` generated at image assembly |

## 6. Kernel policy

- **LTS line, currently 6.12.x**, built with Clang/ThinLTO (as the prototype already does, including its clang-build patches).
- Per-board config = upstream `defconfig` + shared fragments + board fragments (existing mechanism: `config_fragments` in board.toml). Crag adds two required shared fragments:
  - **`rauc.fragment`** — `CONFIG_BLK_DEV_LOOP`, `CONFIG_SQUASHFS` (+zstd), `CONFIG_CRYPTO_SHA256`, `CONFIG_DM_VERITY` + `CONFIG_BLK_DEV_DM` + `CONFIG_MD`, `CONFIG_BLK_DEV_NBD` (HTTP streaming installs), `CONFIG_EFI_VARS`/efivarfs on x86_64.
  - **`crag-net.fragment`** — `CONFIG_CFG80211`, `CONFIG_MAC80211`, packet/netlink options iwd requires, `CONFIG_TUN` (future VPN), nftables basics.
- Squashfs-as-root boots **without initramfs** (AD-006): `root=PARTLABEL=rootfs.A rootflags=ro` with squashfs built in (`=y`, not `=m`) plus the storage driver for the board built in.
- Kernel and DTBs are packaged per board and installed into the per-slot boot partition at image time — they are not part of the rootfs squashfs ([04-boards-images-boot.md §2](04-boards-images-boot.md)).

## 7. Users and privileges

| Principal | UID/GID model | Privileges |
|---|---|---|
| `root` | 0 | owns early boot; no password on prod (login disabled), dev variant sets one via variant TOML `users` |
| `cragd` | dedicated system user | **not root.** Capabilities: none. All privileged operations go through D-Bus services (iwd, RAUC) authorized by D-Bus policy files granting the `cragd` user access to `net.connman.iwd` and `de.pengutronix.rauc`. dinit control (service restart endpoints) via dinit's control socket with group-based access. Direct file writes limited to `/data/config`, `/data/overlay/etc`, `/etc` overlay |
| `crag-api` group | — | membership = permission to use the cragd unix socket; team app service users join it in their package's install script |
| team app users | one system user per app (declared in external tree) | unprivileged; own `/data/apps/<name>`; no default group memberships beyond `crag-api` |

Reboot/poweroff, time setting, and hostname are the residual root-only operations cragd needs; these are handled by a minimal `cragd-helper` — a small setuid-less oneshot dispatched via dinit (cragd asks dinit to start `sys-reboot` etc.), keeping cragd itself fully unprivileged. This list is small and closed; anything new must be added to this table by PR.

We write and ship the D-Bus policy XML for iwd/RAUC access ourselves (upstreams assume root or polkit); they live in `crag-base-net`/`crag-base-update` packages. See [09-security.md §5](09-security.md).
