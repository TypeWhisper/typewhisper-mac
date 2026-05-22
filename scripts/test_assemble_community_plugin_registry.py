#!/usr/bin/env python3
"""Tests for community plugin registry assembly."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from assemble_community_plugin_registry import assemble_registry, load_community_entries


TYPEWHISPER_RELEASE_URL = (
    "https://github.com/TypeWhisper/typewhisper-mac/releases/download/"
    "plugin-example-v1.0.0/ExamplePlugin.zip"
)


def community_entry(plugin_id: str = "com.example.plugin", **overrides) -> dict:
    entry = {
        "id": plugin_id,
        "source": "community",
        "name": "Example Plugin",
        "author": "Example Author",
        "description": "Example community plugin.",
        "category": "utility",
    }
    entry.update(overrides)
    return entry


def release(version: str = "1.0.0", download_url: str = TYPEWHISPER_RELEASE_URL) -> dict:
    return {
        "version": version,
        "minHostVersion": "1.4.0",
        "sdkCompatibilityVersion": "v1",
        "size": 1234,
        "downloadURL": download_url,
    }


class CommunityPluginRegistryAssemblyTests(unittest.TestCase):
    def test_source_only_community_entry_validates_without_releases(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "com.example.plugin.json"
            path.write_text(json.dumps(community_entry()) + "\n")

            entries, errors = load_community_entries(Path(tmp))

        self.assertEqual(errors, [])
        self.assertEqual(len(entries), 1)
        self.assertNotIn("releases", entries[0])

    def test_optional_link_metadata_is_preserved(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "com.example.plugin.json"
            path.write_text(
                json.dumps(
                    community_entry(
                        detailsURL="https://typewhisper.com/addons/example",
                        homepageURL="https://example.com",
                        iconURL="https://www.typewhisper.com/brand-logos/example/logo.svg",
                        iconDarkURL="https://www.typewhisper.com/brand-logos/example/logo-dark.svg",
                    )
                )
                + "\n"
            )

            entries, errors = load_community_entries(Path(tmp))

        self.assertEqual(errors, [])
        self.assertEqual(entries[0]["detailsURL"], "https://typewhisper.com/addons/example")
        self.assertEqual(entries[0]["homepageURL"], "https://example.com")
        self.assertEqual(entries[0]["iconURL"], "https://www.typewhisper.com/brand-logos/example/logo.svg")
        self.assertEqual(entries[0]["iconDarkURL"], "https://www.typewhisper.com/brand-logos/example/logo-dark.svg")

    def test_invalid_optional_link_metadata_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "com.example.plugin.json"
            path.write_text(
                json.dumps(
                    community_entry(
                        detailsURL="/addons/example",
                        homepageURL="mailto:plugins@example.com",
                        iconURL="/brand-logos/example/logo.svg",
                        iconDarkURL="ftp://example.com/icon.svg",
                    )
                )
                + "\n"
            )

            entries, errors = load_community_entries(Path(tmp))

        self.assertEqual(entries, [])
        self.assertTrue(
            any("absolute HTTP(S) URL" in error for error in errors),
            errors,
        )

    def test_external_release_url_is_rejected(self) -> None:
        external_url = (
            "https://github.com/contributor/example/releases/download/"
            "v1.0.0/ExamplePlugin.zip"
        )
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "com.example.plugin.json"
            path.write_text(
                json.dumps(community_entry(releases=[release(download_url=external_url)]))
                + "\n"
            )

            entries, errors = load_community_entries(Path(tmp))

        self.assertEqual(entries, [])
        self.assertTrue(
            any("TypeWhisper-owned GitHub Release asset" in error for error in errors),
            errors,
        )

    def test_unreleased_source_only_entry_is_not_published(self) -> None:
        base_registry = {
            "schemaVersion": 1,
            "plugins": [
                {
                    "id": "com.typewhisper.official",
                    "name": "Official",
                    "author": "TypeWhisper",
                    "description": "Official plugin.",
                    "category": "utility",
                    "releases": [release()],
                }
            ],
        }

        registry, errors = assemble_registry(base_registry, [community_entry()])

        self.assertEqual(errors, [])
        self.assertEqual(
            [plugin["id"] for plugin in registry["plugins"]],
            ["com.typewhisper.official"],
        )

    def test_metadata_only_entry_preserves_published_typewhisper_release(self) -> None:
        base_registry = {
            "schemaVersion": 1,
            "plugins": [
                {
                    "id": "com.example.plugin",
                    "source": "community",
                    "name": "Old Name",
                    "author": "Old Author",
                    "description": "Old description.",
                    "category": "utility",
                    "releases": [release()],
                }
            ],
        }
        source_entry = community_entry(name="Updated Name", author="Updated Author")

        registry, errors = assemble_registry(base_registry, [source_entry])

        self.assertEqual(errors, [])
        self.assertEqual(len(registry["plugins"]), 1)
        plugin = registry["plugins"][0]
        self.assertEqual(plugin["name"], "Updated Name")
        self.assertEqual(plugin["author"], "Updated Author")
        self.assertEqual(plugin["releases"], [release()])

    def test_base_community_external_release_is_rejected(self) -> None:
        base_registry = {
            "schemaVersion": 1,
            "plugins": [
                {
                    "id": "com.example.plugin",
                    "source": "community",
                    "name": "Example Plugin",
                    "author": "Example Author",
                    "description": "Example community plugin.",
                    "category": "utility",
                    "releases": [
                        release(
                            download_url=(
                                "https://example.com/releases/download/"
                                "v1.0.0/ExamplePlugin.zip"
                            )
                        )
                    ],
                }
            ],
        }

        _, errors = assemble_registry(base_registry, [community_entry()])

        self.assertTrue(
            any("TypeWhisper-owned GitHub Release asset" in error for error in errors),
            errors,
        )


if __name__ == "__main__":
    unittest.main()
