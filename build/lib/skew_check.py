#!/usr/bin/env python3
"""
Crag Linux — binary packages-mode version-skew guard (warn-only).

Binary packages-mode mixes Chimera-current binary packages with Crag's
Harbormaster-pinned cports checkout. This tool compares every *installed*
package against the pinned template version and reports:

  - SKEW:     installed (Chimera) version != pinned template version, for
              packages Crag does not build from source. Warn-only: dev
              images may legitimately run slightly ahead of the pin.
              Release/nightly builds are full-source and cannot skew.
  - SHADOWED: a package Crag builds from source (astro-cports, patched via
              build/patches/cports/, or source-packages.list) was installed
              at a different version than the local repo provides — i.e. a
              binary repo shadowed an Crag-built package. This is loud
              because it defeats the point of the source-build subset.

Inputs:
  --installed       apk installed DB (v2 text: P:/V:/o: records) from the
                    assembled rootfs (<rootfs>/lib/apk/db/installed)
  --cports          pinned cports checkout (templates = source of truth)
  --source-manifest file listing templates built from source (optional)
  --local-dump      `apk adbdump` text of the local repo Packages.adb (optional)
  --chimera-dump    `apk adbdump` text of Chimera's Packages.adb (optional,
                    used for provenance attribution in the report)
  --out             report file path

Exit code is always 0 (guard warns, never fails the build).
"""

import argparse
import datetime
import re
import sys
from pathlib import Path


def parse_installed(path):
    """Yield (name, version, origin) from an apk v2-style installed DB."""
    name = version = origin = None
    for line in Path(path).read_text().splitlines():
        if not line.strip():
            if name:
                yield name, version, origin
            name = version = origin = None
            continue
        if line.startswith("P:"):
            name = line[2:]
        elif line.startswith("V:"):
            version = line[2:]
        elif line.startswith("o:"):
            origin = line[2:]
    if name:
        yield name, version, origin


def parse_adbdump(path):
    """Return {name: version} from `apk adbdump Packages.adb` output."""
    pkgs = {}
    name = None
    for line in Path(path).read_text().splitlines():
        m = re.match(r"^  - name: (\S+)$", line)
        if m:
            name = m.group(1)
            continue
        m = re.match(r"^    version: (\S+)$", line)
        if m and name:
            pkgs[name] = m.group(1)
            name = None
    return pkgs


def template_version(cports, template):
    """pkgver-rpkgrel from a cports template, or None."""
    for collection in ("main", "user"):
        tmpl = Path(cports) / collection / template / "template.py"
        if not tmpl.is_file():
            continue
        text = tmpl.read_text()
        ver = re.search(r'^pkgver\s*=\s*["\']([^"\']+)["\']', text, re.M)
        rel = re.search(r"^pkgrel\s*=\s*(\d+)", text, re.M)
        if ver and rel:
            return f"{ver.group(1)}-r{rel.group(1)}"
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--installed", required=True)
    ap.add_argument("--cports", required=True)
    ap.add_argument("--source-manifest")
    ap.add_argument("--local-dump")
    ap.add_argument("--chimera-dump")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    source_set = set()
    if args.source_manifest and Path(args.source_manifest).is_file():
        for line in Path(args.source_manifest).read_text().splitlines():
            line = line.split("#")[0].strip()
            if line:
                # normalize collection/name to bare template name
                source_set.add(line.split("/")[-1])

    local_pkgs = parse_adbdump(args.local_dump) if args.local_dump else {}
    chimera_pkgs = parse_adbdump(args.chimera_dump) if args.chimera_dump else {}

    tmpl_cache = {}
    skew, shadowed, unknown = [], [], []
    total = from_local = from_chimera = 0

    for name, version, origin in parse_installed(args.installed):
        total += 1
        origin = origin or name

        # provenance attribution (equal versions in both repos count as
        # local: the local repo is listed first and wins the solver tie)
        if local_pkgs.get(name) == version:
            provenance = "local"
            from_local += 1
        elif chimera_pkgs.get(name) == version:
            provenance = "chimera"
            from_chimera += 1
        else:
            provenance = "unattributed"

        if origin not in tmpl_cache:
            tmpl_cache[origin] = template_version(args.cports, origin)
        tver = tmpl_cache[origin]

        if origin in source_set:
            lver = local_pkgs.get(name)
            if lver and version != lver:
                shadowed.append(
                    f"{name} (template {origin}): installed {version} "
                    f"[{provenance}], local Crag build is {lver}"
                )
            continue

        if tver is None:
            unknown.append(f"{name} (template {origin}): no pinned template found")
        elif version != tver:
            skew.append(
                f"{name} (template {origin}): installed {version} "
                f"[{provenance}], pinned template is {tver}"
            )

    lines = [
        "Crag binary packages-mode — version-skew report",
        f"generated: {datetime.datetime.now().isoformat(timespec='seconds')}",
        f"installed packages: {total} "
        f"(local repo: {from_local}, chimera repo: {from_chimera}, "
        f"unattributed: {total - from_local - from_chimera})",
        "",
    ]
    if shadowed:
        lines.append(f"SHADOWED source-built packages ({len(shadowed)}) — "
                     "a binary repo won over an Crag-built package:")
        lines += [f"  {s}" for s in shadowed]
        lines.append("")
    if skew:
        lines.append(f"SKEW vs pinned templates ({len(skew)}) — "
                     "warn-only; release builds are full-source:")
        lines += [f"  {s}" for s in skew]
        lines.append("")
    if unknown:
        lines.append(f"unmapped packages ({len(unknown)}):")
        lines += [f"  {s}" for s in unknown]
        lines.append("")
    if not (shadowed or skew):
        lines.append("no skew: every installed package matches its pinned template version")

    Path(args.out).write_text("\n".join(lines) + "\n")

    if shadowed:
        print(f"[WARN] {len(shadowed)} Crag source-built package(s) SHADOWED "
              f"by a binary repo — see {args.out}", file=sys.stderr)
    if skew:
        print(f"[WARN] version skew vs pinned templates for {len(skew)} "
              f"package(s) — see {args.out}", file=sys.stderr)
    if not (shadowed or skew):
        print("[INFO] no version skew against pinned templates")
    return 0


if __name__ == "__main__":
    sys.exit(main())
