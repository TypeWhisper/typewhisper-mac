#!/usr/bin/env python3
"""Exercise release-tool integrity failures and signing-asset cleanup without secrets."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import prepare_release_tools as tools


class ReleaseToolTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.payload = b"a test archive"
        self.lock = {"version": "2.9.6", "sha256": hashlib.sha256(self.payload).hexdigest()}

    def write_locks(self, app_version="2.9.6"):
        manifest = self.root / ".github/release-tools/sparkle.json"
        manifest.parent.mkdir(parents=True)
        manifest.write_text(json.dumps(self.lock))
        swift = self.root / tools.SWIFT_LOCK
        swift.parent.mkdir(parents=True)
        swift.write_text(json.dumps({"pins": [{"identity": "sparkle", "state": {"version": app_version}}]}))

    def test_checked_in_sparkle_version_matches_app(self):
        tools.sparkle_lock(tools.ROOT)

    def test_version_mismatch_stops_before_tool_preparation(self):
        self.write_locks(app_version="2.9.5")
        with patch.object(tools.subprocess, "run") as run:
            with self.assertRaisesRegex(ValueError, "must match"):
                tools.prepare(self.root / "output", self.root)
        run.assert_not_called()
        self.assertFalse((self.root / "output").exists())

    def test_invalid_digest_rejected(self):
        self.lock["sha256"] = "not a digest"
        self.write_locks()
        with self.assertRaisesRegex(ValueError, "Invalid Sparkle SHA"):
            tools.sparkle_lock(self.root)

    def download(self, command, **kwargs):
        if command[0] == "curl":
            Path(command[command.index("--output") + 1]).write_bytes(self.payload)

    def test_corrupt_download_is_never_extracted_or_executed(self):
        self.lock["sha256"] = "0" * 64
        with patch.object(tools.subprocess, "run", side_effect=self.download) as run:
            with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                tools.prepare_sparkle(self.root, self.lock)
        self.assertEqual([call.args[0][0] for call in run.call_args_list], ["curl"])
        self.assertFalse((self.root / "sparkle").exists())

    def test_http_failure_is_never_extracted_or_executed(self):
        with patch.object(tools.subprocess, "run", side_effect=subprocess.CalledProcessError(22, "curl")) as run:
            with self.assertRaises(subprocess.CalledProcessError):
                tools.prepare_sparkle(self.root, self.lock)
        self.assertEqual(run.call_count, 1)
        command = run.call_args.args[0]
        self.assertIn("--fail", command)
        self.assertEqual(command[command.index("--proto-redir") + 1], "=https")

    def test_valid_download_is_extracted_then_smoke_tested(self):
        with patch.object(tools.subprocess, "run", side_effect=self.download) as run:
            tools.prepare_sparkle(self.root, self.lock)
        commands = [call.args[0] for call in run.call_args_list]
        self.assertEqual(commands[1][:2], ["tar", "-xf"])
        self.assertEqual(commands[2], [str(self.root / "sparkle/bin/sign_update"), "--help"])

    def test_python_install_requires_hashes_and_wheels(self):
        self.write_locks()
        with patch.object(tools.subprocess, "run", side_effect=self.download) as run:
            tools.prepare(self.root / "output", self.root)
        commands = [call.args[0] for call in run.call_args_list]
        install = next(command for command in commands if "install" in command)
        self.assertIn("--require-hashes", install)
        self.assertIn("--only-binary=:all:", install)
        self.assertNotIn("--upgrade", install)
        self.assertTrue(any(command[-1] == "check" for command in commands))


class CleanupTests(unittest.TestCase):
    def test_partial_import_and_keychain_failure_still_remove_all_key_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            files = ["typewhisper-signing.p12", "typewhisper-notary-app.p8",
                     "typewhisper-notary-dmg.p8", "TypeWhisperICloudBridge.provisionprofile"]
            for name in files + ["typewhisper-signing.keychain-db"]:
                (root / name).write_text("test fixture")
            security = root / "security"
            security.write_text('#!/bin/sh\nexit 17\n')
            security.chmod(0o700)
            env = dict(os.environ, RUNNER_TEMP=directory, PATH=f"{directory}:{os.environ['PATH']}")
            result = subprocess.run(["bash", str(tools.ROOT / "scripts/cleanup_release_signing.sh")], env=env)
            self.assertEqual(result.returncode, 17)
            for name in files + ["typewhisper-signing.keychain-db"]:
                self.assertFalse((root / name).exists(), name)

    def test_cleanup_is_safe_before_import_and_when_repeated(self):
        with tempfile.TemporaryDirectory() as directory:
            env = dict(os.environ, RUNNER_TEMP=directory)
            for _ in range(2):
                subprocess.run(["bash", str(tools.ROOT / "scripts/cleanup_release_signing.sh")], env=env, check=True)


class WorkflowPolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Ruby/Psych ships on both policy runners; no mutable PyYAML install is needed.
        result = subprocess.run([
            "ruby", "-rjson", "-ryaml", "-rdate", "-e",
            "puts JSON.generate(YAML.load_file(ARGV[0]))",
            str(tools.ROOT / ".github/workflows/release.yml"),
        ], check=True, capture_output=True, text=True)
        cls.workflow = json.loads(result.stdout)

    def test_preparation_precedes_secrets_and_no_late_tool_downloads(self):
        steps = self.workflow["jobs"]["build"]["steps"]
        preparation = next(i for i, step in enumerate(steps) if step["name"] == "Prepare Verified Release Tools")
        first_secret = next(i for i, step in enumerate(steps) if "secrets." in json.dumps(step))
        self.assertLess(preparation, first_secret)
        for step in steps[first_secret:]:
            command = step.get("run", "")
            self.assertNotIn("pip install", command)
            self.assertNotIn("curl ", command)
        cleanup = next(step for step in steps if step["name"] == "Cleanup Signing Assets")
        self.assertEqual(cleanup["if"], "always()")

    def test_checkout_never_persists_credentials_and_only_publisher_can_write(self):
        self.assertEqual(self.workflow["permissions"], {"contents": "read"})
        for name, job in self.workflow["jobs"].items():
            if name == "build":
                self.assertEqual(job["permissions"], {"contents": "write"})
            else:
                self.assertNotIn("write", job.get("permissions", {}).values())
            for step in job["steps"]:
                if step.get("uses", "").startswith("actions/checkout@"):
                    self.assertIs(step["with"]["persist-credentials"], False)

    def test_notary_failure_and_cancellation_remove_key_files(self):
        for name in ("Notarize App", "Notarize DMG"):
            script = next(step["run"] for step in self.workflow["jobs"]["build"]["steps"] if step["name"] == name)
            for cancelled in (False, True):
                with self.subTest(step=name, cancelled=cancelled), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    (root / "build/export").mkdir(parents=True)
                    # Simulate notarytool failing or delivering TERM to the workflow shell.
                    mock = root / "xcrun"
                    mock.write_text("#!/bin/sh\n" + ("kill -TERM \"$PPID\"\nexit 0\n" if cancelled else "exit 42\n"))
                    mock.chmod(0o700)
                    ditto = root / "ditto"
                    ditto.write_text("#!/bin/sh\nexit 0\n")
                    ditto.chmod(0o700)
                    env = dict(os.environ, RUNNER_TEMP=directory, RELEASE_TAG="v0.0.0-test",
                               APPLE_API_KEY_P8="dummy-key", APPLE_API_KEY_ID="dummy-id",
                               APPLE_API_ISSUER_ID="dummy-issuer", PATH=f"{directory}:{os.environ['PATH']}")
                    result = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", script], cwd=root, env=env,
                                            capture_output=True, text=True, timeout=5)
                    self.assertEqual(result.returncode, 143 if cancelled else 42, result.stderr)
                    self.assertEqual(list(root.glob("*.p8")), [])

    def test_notary_keys_removed_on_exit_and_termination(self):
        for step in self.workflow["jobs"]["build"]["steps"]:
            if step["name"] in ("Notarize App", "Notarize DMG"):
                command = step["run"]
                self.assertLess(command.index("umask 077"), command.index('> "$KEY_PATH"'))
                self.assertIn('trap \'rm -f "$KEY_PATH"\' EXIT', command)
                self.assertIn("trap 'exit 130' INT", command)
                self.assertIn("trap 'exit 143' TERM", command)


if __name__ == "__main__":
    unittest.main()
