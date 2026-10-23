#!/usr/bin/env python3
"""Tests for the CodeQL Swift target selection."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from codeql_swift_coverage import expected_areas
from codeql_swift_targets import APP_TARGETS, all_targets, select_targets

PLUGINS = ["GroqPlugin", "Qwen3Plugin", "WebhookPlugin"]


class SelectTargetsTests(unittest.TestCase):
    def test_plugin_change_builds_only_that_plugin(self) -> None:
        self.assertEqual(select_targets([
            "TypeWhisperPluginSDK/Plugins/Qwen3Plugin/Qwen3Plugin.swift",
            "TypeWhisperPluginSDK/Plugins/Qwen3Plugin/manifest.json",
        ], PLUGINS), ["Qwen3Plugin"])

    def test_app_change_builds_app_targets(self) -> None:
        self.assertEqual(select_targets(["TypeWhisper/Services/PluginManager.swift"], PLUGINS), list(APP_TARGETS))

    def test_app_and_plugin_changes_are_combined(self) -> None:
        self.assertEqual(select_targets([
            "typewhisper-cli/main.swift",
            "TypeWhisperPluginSDK/Plugins/GroqPlugin/GroqPlugin.swift",
        ], PLUGINS), list(APP_TARGETS) + ["GroqPlugin"])

    def test_sdk_change_builds_every_consumer(self) -> None:
        self.assertEqual(select_targets([
            "TypeWhisperPluginSDK/Sources/TypeWhisperPluginSDK/TypeWhisperPlugin.swift",
        ], PLUGINS), all_targets(PLUGINS))

    def test_bridged_c_and_objc_sources_build_app_targets(self) -> None:
        for path in [
            "TypeWhisper/TypeWhisper-Bridging-Header.h",
            "TypeWhisper/Services/ObjCExceptionCatcher.m",
            "TypeWhisper/Services/CoreAudioHALCallbackContext.c",
        ]:
            with self.subTest(path=path):
                self.assertEqual(select_targets([path], PLUGINS), list(APP_TARGETS))

    def test_build_inputs_force_a_full_build(self) -> None:
        for path in [
            ".github/workflows/codeql.yml",
            "scripts/codeql-build-swift.sh",
            "scripts/codeql_swift_targets.py",
            "TypeWhisper.xcodeproj/project.pbxproj",
            "CodeSigning.xcconfig",
            "TypeWhisper.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
            "TypeWhisperPluginSDK/Package.swift",
            "TypeWhisperPluginSDK/Package.resolved",
        ]:
            with self.subTest(path=path):
                self.assertEqual(select_targets([path], PLUGINS), all_targets(PLUGINS))

    def test_non_swift_and_test_changes_build_nothing(self) -> None:
        self.assertEqual(select_targets([
            "README.md",
            "docs/codeql-swift.md",
            "TypeWhisper/Resources/Localizable.xcstrings",
            "TypeWhisperTests/PluginManagerTests.swift",
            "TypeWhisperPluginSDK/Tests/TypeWhisperPluginSDKTests/ManifestTests.swift",
            "TypeWhisperPluginSDK/Plugins/GroqPlugin/Tests/GroqPluginTests.swift",
            "TypeWhisper/Services/HTTPServer/APIHandlersTargetLanguageTests.swift",
            ".github/workflows/build.yml",
        ], PLUGINS), [])

    def test_unknown_plugin_directory_is_ignored(self) -> None:
        self.assertEqual(select_targets(["TypeWhisperPluginSDK/Plugins/RemovedPlugin/Removed.swift"], PLUGINS), [])


class ExpectedAreasForTargetsTests(unittest.TestCase):
    TRACKED = [
        "TypeWhisper/App/main.swift",
        "typewhisper-cli/main.swift",
        "TypeWhisperPluginSDK/Sources/TypeWhisperPluginSDK/TypeWhisperPlugin.swift",
        "TypeWhisperPluginSDK/Plugins/GroqPlugin/GroqPlugin.swift",
        "TypeWhisperPluginSDK/Plugins/Qwen3Plugin/Qwen3Plugin.swift",
    ]

    def test_plugin_build_expects_sdk_and_that_plugin(self) -> None:
        areas = expected_areas(self.TRACKED, PLUGINS, ["Qwen3Plugin"])
        self.assertEqual(list(areas), [
            "TypeWhisperPluginSDK/Sources/TypeWhisperPluginSDK/",
            "TypeWhisperPluginSDK/Plugins/Qwen3Plugin/",
        ])

    def test_app_build_expects_app_areas_but_not_plugins(self) -> None:
        areas = expected_areas(self.TRACKED, PLUGINS, list(APP_TARGETS))
        self.assertIn("TypeWhisper/", areas)
        self.assertIn("typewhisper-cli/", areas)
        self.assertNotIn("TypeWhisperPluginSDK/Plugins/GroqPlugin/", areas)

    def test_default_expects_every_area(self) -> None:
        areas = expected_areas(self.TRACKED, PLUGINS)
        self.assertEqual(sum(len(files) for files in areas.values()), len(self.TRACKED))


if __name__ == "__main__":
    unittest.main()
