#!/usr/bin/env python3
"""Astro cports update-currency report.

Sweeps the fork's port tree with `cbuild update-check` (upstream's own
version-check machinery, driven by each template's update.py) and emits a
JSON + Markdown report of packages that have newer upstream releases. The
report is shaped for an agent (or a human) to pick up and work through:
each entry carries the package, current/latest versions, the template
path, whether the package is Astro-maintained (part of the fork delta vs
the fork point) and whether Astro installs it in any image (so security
currency on shipped packages can be prioritized over the rest of the tree).

Runs inside the astro-builder container (cbuild + network live there);
build/astro-update-report.sh is the host entry point.

Usage (in-container, cwd = repo root):
    python3 build/lib/update_report.py [--out-dir DIR] [--jobs N] [--scope SCOPE]

  --scope astro   only the Astro-maintained templates (fork delta) — fast
          shipped only packages installed in some image (base + boards)
          all     the whole tree (slow; the nightly full sweep)
"""

import argparse
import concurrent.futures
import json
import os
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CPORTS = REPO / "cports"
FORK_POINT = "e3c9e1a0"  # keep in lockstep with .harbormaster.lock

# "main/foo: 1.2.3 -> 1.3.0"  (cbuild update-check output)
_LINE = re.compile(r"^(?P<repo>[\w-]+)/(?P<pkg>[\w.+-]+):\s+"
                   r"(?P<cur>\S+)\s+->\s+(?P<new>\S+)\s*$")


def astro_maintained() -> set[str]:
    """Templates that differ from the fork point — the Astro delta we own."""
    out = subprocess.run(
        ["git", "-C", str(CPORTS), "diff", "--name-only",
         f"{FORK_POINT}..HEAD"],
        capture_output=True, text=True, check=True).stdout
    pkgs = set()
    for line in out.splitlines():
        m = re.match(r"(?:main|user)/([\w.+-]+)/template\.py$", line)
        if m:
            pkgs.add(m.group(1))
    return pkgs


def shipped_packages() -> set[str]:
    """Package names Astro installs in any image (base + every board/variant).

    Best-effort: the fixed base list plus every board packages.list and
    variant [packages].install. Subpackage->origin resolution is left to
    the reader (we match on the reported origin name too), so a shipped
    subpackage still flags its origin template via substring fallback.
    """
    names: set[str] = set()
    base = REPO / "boards/common/packages.list"
    lists = [base]
    lists += (REPO / "boards").glob("*/packages.list")
    for lst in lists:
        if not lst.is_file():
            continue
        for raw in lst.read_text().splitlines():
            tok = raw.split("#", 1)[0].strip()
            if tok:
                names.add(tok)
    # variant TOML [packages].install
    for toml in (REPO / "boards").glob("*/variants/*.toml"):
        txt = toml.read_text()
        m = re.search(r"\[packages\].*?install\s*=\s*\[(.*?)\]", txt, re.S)
        if m:
            for q in re.findall(r'"([\w.+-]+)"', m.group(1)):
                names.add(q)
    return names


def list_templates(scope: str, maintained: set[str]) -> list[str]:
    if scope == "astro":
        return sorted(f"main/{p}" if (CPORTS / "main" / p).is_dir()
                      else f"user/{p}" for p in maintained)
    tmpls = []
    for coll in ("main", "user"):
        d = CPORTS / coll
        if not d.is_dir():
            continue
        for t in d.iterdir():
            if (t / "template.py").is_file():  # real template, not a symlink
                tmpls.append(f"{coll}/{t.name}")
    return sorted(tmpls)


def check_one(tmpl: str) -> dict | None:
    """Run cbuild update-check for one template; return an entry or None."""
    try:
        r = subprocess.run(["./cbuild", "update-check", tmpl],
                           cwd=str(CPORTS), capture_output=True, text=True,
                           timeout=120)
    except subprocess.TimeoutExpired:
        return {"template": tmpl, "error": "timeout"}
    for line in r.stdout.splitlines():
        m = _LINE.match(line.strip())
        if m:
            return {"repo": m["repo"], "pkg": m["pkg"],
                    "current": m["cur"], "latest": m["new"],
                    "template": tmpl}
    if r.returncode != 0 and r.stderr.strip():
        return {"template": tmpl, "error": r.stderr.strip().splitlines()[-1]}
    return None  # up to date


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", default=str(REPO / "build/state/update-report"))
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    ap.add_argument("--scope", choices=("astro", "shipped", "all"),
                    default="astro")
    args = ap.parse_args()

    maintained = astro_maintained()
    shipped = shipped_packages()
    tmpls = list_templates("all" if args.scope == "shipped" else args.scope,
                           maintained)
    if args.scope == "shipped":
        tmpls = [t for t in tmpls if t.split("/", 1)[1] in shipped]

    print(f"[update-report] scope={args.scope} "
          f"templates={len(tmpls)} jobs={args.jobs}", file=sys.stderr)

    updates, errors = [], []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        for res in ex.map(check_one, tmpls):
            if not res:
                continue
            if "error" in res:
                errors.append(res)
            else:
                res["maintained"] = res["pkg"] in maintained
                res["shipped"] = res["pkg"] in shipped
                updates.append(res)

    # priority: shipped+maintained first, then shipped, then maintained, rest
    def rank(u):
        return (not u["shipped"], not u["maintained"], u["pkg"])
    updates.sort(key=rank)

    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    report = {"fork_point": FORK_POINT, "scope": args.scope,
              "checked": len(tmpls), "updates": updates, "errors": errors}
    (out / "report.json").write_text(json.dumps(report, indent=2))

    md = [f"# cports update report ({args.scope})", "",
          f"Fork point `{FORK_POINT}` · checked {len(tmpls)} templates · "
          f"**{len(updates)} update(s)**, {len(errors)} check error(s).", "",
          "Priority: shipped+maintained first (security currency on what we"
          " ship and own), then shipped, then maintained, then the rest.", "",
          "| Package | Current | Latest | Shipped | Astro-owned | Template |",
          "|---|---|---|---|---|---|"]
    for u in updates:
        md.append(f"| {u['pkg']} | {u['current']} | {u['latest']} | "
                  f"{'yes' if u['shipped'] else ''} | "
                  f"{'yes' if u['maintained'] else ''} | `{u['template']}` |")
    if errors:
        md += ["", "## Check errors", ""]
        md += [f"- `{e['template']}`: {e.get('error','?')}" for e in errors]
    (out / "report.md").write_text("\n".join(md) + "\n")

    print(f"[update-report] {len(updates)} update(s), {len(errors)} error(s) "
          f"-> {out}/report.{{json,md}}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
