#!/usr/bin/env python3
"""Manual distfile fetcher for cbuild fetch failures (GAP §3.3).

Some distfile hosts (gitlab.alpinelinux.org) sit behind the Anubis anti-bot
proxy, which rejects cbuild's Python-urllib fetcher with HTTP 418 while
letting curl's default UA pass. This helper takes the JSON emitted by
'./cbuild dump <cat>/<pkg>' on stdin, downloads every missing/corrupt
distfile with 'curl -L' into cports/sources/<pkgname>-<pkgver>/ (the layout
cbuild expects), and verifies the sha256 from the template. One attempt per
distfile — the caller re-runs cbuild exactly once afterwards.

Usage: ./cbuild dump main/foo | fetch_distfiles.py <cports-dir>
Exit: 0 if every distfile is now present with a good checksum, 1 otherwise.
"""

import hashlib
import json
import subprocess
import sys
from pathlib import Path


def log(msg):
    print(f"[fetch-distfiles] {msg}", file=sys.stderr)


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def name_from_source(src):
    """Mirror cbuild's get_nameurl(): 'url>name' renames, else basename."""
    if src.startswith("!"):
        src = src[1:]
    bkt = src.rfind(">")
    bsl = src.rfind("/")
    if bkt > bsl:
        return src[:bkt], src[bkt + 1 :]
    return src, src[bsl + 1 :]


def main():
    if len(sys.argv) != 2:
        log("usage: cbuild dump ... | fetch_distfiles.py <cports-dir>")
        return 1
    cports = Path(sys.argv[1])

    try:
        dump = json.load(sys.stdin)
    except json.JSONDecodeError as e:
        log(f"cannot parse cbuild dump JSON: {e}")
        return 1
    if not dump:
        log("empty cbuild dump")
        return 1

    tmpl = dump[0]
    pkgname = tmpl["pkgname"]
    pkgver = tmpl["pkgver"]
    variables = tmpl.get("variables", {})
    sources = variables.get("source") or []
    sums = variables.get("sha256") or []
    if isinstance(sources, str):
        sources = [sources]
    if isinstance(sums, str):
        sums = [sums]
    if len(sources) != len(sums):
        log(f"{pkgname}: source/sha256 length mismatch ({len(sources)} vs {len(sums)})")
        return 1
    if not sources:
        log(f"{pkgname}: no sources to fetch")
        return 1

    srcdir = cports / "sources" / f"{pkgname}-{pkgver}"
    srcdir.mkdir(parents=True, exist_ok=True)

    ok = True
    for src, want in zip(sources, sums):
        url, fname = name_from_source(src)
        dest = srcdir / fname

        if dest.is_file():
            if sha256_of(dest) == want:
                log(f"already good: {fname}")
                continue
            log(f"bad checksum on existing {fname} — refetching")
            dest.unlink()

        log(f"curl -L {url} -> {dest}")
        r = subprocess.run(
            ["curl", "-fL", "--retry", "2", "-o", str(dest), url],
            stdout=sys.stderr,
            stderr=sys.stderr,
        )
        if r.returncode != 0:
            log(f"curl failed (rc={r.returncode}) for {url}")
            dest.unlink(missing_ok=True)
            ok = False
            continue

        got = sha256_of(dest)
        if got != want:
            log(f"checksum mismatch for {fname}: got {got}, want {want}")
            dest.unlink(missing_ok=True)
            ok = False
        else:
            log(f"fetched + verified: {fname}")

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
