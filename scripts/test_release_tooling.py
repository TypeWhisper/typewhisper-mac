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

    def run_homebrew_update(self, cask_version, validation_buckets, cask_sha="0" * 64, cask_text=None,
                            open_prs=()):
        """Run the Homebrew step against a local tap and a mocked GitHub CLI.

        `open_prs` is what `gh pr list` reports as open pull requests against the tap's main.
        """
        script = next(step["run"] for step in self.workflow["jobs"]["update-homebrew"]["steps"]
                      if step["name"] == "Update Homebrew Cask")
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        real_git = subprocess.run(["which", "git"], check=True, capture_output=True, text=True).stdout.strip()
        git_env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.com",
                       GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.com")

        seed = root / "seed"
        (seed / "Casks").mkdir(parents=True)
        (seed / "Casks/typewhisper.rb").write_text(
            cask_text or f'cask "typewhisper" do\n  version "{cask_version}"\n  sha256 "{cask_sha}"\nend\n')
        for command in (["init", "-q", "-b", "main"], ["add", "."], ["commit", "-q", "-m", "seed"]):
            subprocess.run([real_git, *command], cwd=seed, env=git_env, check=True)
        tap = root / "tap.git"
        subprocess.run([real_git, "clone", "-q", "--bare", str(seed), str(tap)], check=True)

        bin_dir = root / "bin"
        bin_dir.mkdir()
        mocks = {
            # Stands in for the published DMG download.
            "curl": '#!/bin/sh\nwhile [ $# -gt 0 ]; do [ "$1" = "-o" ] && out="$2"; shift; done\nprintf dmg > "$out"\n',
            # Clones the local tap instead of github.com; every other command is real git.
            "git": f'#!/bin/sh\nif [ "$1" = "clone" ]; then exec "{real_git}" clone -q "{tap}" homebrew-tap; fi\nexec "{real_git}" "$@"\n',
            "gh": f"""#!/bin/sh
echo "$*" >> "{root}/gh.log"
case "$1 $2" in
  "pr list") echo '{json.dumps(list(open_prs))}' ;;
  "pr create") echo "https://github.com/TypeWhisper/homebrew-tap/pull/99" ;;
  "pr checks")
    case "$*" in
      *--required*) echo '[{{"name":"CLA","bucket":"pass"}}]' ;;
      *)
        count=$(cat "{root}/polls" 2>/dev/null || echo 0)
        echo $((count + 1)) > "{root}/polls"
        bucket=$(echo "{" ".join(validation_buckets)}" | cut -d' ' -f$((count + 1)))
        [ -n "$bucket" ] || bucket=$(echo "{" ".join(validation_buckets)}" | awk '{{print $NF}}')
        echo '[{{"name":"CLA","bucket":"pass"}},{{"name":"Validate Homebrew Cask","bucket":"'"$bucket"'"}}]' ;;
    esac ;;
  "pr merge") touch "{root}/merged" ;;
esac
""",
        }
        for name, body in mocks.items():
            (bin_dir / name).write_text(body)
            (bin_dir / name).chmod(0o700)

        work = root / "work"
        work.mkdir()
        env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", GH_TOKEN="dummy",
                   RELEASE_TAG="v9.9.9", TAP_REPO="TypeWhisper/homebrew-tap",
                   VALIDATION_CHECK="Validate Homebrew Cask", CHECK_TIMEOUT_SECONDS="20",
                   CHECK_POLL_SECONDS="0", GITHUB_RUN_ID="1", GITHUB_RUN_ATTEMPT="1")
        result = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", script], cwd=work, env=env,
                                capture_output=True, text=True, timeout=60)
        branches = sorted(subprocess.run([real_git, "--git-dir", str(tap), "branch", "--format=%(refname:short)"],
                                         check=True, capture_output=True, text=True).stdout.split())
        main_cask = subprocess.run([real_git, "--git-dir", str(tap), "show", "main:Casks/typewhisper.rb"],
                                   check=True, capture_output=True, text=True).stdout
        log = (root / "gh.log").read_text() if (root / "gh.log").exists() else ""
        return result, branches, main_cask, log, (root / "merged").exists()

    def test_homebrew_update_goes_through_a_pull_request(self):
        result, branches, main_cask, log, merged = self.run_homebrew_update("1.0.0", ["pending", "pass"])
        self.assertEqual(result.returncode, 0, result.stderr)
        # The tap's main branch is never pushed to; the change waits on a release branch.
        self.assertIn('version "1.0.0"', main_cask)
        self.assertEqual(branches, ["main", "release/typewhisper-9.9.9-1-1"])
        self.assertIn("pr create --repo TypeWhisper/homebrew-tap --base main --head release/typewhisper-9.9.9-1-1", log)
        # A rerun recognizes its own earlier pull requests by this body.
        self.assertIn("Opened by the release workflow of TypeWhisper/typewhisper-mac for v9.9.9", log)
        self.assertTrue(merged)
        self.assertLess(log.index("pr checks"), log.index("pr merge"))

    def test_homebrew_updates_for_one_release_never_overlap(self):
        concurrency = self.workflow["jobs"]["update-homebrew"]["concurrency"]
        self.assertEqual(concurrency, {"group": "homebrew-tap-${{ needs.prepare.outputs.tag }}",
                                       "cancel-in-progress": False})

    def test_homebrew_update_closes_pull_requests_of_earlier_attempts(self):
        ours = "Updates the cask. Opened by the release workflow of TypeWhisper/typewhisper-mac for v9.9.9."
        open_prs = [
            {"number": 97, "headRefName": "release/typewhisper-9.9.9-0-1", "isCrossRepository": False, "body": ours},
            # None of these were opened by the workflow, so none may be closed.
            {"number": 96, "headRefName": "release/typewhisper-9.9.9-5-1", "isCrossRepository": True, "body": ours},
            {"number": 93, "headRefName": "release/typewhisper-9.9.9-hotfix", "isCrossRepository": False,
             "body": ours},
            {"number": 92, "headRefName": "release/typewhisper-9.9.9-7-1", "isCrossRepository": False,
             "body": "Manual cask fix."},
            {"number": 95, "headRefName": "release/typewhisper-9.9.10-1-1", "isCrossRepository": False, "body": ours},
            {"number": 94, "headRefName": "seofood/unrelated", "isCrossRepository": False, "body": ""},
        ]
        result, branches, _, log, merged = self.run_homebrew_update("1.0.0", ["pass"], open_prs=open_prs)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("pr list --repo TypeWhisper/homebrew-tap --state open --base main --limit 1000", log)
        self.assertIn("pr close 97 --repo TypeWhisper/homebrew-tap --delete-branch", log)
        for number in (96, 95, 94, 93, 92):
            self.assertNotIn(f"pr close {number} ", log)
        # The fresh pull request is opened only after the stale one is closed.
        self.assertLess(log.index("pr close 97"), log.index("pr create"))
        self.assertEqual(branches, ["main", "release/typewhisper-9.9.9-1-1"])
        self.assertTrue(merged)

    def test_homebrew_update_does_not_merge_when_cask_validation_fails(self):
        result, _, _, log, merged = self.run_homebrew_update("1.0.0", ["pending", "fail"])
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("Validate Homebrew Cask", result.stderr)
        self.assertFalse(merged)
        self.assertNotIn("pr merge", log)

    def test_homebrew_update_is_a_no_op_when_the_cask_is_current(self):
        result, branches, _, log, merged = self.run_homebrew_update(
            "9.9.9", ["pass"], cask_sha=hashlib.sha256(b"dmg").hexdigest())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("nothing to update", result.stdout)
        self.assertEqual(branches, ["main"])
        self.assertEqual(log, "")
        self.assertFalse(merged)

    def test_homebrew_update_fails_when_the_cask_lines_cannot_be_rewritten(self):
        # Single quotes are valid Ruby but do not match the patterns the step rewrites.
        reformatted = "cask 'typewhisper' do\n  version '1.0.0'\n  sha256 '" + "0" * 64 + "'\nend\n"
        result, branches, main_cask, log, merged = self.run_homebrew_update("1.0.0", ["pass"], cask_text=reformatted)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("Could not set the cask version or SHA-256", result.stderr)
        self.assertEqual(branches, ["main"])
        self.assertEqual(main_cask, reformatted)
        self.assertEqual(log, "")
        self.assertFalse(merged)


if __name__ == "__main__":
    unittest.main()
