#!/usr/bin/env python3

import os
import sys
from pathlib import Path

def add_yaml_separator(directory="."):
    modified_count = 0
    total_files = 0

    print("🔍 Scanning for YAML files without document separator...\n")

    # Find all .yaml files
    for yaml_file in Path(directory).rglob("*.yaml"):
        # Skip .git directory
        if ".git" in yaml_file.parts:
            continue

        total_files += 1

        try:
            # Read the file
            with open(yaml_file, 'r') as f:
                content = f.read()

            # Skip empty files
            if not content.strip():
                print(f"⚠  Skipping empty file: {yaml_file}")
                continue

            # Check if first line is "---"
            if not content.startswith("---\n") and not content.startswith("---\r\n"):
                print(f"📝 Adding '---' to: {yaml_file}")

                # Prepend "---"
                with open(yaml_file, 'w') as f:
                    f.write("---\n" + content)

                modified_count += 1
            else:
                print(f"✓  Already has '---': {yaml_file}")

        except Exception as e:
            print(f"❌ Error processing {yaml_file}: {e}")

    print("\n================================")
    print("✅ Complete!")
    print(f"Total YAML files found: {total_files}")
    print(f"Files modified: {modified_count}")
    print("================================")

if __name__ == "__main__":
    add_yaml_separator()
