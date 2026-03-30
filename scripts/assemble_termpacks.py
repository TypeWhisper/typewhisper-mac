#!/usr/bin/env python3
"""Assemble individual term pack JSON files into a single termpacks.json registry."""

import json
import os
import sys
from pathlib import Path

# Built-in pack IDs that must not be reused
BUILTIN_IDS = {"web-dev", "ios-macos", "devops", "data-ai", "design"}

REQUIRED_FIELDS = {"id", "name", "description", "icon", "version", "author"}


def validate_pack(pack: dict, filename: str) -> list[str]:
    """Validate a single pack and return a list of errors."""
    errors = []

    # Required fields
    for field in REQUIRED_FIELDS:
        if field not in pack or not pack[field]:
            errors.append(f"{filename}: missing required field '{field}'")

    pack_id = pack.get("id", "")

    # Must have terms or corrections
    terms = pack.get("terms", [])
    corrections = pack.get("corrections", [])
    if not terms and not corrections:
        errors.append(f"{filename}: must have at least 'terms' or 'corrections'")

    # No built-in ID collision
    if pack_id in BUILTIN_IDS:
        errors.append(f"{filename}: ID '{pack_id}' collides with built-in pack")

    # No duplicate terms within pack (case-insensitive)
    if terms:
        seen_terms = set()
        for term in terms:
            lower = term.lower()
            if lower in seen_terms:
                errors.append(f"{filename}: duplicate term '{term}'")
            seen_terms.add(lower)

    # No duplicate corrections within pack (case-insensitive)
    if corrections:
        seen_corrections = set()
        for corr in corrections:
            if not isinstance(corr, dict) or "original" not in corr or "replacement" not in corr:
                errors.append(f"{filename}: invalid correction entry")
                continue
            key = f"{corr['original'].lower()}|{corr['replacement'].lower()}"
            if key in seen_corrections:
                errors.append(f"{filename}: duplicate correction '{corr['original']}' -> '{corr['replacement']}'")
            seen_corrections.add(key)

    # Version must look like semver
    version = pack.get("version", "")
    if version:
        parts = version.split(".")
        if len(parts) < 2 or not all(p.isdigit() for p in parts):
            errors.append(f"{filename}: version '{version}' is not valid semver")

    return errors


def main():
    repo_root = Path(__file__).resolve().parent.parent
    termpacks_dir = repo_root / "termpacks"

    if not termpacks_dir.exists():
        print("Error: termpacks/ directory not found", file=sys.stderr)
        sys.exit(1)

    pack_files = sorted(termpacks_dir.glob("*.json"))
    if not pack_files:
        print("Warning: no JSON files found in termpacks/", file=sys.stderr)

    all_errors = []
    packs = []
    seen_ids = set()

    for pack_file in pack_files:
        try:
            with open(pack_file) as f:
                pack = json.load(f)
        except json.JSONDecodeError as e:
            all_errors.append(f"{pack_file.name}: invalid JSON - {e}")
            continue

        errors = validate_pack(pack, pack_file.name)
        all_errors.extend(errors)

        if not errors:
            pack_id = pack["id"]
            if pack_id in seen_ids:
                all_errors.append(f"{pack_file.name}: duplicate ID '{pack_id}' across packs")
            else:
                seen_ids.add(pack_id)
                packs.append(pack)

    if all_errors:
        print("Validation errors:", file=sys.stderr)
        for error in all_errors:
            print(f"  - {error}", file=sys.stderr)
        sys.exit(1)

    # Sort by ID for deterministic output
    packs.sort(key=lambda p: p["id"])

    registry = {
        "schemaVersion": 1,
        "packs": packs
    }

    output = json.dumps(registry, indent=2, ensure_ascii=False) + "\n"

    # Write to stdout by default, or to a file if specified
    if len(sys.argv) > 1:
        output_path = Path(sys.argv[1])
        with open(output_path, "w") as f:
            f.write(output)
        print(f"Wrote {len(packs)} pack(s) to {output_path}")
    else:
        print(output, end="")


if __name__ == "__main__":
    main()
