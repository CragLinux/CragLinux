# 09 — Security Model

**Status:** Draft for review · **Owns decisions:** AD-018 · **Read after:** [05-updates.md](05-updates.md), [06-config-api.md](06-config-api.md)

---

## 1. Threat model (v1, concrete)

| Adversary | In scope v1? | Primary mitigations |
|---|---|---|
| Network MITM on update delivery | **yes** | signed verity bundles; signature verified before any block is trusted; HTTPS transport on top |
| Malicious/corrupt update artifact | **yes** | RAUC signature + compatible string + AD-021 monotonic versions; rollback on boot failure |
| Local unprivileged process (compromised app) | **yes** | RO rootfs; per-app users; cragd socket group gating; no arbitrary init control via API; `/etc` write policy |
| LAN attacker (device on same network) | **yes** | LAN API off by default (AD-025); token auth + optional TLS when on; no SSH on prod images |
| Attacker during provisioning window | **partially** | PSK-protected AP, minimal unauthenticated subset, time-boxed window — §6 |
| Physical attacker (storage removal, console) | **partially** | acknowledged gap: no verified boot, no encryption at rest in v1 — §2, §3 |
| Supply chain (upstream source tampering) | **partially** | pinned hashes in cports templates, SHA-pinned cports checkout (Harbormaster lock), reproducible-build checking; no independent source auditing claimed |

## 2. Trust chain — the v1 reality

```
build time:   sources (pinned hashes) → cbuild sandbox → apk packages (SHA512-signed)
image time:   signed packages → rootfs squashfs → GPT image     [no per-boot verification]
update time:  bundle signed (verity format) → device keyring CA → atomic slot write
boot time:    firmware → bootloader → kernel → rootfs           [***UNVERIFIED in v1***]
```

**Stated plainly: v1 verifies what arrives (packages, bundles) but does not attest what boots.** A physical attacker or a root-level compromise can modify a slot and it will boot. This is a deliberate v1 scope cut, not an oversight — and the design keeps every door open (§3).

## 3. AD-018 — Secure boot posture and roadmap

> **AD-018 — v1 ships signed-updates-only. Verified boot arrives in three explicit stages; every v1 layout/format decision is already compatible with them.** *(Recommended)*

| Stage | Adds | Mechanism | v1 decisions that keep the door open |
|---|---|---|---|
| **1 (v1)** | update + package signing | RAUC verity bundles, apk SHA512 | — |
| **2** | rootfs integrity at boot | dm-verity root hash on kernel cmdline; tiny static initramfs opens the verity device ([04 §5](04-boards-images-boot.md)) | squashfs slots written as raw images (hash tree appendable); `rauc.fragment` already carries DM_VERITY; initramfs design specified |
| **3** | full chain to hardware | x86_64: Secure Boot → signed UKI per slot (dual-ESP evolution of AD-008); aarch64: U-Boot FIT signature verification (+ vendor fuse/ROM chain where hardware allows) | boot.A/B partitions can become per-slot ESPs without repartitioning; kernel+cmdline packaged per-slot already |

Stage triggers are product-driven (a product with a regulatory or tamper requirement funds the stage), not calendar-driven.

## 4. PKI inventory and operations

| Key | Purpose | Dev | Prod | Rotation |
|---|---|---|---|---|
| apk repo signing key | package/repo signatures | `keys/dev/apk*` in-repo | CI secret store | new key published in repo metadata one release ahead |
| RAUC dev CA | dev/CI bundle trust | `keys/dev/rauc-ca*` in-repo, CN `CRAG DEV — DO NOT SHIP` | — | regenerate at will |
| RAUC prod root CA | device keyring anchor | — | offline/HSM, never in repo/CI | root rotation via dual-CA keyring transition release ([05 §6](05-updates.md)) |
| RAUC release signing certs | bundle signatures | — | CI secret store or PKCS#11, 1-year validity, issued by prod root | reissue annually; `rauc resign` for channel promotion |
| API bearer token | local/LAN API auth | generated per device at firstboot | same | `POST /system/api-token/rotate` (invalidates old, returns new once) |
| Device TLS cert (LAN opt-in) | API TLS | self-signed per device at enable-time | same (or product-provisioned) | regenerate on demand |
| SSH host keys | dev variant only | per device firstboot | n/a (no prod sshd) | on factory reset |
| Future: UKI/FIT signing keys | stage 3 | — | reserved in this table | — |

