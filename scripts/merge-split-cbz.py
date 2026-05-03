#!/usr/bin/env python3
"""Merge split CBZ chapters (e.g., Ch.3.1 + Ch.3.2 → Ch.3).

Also renames lone sub-chapter files (e.g., Ch.17.1 with no siblings → Ch.17).

Usage:
    python3 merge-split-cbz.py <manga_dir>            # dry run
    python3 merge-split-cbz.py <manga_dir> --execute  # actually merge
"""

import re
import sys
import zipfile
import tempfile
from pathlib import Path
from collections import defaultdict


def natural_sort_key(s):
    return [int(c) if c.isdigit() else c.lower() for c in re.split(r"(\d+)", s)]


def is_image(name):
    return Path(name).suffix.lower() in {".png", ".jpg", ".jpeg", ".webp", ".gif", ".avif"}


# Matches sub-chapters: "Vol.1 Ch.3.1 - Title.cbz" or "Vol.1 Ch.3.2.cbz" (title optional)
SUB_PATTERN = re.compile(
    r"^(Vol\.\d+\s+Ch\.)(\d+)\.(\d+)((?:\s+-\s+.+)?\.cbz)$", re.IGNORECASE
)


def scan(directory):
    """Return (groups_to_merge, lone_subs_to_rename).

    groups_to_merge: {(prefix, ch_base): [(sub_int, suffix, path), ...]}  — 2+ sub files, no base
    lone_subs_to_rename: [(old_path, new_name)]  — sub=1, no siblings, no base file
    """
    subs = defaultdict(list)  # (prefix, ch_base) → [(sub_int, suffix, path)]
    base_exists = set()       # (prefix, ch_base) keys that have a non-sub file

    for f in sorted(directory.glob("*.cbz")):
        if "Zone.Identifier" in f.name:
            continue
        m = SUB_PATTERN.match(f.name)
        if m:
            prefix, ch_base, ch_sub, suffix = m.group(1), m.group(2), int(m.group(3)), m.group(4)
            subs[(prefix, ch_base)].append((ch_sub, suffix, f))
        else:
            # Track base chapters so we don't rename lone subs that already have a base
            m_vol = re.match(r"^(Vol\.\d+\s+Ch\.)(\d+)((?:\s+-\s+.+)?\.cbz)$", f.name, re.IGNORECASE)
            if m_vol:
                base_exists.add((m_vol.group(1), m_vol.group(2)))

    groups_to_merge = {}
    lone_subs_to_rename = []

    for key, sub_list in subs.items():
        prefix, ch_base = key
        sub_list_sorted = sorted(sub_list)

        if len(sub_list_sorted) >= 2:
            # Multiple parts — merge them
            groups_to_merge[key] = sub_list_sorted
        elif len(sub_list_sorted) == 1:
            ch_sub, suffix, f = sub_list_sorted[0]
            if ch_sub == 1 and key not in base_exists:
                # Lone Ch.X.1 with no base file → rename to Ch.X
                new_name = f"{prefix}{ch_base}{suffix}"
                lone_subs_to_rename.append((f, new_name))

    return groups_to_merge, lone_subs_to_rename


def merge_cbz(parts, output_path):
    """Merge list of (sub, suffix, path) into output_path with consecutive image numbering."""
    collected = []
    comic_info = None

    for i, (sub, _, cbz_path) in enumerate(parts):
        with zipfile.ZipFile(cbz_path, "r") as z:
            names = sorted(z.namelist(), key=natural_sort_key)
            for name in names:
                if name.endswith("/"):
                    continue
                basename = Path(name).name
                if basename.lower() == "comicinfo.xml":
                    if i == 0:
                        comic_info = z.read(name)
                elif is_image(basename):
                    collected.append((basename, z.read(name)))

    with tempfile.NamedTemporaryFile(
        dir=output_path.parent, suffix=".cbz", delete=False
    ) as tmp_f:
        tmp_path = Path(tmp_f.name)

    try:
        with zipfile.ZipFile(tmp_path, "w", zipfile.ZIP_DEFLATED) as z:
            for idx, (orig_name, data) in enumerate(collected, 1):
                ext = Path(orig_name).suffix.lower()
                z.writestr(f"{idx:03d}{ext}", data)
            if comic_info:
                z.writestr("ComicInfo.xml", comic_info)
        tmp_path.replace(output_path)
    except Exception:
        tmp_path.unlink(missing_ok=True)
        raise


def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        print(__doc__)
        sys.exit(0)

    directory = Path(sys.argv[1])
    dry_run = "--execute" not in sys.argv

    if not directory.is_dir():
        print(f"Error: '{directory}' is not a directory")
        sys.exit(1)

    groups_to_merge, lone_subs_to_rename = scan(directory)

    if not groups_to_merge and not lone_subs_to_rename:
        print("Nothing to do.")
        return

    tag = "[DRY RUN] " if dry_run else ""

    for (prefix, ch_base), parts in sorted(groups_to_merge.items()):
        out_name = f"{prefix}{ch_base}{parts[0][1]}"  # title suffix from first part
        out_path = directory / out_name

        print(f"\n{tag}MERGE Ch.{ch_base} ({len(parts)} parts):")
        for sub, _, f in parts:
            print(f"  [{sub}] {f.name}")
        print(f"       → {out_name}")

        if out_path.exists() and not any(f == out_path for _, _, f in parts):
            print(f"  WARNING: '{out_name}' already exists — skipping")
            continue

        if not dry_run:
            merge_cbz(parts, out_path)
            for _, _, f in parts:
                if f != out_path:
                    f.unlink()
                    print(f"  Deleted {f.name}")
            print(f"  Created {out_name}  ({out_path.stat().st_size // 1024} KB)")

    for old_path, new_name in sorted(lone_subs_to_rename, key=lambda x: x[1]):
        new_path = directory / new_name
        print(f"\n{tag}RENAME: {old_path.name}")
        print(f"         → {new_name}")

        if new_path.exists():
            print(f"  WARNING: '{new_name}' already exists — skipping")
            continue

        if not dry_run:
            old_path.rename(new_path)
            print(f"  Done.")

    if dry_run:
        print(f"\n{'='*60}")
        print(f"Dry run: {len(groups_to_merge)} merge(s), {len(lone_subs_to_rename)} rename(s).")
        print("Re-run with --execute to apply.")


if __name__ == "__main__":
    main()
