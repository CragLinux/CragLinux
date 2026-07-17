# Chimera Linux repository signing keys (pinned)

apk public keys trusted to verify packages and indexes from Chimera's
official binary repository (`https://repo.chimera-linux.org/current/main`),
consumed by **binary packages-mode dev builds only**
(see docs/03-build-system.md §1 "Binary consumption for dev builds").

- **Provenance:** copied verbatim from the Harbormaster-pinned cports
  checkout (`cports/etc/apk/keys/`, identical to
  `cports/main/chimera-repo-main/files/`), i.e. their trust chains back to
  the committed `.harbormaster.lock` pin — no TOFU at build time.
- **Trust scope:** dev/PR artifacts only. Release and nightly-canary builds
  are full-source and never consume these repos; a prod image must not be
  assembled against them.
- **Rotation:** if Chimera rotates keys, a cports pin bump brings the new
  keys into `cports/etc/apk/keys/`; re-copy them here in the same PR so the
  pin and the pinned keys move together.
