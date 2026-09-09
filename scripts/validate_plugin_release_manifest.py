#!/usr/bin/env python3
"""Validate manifests for newly built TypeWhisper plugin releases."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


MINIMUM_HOST_VERSION = (1, 7, 0)


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
    if not isinstance(sdk_version, str) or not re.fullmatch(r"v[1-9][0-9]*", sdk_version):
        raise ValueError(
            f"manifest sdkCompatibilityVersion {sdk_version!r} must use the format vN"
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path, nargs="+")
    parser.add_argument("--version", help="Expected plugin release version")
    args = parser.parse_args()
    for path in args.manifest:
        try:
            manifest = json.loads(path.read_text())
            if not isinstance(manifest, dict):
                raise ValueError("manifest must be a JSON object")
            validate_manifest(manifest, args.version)
        except (OSError, ValueError) as error:
            print(f"error: {path}: {error}", file=sys.stderr)
            return 1
        print(f"Validated {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
