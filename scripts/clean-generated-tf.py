#!/usr/bin/env python3
"""Strip the unusable artifacts out of `tofu plan -generate-config-out` output.

The bpg/proxmox provider emits every unset optional as a zero value, and several
of those fail the provider's *own* validation on the next plan:

    hugepages = ""   -> expected hugepages to be one of ["1024" "2" "any"]
    units     = 0    -> expected units to be in the range (1 - 262144)
    affinity  = ""   -> must contain numbers or number ranges separated by ','

It also freezes computed list attributes as `[]`. `mac_addresses` is the one that
bites: once the PVE role carries VM.GuestAgent.Audit the provider reads every
interface inside the guest, and a frozen `[]` then plans a spurious update.

Dropping an optional attribute is not the same as setting it to a zero value:
absent means "provider decides", which is what the live object actually has.

Usage:  clean-generated-tf.py generated.tf [...]
        clean-generated-tf.py --check generated.tf   (report only, exit 1 if dirty)
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# Attributes the provider rejects when present but zero-valued.
ZERO_VALUED_REJECTS = {"units"}

# Computed attributes that config generation writes as an empty list. They are
# read back from the guest agent once it is readable (VM.GuestAgent.Audit), at
# which point a frozen `[]` in config plans a spurious in-place update — for a
# Talos node that means every Cilium veth MAC inside the guest.
EMPTY_LIST_COMPUTED = {"mac_addresses"}

EMPTY_ASSIGNMENT = re.compile(r'^\s*([a-z_]+)\s*=\s*(""|null)\s*$')
EMPTY_LIST_ASSIGNMENT = re.compile(r"^\s*([a-z_]+)\s*=\s*\[\]\s*$")
ZERO_ASSIGNMENT = re.compile(r"^\s*([a-z_]+)\s*=\s*0\s*$")

GENERATED_HEADER = re.compile(r"^# __generated__ by OpenTofu\s*$")


def clean(text: str) -> tuple[str, list[str]]:
    kept: list[str] = []
    dropped: list[str] = []

    for line in text.splitlines():
        if GENERATED_HEADER.match(line):
            continue
        if line.strip() == "# Please review these resources and move them into your main configuration files.":
            continue

        if EMPTY_ASSIGNMENT.match(line):
            dropped.append(line.strip())
            continue

        if match := EMPTY_LIST_ASSIGNMENT.match(line):
            if match.group(1) in EMPTY_LIST_COMPUTED:
                dropped.append(line.strip())
                continue

        if match := ZERO_ASSIGNMENT.match(line):
            if match.group(1) in ZERO_VALUED_REJECTS:
                dropped.append(line.strip())
                continue

        kept.append(line)

    # Collapse the blank run the stripped header leaves behind.
    while kept and not kept[0].strip():
        kept.pop(0)

    return "\n".join(kept) + "\n", dropped


def main(argv: list[str]) -> int:
    check_only = "--check" in argv
    paths = [Path(a) for a in argv if not a.startswith("-")]

    if not paths:
        print(__doc__, file=sys.stderr)
        return 2

    dirty = False
    for path in paths:
        if not path.is_file():
            print(f"{path}: not a file", file=sys.stderr)
            return 2

        original = path.read_text(encoding="utf-8")
        cleaned, dropped = clean(original)

        if not dropped and cleaned == original:
            print(f"{path}: already clean")
            continue

        dirty = True
        print(f"{path}: dropped {len(dropped)} unset optional(s)")
        for item in dropped:
            print(f"    {item}")

        if not check_only:
            path.write_text(cleaned, encoding="utf-8")

    return 1 if (check_only and dirty) else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