Operational rules: dev keys are *loudly* fake (naming, CN, a `keys/dev/README` that says so); release builds **fail** if a dev CA is in the keyring of a `prod` variant bundle (CI check); no private key material ever transits the repo except `keys/dev/`.

## 5. Runtime hardening

- **Compiler-level (inherited from cbuild, distro-wide):** ThinLTO, PIE, stack protectors, `_FORTIFY_SOURCE`, per-package CFI/UBSan subsets where Chimera enables them; musl+mimalloc's allocator hardening.
- **Immutable rootfs** (AD-004): no persistence surface on `/`; `/data` mounted `nosuid,nodev`; tmpfs mounts `noexec` where services don't need otherwise.
- **Privilege separation** ([02 §7](02-base-system.md)): cragd unprivileged; per-app users; the closed `cragd-helper` list for root operations (reboot/time/hostname) via dinit oneshots, not setuid binaries — there are **zero setuid binaries** on a prod image (doas is dev-only).
- **D-Bus policy files we author** (in `crag-base-net`/`crag-base-update`): grant `cragd` user access to `net.connman.iwd` and `de.pengutronix.rauc` interfaces explicitly; default-deny for everyone else; team apps have no system-bus access unless their tree ships a policy (discouraged; the HTTP API is the contract).
- **No MAC (SELinux/AppArmor) in v1** — recorded as a roadmap candidate; the per-app-user + RO-root model is the v1 containment story.

## 6. API exposure analysis

Surfaces and their exposure ([06 §6](06-config-api.md)): unix socket (group-gated), localhost (token), LAN (opt-in, token, optional TLS), AP provisioning subset (unauthenticated).

**The provisioning window** is the deliberate soft spot; its bounding:

- Reachable only on the AP interface, only in `provisioning` state, and the AP is WPA2-PSK with a per-device key by default (label-printed) — an *open* AP is a per-product opt-out that products must justify.
- The unauthenticated subset is minimal: scan, submit credentials, redacted system info. It cannot: read stored secrets, install updates, touch services, or reach `/data`.
- Worst case accepted: an attacker within radio range during the window, holding the label PSK, can provision the device onto a hostile SSID. Consequence bounded by update signing (they still can't flash it) and by physical-presence assumptions of installation. Products needing more use the wired path or installer-app flow with the label token.
- The window closes on `provisioned` and never reopens without factory reset or explicit API action.

## 7. Update security corner cases

- **Downgrade protection** — AD-021 ([05 §6](05-updates.md)): cragd-enforced monotonic versions, signed-metadata-only comparison, explicit forced-downgrade audit trail.
- **Cross-flash protection** — RAUC compatible string per board family; a bundle for the wrong hardware fails before any write.
- **Rollback-window abuse** — `rauc-mark-good` only after `boot-success`; an update that boots but degrades is revertable via `POST /update/rollback` while the old slot survives (i.e., until the *next* update); documented operational guidance: stage fleet rollouts so the previous release is always one reboot away.
- **Time attacks** — no-RTC devices trust NTP for cert validity ([07 §6](07-networking-provisioning.md)); the monotonic time floor prevents gross rollback of the clock across reboots; NTS is the roadmap hardening.
- **Signature stripping** — `bundle-formats=verity` in system.conf refuses legacy `plain` bundles outright; there is no unsigned or weaker path to negotiate down to.
