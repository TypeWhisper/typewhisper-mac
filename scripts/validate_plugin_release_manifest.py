#!/usr/bin/env python3
"""Validate manifests for newly built TypeWhisper plugin releases."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


MINIMUM_HOST_VERSION = (1, 7, 0)
VALID_LOCALITIES = ("local", "cloud", "configurable")


def validate_manifest(manifest: dict, expected_version: str | None = None) -> None:
    if expected_version is not None and manifest.get("version") != expected_version:
        raise ValueError(
            f"manifest version {manifest.get('version')!r} does not match "
            f"release version {expected_version!r}"
        )

    minimum = ".".join(str(part) for part in MINIMUM_HOST_VERSION)
    min_host_version = manifest.get("minHostVersion")
    if not isinstance(min_host_version, str) or not re.fullmatch(
        r"[0-9]+\.[0-9]+\.[0-9]+", min_host_version
    ):
        raise ValueError(
            f"manifest minHostVersion {min_host_version!r} must be a release version like {minimum}"
        )
    if tuple(int(part) for part in min_host_version.split(".")) < MINIMUM_HOST_VERSION:
        raise ValueError(
            f"manifest minHostVersion {min_host_version!r} must be {minimum} or newer"
        )

    sdk_version = manifest.get("sdkCompatibilityVersion")
    if sdk_version not in ("v1", "v1-model-import"):
        raise ValueError(
            f"manifest sdkCompatibilityVersion {sdk_version!r} must be 'v1' or 'v1-model-import'"
        )

    locality = manifest.get("locality")
    if locality not in VALID_LOCALITIES:
        raise ValueError(
            f"manifest locality {locality!r} must be one of {', '.join(VALID_LOCALITIES)}"
        )


def version_key(value: str) -> tuple:
    """Orders versions like the release workflow: pre-releases sort before their release."""
    core, _, pre = str(value).partition("-")
    core = core.split("+", 1)[0]
    core_tuple = tuple(int(part) if part.isdigit() else 0 for part in core.split("."))
    if not pre:
        return (core_tuple, 1, ())
    tokens = []
    for token in pre.replace("+", ".").split("."):
        tokens.append((0, int(token)) if token.isdigit() else (1, token))
    return (core_tuple, 0, tuple(tokens))


def validate_release_order(manifest: dict, version: str, registry: dict) -> None:
    """Refuses a release older than one already published for the same plugin.

    Hosts install the newest compatible release, so an older version would never reach anyone.
    Publishing the same version again stays allowed for re-runs.
    """
    for plugin in registry.get("plugins", []):
        if not isinstance(plugin, dict) or plugin.get("id") != manifest.get("id"):
            continue
        newer = [
            release["version"]
            for release in plugin.get("releases", [])
            if isinstance(release, dict)
            and isinstance(release.get("version"), str)
            and version_key(release["version"]) > version_key(version)
        ]
        if newer:
            raise ValueError(
                f"release version {version!r} is older than the published "
                f"{max(newer, key=version_key)!r}; bump the manifest version"
            )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path, nargs="+")
    parser.add_argument("--version", help="Expected plugin release version")
    parser.add_argument(
        "--published-registry",
        type=Path,
        help="Plugin feed already published; the release must not be older than its entries",
    )
    args = parser.parse_args()
    registry = None
    if args.published_registry is not None:
        try:
            registry = json.loads(args.published_registry.read_text())
        except (OSError, ValueError) as error:
            print(f"error: {args.published_registry}: {error}", file=sys.stderr)
            return 1
    for path in args.manifest:
        try:
            manifest = json.loads(path.read_text())
            if not isinstance(manifest, dict):
                raise ValueError("manifest must be a JSON object")
            validate_manifest(manifest, args.version)
            if registry is not None:
                validate_release_order(manifest, args.version or manifest.get("version", ""), registry)
        except (OSError, ValueError) as error:
            print(f"error: {path}: {error}", file=sys.stderr)
            return 1
        print(f"Validated {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
