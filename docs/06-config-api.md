# 06 — astrod: The Device Configuration API

**Status:** Draft for review · **Owns decisions:** AD-012, AD-013, AD-014, AD-016, AD-025 · **Read after:** [02-base-system.md](02-base-system.md)

---

## 1. Role and philosophy

astrod is **the only supported way application code touches system configuration.** The promise to embedded teams: you never learn iwd, D-Bus, routing tables, or RAUC — you make local HTTP calls (the Onics Squid.link model: a local API between apps and the OS).

Principles:

1. **Desired state, reconciled.** Clients declare what they want (`PUT /network/wifi/connection {"ssid": …}`); astrod persists it to `/data/config` *first*, then drives the system toward it and keeps it there across reboots and daemon restarts. A device is restorable from `/data/config` alone.
2. **One policy brain.** astrod owns policy (WAN choice, provisioning mode, update gating). iwd, dhcpcd, RAUC, dinit are mechanisms.
3. **Control plane, not data plane.** astrod down ≠ network down. dinit restarts it; it re-reads `/data/config` and reconciles.

> **AD-016 — D-Bus is the internal spine. astrod is a D-Bus client and never shells out for state-changing operations.** *(Recommended)*
> RAUC and iwd already require D-Bus; using it uniformly gives astrod evented state (PropertiesChanged, RAUC progress signals) instead of polling CLI output. dinit is the one non-D-Bus mechanism: astrod uses dinit's own control socket protocol (as `dinitctl` does). Team apps get HTTP only; D-Bus is not part of the app contract.

## 2. Architecture

```
            ┌───────────────────────────────────────────────────────┐
            │                       astrod                          │
            │                                                       │
 unix sock  │  ┌─────────┐   ┌──────────┐   ┌───────────────────┐   │ D-Bus
 /run/      │  │ HTTP    │   │ core:    │   │ backends:         │   │
 astrod.sock├──┤ listener├──►│ validate │──►│  wifi   → iwd     ├───┼──► net.connman.iwd
 127.0.0.1  │  │ + auth  │   │ persist  │   │  eth    → dhcpcd  │   │──► de.pengutronix.rauc
 (opt LAN)  │  │ + SSE   │   │ reconcile│   │  update → rauc    │   │──► dinit ctl socket
            │  └─────────┘   │ state    │   │  system → helper  │   │──► files: /etc overlay,
            │       ▲        │ machine  │   │  svc    → dinit   │   │    dhcpcd conf, tz, …
            │       │        └────┬─────┘   └───────────────────┘   │
            │  ┌────┴─────┐       ▼                                 │
            │  │ embedded │  /data/config/astro.json (atomic writes)│
            │  │ prov. UI │  /data/config/api-token                 │
            │  └──────────┘                                         │
            └───────────────────────────────────────────────────────┘
```

- **Config store**: one versioned JSON document `/data/config/astro.json` (schema-versioned per [05-updates.md §7](05-updates.md)); writes are atomic (`write tmp + fsync + rename`). TOML was considered; JSON wins because the API is JSON and round-tripping is lossless.
- **Reconciler**: a single-threaded state machine per subsystem (wifi, ethernet, update, system) consuming (desired state, observed D-Bus events) and issuing backend calls with retry/backoff. No shared mutable state between subsystems except through the store.
- **Event bus**: every observed transition becomes an event: persisted ring buffer (memory) + fan-out to SSE clients.
- **Embedded provisioning UI**: a single static HTML/JS page compiled into the binary (`@embedFile`), served only in provisioning mode ([07-networking-provisioning.md §4](07-networking-provisioning.md)).

## 3. AD-012 — Implementation language: Zig

> **AD-012 — astrod (and astroctl) are written in Zig.** *(Accepted)*

Fit: Zig rides the same LLVM backend as the rest of the distro, cross-compiles to `{x86_64,aarch64}-linux-musl` out of the box (it bundles musl), and produces small static binaries with no runtime/GC — an appliance daemon profile.

Design consequences (the two honest gaps, and their mitigations):

1. **No native Zig D-Bus library exists.** astrod links a C D-Bus implementation via Zig's first-class C interop:
   - **Primary: `basu`** — the systemd-free sd-bus extraction; small, musl-friendly, the sd-bus API is well-shaped for clients (async calls, signal matches, property tracking). Packaged in astro-cports; astrod wraps it in one Zig module (`src/bus.zig`) so the dependency is swappable.
   - **Fallback: `libdbus-1`** — already on the image for the daemons; clunkier API, kept as the documented plan-B if basu misbehaves under musl.
   - The wrapper is the *only* place C bus types appear; reconcilers see typed Zig interfaces. An integration-test suite runs against real iwd/RAUC in the QEMU `test api` stage.
