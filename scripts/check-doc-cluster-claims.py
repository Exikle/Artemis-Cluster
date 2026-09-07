#!/usr/bin/env python3
"""Flag agent docs naming Kubernetes objects the cluster does not have.

check-doc-paths.py catches a dead FILE path. It cannot catch a dead CLUSTER
name, which is how the Rook-Ceph rot survived: docs kept naming the `rook-ceph`
namespace and the `ceph-block` StorageClass long after both were deleted.

Needs cluster access, so this is NOT a pre-commit hook — commits happen offline.
Run it directly, or from the cluster-health subagent.

Usage: check-doc-cluster-claims.py [--context artemis]
"""
from __future__ import annotations
import re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CTX = "artemis"

def kube(*args: str) -> set[str]:
    try:
        out = subprocess.run(["kubectl", "--context", CTX, *args, "-o",
                              "jsonpath={range .items[*]}{.metadata.name}{\"\\n\"}{end}"],
                             capture_output=True, text=True, timeout=30)
        return {l.strip() for l in out.stdout.splitlines() if l.strip()}
    except Exception:
        return set()

def main() -> int:
    global CTX
    if "--context" in sys.argv:
        CTX = sys.argv[sys.argv.index("--context") + 1]

    namespaces = kube("get", "ns")
    classes = kube("get", "sc")
    if not namespaces:
        print("cannot reach the cluster; skipping", file=sys.stderr)
        return 0

    # Only assert names that LOOK like a claim: a backticked token used next to
    # the word namespace/StorageClass, or one we know the shape of. Anything
    # broader produces noise from prose and example snippets.
    ns_re = re.compile(r'`([a-z0-9][a-z0-9-]{2,})`\s+namespace|namespace\s+`([a-z0-9][a-z0-9-]{2,})`')
    sc_re = re.compile(r'`([a-z0-9][a-z0-9-]{2,})`\s+StorageClass|StorageClass\s+`([a-z0-9][a-z0-9-]{2,})`')

    bad = []
    for f in sorted(ROOT.glob(".agents/**/*.md")):
        text = f.read_text(encoding="utf-8")
        for n, line in enumerate(text.splitlines(), 1):
            # a line that says the thing is gone is not a claim that it exists
            if re.search(r'no longer|removed|does not exist|was removed|deleted|gone|never', line, re.I):
                continue
            for m in ns_re.finditer(line):
                name = m.group(1) or m.group(2)
                if name not in namespaces:
                    bad.append((f, n, "namespace", name))
            for m in sc_re.finditer(line):
                name = m.group(1) or m.group(2)
                if name not in classes:
                    bad.append((f, n, "StorageClass", name))

    for f, n, kind, name in bad:
        print(f"{f.relative_to(ROOT)}:{n}: {kind} does not exist in the cluster: {name}")
    if bad:
        print(f"\n{len(bad)} dead cluster reference(s). This is the class of rot a path check "
              f"cannot see — a doc naming a namespace or class that was deleted.")
        return 1
    print(f"clean — checked against {len(namespaces)} namespaces, {len(classes)} storage classes")
    return 0

if __name__ == "__main__":
    sys.exit(main())
