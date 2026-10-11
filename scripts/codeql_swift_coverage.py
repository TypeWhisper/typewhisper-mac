#!/usr/bin/env python3
"""Check which first-party Swift sources a CodeQL Swift analysis extracted.

Reads the SARIF written by github/codeql-action/analyze and compares the files
CodeQL reports as successfully extracted with the tracked Swift sources of the
app, its extensions, the Plugin SDK and every plugin that has a manifest.json.
Prints a per-area table and fails when any of those files was not extracted,
so a build that silently skips the app, a plugin or part of a target is not
reported as a success.
See docs/codeql-swift.md.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from urllib.parse import unquote, urlparse

EXTRACTED_FILES_RULE = "swift/diagnostics/successfully-extracted-files"
EXTRACTION_ERRORS_RULE = "swift/diagnostics/extraction-errors"

# Areas outside TypeWhisperPluginSDK/Plugins that the Swift build must cover.
APP_AREAS = (
    "TypeWhisper/",
    "typewhisper-cli/",
    "TypeWhisperICloudBridge/",
    "TypeWhisperTranscribeAction/",
    "TypeWhisperWidgetExtension/",
    "TypeWhisperWidgetShared/",
    "TypeWhisperPluginSDK/Sources/TypeWhisperPluginSDK/",
)
PLUGINS_DIR = "TypeWhisperPluginSDK/Plugins/"


def expected_areas(tracked_swift_files: list[str], plugin_names: list[str]) -> dict[str, list[str]]:
    areas = list(APP_AREAS) + [f"{PLUGINS_DIR}{name}/" for name in sorted(plugin_names)]
    result: dict[str, list[str]] = {area: [] for area in areas}
    for path in tracked_swift_files:
        # Test sources belong to test targets, which the CodeQL build does not compile.
        if "/Tests/" in path or path.endswith("Tests.swift"):
            continue
        for area in areas:
            if path.startswith(area):
                result[area].append(path)
                break
    return result


def normalize_uri(uri: str, repo_root: str) -> str:
    if uri.startswith("file:"):
        uri = unquote(urlparse(uri).path)
    root = repo_root.rstrip("/") + "/"
    if uri.startswith(root):
        uri = uri[len(root):]
    return uri.lstrip("/")


def notified_files(sarif: dict, repo_root: str, rule: str) -> set[str]:
    files: set[str] = set()
    for run in sarif.get("runs", []):
        for invocation in run.get("invocations", []):
            for notification in invocation.get("toolExecutionNotifications", []):
                if notification.get("descriptor", {}).get("id") != rule:
                    continue
                for location in notification.get("locations", []):
                    uri = location.get("physicalLocation", {}).get("artifactLocation", {}).get("uri")
                    if uri:
                        files.add(normalize_uri(uri, repo_root))
    return files


def extracted_files(sarif: dict, repo_root: str) -> set[str]:
    return notified_files(sarif, repo_root, EXTRACTED_FILES_RULE)


def coverage_report(areas: dict[str, list[str]], extracted: set[str]) -> tuple[list[str], list[str]]:
    """Returns the table lines and the tracked files that were not extracted."""
    lines = [f"{'Area':<62} {'extracted':>9} {'tracked':>7}"]
    missing = []
    for area, tracked in areas.items():
        hits = [path for path in tracked if path in extracted]
        lines.append(f"{area:<62} {len(hits):>9} {len(tracked):>7}")
        missing.extend(sorted(set(tracked) - extracted))
    return lines, missing


def tracked_swift_files(repo_root: Path) -> list[str]:
    output = subprocess.run(
        ["git", "-C", str(repo_root), "ls-files", "*.swift"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return [line for line in output.splitlines() if line]


def plugin_names(repo_root: Path) -> list[str]:
    return sorted(path.parent.name for path in (repo_root / PLUGINS_DIR).glob("*/manifest.json"))


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("sarif", type=Path, help="SARIF file written by codeql-action/analyze")
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args(argv)

    repo_root = args.repo_root.resolve()
    sarif = json.loads(args.sarif.read_text())
    extracted = extracted_files(sarif, str(repo_root))
    areas = expected_areas(tracked_swift_files(repo_root), plugin_names(repo_root))
    lines, missing = coverage_report(areas, extracted)

    print("\n".join(lines))
    total_tracked = sum(len(files) for files in areas.values())
    total_hits = sum(1 for files in areas.values() for path in files if path in extracted)
    print(f"\nExtracted {total_hits} of {total_tracked} first-party Swift files in {len(areas)} areas "
          f"({len(extracted)} Swift files reported by CodeQL in total).")

    # The extractor's own Swift frontend can report compiler errors for files that
    # Xcode built and CodeQL still extracted; list them without failing the job.
    tracked = {path for files in areas.values() for path in files}
    for path in sorted(notified_files(sarif, str(repo_root), EXTRACTION_ERRORS_RULE) & tracked):
        print(f"::warning file={path}::CodeQL reported Swift extraction errors in this file")

    if not extracted:
        print(f"error: SARIF contains no '{EXTRACTED_FILES_RULE}' notifications", file=sys.stderr)
        return 1
    if missing:
        print(f"error: {len(missing)} first-party Swift files were not extracted:", file=sys.stderr)
        for path in missing:
            print(f"  {path}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
