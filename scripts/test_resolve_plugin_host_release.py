#!/usr/bin/env python3

import json
import subprocess
import unittest
from unittest.mock import patch

from resolve_plugin_host_release import ReleaseResolutionError, resolve_host_release


def gh_result(
    *,
    returncode: int = 0,
    stdout: str = "",
    stderr: str = "",
) -> subprocess.CompletedProcess[str]:
    return subprocess.CompletedProcess(
        args=["gh"],
        returncode=returncode,
        stdout=stdout,
        stderr=stderr,
    )


def release_json(tag: str, *, prerelease: bool) -> str:
    return json.dumps(
        {
            "tagName": tag,
            "isDraft": False,
            "isPrerelease": prerelease,
            "assets": [{"name": f"TypeWhisper-{tag}.zip", "digest": "sha256:test"}],
        }
    )


class ResolvePluginHostReleaseTests(unittest.TestCase):
    @patch("resolve_plugin_host_release.run_gh")
    def test_prefers_exact_stable_release(self, mock_run_gh) -> None:
        mock_run_gh.side_effect = [
            gh_result(stdout="HTTP/2.0 200 OK\n"),
            gh_result(stdout=release_json("v1.7.0", prerelease=False)),
        ]

        release = resolve_host_release(
            "TypeWhisper/typewhisper-mac",
            "1.7.0",
            allow_prerelease_host=True,
        )

        self.assertEqual(release["tagName"], "v1.7.0")
        self.assertEqual(mock_run_gh.call_count, 2)

    @patch("resolve_plugin_host_release.run_gh")
    def test_falls_back_to_latest_matching_daily_after_404(self, mock_run_gh) -> None:
        releases = [
            {
                "tagName": "v1.7.0-daily.20260831",
                "isDraft": False,
                "isPrerelease": True,
                "publishedAt": "2026-08-31T10:00:00Z",
            },
            {
                "tagName": "v1.7.0-daily.20260901",
                "isDraft": False,
                "isPrerelease": True,
                "publishedAt": "2026-09-01T10:00:00Z",
            },
            {
                "tagName": "v1.6.0-daily.20260902",
                "isDraft": False,
                "isPrerelease": True,
                "publishedAt": "2026-09-02T10:00:00Z",
            },
        ]
        mock_run_gh.side_effect = [
            gh_result(
                returncode=1,
                stdout="HTTP/2.0 404 Not Found\n",
                stderr="gh: Not Found (HTTP 404)",
            ),
            gh_result(stdout=json.dumps(releases)),
            gh_result(stdout=release_json("v1.7.0-daily.20260901", prerelease=True)),
        ]

        release = resolve_host_release(
            "TypeWhisper/typewhisper-mac",
            "1.7.0",
            allow_prerelease_host=True,
        )

        self.assertEqual(release["tagName"], "v1.7.0-daily.20260901")

    @patch("resolve_plugin_host_release.run_gh")
    def test_propagates_non_404_lookup_failure(self, mock_run_gh) -> None:
        mock_run_gh.return_value = gh_result(
            returncode=1,
            stdout="HTTP/2.0 503 Service Unavailable\n",
            stderr="gh: service unavailable (HTTP 503)",
        )

        with self.assertRaisesRegex(ReleaseResolutionError, "without a 404"):
            resolve_host_release(
                "TypeWhisper/typewhisper-mac",
                "1.7.0",
                allow_prerelease_host=True,
            )

    @patch("resolve_plugin_host_release.run_gh")
    def test_rejects_exact_tag_prerelease(self, mock_run_gh) -> None:
        mock_run_gh.side_effect = [
            gh_result(stdout="HTTP/2.0 200 OK\n"),
            gh_result(stdout=release_json("v1.7.0", prerelease=True)),
        ]

        with self.assertRaisesRegex(ReleaseResolutionError, "must be stable"):
            resolve_host_release(
                "TypeWhisper/typewhisper-mac",
                "1.7.0",
                allow_prerelease_host=True,
            )


if __name__ == "__main__":
    unittest.main()
