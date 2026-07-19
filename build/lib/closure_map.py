#!/usr/bin/env python3
"""Map unsatisfied apk dependencies to cports templates (GAP §3.4).

Input: the output of a failed 'apk --simulate add ...' (apk-tools 3.x),
which lists unsatisfied dependencies as e.g.

    ERROR: unable to select packages:
      so:libkrb5.so.26 (no such package):
        required by: openssh-10.3_p1-r1[so:libkrb5.so.26]
      dhcpcd-dinit (no such package):
        ...

Each dependency token (name, so:..., pc:..., cmd:...) is mapped to the
cports template that would provide it, using, in order:

  1. a template directory of the same name (cports/<cat>/<name>);
  2. the provider oracle: an 'apk adbdump' of a Packages.adb index (we pass
     Chimera's official index) — find the package whose name or provides
     matches the dep, then follow its 'origin' field to the template;
  3. a subpackage-decorator search over template sources
     (@subpackage("<name>" in cports/<cat>/*/template.py).

Output: unique "cat/template" lines on stdout.
Diagnostics + unresolved deps go to stderr.
Exit: 0 if at least one dep was mapped, 2 if none could be mapped.
"""

import argparse
import re
import sys
from pathlib import Path

CATEGORIES = ("main", "user")


def log(msg):
    print(f"[closure-map] {msg}", file=sys.stderr)


def parse_apk_errors(text):
    """Extract unsatisfied dependency tokens from apk error output."""
    deps = []
    for m in re.finditer(r"^\s+(\S+?)\s+\(no such package\)", text, re.M):
        deps.append(m.group(1))
    # conflict/branch forms also list bare unsatisfiable constraints
    for m in re.finditer(r"^\s+(\S+?)\s+\(virtual\)", text, re.M):
        deps.append(m.group(1))
    # normalize: strip version constraints (name>=1.2, name=1.2-r0, name~1)
    out = []
    for d in deps:
        d = re.split(r"[<>=~]", d, maxsplit=1)[0]
        if d and d not in out:
            out.append(d)
    return out


def parse_index_dump(path):
    """Parse 'apk adbdump Packages.adb' output.

    Returns (by_name, providers): package-name -> origin, and
    provider-token (before '=') -> package-name.
    """
    by_name = {}
    providers = {}
    cur_name = None
    in_provides = False
    with open(path, errors="replace") as f:
        for line in f:
            m = re.match(r"^  - name: (\S+)$", line)
            if m:
                cur_name = m.group(1)
                by_name.setdefault(cur_name, None)
                in_provides = False
                continue
            if cur_name is None:
                continue
            m = re.match(r"^    origin: (\S+)$", line)
            if m:
                by_name[cur_name] = m.group(1)
                continue
            if re.match(r"^    provides:", line):
                in_provides = True
                continue
            if in_provides:
                m = re.match(r"^      - (\S+)$", line)
                if m:
                    token = m.group(1).split("=", 1)[0]
                    providers.setdefault(token, cur_name)
                else:
                    in_provides = False
    return by_name, providers


def find_template_dir(cports, name):
    for cat in CATEGORIES:
        d = cports / cat / name
        if (d / "template.py").is_file():
            # resolve symlinked templates (e.g. libcxx -> llvm)
            real = (d / "template.py").resolve().parent
            return f"{real.parent.name}/{real.name}"
    return None


def find_subpackage_template(cports, name):
    """Slow-path: search @subpackage declarations in template sources."""
    needle = re.compile(
        r"@subpackage\(\s*[\"']" + re.escape(name) + r"[\"']"
    )
    for cat in CATEGORIES:
        catdir = cports / cat
        if not catdir.is_dir():
            continue
        for tmpl in catdir.glob("*/template.py"):
            try:
                if needle.search(tmpl.read_text(errors="replace")):
                    real = tmpl.resolve().parent
                    return f"{real.parent.name}/{real.name}"
            except OSError:
                continue
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--errors", required=True, help="apk --simulate output")
    ap.add_argument("--cports", required=True, help="cports checkout dir")
    ap.add_argument(
        "--index-dump",
        action="append",
        default=[],
        help="apk adbdump of a Packages.adb (provider oracle); repeatable",
    )
    args = ap.parse_args()

    cports = Path(args.cports)
    text = Path(args.errors).read_text(errors="replace")
    deps = parse_apk_errors(text)
    if not deps:
        log("no unsatisfied dependencies found in apk output")
        return 2

    by_name = {}
    providers = {}
    for dump in args.index_dump:
        try:
            n, p = parse_index_dump(dump)
        except OSError as e:
            log(f"cannot read index dump {dump}: {e}")
            continue
        for k, v in n.items():
            by_name.setdefault(k, v)
        for k, v in p.items():
            providers.setdefault(k, v)

    templates = []
    unresolved = []
    for dep in deps:
        tmpl = None
        origin = None

        if not dep.startswith(("so:", "pc:", "cmd:")):
            # 1. direct template dir
            tmpl = find_template_dir(cports, dep)

        if tmpl is None:
            # 2. provider oracle
            pkg = None
            if dep in by_name:
                pkg = dep
            elif dep in providers:
                pkg = providers[dep]
            if pkg is not None:
                origin = by_name.get(pkg) or pkg
                tmpl = find_template_dir(cports, origin)

        if tmpl is None and not dep.startswith(("so:", "pc:", "cmd:")):
            # 3. subpackage declaration search
            tmpl = find_subpackage_template(cports, dep)

        if tmpl is None:
            unresolved.append(dep)
            log(f"UNRESOLVED: {dep}"
                + (f" (index origin '{origin}' has no template)" if origin else ""))
        else:
            log(f"{dep} -> {tmpl}")
            if tmpl not in templates:
                templates.append(tmpl)

    for t in templates:
        print(t)

    if not templates:
        log("no dependency could be mapped to a template")
        return 2
    if unresolved:
        log(f"note: {len(unresolved)} dep(s) unresolved this round: {', '.join(unresolved)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
