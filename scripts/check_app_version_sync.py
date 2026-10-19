#!/usr/bin/env python3
"""Checks that the direct and the Mac App Store edition carry the same version.

The direct app takes its version from the TypeWhisper target in
TypeWhisper.xcodeproj (daily tags read the first MARKETING_VERSION there), the
App Store edition from AppStore/Config/AppStore.xcconfig. Both ship every
release under the same number.

With --tag, also checks that a release tag (v1.8.0, v1.8.0-rc1,
v1.8.0-daily.20261019) names that version.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PBXPROJ = Path("TypeWhisper.xcodeproj/project.pbxproj")
APPSTORE_XCCONFIG = Path("AppStore/Config/AppStore.xcconfig")
APP_TARGET = "TypeWhisper"

OBJECT_START = re.compile(r"^(\t+)([0-9A-Z]{22,24})(?: /\*.*?\*/)? = \{$")
OBJECT_END = re.compile(r"^(\t*)\};$")
VERSION_SETTING = re.compile(r"\bMARKETING_VERSION = \"?([^\";]+)\"?;")
TAG_PATTERN = re.compile(r"^v(\d+\.\d+\.\d+)(?:-[A-Za-z0-9][A-Za-z0-9.-]*)?$")


class VersionSyncError(Exception):
    pass


def pbxproj_objects(text: str) -> dict[str, str]:
    """Maps the IDs of multi-line objects to their bodies (one-line objects are skipped).

    Indentation in the project is not always consistent, so an object ends at
    the first closing brace that is not indented deeper than its opening line.
    """
    objects: dict[str, str] = {}
    lines = text.splitlines()
    for index, line in enumerate(lines):
        start = OBJECT_START.match(line)
        if start is None:
            continue
        indent = len(start.group(1))
        end = index + 1
        while end < len(lines):
            closing = OBJECT_END.match(lines[end])
            if closing and len(closing.group(1)) <= indent:
                break
            end += 1
        body = "\n".join(lines[index + 1:end])
        # IDs also key plain dictionaries such as TargetAttributes; keep real objects.
        if re.search(r"^\t+isa = ", body, re.M):
            objects.setdefault(start.group(2), body)
    return objects


def pbxproj_versions(text: str, target: str = APP_TARGET) -> tuple[str | None, set[str]]:
    """Returns the first MARKETING_VERSION and the versions of the target's configurations."""
    first = VERSION_SETTING.search(text)
    objects = pbxproj_objects(text)

    config_list_id = None
    for body in objects.values():
        if "isa = PBXNativeTarget;" not in body:
            continue
        name = re.search(r"^\t+name = \"?([^\";]+)\"?;", body, re.M)
        if name and name.group(1) == target:
            config_list = re.search(r"buildConfigurationList = ([0-9A-Z]{22,24})", body)
            config_list_id = config_list.group(1) if config_list else None
            break
    if config_list_id is None or config_list_id not in objects:
        raise VersionSyncError(f"Target {target} not found in {PBXPROJ}")

    configurations = re.search(r"buildConfigurations = \((.*?)\);", objects[config_list_id], re.S)
    config_ids = re.findall(r"[0-9A-Z]{22,24}", configurations.group(1) if configurations else "")
    versions = set()
    for config_id in config_ids:
        setting = VERSION_SETTING.search(objects.get(config_id, ""))
        if setting is None:
            raise VersionSyncError(f"A {target} build configuration has no MARKETING_VERSION")
        versions.add(setting.group(1))
    if not versions:
        raise VersionSyncError(f"Target {target} has no build configurations")
    return (first.group(1) if first else None), versions


def xcconfig_version(text: str) -> str:
    match = re.search(r"^\s*MARKETING_VERSION\s*=\s*(\S+)\s*$", text, re.M)
    if match is None:
        raise VersionSyncError(f"No MARKETING_VERSION in {APPSTORE_XCCONFIG}")
    return match.group(1)


def check(pbxproj_text: str, xcconfig_text: str, tag: str | None = None) -> str:
    """Returns the shared version or raises VersionSyncError."""
    first, target_versions = pbxproj_versions(pbxproj_text)
    if len(target_versions) != 1:
        listed = ", ".join(sorted(target_versions))
        raise VersionSyncError(f"{APP_TARGET} build configurations disagree: {listed}")
    version = target_versions.pop()
    if first != version:
        raise VersionSyncError(
            f"The first MARKETING_VERSION in {PBXPROJ} is {first}, the {APP_TARGET} target has "
            f"{version}; daily tags read the first one"
        )

    appstore = xcconfig_version(xcconfig_text)
    if appstore != version:
        raise VersionSyncError(
            f"Direct app is {version} ({PBXPROJ}), App Store edition is {appstore} "
            f"({APPSTORE_XCCONFIG}); bump both together"
        )

    if tag is not None:
        match = TAG_PATTERN.match(tag)
        if match is None:
            raise VersionSyncError(f"Release tag {tag} is not vX.Y.Z or vX.Y.Z-suffix")
        if match.group(1) != version:
            raise VersionSyncError(
                f"Release tag {tag} names {match.group(1)}, but the app version is {version}"
            )
    return version


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--tag", help="release tag that must name the app version")
    parser.add_argument("--root", type=Path, default=REPO_ROOT, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)

    try:
        version = check(
            (args.root / PBXPROJ).read_text(encoding="utf-8"),
            (args.root / APPSTORE_XCCONFIG).read_text(encoding="utf-8"),
            args.tag,
        )
    except (OSError, VersionSyncError) as error:
        print(f"check_app_version_sync: {error}", file=sys.stderr)
        return 1
    suffix = f", tag {args.tag}" if args.tag else ""
    print(f"App version {version} matches in both editions{suffix}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
