# 07 — Network Stack, First Boot, and Provisioning

**Status:** Draft for review · **Owns decisions:** AD-015 · **Read after:** [06-config-api.md](06-config-api.md)

---

## 1. AD-015 — Network stack: iwd + dhcpcd

> **AD-015 — WiFi is managed by iwd, addressing by dhcpcd; cragd is the single policy brain on top. ConnMan and NetworkManager are rejected.** *(Accepted)*

| | **iwd + dhcpcd (chosen)** | ConnMan (+iwd backend) | NetworkManager |
|---|---|---|---|
| Footprint / deps | minimal; iwd leans on modern kernel crypto, dhcpcd is tiny | small daemon, GLib | heaviest: GLib + many libs, high RSS |
| D-Bus API | iwd: clean, small, station+AP+scan; dhcpcd: none needed (config-file + hook driven) | unified but coarser | richest |
| musl fit | proven (Alpine/postmarketOS ship both) | okay | historically painful |
| Policy location | **cragd** — nothing else has opinions | ConnMan has its own WAN/failover brain → fights cragd | NM has the biggest brain of all → fights cragd |
| AP mode + DHCP for provisioning | iwd has native AP mode **and** a built-in DHCP server for it | via backend | yes |
| Cellular later | add ModemManager beside iwd; cragd orchestrates | ofono coupling | native |

The decisive argument is the **policy row**: Crag already has exactly one place where "which network wins, when do we fall back, when are we in AP mode" lives — cragd ([06 §1](06-config-api.md)). ConnMan/NM would be a second policy engine to configure into passivity. iwd and dhcpcd are pure mechanisms.

**Implementation notes:**
- iwd runs with its network-configuration feature **disabled** (`EnableNetworkConfiguration=false`) — addressing is dhcpcd's job in station mode; in AP mode iwd's built-in DHCP server *is* used (single-purpose, provisioning subnet only).
- dhcpcd runs as a single daemon on allowed interfaces (allowlist rendered by cragd), handles IPv4 DHCP + IPv6 RA/DHCPv6 and static assignments (`static ip_address=` per-interface blocks).
- Verified against current cports before implementation: iwd and dhcpcd package state upstream (both are established in the musl world; if a template is missing in cports it is added to the fork).

## 2. Configuration rendering model

cragd's desired state is authoritative in `/data/config/crag.json`; daemon-native files are *rendered output*:

| Consumer | Rendered artifact | Location |
|---|---|---|
| iwd | known-network PSK files (`<ssid>.psk`) | `/data/net/iwd/` (iwd `StateDirectory` pointed here via its main.conf in the `/etc` overlay) |
| dhcpcd | `dhcpcd.conf` (interface allowlist, static blocks, DNS options) | `/etc` overlay, regenerated atomically + `dhcpcd` reload |
| DNS | `/etc/resolv.conf` | **owned by cragd** (symlink into `/run/crag/resolv.conf`); dhcpcd's own resolv.conf hook is disabled; DHCP-learned DNS flows dhcpcd hook → cragd → rendered file. One writer, no resolvconf-style arbitration |
| WAN policy | default-route metrics per interface | cragd adjusts via rtnetlink (small netlink module in Zig — route metric set is the one operation with no daemon to delegate to) |

Everything under `/data/net/` and the rendered `/etc` files can be regenerated from `crag.json` at any time — factory-reset correctness ([02 §4.4](02-base-system.md)) and "restore from config backup" both fall out of this.

## 3. First boot

`firstboot` dinit oneshot (runs when `/data/.crag/firstboot-done` is absent, after `data.mount`, before `dbus`):

1. **Grow `/data`**: extend partition 7 to the end of the disk (`sfdisk --no-reread -N7` + `resize2fs`) — images ship with minimal data size ([04 §6](04-boards-images-boot.md)).
2. Generate: machine id (`/data/keys/machine-id`, bind-target for `/etc/machine-id`), **API bearer token** (`/data/config/api-token`), SSH host keys (dev variant only), initial `crag.json` from image defaults (`[api]` flags baked at build — [03 §6](03-build-system.md)).
3. Stamp `/data/.crag/{firstboot-done, schema-version}`.
4. Exit; boot proceeds. cragd starts and finds `provisioned=false` unless the image pre-baked a network config.

Total added boot time budget: < 3 s excluding resize2fs on large disks (runs with `nodiscard` defaults; acceptable one-time cost).

