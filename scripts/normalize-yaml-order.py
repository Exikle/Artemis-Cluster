#!/usr/bin/env python3
"""Normalize manifest key order per .agents/instructions/yaml-conventions.md.

Two passes:
  1. ks.yaml — reorder Flux Kustomization `spec` keys into the canonical semantic order
  2. helmrelease.yaml — for app-template values (detected by `defaultPodOptions`),
     put `defaultPodOptions` first and sort the remaining top-level values keys
     alphabetically. Non-app-template charts are left untouched.

Only reorders the levels above — never nested content, comments, anchors, or quoting.
Every rewrite is verified semantically identical (safe-load compare) before the file
is written; a mismatch aborts without writing.

Run with the hooks venv (has ruamel.yaml):
    hooks/.venv/bin/python scripts/normalize-yaml-order.py [--check] [paths...]

--check: report files that would change and exit 1, without writing.
Default paths: kubernetes/
"""

from __future__ import annotations

import argparse
import io
import json
import sys
from pathlib import Path

from ruamel.yaml import YAML  # type: ignore[import-untyped]

KS_SPEC_ORDER = [
    "targetNamespace",
    "commonMetadata",
    "path",
    "prune",
    "sourceRef",
    "interval",
    "retryInterval",
    "timeout",
    "dependsOn",
    "components",
    "postBuild",
    "wait",
    "healthCheckExprs",
    "healthChecks",
]


def _rt_yaml() -> YAML:
    yaml = YAML(typ="rt")
    yaml.preserve_quotes = True
    yaml.width = 4096
    yaml.indent(mapping=2, sequence=4, offset=2)
    yaml.explicit_start = True
    return yaml


def _reorder_map(mapping, want: list[str]) -> bool:
    """Reorder `mapping` keys in place to `want`, carrying per-key comments."""
    keys = list(mapping.keys())
    if want == keys:
        return False
    items = {k: mapping[k] for k in keys}
    comments = dict(getattr(mapping, "ca", None).items) if hasattr(mapping, "ca") else {}
    mapping.clear()
    if comments:
        mapping.ca.items.clear()
    for k in want:
        mapping[k] = items[k]
        if k in comments:
            mapping.ca.items[k] = comments[k]
    return True


def _ks_spec_target(keys: list[str]) -> list[str]:
    idx = {k: KS_SPEC_ORDER.index(k) if k in KS_SPEC_ORDER else 999 for k in keys}
    return sorted(keys, key=lambda k: (idx[k], keys.index(k)))


def _values_target(keys: list[str]) -> list[str]:
    return sorted(keys, key=lambda k: (0 if k == "defaultPodOptions" else 1, k))


def _process_docs(path: Path, docs) -> bool:
    touched = False
    for doc in docs:
        if not isinstance(doc, dict):
            continue
        kind = doc.get("kind")
        if kind == "Kustomization" and path.name in ("ks.yaml", "ks.yml"):
            spec = doc.get("spec")
            if spec is not None and _reorder_map(spec, _ks_spec_target(list(spec.keys()))):
                touched = True
        elif kind == "HelmRelease":
            values = (doc.get("spec") or {}).get("values")
            if (
                isinstance(values, dict)
                and "defaultPodOptions" in values
                and _reorder_map(values, _values_target(list(values.keys())))
            ):
                touched = True
    return touched


def _canonical(text: str) -> list[str]:
    safe = YAML(typ="safe")
    return sorted(
        json.dumps(d, sort_keys=True, default=str)
        for d in safe.load_all(text)
        if d is not None
    )


def _process_file(path: Path, check: bool) -> bool:
    """Returns True if the file changed (or would change in --check mode)."""
    text = path.read_text(encoding="utf-8")
    yaml = _rt_yaml()
    docs = list(yaml.load_all(text))
    if not _process_docs(path, docs):
        return False
    if check:
        print(f"would reorder: {path}")
        return True
    buf = io.StringIO()
    yaml.dump_all(docs, buf)
    out = buf.getvalue()
    if _canonical(text) != _canonical(out):
        print(f"normalize-yaml-order: SEMANTIC MISMATCH, not writing: {path}", file=sys.stderr)
        raise SystemExit(2)
    path.write_text(out, encoding="utf-8")
    print(f"reordered: {path}")
    return True


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true", help="report drift, write nothing, exit 1 if any")
    ap.add_argument("paths", nargs="*", default=["kubernetes"], help="files or directories")
    args = ap.parse_args(argv)

    files: list[Path] = []
    for p in (Path(p) for p in args.paths):
        if p.is_dir():
            files += sorted(p.rglob("ks.yaml")) + sorted(p.rglob("helmrelease.yaml"))
        elif p.suffix in (".yaml", ".yml"):
            files.append(p)

    changed = sum(_process_file(f, args.check) for f in files)
    if changed:
        print(f"{'drifted' if args.check else 'reordered'}: {changed} file(s)")
    return 1 if (args.check and changed) else 0


if __name__ == "__main__":
    raise SystemExit(main())
