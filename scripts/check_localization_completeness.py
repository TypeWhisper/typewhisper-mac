#!/usr/bin/env python3
"""Verify that bundled string catalogs have Simplified Chinese translations."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parent.parent
CATALOGS = [
    REPO_ROOT / "TypeWhisper/Resources/Localizable.xcstrings",
    *sorted(
        (REPO_ROOT / "TypeWhisperPluginSDK/Plugins").glob(
            "*/Localizable.xcstrings"
        )
    ),
]
LANGUAGE = "zh-Hans"


def localized_values(node: Any) -> list[str]:
    if not isinstance(node, dict):
        return []

    values: list[str] = []
    string_unit = node.get("stringUnit")
    if isinstance(string_unit, dict) and isinstance(string_unit.get("value"), str):
        values.append(string_unit["value"])

    for value in node.values():
        if isinstance(value, (dict, list)):
            values.extend(localized_values(value))
    return values


def main() -> int:
    missing: list[tuple[Path, str]] = []
    string_count = 0

    for catalog_path in CATALOGS:
        catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
        for key, entry in catalog.get("strings", {}).items():
            if key == "":
                continue
            string_count += 1
            localization = entry.get("localizations", {}).get(LANGUAGE)
            values = localized_values(localization)
            if not values or any(not value for value in values):
                missing.append((catalog_path, key))

    if missing:
        print(f"error: {len(missing)} strings are missing complete {LANGUAGE} localizations")
        for catalog_path, key in missing:
            print(f"  {catalog_path.relative_to(REPO_ROOT)}: {key}")
        return 1

    print(
        f"verified {LANGUAGE} localizations for {string_count} strings "
        f"across {len(CATALOGS)} bundled catalogs"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
