#!/usr/bin/env python3
"""Tests for plugin registry metadata normalization."""

from __future__ import annotations

import copy
import unittest

from plugin_registry_metadata import (
    find_top_level_release_metadata,
    normalize_registry_release_metadata,
)


class PluginRegistryMetadataTests(unittest.TestCase):
    def test_normalization_removes_stale_top_level_release_metadata(self) -> None:
        registry = {
            "schemaVersion": 1,
            "plugins": [
                {
                    "id": "com.typewhisper.openai",
                    "name": "OpenAI",
                    "author": "TypeWhisper",
                    "description": "Cloud transcription.",
                    "category": "transcription",
                    "categories": ["transcription", "llm"],
                    "downloadCount": 10,
                    "version": "1.1.6",
                    "minHostVersion": "1.2.2",
                    "sdkCompatibilityVersion": "v1",
                    "size": 100,
                    "downloadURL": "https://example.com/openai-1.1.6.zip",
                    "releases": [
                        {
                            "version": "1.2.0",
                            "minHostVersion": "1.4.0",
                            "sdkCompatibilityVersion": "v1",
                            "size": 200,
                            "downloadURL": "https://example.com/openai-1.2.0.zip",
                        },
                        {
                            "version": "1.1.6",
                            "minHostVersion": "1.2.2",
                            "sdkCompatibilityVersion": "v1",
                            "size": 100,
                            "downloadURL": "https://example.com/openai-1.1.6.zip",
                        },
                    ],
                }
            ],
        }
        original_releases = copy.deepcopy(registry["plugins"][0]["releases"])

        findings = normalize_registry_release_metadata(registry)

        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0]["id"], "com.typewhisper.openai")
        self.assertEqual(
            findings[0]["staleFields"],
            ["downloadURL", "minHostVersion", "size", "version"],
        )
        plugin = registry["plugins"][0]
        for field in [
            "version",
            "minHostVersion",
            "sdkCompatibilityVersion",
            "minOSVersion",
            "supportedArchitectures",
            "size",
            "downloadURL",
        ]:
            self.assertNotIn(field, plugin)
        self.assertEqual(plugin["category"], "transcription")
        self.assertEqual(plugin["categories"], ["transcription", "llm"])
        self.assertEqual(plugin["downloadCount"], 10)
        self.assertEqual(plugin["releases"], original_releases)

    def test_normalization_is_idempotent(self) -> None:
        registry = {
            "schemaVersion": 1,
            "plugins": [
                {
                    "id": "com.typewhisper.ready",
                    "name": "Ready",
                    "author": "TypeWhisper",
                    "description": "Already normalized.",
                    "category": "utility",
                    "releases": [
                        {
                            "version": "1.0.0",
                            "minHostVersion": "1.4.0",
                            "sdkCompatibilityVersion": "v1",
                            "size": 10,
                            "downloadURL": "https://example.com/ready.zip",
                        }
                    ],
                }
            ],
        }

        self.assertEqual(normalize_registry_release_metadata(registry), [])
        self.assertEqual(find_top_level_release_metadata(registry), [])

    def test_flat_entry_top_level_release_metadata_is_not_preserved(self) -> None:
        registry = {
            "schemaVersion": 1,
            "plugins": [
                {
                    "id": "com.typewhisper.legacy-flat",
                    "name": "Legacy Flat",
                    "author": "TypeWhisper",
                    "description": "Flat legacy entry.",
                    "category": "utility",
                    "version": "1.0.0",
                    "minHostVersion": "1.2.0",
                    "sdkCompatibilityVersion": "v1",
                    "size": 10,
                    "downloadURL": "https://example.com/legacy.zip",
                }
            ],
        }

        findings = normalize_registry_release_metadata(registry)

        self.assertEqual(len(findings), 1)
        self.assertEqual(
            findings[0]["staleFields"],
            ["downloadURL", "minHostVersion", "sdkCompatibilityVersion", "size", "version"],
        )
        plugin = registry["plugins"][0]
        self.assertNotIn("version", plugin)
        self.assertNotIn("downloadURL", plugin)
        self.assertNotIn("releases", plugin)


if __name__ == "__main__":
    unittest.main()
