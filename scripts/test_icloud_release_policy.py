#!/usr/bin/env python3
"""Check that release entry points cannot bypass the production bridge profile."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class ICloudReleasePolicyTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        scripts = self.root / "scripts"
        scripts.mkdir()
        for name in ("archive_release.sh", "build-release-local.sh", "check_release_signing.sh"):
            shutil.copyfile(Path(__file__).with_name(name), scripts / name)
        self.environment = os.environ.copy()
        for name in ("MACOS_ICLOUD_HELPER_DEVELOPER_ID_PROVISIONING_PROFILE_PATH",
                     "MACOS_DEVELOPER_ID_PROVISIONING_PROFILE_PATH"):
            self.environment.pop(name, None)
        self.archive_arguments = [
            "--archive-path", str(self.root / "app.xcarchive"),
            "--export-path", str(self.root / "export"),
            "--release-tag", "v1.7.0-daily.20260909.1", "--build-number", "1",
        ]

    def run_script(self, name, arguments):
        return subprocess.run(
            ["bash", str(self.root / "scripts" / name), *arguments],
            env=self.environment, capture_output=True, text=True, timeout=5,
        )

    def test_removed_switch_is_rejected_by_every_entry_point(self):
        for name in ("archive_release.sh", "build-release-local.sh", "check_release_signing.sh"):
            with self.subTest(script=name):
                result = self.run_script(name, ["--without-icloud"])
                self.assertEqual(result.returncode, 2)
                self.assertIn("unknown option: --without-icloud", result.stderr)

    def test_archive_requires_profile_before_creating_outputs(self):
        result = self.run_script("archive_release.sh", self.archive_arguments)
        self.assertEqual(result.returncode, 2)
        self.assertIn("PROVISIONING_PROFILE_PATH is required", result.stderr)
        self.assertFalse((self.root / "app.xcarchive").exists())
        self.assertFalse((self.root / "export").exists())

    def test_archive_rejects_missing_profile_file(self):
        result = self.run_script(
            "archive_release.sh", self.archive_arguments + ["--profile", str(self.root / "missing.profile")]
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("provisioning profile not found", result.stderr)
        self.assertFalse((self.root / "app.xcarchive").exists())

    def assert_local_build_preserved(self, arguments, error):
        build = self.root / "build-release"
        build.mkdir()
        sentinel = build / "previous-build"
        sentinel.write_text("preserve me")
        result = self.run_script("build-release-local.sh", arguments)
        self.assertEqual(result.returncode, 2)
        self.assertIn(error, result.stderr)
        self.assertEqual(sentinel.read_text(), "preserve me")

    def test_local_build_requires_profile_before_removing_previous_build(self):
        self.assert_local_build_preserved([], "PROVISIONING_PROFILE_PATH is required")

    def test_local_build_rejects_missing_profile_before_removing_previous_build(self):
        self.assert_local_build_preserved(
            ["--profile", str(self.root / "missing.profile")], "provisioning profile not found"
        )


if __name__ == "__main__":
    unittest.main()
