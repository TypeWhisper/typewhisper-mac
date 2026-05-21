#!/usr/bin/env python3
"""Normalize TypeWhisper plugin registry release metadata."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


TOP_LEVEL_RELEASE_FIELDS = {
    "version",
    "minHostVersion",
    "sdkCompatibilityVersion",
    "minOSVersion",
    "supportedArchitectures",
    "size",
    "downloadURL",
}


def _release_metadata_finding(plugin: dict[str, Any], index: int) -> dict[str, Any] | None:
    fields = sorted(field for field in TOP_LEVEL_RELEASE_FIELDS if field in plugin)
    if not fields:
        return None

    releases = plugin.get("releases")
    latest_release = releases[0] if isinstance(releases, list) and releases else None
    stale_fields = []
    for field in fields:
        if not isinstance(latest_release, dict) or plugin.get(field) != latest_release.get(field):
            stale_fields.append(field)

    return {
        "id": plugin.get("id", f"<plugin[{index}]>"),
        "fields": fields,
        "staleFields": stale_fields,
    }


def find_top_level_release_metadata(registry: dict[str, Any]) -> list[dict[str, Any]]:
    plugins = registry.get("plugins")
    if not isinstance(plugins, list):
        return []

    findings = []
    for index, plugin in enumerate(plugins):
        if not isinstance(plugin, dict):
            continue
        finding = _release_metadata_finding(plugin, index)
        if finding is not None:
            findings.append(finding)
    return findings


def remove_top_level_release_metadata(plugin: dict[str, Any]) -> dict[str, Any] | None:
    finding = _release_metadata_finding(plugin, -1)
    if finding is None:
        return None

    for field in TOP_LEVEL_RELEASE_FIELDS:
        plugin.pop(field, None)
    return finding


def normalize_registry_release_metadata(registry: dict[str, Any]) -> list[dict[str, Any]]:
    plugins = registry.get("plugins")
    if not isinstance(plugins, list):
        return []

    findings = []
    for plugin in plugins:
        if not isinstance(plugin, dict):
            continue
        finding = remove_top_level_release_metadata(plugin)
        if finding is not None:
            findings.append(finding)
    return findings


def format_findings(findings: list[dict[str, Any]]) -> list[str]:
    lines = []
    for finding in findings:
        fields = ", ".join(finding["fields"])
        stale_fields = ", ".join(finding["staleFields"])
        suffix = f"; stale: {stale_fields}" if stale_fields else ""
        lines.append(f"{finding['id']}: top-level release fields: {fields}{suffix}")
    return lines


def _load_json(path: Path) -> dict[str, Any]:
    with path.open() as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"{path}: expected a JSON object")
    return value


def _dump_json(path: Path, registry: dict[str, Any]) -> None:
    path.write_text(json.dumps(registry, indent=2, ensure_ascii=False) + "\n")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Remove or check top-level release metadata in plugin registry files."
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Fail if any top-level release metadata is present.",
    )
    parser.add_argument("registry", nargs="+", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    failed = False

    for registry_path in args.registry:
        registry = _load_json(registry_path)
        findings = find_top_level_release_metadata(registry)

        if args.check:
            if findings:
                failed = True
                print(f"{registry_path}: top-level release metadata found", file=sys.stderr)
                for line in format_findings(findings):
                    print(f"  - {line}", file=sys.stderr)
            continue

        removed = normalize_registry_release_metadata(registry)
        if removed:
            _dump_json(registry_path, registry)
            print(f"{registry_path}: removed top-level release metadata")
            for line in format_findings(removed):
                print(f"  - {line}")
        else:
            print(f"{registry_path}: no top-level release metadata found")

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
