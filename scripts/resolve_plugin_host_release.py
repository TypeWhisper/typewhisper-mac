#!/usr/bin/env python3

import argparse
import json
import re
import subprocess
import sys
from typing import Any


class ReleaseResolutionError(RuntimeError):
    pass


def run_gh(arguments: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["gh", *arguments],
        capture_output=True,
        check=False,
        text=True,
    )


def require_success(
    result: subprocess.CompletedProcess[str],
    operation: str,
) -> str:
    if result.returncode == 0:
        return result.stdout

    detail = result.stderr.strip() or result.stdout.strip() or "unknown gh error"
    raise ReleaseResolutionError(f"{operation} failed: {detail}")


def response_status_code(headers: str) -> int | None:
    matches = re.findall(r"^HTTP/\S+\s+(\d{3})\b", headers, flags=re.MULTILINE)
    return int(matches[-1]) if matches else None


def exact_release_exists(repository: str, tag: str) -> bool:
    result = run_gh(
        [
            "api",
            "--include",
            "--silent",
            f"repos/{repository}/releases/tags/{tag}",
        ]
    )
    if result.returncode == 0:
        return True
    if response_status_code(result.stdout) == 404:
        return False

    detail = result.stderr.strip() or result.stdout.strip() or "unknown gh error"
    raise ReleaseResolutionError(
        f"lookup for host release {tag} failed without a 404: {detail}"
    )


def load_release(repository: str, tag: str) -> dict[str, Any]:
    output = require_success(
        run_gh(
            [
                "release",
                "view",
                tag,
                "--repo",
                repository,
                "--json",
                "tagName,isDraft,isPrerelease,assets",
            ]
        ),
        f"loading host release {tag}",
    )
    try:
        release = json.loads(output)
    except json.JSONDecodeError as error:
        raise ReleaseResolutionError(
            f"host release {tag} returned invalid JSON: {error}"
        ) from error
    if not isinstance(release, dict):
        raise ReleaseResolutionError(f"host release {tag} did not return an object")
    return release


def list_releases(repository: str) -> list[dict[str, Any]]:
    output = require_success(
        run_gh(
            [
                "release",
                "list",
                "--repo",
                repository,
                "--limit",
                "100",
                "--json",
                "tagName,isDraft,isPrerelease,publishedAt",
            ]
        ),
        "listing host releases",
    )
    try:
        releases = json.loads(output)
    except json.JSONDecodeError as error:
        raise ReleaseResolutionError(
            f"host release list returned invalid JSON: {error}"
        ) from error
    if not isinstance(releases, list):
        raise ReleaseResolutionError("host release list did not return an array")
    return [release for release in releases if isinstance(release, dict)]


def validate_release(
    release: dict[str, Any],
    minimum_host_version: str,
    *,
    expected_kind: str,
) -> None:
    tag = release.get("tagName")
    stable_tag = f"v{minimum_host_version}"
    daily_prefix = f"{stable_tag}-daily."

    if release.get("isDraft") is not False:
        raise ReleaseResolutionError(f"host release {tag!r} must be published")
    if expected_kind == "stable":
        if tag != stable_tag or release.get("isPrerelease") is not False:
            raise ReleaseResolutionError(
                f"host release {stable_tag} must be stable, not a prerelease"
            )
    elif expected_kind == "daily":
        if (
            not isinstance(tag, str)
            or not tag.startswith(daily_prefix)
            or release.get("isPrerelease") is not True
        ):
            raise ReleaseResolutionError(
                f"daily host release {tag!r} must match {daily_prefix}* and be a prerelease"
            )
    else:
        raise ReleaseResolutionError(f"unknown host release kind: {expected_kind}")

    expected_asset = f"TypeWhisper-{tag}.zip"
    assets = release.get("assets")
    if not isinstance(assets, list):
        raise ReleaseResolutionError(f"host release {tag} has no asset list")
    matching_assets = [
        asset
        for asset in assets
        if isinstance(asset, dict) and asset.get("name") == expected_asset
    ]
    if len(matching_assets) != 1:
        raise ReleaseResolutionError(
            f"host release {tag} must contain exactly one {expected_asset} asset"
        )


def resolve_host_release(
    repository: str,
    minimum_host_version: str,
    *,
    allow_prerelease_host: bool,
) -> dict[str, Any]:
    stable_tag = f"v{minimum_host_version}"
    if exact_release_exists(repository, stable_tag):
        release = load_release(repository, stable_tag)
        validate_release(release, minimum_host_version, expected_kind="stable")
        return release

    if not allow_prerelease_host:
        raise ReleaseResolutionError(
            f"no published TypeWhisper release found for minHostVersion "
            f"{minimum_host_version} ({stable_tag})"
        )

    daily_prefix = f"{stable_tag}-daily."
    candidates = [
        release
        for release in list_releases(repository)
        if release.get("isDraft") is False
        and release.get("isPrerelease") is True
        and isinstance(release.get("tagName"), str)
        and release["tagName"].startswith(daily_prefix)
        and isinstance(release.get("publishedAt"), str)
    ]
    if not candidates:
        raise ReleaseResolutionError(
            f"no published daily TypeWhisper release found for minHostVersion "
            f"{minimum_host_version}"
        )

    selected = max(candidates, key=lambda release: release["publishedAt"])
    release = load_release(repository, selected["tagName"])
    validate_release(release, minimum_host_version, expected_kind="daily")
    return release


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", required=True)
    parser.add_argument("--min-host-version", required=True)
    parser.add_argument("--allow-prerelease-host", action="store_true")
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    try:
        release = resolve_host_release(
            arguments.repository,
            arguments.min_host_version,
            allow_prerelease_host=arguments.allow_prerelease_host,
        )
    except ReleaseResolutionError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    print(json.dumps(release, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