## 4. Provisioning state machine

Persisted in `crag.json` (`system.provisioning`): `factory → provisioning → provisioned`.

```
            ┌──────────────────────────────────────────────────────┐
            ▼                                                      │
        factory ──(cragd starts, no usable network config)──► provisioning
            │                                                      │
            │ (image pre-baked config / ethernet DHCP succeeds     │
            │  and product policy says wired-is-provisioned)       │
            ▼                                                      ▼
        provisioned ◄──(valid config applied + connectivity verified)
            │
            └──(factory reset)──► factory
```

**Wired path (always on):** if an Ethernet link comes up and DHCP succeeds while unprovisioned, the API is reachable on that LAN **for provisioning purposes** (token still required — the token is printed on the device label / retrievable over serial; products choose their bootstrap-secret story). mDNS advertises `_crag._tcp` (TXT: serial, version, provisioning state) so installer tools can discover devices; the responder is built into cragd (announce-only), active per `[api] mdns` flag.

**Wireless path — AP-mode captive portal (v1, per project owner):**
1. In `provisioning` with no Ethernet carrier (configurable trigger), cragd enables iwd AP mode: SSID `crag-<serial-suffix>`, WPA2 PSK derived per-device (printed on label; open-AP is a per-product opt-out, discouraged), iwd's built-in DHCP serving `192.168.223.0/24`.
2. cragd serves, on that interface only: the **unauthenticated provisioning subset** ([06 §6](06-config-api.md)) and the embedded provisioning page.
3. **Captive-portal detection**: cragd answers all DNS on the AP subnet with itself (tiny built-in DNS responder, AP mode only) and returns the OS-probe redirects (`/generate_204`, `/hotspot-detect.html` → 302 to the portal) so phones auto-open the page. Prior art: balena wifi-connect (same HTTP → D-Bus → wifi-daemon pattern).
4. User (or installer app speaking the same API) scans, picks SSID, submits credentials → cragd persists, **flips iwd AP → station**, attempts the connection.
5. **Connectivity verified** (association + address + gateway reachable) → state `provisioned`, AP never returns (unless factory reset or explicit `PUT /network/wifi/ap`). On failure → AP comes back with the error surfaced in the portal (the classic wrong-password loop must be survivable without serial access).

Edge cases owned by the design (risk register [11 §4](11-roadmap-migration.md)): single-radio AP↔station flip means the portal *will* drop during the connection attempt — the page sets expectations and the phone re-joins the AP if it reappears; scan-while-AP is limited on some chipsets — cragd caches the pre-AP scan results.

## 5. Factory reset

| Trigger | Path |
|---|---|
| API | `POST /system/factory-reset` (confirm-with-serial — [06 §5.1](06-config-api.md)) |
| Physical | board hook: GPIO/button held N s at boot → boot script touches `/data/.crag/factory-reset-request` (boards define this in their external tree/board dir; qemu boards expose a QMP-triggerable equivalent for tests) |
| Boot flag | presence of `/data/.crag/factory-reset-request` at `data.mount` time |

Semantics: the reset executor (early dinit oneshot, before anything reads `/data`) wipes `/data` — fast path `rm -rf` of contents; secure path `blkdiscard` + re-mkfs (per-product flag) — then reboots. After reset: firstboot reruns, state `factory`. **Slots are untouched: the device keeps its current firmware version.** Nothing outside `/data` may hold device-local state, so this is a complete reset by construction.

## 6. Time, TLS, and the no-RTC chicken-and-egg

Battery-less boards boot in 1970; TLS (update downloads, NTS) then fails certificate validity checks before NTP has run.

Mitigations, all v1:
1. **Build-time floor**: firstboot sets the clock to the image's build timestamp if current time is earlier (monotonic floor persisted in `/data/.crag/last-known-time`, updated on clean shutdown and hourly).
2. NTP client (chrony from cports, or busybox-free equivalent already in Chimera's base — final pick recorded in the fork) with `makestep`-style initial correction, started after first connectivity, before cragd reports `time.synced=true`.
3. cragd gates *its own* TLS-dependent operations (`POST /update` with https URL) on `time.synced || time > floor`, and surfaces `time` state in `GET /system` so product apps can gate theirs.
4. NTS/HTTPS time hardening deferred to the security roadmap ([09 §7](09-security.md)).
