# external-tree-acme — the docs/08 reference tree

A **complete, buildable** external product tree, kept green in CI
(`astro-ci.sh` step `external-tree`). Every section of
[docs/08](../../docs/08-external-trees.md) points at a file here; if a
contract question isn't answered there, the answer is demonstrated
here.

```
./build/astro-build.sh qemu-x86_64 acme-prod \
    --external=examples/external-tree-acme
./build/test-boot-smoke.sh qemu-x86_64 acme-prod
```

## Map (docs/08 § → file)

| § | Contract | Demonstrated by |
|---|---|---|
| §2 | tree identity, priority, version gate | [`tree.toml`](tree.toml) |
| §2 | tree-wide package additions | [`packages.list`](packages.list) |
| §3 | AD-017: apps are apk packages | [`cports/main/acme-sensord/template.py`](cports/main/acme-sensord/template.py) — local-source C daemon, custom build/install phases, explicit `-dinit` subpackage |
| §3 | config may ship as a package… | [`cports/main/acme-branding/`](cports/main/acme-branding/template.py) |
| §3 | …or as overlay; code may NOT | [`overlay/etc/acme/defaults.toml`](overlay/etc/acme/defaults.toml) (an ELF or `usr/bin` file here would die in the fence) |
| §4 | hook interleave across layers | [`hooks/60-acme-branding.sh`](hooks/60-acme-branding.sh) |
| §4 | tree PROVIDES a variant | [`variants/acme-prod.toml`](variants/acme-prod.toml) |
| §5 | service manifest → platform wiring | [`…/files/acme-sensord.toml`](cports/main/acme-sensord/files/acme-sensord.toml) |
| §5 | env-file, run-as, deps | [`…/files/acme-sensord`](cports/main/acme-sensord/files/acme-sensord) (dinit service) |
| §5, §7 | the api_client pattern | [`…/files/acme-sensord.c`](cports/main/acme-sensord/files/acme-sensord.c) — `GET /network` + `GET /update/status` over `$ASTRO_API_SOCKET` at startup |

## What lands on the image

- `acme-sensord` apk in the image world (`apk query` sees it, versions
  and all), its service enabled, running as the generated `acme` system
  user with `/data/apps/acme-sensord` writable and the astrod socket
  reachable (astro-api group).
- `POST /api/v1/services/acme-sensord/restart` works
  (`api_controllable = true`); the service does **not** gate rollback
  (`boot_success = false`).
- `acme-branding` config in `/etc/acme` + `/usr/share/acme`, the tree
  overlay's `/etc/acme/defaults.toml`, and a branded `/etc/motd` from
  the tree hook.

## Author traps this tree encodes (learn from them)

- `template.py` must be black-formatted at line length 80 — cbuild
  refuses to build otherwise.
- dinit service files: all `key = value` lines before any `key: value`
  dependency lines (cports style lint).
- `depends-on:` targets are provider-checked at package time; Astro's
  `astrod`/`data-mount` are overlay services no apk provides, so the
  `-dinit` subpackage sets `!scanrundeps`.
- A tree-provided prod-shaped variant must set `[rootfs].type =
  "squashfs"` explicitly — the stem-based default only special-cases a
  variant literally named `prod`.
- The manifest's `[service].name` must equal its file stem.
