#!/usr/bin/env python3
"""Tests for the CodeQL Swift extraction coverage check."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from codeql_swift_coverage import (
    EXTRACTED_FILES_RULE,
    EXTRACTION_ERRORS_RULE,
    coverage_report,
    expected_areas,
    extracted_files,
    notified_files,
)

REPO_ROOT = "/Users/runner/work/typewhisper-mac/typewhisper-mac"


def notification(uri: str, rule: str = EXTRACTED_FILES_RULE) -> dict:
    return {
        "descriptor": {"id": rule},
        "locations": [{"physicalLocation": {"artifactLocation": {"uri": uri}}}],
    }


def sarif(*notifications: dict) -> dict:
    return {"runs": [{"invocations": [{"toolExecutionNotifications": list(notifications)}]}]}


class ExtractedFilesTests(unittest.TestCase):
    def test_relative_and_absolute_uris_are_normalized(self) -> None:
        files = extracted_files(sarif(
            notification("TypeWhisper/App/main.swift"),
            notification(f"file://{REPO_ROOT}/TypeWhisperPluginSDK/Plugins/GroqPlugin/GroqPlugin.swift"),
        ), REPO_ROOT)
        self.assertEqual(files, {
            "TypeWhisper/App/main.swift",
            "TypeWhisperPluginSDK/Plugins/GroqPlugin/GroqPlugin.swift",
        })

    def test_other_diagnostics_are_ignored(self) -> None:
        files = extracted_files(sarif(
            notification("TypeWhisper/App/main.swift", rule=EXTRACTION_ERRORS_RULE),
        ), REPO_ROOT)
        self.assertEqual(files, set())

    def test_extraction_errors_are_collected_separately(self) -> None:
        report = sarif(
            notification("TypeWhisper/App/main.swift"),
            notification("TypeWhisper/App/main.swift", rule=EXTRACTION_ERRORS_RULE),
        )
        self.assertEqual(
            notified_files(report, REPO_ROOT, EXTRACTION_ERRORS_RULE),
            {"TypeWhisper/App/main.swift"},
        )


class CoverageReportTests(unittest.TestCase):
    TRACKED = [
        "TypeWhisper/App/main.swift",
        "TypeWhisper/Services/PluginManager.swift",
        "TypeWhisper/Services/HTTPServer/APIHandlersTargetLanguageTests.swift",
        "TypeWhisperPluginSDK/Plugins/GroqPlugin/GroqPlugin.swift",
        "TypeWhisperPluginSDK/Plugins/GroqPlugin/Tests/GroqPluginTests.swift",
        "TypeWhisperPluginSDK/Plugins/WebhookPlugin/WebhookPlugin.swift",
        "TypeWhisperTests/PluginManagerTests.swift",
    ]

    def test_plugin_tests_and_unlisted_directories_are_not_expected(self) -> None:
        areas = expected_areas(self.TRACKED, ["GroqPlugin", "WebhookPlugin"])
        self.assertEqual(areas["TypeWhisperPluginSDK/Plugins/GroqPlugin/"], [
            "TypeWhisperPluginSDK/Plugins/GroqPlugin/GroqPlugin.swift",
        ])
        expected = {path for files in areas.values() for path in files}
        self.assertNotIn("TypeWhisperTests/PluginManagerTests.swift", expected)
        self.assertNotIn("TypeWhisper/Services/HTTPServer/APIHandlersTargetLanguageTests.swift", expected)

    def test_plugin_without_extracted_files_is_reported(self) -> None:
        areas = expected_areas(self.TRACKED, ["GroqPlugin", "WebhookPlugin"])
        lines, missing = coverage_report(areas, {
            "TypeWhisper/App/main.swift",
            "TypeWhisper/Services/PluginManager.swift",
            "TypeWhisperPluginSDK/Plugins/GroqPlugin/GroqPlugin.swift",
        })
        self.assertEqual(missing, ["TypeWhisperPluginSDK/Plugins/WebhookPlugin/WebhookPlugin.swift"])
        self.assertIn(f"{'TypeWhisperPluginSDK/Plugins/WebhookPlugin/':<62} {0:>9} {1:>7}", lines)

    def test_partially_extracted_area_is_reported(self) -> None:
        # Explicit module builds once extracted 1 of 226 app files; a non-empty
        # area must not count as covered.
        areas = expected_areas(self.TRACKED, ["GroqPlugin", "WebhookPlugin"])
        _, missing = coverage_report(areas, {
            "TypeWhisper/App/main.swift",
            "TypeWhisperPluginSDK/Plugins/GroqPlugin/GroqPlugin.swift",
            "TypeWhisperPluginSDK/Plugins/WebhookPlugin/WebhookPlugin.swift",
        })
        self.assertEqual(missing, ["TypeWhisper/Services/PluginManager.swift"])

    def test_complete_extraction_has_no_missing_files(self) -> None:
        areas = expected_areas(self.TRACKED, ["GroqPlugin", "WebhookPlugin"])
        expected = {path for files in areas.values() for path in files}
        _, missing = coverage_report(areas, expected | {"TypeWhisperTests/PluginManagerTests.swift"})
        self.assertEqual(missing, [])


if __name__ == "__main__":
    unittest.main()
