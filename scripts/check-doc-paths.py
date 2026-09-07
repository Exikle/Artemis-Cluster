#!/usr/bin/env python3
"""Fail when agent docs reference repo paths that do not exist.

The Rook-Ceph removal left ~40 factually wrong claims across .agents/ because
nothing checked that the paths those docs named still resolved. This is the
cheapest possible guard: it does not understand the prose, only that a path
written as a repo path is real.

Usage: check-doc-paths.py [--fix-list] [files...]   (default: all .agents/**/*.md)
"""
from __future__ import annotations
import re, sys, subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Repo-relative paths the docs cite. Deliberately narrow: only prefixes that are
# real directories in this repo, so prose like "kubernetes/" alone is ignored.
PATH_RE = re.compile(
    r'`((?:kubernetes|talos|ansible|terraform|bootstrap|scripts|hooks|\.agents|\.claude|\.forgejo)'
    r'/[A-Za-z0-9_./\*-]+)`'
)

def candidates(files: list[Path]) -> list[tuple[Path, int, str]]:
    out = []
    for f in files:
        for n, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
            for m in PATH_RE.finditer(line):
                out.append((f, n, m.group(1)))
    return out

def exists(p: str) -> bool:
    # A glob is satisfied by any match; <placeholder> segments are unresolvable
    # by design, so treat the parent directory as the assertion.
    if "<" in p or "${" in p:
        p = p.split("<")[0].split("${")[0].rstrip("/")
        if not p:
            return True
    if "*" in p:
        return any(ROOT.glob(p))
    return (ROOT / p).exists()

def main(argv: list[str]) -> int:
    args = [a for a in argv[1:] if not a.startswith("--")]
    files = [Path(a) for a in args] if args else sorted(ROOT.glob(".agents/**/*.md"))
    files = [f for f in files if f.suffix == ".md" and f.exists()]
    bad = [(f, n, p) for f, n, p in candidates(files) if not exists(p)]
    for f, n, p in bad:
        try:
            rel = f.relative_to(ROOT)
        except ValueError:
            rel = f
        print(f"{rel}:{n}: path does not exist: {p}")
    if bad:
        print(f"\n{len(bad)} dead path reference(s). Fix the doc or the path — a doc that names a "
              f"file that is gone is how the Rook-Ceph rot survived for weeks.")
        return 1
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv))