2. **Zig is pre-1.0; the language and std churn.** The build container pins the exact Zig version (single source of truth: `build/zig-version`); astrod vendors its few dependencies (no network package manager use at build time — fits cbuild's offline build phase); version bumps are deliberate PRs that run the full test suite.

Stack: `std.http.Server` for HTTP/1.1 (behind our own thin router), `std.json` with typed schemas, `std.crypto` for token comparison (constant-time). Budgets, checked in CI: **binary ≤ 8 MiB static, RSS ≤ 16 MiB steady-state, cold start ≤ 150 ms** on the QEMU boards.

`astroctl` (CLI) is a thin client over the same API (unix socket by default), shipped in `astro-base-api`; it exists so operators and hooks never need `curl` incantations.

## 4. AD-013 — API conventions

> **AD-013 — REST over JSON; `/api/v1` URL versioning; OpenAPI 3.1 is the source of truth; async work is modeled as operations + an SSE event stream; errors are RFC 7807.** *(Recommended)*

| Convention | Rule |
|---|---|
| Versioning | `/api/v1/...`; v1 is frozen once shipped — additive changes only (new endpoints/fields); breaking → `/api/v2` served alongside |
| Spec | `astrod/api/openapi.yaml` is authoritative; served at `GET /api/v1/openapi.json`; CI fails if handlers and spec diverge (spec-driven route table) |
| Verbs | GET (read), PUT (full idempotent replace of a config object), PATCH (partial, JSON Merge Patch), POST (actions/creation), DELETE |
| Errors | RFC 7807 `application/problem+json`: `type` (stable URN per error class), `title`, `status`, `detail`, `instance` |
| Long-running ops | `POST` returns `202` + `{"operation": "/api/v1/operations/<id>"}`; operations expose `state: pending|running|succeeded|failed`, `progress`, `error`; discoverable via `GET /operations` |
| Events | `GET /api/v1/events` — SSE; typed events (`network.wifi.state`, `update.progress`, `system.provisioned`, …) each carrying the operation id when applicable; `Last-Event-ID` replay from the ring buffer |
| Concurrency | config objects carry `ETag`; `PUT`/`PATCH` honor `If-Match`, `409`/`412` on conflict; reconciler generation numbers exposed as `observedGeneration` so clients can await convergence |
| Compat contract | fields are never repurposed; unknown request fields are rejected (400) to surface client typos early |

## 5. Endpoint catalog (v1)

Assumed-in scope: networking (WiFi + Ethernet), updates, system basics. Cellular namespace reserved, returns 501 with a problem type documenting the roadmap.

### 5.1 `system`

| Endpoint | Semantics |
|---|---|
| `GET /system` | model/board, serial, astro release + variant, booted slot, uptime, health summary, provisioning state |
| `GET,PUT /system/hostname` | hostname (rendered to `/etc` overlay + kernel) |
| `GET,PUT /system/time` | current time; PUT allowed only when NTP disabled |
| `GET,PUT /system/time/config` | NTP enabled/servers, timezone (IANA name) |
| `POST /system/reboot`, `POST /system/poweroff` | via `sys-reboot`/`sys-poweroff` dinit oneshots; optional `delay` |
| `POST /system/factory-reset` | requires `{"confirm": "<serial>"}`; wipes `/data` and reboots ([07 §5](07-networking-provisioning.md)) |
| `GET /system/logs?service=&lines=&follow=` | tails `/data/var/log/*`; `follow` upgrades to SSE |

### 5.2 `network`

| Endpoint | Semantics |
|---|---|
| `GET /network` | all interfaces: type, MAC, carrier/rssi, addresses, WAN role |
| `GET,PUT,PATCH /network/ethernet/{iface}` | `{"ipv4": {"mode": "dhcp"} \| {"mode": "static", "address", "prefix", "gateway"}, "ipv6": {...}, "dns": [...]}` |
| `GET /network/wifi` | radio state, current connection (ssid, rssi, freq), station/ap mode |
| `POST /network/wifi/scan` → operation | triggers iwd scan; results at `GET /network/wifi/networks` (ssid, signal, security) |
| `GET,PUT,DELETE /network/wifi/connection` | the (single, v1) configured station profile: `{"ssid", "psk"}`; WPA2/WPA3-PSK v1, EAP fields reserved; PUT connects and persists; DELETE forgets |
| `GET,PUT /network/wifi/ap` | AP/provisioning mode control (ssid/psk/enabled); normally driven by the provisioning state machine, exposed for products that want on-demand AP |
| `GET,PUT /network/wan` | WAN policy: ordered interface preference (`["ethernet:eth0", "wifi"]`), failover on carrier/connectivity loss; astrod manages default-route metric accordingly |
| `GET,PUT /network/cellular` | **501** reserved |

### 5.3 `update`

| Endpoint | Semantics |
|---|---|
| `GET /update/status` | slots (bootname, version, state, boot attempts), booted slot, mark-good state, last install result, history |
| `POST /update` → operation | `{"url": …}` (streamed install) or multipart bundle upload; policy checks (AD-021) then RAUC `InstallBundle`; progress via events |
| `POST /update/apply` | reboot into the newly primary slot (no-op error if none pending) |
| `POST /update/rollback` | mark-bad + other-slot-primary + reboot ([05 §5](05-updates.md)) |

### 5.4 `services` (deliberately narrow)

| Endpoint | Semantics |
|---|---|
| `GET /services` | app-controllable services only: name, state, pid, restart count |
| `POST /services/{name}/restart`, `/stop`, `/start` | allowed **only** for services flagged `api_controllable = true` in their external-tree manifest ([08 §5](08-external-trees.md)). No arbitrary dinitctl passthrough — the API must not become a privilege-escalation bridge to init |

## 6. AD-014 / AD-025 — Authentication and exposure

> **AD-014 — Default surfaces: a unix socket gated by group membership, and 127.0.0.1 gated by a bearer token. LAN exposure is opt-in with mandatory token (+ optional TLS). In AP provisioning mode only, an unauthenticated *subset* is served.** *(Recommended)*
> **AD-025 — LAN exposure defaults to off on provisioned devices.** *(Accepted)*

| Surface | Default | Auth |
|---|---|---|
| `/run/astrod.sock` | on | filesystem: group `astro-api` (app service users join it — [02 §7](02-base-system.md)); no token needed |
| `127.0.0.1:80` | on | `Authorization: Bearer <token>`; token generated at firstboot into `/data/config/api-token` (0640 root:astro-api) |
| LAN (`0.0.0.0`) | **off** (AD-025) | enable via `PATCH /system` config or image `[api] lan_exposure`; token mandatory; optional TLS with device-generated self-signed cert (`GET /system` exposes fingerprint) |
| AP provisioning mode | while unprovisioned only | **unauthenticated subset**: wifi scan/networks, `PUT wifi/connection`, `GET /system` (redacted), provisioning UI page. Everything else 403. Window analysis in [09-security.md §6](09-security.md) |

Rejected alternatives: fully-open localhost (any local process could silently reconfigure the device — the unix-socket group is barely more work and much better); mTLS everywhere (real per-device PKI cost, no v1 consumer; can layer later for LAN surface).

## 7. Failure and concurrency semantics

- **Write path**: validate → persist desired state → `202`/`200` → reconcile. A valid-but-unsatisfiable config (SSID out of range) is *not* an API error: state shows `degraded` with cause, events narrate; this is deliberate — desired state may precede reality (pre-provisioning a site's SSID).
- **Dangerous transitions** get connectivity-guard behavior: changing the config of the interface currently serving the API applies with a 60 s revert timer unless the client confirms (`POST /network/commit`) — the classic "locked myself out via the API I reconfigured" guard. Applies to LAN surface only; socket/localhost callers are immune by construction.
- **astrod crash**: dinit restarts (`restart = true`); on start: load config → migrate if needed → observe world (D-Bus GetAll) → reconcile diffs. In-flight RAUC installs are re-attached via RAUC's Operation/Progress properties, and in-flight operations are recovered from the store, so an operation id remains pollable across a daemon restart.
- **Backpressure**: SSE clients capped (default 16); slow clients dropped with `event: overflow` marker; ring buffer 1024 events.

## 8. Client story

- **OpenAPI-generated clients** for Go, Python, and C (product teams' likeliest stacks), published per release with the SDK; the spec is the contract, generation is CI-verified.
- **`astroctl`**: `astroctl wifi scan`, `astroctl update install <url>`, `astroctl system factory-reset` — same API, ships on every image (tiny, and it makes hooks/USB-update/debug flows uniform).
- **curl cookbook** appendix in the SDK docs: every endpoint with a copy-paste example against the unix socket (`curl --unix-socket /run/astrod.sock http://localhost/api/v1/system`).
