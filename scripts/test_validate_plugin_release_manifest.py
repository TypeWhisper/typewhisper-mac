#!/usr/bin/env python3
"""Regression tests for the minimum host of new plugin releases."""

import copy
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from validate_plugin_release_manifest import validate_manifest, validate_release_order


class PluginReleaseManifestTests(unittest.TestCase):
    def manifest(self, host="1.7.0"):
        return {
            "id": "com.typewhisper.example",
            "version": "1.2.3",
            "minHostVersion": host,
            "sdkCompatibilityVersion": "v1",
            "locality": "local",
        }

    def test_rejects_older_hosts(self):
        for host in ("1.5.0", "1.6.0", "1.6.99"):
            with self.subTest(host=host), self.assertRaisesRegex(ValueError, "1.7.0 or newer"):
                validate_manifest(self.manifest(host), "1.2.3")

    def test_accepts_current_and_newer_hosts(self):
        for host in ("1.7.0", "1.7.1", "1.10.0", "2.0.0"):
            with self.subTest(host=host):
                validate_manifest(self.manifest(host), "1.2.3")

    def test_prerelease_permission_does_not_change_manifest_version_format(self):
        for host in (None, 1.7, "1.7", "v1.7.0", "1.7.0-daily.20260908"):
            with self.subTest(host=host), self.assertRaisesRegex(ValueError, "release version"):
                validate_manifest(self.manifest(host))

    def test_release_version_must_match(self):
        with self.assertRaisesRegex(ValueError, "does not match release version"):
            validate_manifest(self.manifest(), "1.2.4")

    def test_sdk_compatibility_line_remains_required(self):
        for sdk in (None, "1.7.0", "v0", "v1-beta", "v2", "v10"):
            manifest = self.manifest()
            manifest["sdkCompatibilityVersion"] = sdk
            with self.subTest(sdk=sdk), self.assertRaisesRegex(ValueError, "must be 'v1'"):
                validate_manifest(manifest)

    def test_accepts_additive_model_import_capability_marker(self):
        manifest = self.manifest()
        manifest["sdkCompatibilityVersion"] = "v1-model-import"
        validate_manifest(manifest)

    def test_locality_is_required_and_known(self):
        for locality in ("local", "cloud", "configurable"):
            manifest = self.manifest()
            manifest["locality"] = locality
            with self.subTest(locality=locality):
                validate_manifest(manifest)
        for locality in (None, "", "Local", "hybrid", True):
            manifest = self.manifest()
            manifest["locality"] = locality
            with self.subTest(locality=locality), self.assertRaisesRegex(ValueError, "locality"):
                validate_manifest(manifest)

    def test_release_must_not_be_older_than_the_published_version(self):
        registry = {"plugins": [
            {"id": "com.typewhisper.other", "releases": [{"version": "9.0.0"}]},
            {"id": "com.typewhisper.example", "releases": [{"version": "1.2.3"}, {"version": "1.0.0"}]},
        ]}
        validate_release_order(self.manifest(), "1.2.3", registry)
        validate_release_order(self.manifest(), "1.2.4", registry)
        validate_release_order(self.manifest(), "1.2.4", {"plugins": []})
        with self.assertRaisesRegex(ValueError, "older than the published '1.2.3'"):
            validate_release_order(self.manifest(), "1.2.2", registry)
        with self.assertRaisesRegex(ValueError, "older than the published"):
            validate_release_order(self.manifest(), "1.2.3-rc.1", registry)

    def test_cli_compares_with_the_published_registry(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest_path = Path(directory) / "manifest.json"
            registry_path = Path(directory) / "plugins.json"
            manifest_path.write_text(json.dumps(self.manifest()))
            registry_path.write_text(json.dumps({"plugins": [
                {"id": "com.typewhisper.example", "releases": [{"version": "1.3.0"}]},
            ]}))
            result = subprocess.run(
                [sys.executable, str(Path(__file__).with_name("validate_plugin_release_manifest.py")),
                 str(manifest_path), "--version", "1.2.3", "--published-registry", str(registry_path)],
                capture_output=True, text=True
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("older than the published '1.3.0'", result.stderr)

    def test_validation_does_not_rewrite_metadata(self):
        manifest = self.manifest()
        original = copy.deepcopy(manifest)
        validate_manifest(manifest)
        self.assertEqual(manifest, original)

    def test_cli_checks_every_manifest_and_reports_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            paths = [Path(directory) / name for name in ("current.json", "old.json")]
            paths[0].write_text(json.dumps(self.manifest()))
            paths[1].write_text(json.dumps(self.manifest("1.6.0")))
            result = subprocess.run(
                [sys.executable, str(Path(__file__).with_name("validate_plugin_release_manifest.py")),
                 *map(str, paths)], capture_output=True, text=True
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("old.json", result.stderr)
            self.assertIn("1.7.0 or newer", result.stderr)


if __name__ == "__main__":
    unittest.main()
