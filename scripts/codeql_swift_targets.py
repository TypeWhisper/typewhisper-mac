#!/usr/bin/env python3
"""Select the Xcode targets the CodeQL Swift job builds.

Pushes, tags, the weekly schedule and manual runs build every target. A pull
request builds only what its Swift changes touch, so a plugin-only change does
not compile the app and 52 other plugins:

- changes to the CodeQL workflow, its scripts, the Xcode project or its base
  xcconfig, a package manifest or lock file, or Plugin SDK sources (the app and every plugin call
  into the SDK): every target
- app, extension or CLI sources: the app targets
- sources in `TypeWhisperPluginSDK/Plugins/<Name>/`: that plugin's target
- anything else (tests, docs, resources, the App Store edition): nothing

Sources are Swift files plus the C and Objective-C files and headers that
Swift imports through bridging headers or module maps.

Usage:
  codeql_swift_targets.py all
  codeql_swift_targets.py changed <file-with-changed-paths>

Prints `targets=<space-separated targets>` and `build=true|false` for
$GITHUB_OUTPUT. See docs/codeql-swift.md.
"""

from __future__ import annotations

import sys
from pathlib import Path

APP_TARGETS = (
    "TypeWhisper",
    "typewhisper-cli",
    "TypeWhisperICloudBridge",
    "TypeWhisperWidgetExtension",
    "TypeWhisperTranscribeAction",
)
APP_SOURCE_DIRS = (
    "TypeWhisper/",
    "typewhisper-cli/",
    "TypeWhisperICloudBridge/",
    "TypeWhisperTranscribeAction/",
    "TypeWhisperWidgetExtension/",
    "TypeWhisperWidgetShared/",
)
SDK_SOURCE_DIR = "TypeWhisperPluginSDK/Sources/TypeWhisperPluginSDK/"
PLUGINS_DIR = "TypeWhisperPluginSDK/Plugins/"
SOURCE_SUFFIXES = (".swift", ".h", ".c", ".m", ".mm", ".cpp", ".modulemap")
FULL_BUILD_PATHS = (
    ".github/workflows/codeql.yml",
    "scripts/codeql-build-swift.sh",
    "scripts/codeql_swift_coverage.py",
    "scripts/codeql_swift_targets.py",
    "TypeWhisper.xcodeproj/",
    # Base configuration of every project build configuration.
    "CodeSigning.xcconfig",
)
FULL_BUILD_FILE_NAMES = ("Package.swift", "Package.resolved")


def plugin_names(repo_root: Path) -> list[str]:
    return sorted(path.parent.name for path in (repo_root / PLUGINS_DIR).glob("*/manifest.json"))


def all_targets(plugins: list[str]) -> list[str]:
    return list(APP_TARGETS) + sorted(plugins)


def is_test_source(path: str) -> bool:
    return "/Tests/" in path or path.endswith("Tests.swift")


def select_targets(changed_paths: list[str], plugins: list[str]) -> list[str]:
    """Returns the targets to build for a pull request, in build order."""
    selected: set[str] = set()
    for path in changed_paths:
        if path.startswith(FULL_BUILD_PATHS) or Path(path).name in FULL_BUILD_FILE_NAMES:
            return all_targets(plugins)
        if not path.endswith(SOURCE_SUFFIXES) or is_test_source(path):
            continue
        if path.startswith(SDK_SOURCE_DIR):
            return all_targets(plugins)
        if path.startswith(APP_SOURCE_DIRS):
            selected.update(APP_TARGETS)
        elif path.startswith(PLUGINS_DIR):
            plugin = path[len(PLUGINS_DIR):].split("/", 1)[0]
            if plugin in plugins:
                selected.add(plugin)
    return [target for target in all_targets(plugins) if target in selected]


def main(argv: list[str]) -> int:
    repo_root = Path(__file__).resolve().parent.parent
    plugins = plugin_names(repo_root)
    if not plugins:
        print("error: no plugin manifests found", file=sys.stderr)
        return 1
    if argv == ["all"]:
        targets = all_targets(plugins)
    elif len(argv) == 2 and argv[0] == "changed":
        changed = [line.strip() for line in Path(argv[1]).read_text().splitlines() if line.strip()]
        targets = select_targets(changed, plugins)
    else:
        print(__doc__, file=sys.stderr)
        return 2
    print(f"targets={' '.join(targets)}")
    print(f"build={'true' if targets else 'false'}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
