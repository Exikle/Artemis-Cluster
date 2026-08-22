#!/usr/bin/env python3
"""Refuse to commit an OpenTofu state file that is not encrypted.

State is deliberately tracked in this repo (see .agents/references/terraform.md),
which is only safe while it is ciphertext. If the encryption config is ever
missing or misconfigured, OpenTofu writes plaintext state containing every
secret it touched — and nothing else would stop that landing in git.

An encrypted state document looks like:

    {"serial": 1, "lineage": "...", "meta": {...}, "encrypted_data": "..."}

A plaintext one carries "resources" and/or "outputs" at the top level. We treat
"has encrypted_data" as the pass condition rather than "lacks resources", so an
unrecognised shape fails closed.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path


def verdict(path: Path) -> str | None:
    """Return an error string, or None if the file is safe to commit."""
    try:
        raw = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        return f"could not read ({exc})"

    if not raw.strip():
        return "is empty — tofu never wrote it, or the backend path was wrong"

    try:
        doc = json.loads(raw)
    except json.JSONDecodeError:
        return "is not valid JSON — refusing to guess whether it is encrypted"

    if not isinstance(doc, dict):
        return "is not a JSON object"

    if isinstance(doc.get("encrypted_data"), str) and doc["encrypted_data"]:
        return None

    leaked = sorted(k for k in ("resources", "outputs", "check_results") if k in doc)
    if leaked:
        return (
            f"is PLAINTEXT — found top-level {', '.join(leaked)}. "
            "This file may contain credentials in the clear."
        )

    return "has no 'encrypted_data' key — cannot confirm it is encrypted"


def main(argv: list[str]) -> int:
    failures: list[tuple[Path, str]] = []

    for arg in argv:
        path = Path(arg)
        if not path.is_file():
            continue
        if problem := verdict(path):
            failures.append((path, problem))

    if not failures:
        return 0

    print("Refusing to commit OpenTofu state:\n", file=sys.stderr)
    for path, problem in failures:
        print(f"  {path} {problem}", file=sys.stderr)
    print(
        "\nState in this repo must be encrypted with OpenTofu's native state\n"
        "encryption. Check that TF_ENCRYPTION was set — `just tofu` recipes do\n"
        "this for you; a bare `tofu apply` does not.\n"
        "See .agents/references/terraform.md for the recovery procedure.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
