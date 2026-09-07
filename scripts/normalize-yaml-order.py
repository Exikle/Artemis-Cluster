#!/usr/bin/env python3
"""Normalize manifest key order per .agents/instructions/yaml-conventions.md.

Covers every level the conventions file defines an order for:
  - document top level, and `metadata`
  - ks.yaml (Flux Kustomization) `spec`
  - HelmRelease `spec`, and app-template `spec.values`
  - app-template `controllers.*`, `containers.*`, `initContainers.*`,
    `persistence.*`, `service.*`, `route.*`
  - OCIRepository / ExternalSecret / GitRepository / HelmRepository `spec`
  - kustomization.yaml top level, and its `resources` list

Only documents carrying both `apiVersion` and `kind` are touched, so application
config payloads that happen to live in a .yaml file are left alone. Comments,
anchors and quoting are preserved; ruamel re-emits an anchor at whatever position
its object first appears, so reordering cannot orphan an alias.

Every rewrite is verified semantically identical (safe-load compare) before the
file is written; a mismatch aborts without writing.

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

DOC_ORDER = ["apiVersion", "kind", "metadata", "spec"]
METADATA_ORDER = ["name", "namespace", "annotations", "labels"]

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

HR_SPEC_HEAD = ["chartRef", "chart", "interval", "dependsOn", "install", "upgrade"]
HR_SPEC_TAIL = ["values", "postRenderers"]

CONTROLLER_HEAD = ["enabled", "type", "annotations", "labels"]
CONTROLLER_TAIL = ["pod", "initContainers", "containers"]
CONTAINER_HEAD = ["enabled", "image"]
PERSISTENCE_HEAD = ["enabled", "type", "existingClaim", "annotations", "labels"]
PERSISTENCE_TAIL = ["globalMounts", "advancedMounts"]
SERVICE_HEAD = ["enabled", "type", "annotations", "labels"]
SERVICE_TAIL = ["ports"]

KUSTOMIZE_HEAD = ["apiVersion", "kind", "namespace", "components", "resources"]

FLUX_KUSTOMIZE_API = "kustomize.toolkit.fluxcd.io"
ALPHA_SPEC_KINDS = ("OCIRepository", "GitRepository", "HelmRepository", "ExternalSecret")


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


def _is_map(value) -> bool:
    return hasattr(value, "keys")


def _semantic(keys: list[str], head: list[str], tail: list[str] | None = None) -> list[str]:
    """`head` keys in the given order, then alphabetical middle, then `tail` in order."""
    tail = tail or []
    lead = [k for k in head if k in keys]
    trail = [k for k in tail if k in keys]
    middle = sorted(k for k in keys if k not in lead and k not in trail)
    return lead + middle + trail


def _order(mapping, head: list[str], tail: list[str] | None = None) -> bool:
    if not _is_map(mapping):
        return False
    return _reorder_map(mapping, _semantic(list(mapping.keys()), head, tail))


def _order_alpha(mapping) -> bool:
    if not _is_map(mapping):
        return False
    return _reorder_map(mapping, _semantic(list(mapping.keys()), ["enabled"]))


def _ks_spec_target(keys: list[str]) -> list[str]:
    idx = {k: KS_SPEC_ORDER.index(k) if k in KS_SPEC_ORDER else 999 for k in keys}
    return sorted(keys, key=lambda k: (idx[k], keys.index(k)))


def _values_target(keys: list[str]) -> list[str]:
    return sorted(keys, key=lambda k: (0 if k == "defaultPodOptions" else 1, k))


def _order_named(parent, head: list[str], tail: list[str] | None = None) -> bool:
    """Apply an order to every named entry under `parent`, not to `parent` itself."""
    if not _is_map(parent):
        return False
    return any([_order(entry, head, tail) for entry in parent.values()])


def _order_controllers(controllers) -> bool:
    if not _is_map(controllers):
        return False
    touched = False
    for controller in controllers.values():
        if not _is_map(controller):
            continue
        touched |= _order(controller, CONTROLLER_HEAD, CONTROLLER_TAIL)
        for key in ("containers", "initContainers"):
            touched |= _order_named(controller.get(key), CONTAINER_HEAD)
    return touched


def _process_values(values) -> bool:
    touched = _reorder_map(values, _values_target(list(values.keys())))
    touched |= _order_controllers(values.get("controllers"))
    touched |= _order_named(values.get("persistence"), PERSISTENCE_HEAD, PERSISTENCE_TAIL)
    touched |= _order_named(values.get("service"), SERVICE_HEAD, SERVICE_TAIL)
    touched |= _order_named(values.get("route"), ["enabled"])
    return touched


def _process_kustomization(doc) -> bool:
    touched = _order(doc, KUSTOMIZE_HEAD)
    resources = doc.get("resources")
    if isinstance(resources, list) and all(isinstance(r, str) for r in resources):
        want = sorted(resources, key=lambda r: (r != "./namespace.yaml", r))
        if list(resources) != want:
            resources[:] = want
            touched = True
    return touched


def _process_docs(path: Path, docs) -> bool:
    touched = False
    for doc in docs:
        if not _is_map(doc) or "apiVersion" not in doc or "kind" not in doc:
            continue
        kind = doc.get("kind")
        api = str(doc.get("apiVersion") or "")

        if api.startswith("kustomize.config.k8s.io/") and kind == "Kustomization":
            touched |= _process_kustomization(doc)
            continue

        touched |= _order(doc, DOC_ORDER)
        touched |= _order(doc.get("metadata"), METADATA_ORDER)

        spec = doc.get("spec")
        if not _is_map(spec):
            continue

        if kind == "Kustomization" and api.startswith(FLUX_KUSTOMIZE_API):
            touched |= _reorder_map(spec, _ks_spec_target(list(spec.keys())))
        elif kind == "HelmRelease":
            touched |= _order(spec, HR_SPEC_HEAD, HR_SPEC_TAIL)
            values = spec.get("values")
            if _is_map(values) and "defaultPodOptions" in values:
                touched |= _process_values(values)
        elif kind in ALPHA_SPEC_KINDS:
            touched |= _order_alpha(spec)
    return touched


def _canonical(text: str) -> list[str]:
    """Semantic fingerprint of a file, used to prove a rewrite changed nothing.

    A kustomize `resources` list is sorted on both sides: reordering it is a
    transformation this script performs deliberately, and kustomize treats the
    list as a set, so it must not read as a semantic change here.
    """
    safe = YAML(typ="safe")
    docs = []
    for d in safe.load_all(text):
        if d is None:
            continue
        if isinstance(d, dict) and str(d.get("apiVersion", "")).startswith(
            "kustomize.config.k8s.io/"
        ):
            resources = d.get("resources")
            if isinstance(resources, list) and all(isinstance(r, str) for r in resources):
                d = {**d, "resources": sorted(resources)}
        docs.append(json.dumps(d, sort_keys=True, default=str))
    return sorted(docs)


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
            files += sorted(f for f in p.rglob("*.yaml"))
        elif p.suffix in (".yaml", ".yml"):
            files.append(p)

    changed = sum(_process_file(f, args.check) for f in files)
    if changed:
        print(f"{'drifted' if args.check else 'reordered'}: {changed} file(s)")
    return 1 if (args.check and changed) else 0


if __name__ == "__main__":
    raise SystemExit(main())
