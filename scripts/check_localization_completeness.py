#!/usr/bin/env python3
"""Verify that every main-app string has a Simplified Chinese translation."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parent.parent
CATALOG = REPO_ROOT / "TypeWhisper/Resources/Localizable.xcstrings"
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
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    missing: list[str] = []

    for key, entry in catalog.get("strings", {}).items():
        if key == "":
            continue
        localization = entry.get("localizations", {}).get(LANGUAGE)
        values = localized_values(localization)
        if not values or any(not value for value in values):
            missing.append(key)

    if missing:
        print(f"error: {len(missing)} strings are missing complete {LANGUAGE} localizations")
        for key in missing:
            print(f"  {key}")
        return 1

    count = len(catalog.get("strings", {})) - 1
    print(f"verified {LANGUAGE} localizations for {count} main-app strings")
    return 0


if __name__ == "__main__":
    sys.exit(main())
