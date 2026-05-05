#!/usr/bin/env python3
"""Validate and assemble the TypeWhisper community plugin registry."""

from __future__ import annotations

import argparse
import copy
import json
import re
import sys
from pathlib import Path
from urllib.parse import urlparse


REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_COMMUNITY_DIR = REPO_ROOT / "PluginRegistry" / "community-v1"

VALID_CATEGORIES = {
    "transcription",
    "tts",
    "llm",
    "post-processor",
    "action",
    "memory",
    "utility",
}
VALID_HOSTING = {"local", "cloud"}
VALID_ARCHITECTURES = {"arm64", "x86_64"}

PLUGIN_REQUIRED_FIELDS = {
    "id",
    "source",
    "name",
    "author",
    "description",
    "category",
    "releases",
}
RELEASE_REQUIRED_FIELDS = {
    "version",
    "minHostVersion",
    "sdkCompatibilityVersion",
    "size",
    "downloadURL",
}
TOP_LEVEL_RELEASE_FIELDS = {
    "version",
    "minHostVersion",
    "sdkCompatibilityVersion",
    "minOSVersion",
    "supportedArchitectures",
    "size",
    "downloadURL",
}

PLUGIN_ID_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$")
SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$")
OS_VERSION_RE = re.compile(r"^\d+\.\d+(?:\.\d+)?$")


def load_json(path: Path) -> tuple[dict | None, list[str]]:
    try:
        with path.open() as handle:
            value = json.load(handle)
    except json.JSONDecodeError as error:
        return None, [f"{path}: invalid JSON - {error}"]
    except OSError as error:
        return None, [f"{path}: could not read file - {error}"]

    if not isinstance(value, dict):
        return None, [f"{path}: expected a JSON object"]
    return value, []


def is_non_empty_string(value: object) -> bool:
    return isinstance(value, str) and bool(value.strip())


