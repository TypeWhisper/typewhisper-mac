#!/usr/bin/env python3
"""Verify the translations in the bundled string catalogs.

Every key needs a non-empty Simplified Chinese and Spanish value, including each plural
variation. Every translation, in any language, has to use the format specifiers of its
English text: a missing or different specifier drops an argument or crashes when the
string is formatted. Keys marked "shouldTranslate": false are skipped.
"""

from __future__ import annotations

import json
import re
import sys
from collections import Counter
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parent.parent
REQUIRED_LANGUAGES = ("zh-Hans", "es")
SOURCE_LANGUAGE = "en"

# printf-style specifiers as Foundation reads them, e.g. %@, %lld, %1$@, %.1f, %%.
# A space is not accepted as a flag so that prose like "0% mutes" is not read as "% m".
FORMAT_SPECIFIER = re.compile(
    r"%(?:(?P<position>\d+)\$)?[-+0#']*(?:\d+|\*)?(?:\.(?:\d+|\*))?"
    r"(?P<length>hh|h|ll|l|q|L|z|t|j)?(?P<conversion>[@dDiuUxXoOfFeEgGcCsSpaA%])"
)
# Plural categories that may leave out the number, as in "Synced 1 change."
OPTIONAL_SPECIFIER_CATEGORIES = {"zero", "one", "two", "few"}


def catalog_paths(repo_root: Path = REPO_ROOT) -> list[Path]:
    return [
        repo_root / "TypeWhisper/Resources/Localizable.xcstrings",
        repo_root / "TypeWhisperTranscribeAction/InfoPlist.xcstrings",
        *sorted((repo_root / "TypeWhisperPluginSDK/Plugins").glob("*/Localizable.xcstrings")),
    ]


def format_specifiers(text: str) -> Counter:
    """Specifiers of a string, ignoring their position, e.g. Counter({"lld": 1, "@": 2})."""
    specifiers: Counter = Counter()
    for match in FORMAT_SPECIFIER.finditer(text):
        conversion = match.group("conversion")
        specifiers["%" if conversion == "%" else (match.group("length") or "") + conversion] += 1
    return specifiers


def localized_forms(node: Any) -> dict[str, str] | None:
    """The values of one localization by plural category ("other" for a plain string).

    Returns None when the localization has no value at all.
    """
    if not isinstance(node, dict):
        return None
    string_unit = node.get("stringUnit")
    if isinstance(string_unit, dict):
        value = string_unit.get("value")
        return {"other": value} if isinstance(value, str) else None

    variations = node.get("variations")
    if not isinstance(variations, dict) or not variations:
        return None
    forms: dict[str, str] = {}
    for variation_type, cases in variations.items():
        if not isinstance(cases, dict):
            return None
        for category, case in cases.items():
            case_forms = localized_forms(case)
            if case_forms is None:
                return None
            for nested_category, value in case_forms.items():
                name = category if variation_type == "plural" else f"{variation_type}.{category}"
                if nested_category != "other":
                    name = f"{name}.{nested_category}"
                forms[name] = value
    return forms or None


def english_forms(key: str, entry: dict) -> dict[str, str]:
    """The English text of a key: its explicit "en" localization, otherwise the key itself."""
    forms = localized_forms(entry.get("localizations", {}).get(SOURCE_LANGUAGE))
    return forms or {"other": key}


def specifier_problem(english: dict[str, str], category: str, value: str) -> str | None:
    reference = english.get(category) or english.get("other", "")
    expected = format_specifiers(english.get("other", reference))
    actual = format_specifiers(value)
    if category in OPTIONAL_SPECIFIER_CATEGORIES:
        # These forms may leave out the number but must not add or change a specifier.
        if actual - expected:
            return f"{category}: {sorted(actual.elements())} is not part of {sorted(expected.elements())}"
        return None
    expected = format_specifiers(reference)
    if actual != expected:
        return f"{category}: specifiers {sorted(actual.elements())} != English {sorted(expected.elements())}"
    return None


def check_catalog(catalog: dict, required_languages=REQUIRED_LANGUAGES) -> tuple[list[str], list[str], int]:
    """Returns (missing translations, specifier mismatches, number of checked keys)."""
    missing: list[str] = []
    mismatches: list[str] = []
    checked = 0
    for key, entry in catalog.get("strings", {}).items():
        if key == "" or entry.get("shouldTranslate") is False:
            continue
        checked += 1
        localizations = entry.get("localizations", {})
        english = english_forms(key, entry)

        for language in required_languages:
            forms = localized_forms(localizations.get(language))
            if not forms or any(not value for value in forms.values()):
                missing.append(f"{language}: {key}")

        for language, node in localizations.items():
            if language == SOURCE_LANGUAGE:
                continue
            for category, value in (localized_forms(node) or {}).items():
                problem = specifier_problem(english, category, value)
                if problem:
                    mismatches.append(f"{language}: {key} ({problem})")
    return missing, mismatches, checked


def main() -> int:
    paths = catalog_paths()
    all_missing: list[tuple[Path, str]] = []
    all_mismatches: list[tuple[Path, str]] = []
    string_count = 0

    for catalog_path in paths:
        catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
        missing, mismatches, checked = check_catalog(catalog)
        string_count += checked
        all_missing.extend((catalog_path, item) for item in missing)
        all_mismatches.extend((catalog_path, item) for item in mismatches)

    failed = False
    if all_missing:
        failed = True
        languages = " and ".join(REQUIRED_LANGUAGES)
        print(f"error: {len(all_missing)} strings are missing complete {languages} localizations")
        for catalog_path, item in all_missing:
            print(f"  {catalog_path.relative_to(REPO_ROOT)}: {item}")
    if all_mismatches:
        failed = True
        print(f"error: {len(all_mismatches)} translations use other format specifiers than English")
        for catalog_path, item in all_mismatches:
            print(f"  {catalog_path.relative_to(REPO_ROOT)}: {item}")
    if failed:
        return 1

    print(
        f"verified {', '.join(REQUIRED_LANGUAGES)} localizations and format specifiers "
        f"for {string_count} strings across {len(paths)} bundled catalogs"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
