# DEVELOPMENT KEYS — NOT FOR PRODUCTION

Everything in this directory is part of the **development-only PKI**
(see docs/09-security.md §4). These keys are:

- **Loudly fake.** They exist so that dev builds, QEMU boots, and CI can
  exercise the full signing/verification path (RAUC bundles, apk repos)
  without touching real key material.
- **Generated**, not hand-crafted: run `crag keys init-dev` to (re)create
  them. Committed dev keys are a convenience for reproducible dev/CI builds;
  regenerating them at any time is safe.
- **Worthless as secrets.** Anyone with a checkout has them, by design.
  Nothing signed with these keys may ever be trusted by, or shipped to, a
  production device.

Production keys are a different world entirely: they live in the CI secret
store / PKCS#11, are used only by the release pipeline, and are never present
in this repository in any form. A CI check refuses any `prod`-variant
artifact whose keyring contains the dev CA (docs/10-release-ci.md §4).