def is_non_negative_int(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def is_positive_int(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def validate_https_url(value: object, filename: str, field: str) -> list[str]:
    if not is_non_empty_string(value):
        return [f"{filename}: '{field}' must be a non-empty string"]

    parsed = urlparse(value)
    if parsed.scheme != "https" or not parsed.netloc:
        return [f"{filename}: '{field}' must be an HTTPS URL"]
    return []


def validate_optional_localized_strings(plugin: dict, filename: str) -> list[str]:
    descriptions = plugin.get("descriptions")
    if descriptions is None:
        return []
    if not isinstance(descriptions, dict):
        return [f"{filename}: 'descriptions' must be an object when present"]

    errors = []
    for key, value in descriptions.items():
        if not is_non_empty_string(key) or not isinstance(value, str):
            errors.append(f"{filename}: 'descriptions' keys and values must be strings")
            break
    return errors


def validate_categories(plugin: dict, filename: str) -> list[str]:
    errors = []
    category = plugin.get("category")
    if category not in VALID_CATEGORIES:
        errors.append(
            f"{filename}: 'category' must be one of {', '.join(sorted(VALID_CATEGORIES))}"
        )

    categories = plugin.get("categories")
    if categories is None:
        return errors

    if not isinstance(categories, list) or not categories:
        errors.append(f"{filename}: 'categories' must be a non-empty array when present")
        return errors

    seen = set()
    for category_value in categories:
        if category_value not in VALID_CATEGORIES:
            errors.append(
                f"{filename}: 'categories' contains invalid category '{category_value}'"
            )
        if category_value in seen:
            errors.append(f"{filename}: duplicate category '{category_value}'")
        seen.add(category_value)

    if isinstance(category, str) and category not in categories:
        errors.append(f"{filename}: 'categories' must include primary 'category'")

    return errors


def validate_release(release: object, filename: str, index: int) -> list[str]:
    prefix = f"{filename}: releases[{index}]"
    if not isinstance(release, dict):
        return [f"{prefix} must be an object"]

    errors = []
    for field in sorted(RELEASE_REQUIRED_FIELDS):
        if field not in release:
            errors.append(f"{prefix}: missing required field '{field}'")

    version = release.get("version")
    if version is not None and not (
        is_non_empty_string(version) and SEMVER_RE.match(version)
    ):
        errors.append(f"{prefix}: 'version' must be semver like 1.0.0")

    min_host_version = release.get("minHostVersion")
    if min_host_version is not None and not (
        is_non_empty_string(min_host_version) and SEMVER_RE.match(min_host_version)
    ):
        errors.append(f"{prefix}: 'minHostVersion' must be semver like 1.4.0")

    sdk_version = release.get("sdkCompatibilityVersion")
    if sdk_version is not None and sdk_version != "v1":
        errors.append(f"{prefix}: 'sdkCompatibilityVersion' must be 'v1'")

    size = release.get("size")
    if size is not None and not is_positive_int(size):
        errors.append(f"{prefix}: 'size' must be a positive integer")

    errors.extend(validate_https_url(release.get("downloadURL"), prefix, "downloadURL"))

    min_os_version = release.get("minOSVersion")
    if min_os_version is not None and not (
        is_non_empty_string(min_os_version) and OS_VERSION_RE.match(min_os_version)
    ):
        errors.append(f"{prefix}: 'minOSVersion' must look like 14.0 or 14.0.0")

    architectures = release.get("supportedArchitectures")
    if architectures is not None:
        if not isinstance(architectures, list) or not architectures:
            errors.append(f"{prefix}: 'supportedArchitectures' must be a non-empty array")
        else:
            for architecture in architectures:
                if architecture not in VALID_ARCHITECTURES:
                    errors.append(
                        f"{prefix}: unsupported architecture '{architecture}'"
                    )

    download_count = release.get("downloadCount")
    if download_count is not None and not is_non_negative_int(download_count):
        errors.append(f"{prefix}: 'downloadCount' must be a non-negative integer")

    published_at = release.get("publishedAt")
    if published_at is not None and not isinstance(published_at, str):
        errors.append(f"{prefix}: 'publishedAt' must be a string when present")

    return errors


def validate_plugin(plugin: dict, path: Path) -> list[str]:
    filename = str(path)
    errors = []

    for field in sorted(PLUGIN_REQUIRED_FIELDS):
        if field not in plugin:
            errors.append(f"{filename}: missing required field '{field}'")

    plugin_id = plugin.get("id")
    if plugin_id is not None:
        if not is_non_empty_string(plugin_id) or not PLUGIN_ID_RE.match(plugin_id):
            errors.append(f"{filename}: 'id' must be a valid reverse-domain identifier")
        elif "." not in plugin_id:
            errors.append(f"{filename}: 'id' must use reverse-domain form")
        elif path.name != f"{plugin_id}.json":
            errors.append(f"{filename}: filename must be '{plugin_id}.json'")

    if plugin.get("source") != "community":
        errors.append(f"{filename}: 'source' must be 'community'")

    for field in sorted(TOP_LEVEL_RELEASE_FIELDS):
        if field in plugin:
            errors.append(
                f"{filename}: '{field}' belongs inside releases[] for community entries"
            )

    for field in ["name", "author", "description"]:
        value = plugin.get(field)
        if value is not None and not is_non_empty_string(value):
            errors.append(f"{filename}: '{field}' must be a non-empty string")

    errors.extend(validate_categories(plugin, filename))
    errors.extend(validate_optional_localized_strings(plugin, filename))

    hosting = plugin.get("hosting")
    if hosting is not None and hosting not in VALID_HOSTING:
        errors.append(f"{filename}: 'hosting' must be 'local' or 'cloud'")

    requires_api_key = plugin.get("requiresAPIKey")
    if requires_api_key is not None and not isinstance(requires_api_key, bool):
        errors.append(f"{filename}: 'requiresAPIKey' must be boolean when present")

    download_count = plugin.get("downloadCount")
    if download_count is not None and not is_non_negative_int(download_count):
        errors.append(f"{filename}: 'downloadCount' must be a non-negative integer")

    releases = plugin.get("releases")
    if releases is not None:
        if not isinstance(releases, list) or not releases:
            errors.append(f"{filename}: 'releases' must be a non-empty array")
        else:
            seen_versions = set()
            for index, release in enumerate(releases):
                errors.extend(validate_release(release, filename, index))
                if isinstance(release, dict):
                    version = release.get("version")
                    if version in seen_versions:
                        errors.append(f"{filename}: duplicate release version '{version}'")
                    seen_versions.add(version)

    return errors


def version_key(value: object):
    core, _, pre = str(value).partition("-")
    core = core.split("+", 1)[0]
    core_tuple = tuple(int(part) if part.isdigit() else 0 for part in core.split("."))
    if not pre:
        return (core_tuple, 1, ())

    pre_tokens = []
    for token in pre.replace("+", ".").split("."):
        if token.isdigit():
            pre_tokens.append((0, int(token)))
        else:
            pre_tokens.append((1, token))
    return (core_tuple, 0, tuple(pre_tokens))


def normalized_plugin(plugin: dict) -> dict:
    result = copy.deepcopy(plugin)
    result["releases"] = sorted(
        result["releases"],
        key=lambda release: version_key(release.get("version")),
        reverse=True,
    )
    return result


def load_community_entries(community_dir: Path) -> tuple[list[dict], list[str]]:
    errors = []
    entries = []

    if not community_dir.exists():
        return [], [f"{community_dir}: directory not found"]

    json_files = sorted(community_dir.glob("*.json"))
    seen_ids = set()
    for path in json_files:
        plugin, load_errors = load_json(path)
        errors.extend(load_errors)
        if plugin is None:
            continue

        plugin_errors = validate_plugin(plugin, path)
        errors.extend(plugin_errors)

        plugin_id = plugin.get("id")
        if isinstance(plugin_id, str):
            if plugin_id in seen_ids:
                errors.append(f"{path}: duplicate plugin id '{plugin_id}'")
            seen_ids.add(plugin_id)

        if not plugin_errors:
            entries.append(normalized_plugin(plugin))

    return entries, errors


def load_base_registry(base_path: Path | None) -> tuple[dict, list[str]]:
    if base_path is None or not base_path.exists():
        return {"schemaVersion": 1, "plugins": []}, []

    registry, errors = load_json(base_path)
    if registry is None:
        return {"schemaVersion": 1, "plugins": []}, errors

    plugins = registry.get("plugins")
    if not isinstance(plugins, list):
        return registry, [f"{base_path}: 'plugins' must be an array"]
    return registry, []


def assemble_registry(base_registry: dict, community_entries: list[dict]) -> tuple[dict, list[str]]:
    errors = []
    official_entries = []
    official_ids = set()

    for plugin in base_registry.get("plugins", []):
        if not isinstance(plugin, dict):
            errors.append("base registry contains a non-object plugin entry")
            continue
        if plugin.get("source", "official") == "community":
            continue
        plugin_id = plugin.get("id")
        if isinstance(plugin_id, str):
            official_ids.add(plugin_id)
        official_entries.append(plugin)

    community_ids = {entry["id"] for entry in community_entries}
    collisions = sorted(official_ids & community_ids)
    for plugin_id in collisions:
        errors.append(f"community plugin id '{plugin_id}' collides with an official entry")

    if errors:
        return base_registry, errors

    return {
        "schemaVersion": base_registry.get("schemaVersion", 1),
        "plugins": official_entries
        + sorted(
            community_entries,
            key=lambda plugin: (plugin.get("name", "").lower(), plugin["id"]),
        ),
    }, []


def dump_registry(registry: dict) -> str:
    return json.dumps(registry, indent=2, ensure_ascii=False) + "\n"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate and assemble community plugin registry entries."
    )
    parser.add_argument(
        "--community-dir",
        type=Path,
        default=DEFAULT_COMMUNITY_DIR,
        help="Directory containing one community plugin JSON file per plugin.",
    )
    parser.add_argument(
        "--base",
        type=Path,
        help="Existing plugins-community-v1.json to preserve official entries from.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="Write assembled plugins-community-v1.json to this path.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    community_entries, errors = load_community_entries(args.community_dir)
    if errors:
        print("Community registry validation errors:", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1

    if args.base or args.output:
        base_registry, base_errors = load_base_registry(args.base)
        if base_errors:
            print("Base registry errors:", file=sys.stderr)
            for error in base_errors:
                print(f"  - {error}", file=sys.stderr)
            return 1

        registry, assemble_errors = assemble_registry(base_registry, community_entries)
        if assemble_errors:
            print("Community registry assembly errors:", file=sys.stderr)
            for error in assemble_errors:
                print(f"  - {error}", file=sys.stderr)
            return 1

        output = dump_registry(registry)
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(output)
            print(
                f"Wrote {len(community_entries)} community plugin(s) to {args.output}"
            )
        else:
            print(output, end="")
    else:
        noun = "entry" if len(community_entries) == 1 else "entries"
        print(f"Validated {len(community_entries)} community plugin registry {noun}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
