#!/usr/bin/env python3

import unittest
from unittest.mock import patch

from verify_appcast_publication import (
    PublicationExpectation,
    cache_max_age,
    verify_appcast,
    verify_response,
    wait_for_publication,
)


def appcast_item(
    *,
    version: str,
    build_version: str,
    channel: str | None,
    download_url: str,
    signature: str = "test-signature",
    length: str = "1234",
) -> bytes:
    channel_element = f"<sparkle:channel>{channel}</sparkle:channel>" if channel else ""
    return f"""<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <item>
      <sparkle:version>{build_version}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      {channel_element}
      <enclosure url="{download_url}" sparkle:edSignature="{signature}" length="{length}" />
    </item>
  </channel>
</rss>
""".encode()


class CacheControlTests(unittest.TestCase):
    def test_reads_max_age(self) -> None:
        self.assertEqual(cache_max_age("public, max-age=600"), 600)
        self.assertEqual(cache_max_age('max-age="60", must-revalidate'), 60)

    def test_returns_none_without_max_age(self) -> None:
        self.assertIsNone(cache_max_age("no-cache"))


class AppcastVerificationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.download_url = (
            "https://github.com/TypeWhisper/typewhisper-mac/releases/download/"
            "v1.6.0-daily.20260714/TypeWhisper-v1.6.0-daily.20260714.zip"
        )
        self.expected = PublicationExpectation(
            version="1.6.0-daily.20260714",
            build_version="961",
            channel="daily",
            download_url=self.download_url,
            signature="test-signature",
            length="1234",
        )

    def test_accepts_matching_preview_release(self) -> None:
        body = appcast_item(
            version=self.expected.version,
            build_version=self.expected.build_version,
            channel=self.expected.channel,
            download_url=self.download_url,
        )

        verified, detail = verify_appcast(body, self.expected)

        self.assertTrue(verified, detail)

    def test_accepts_stable_release_without_channel_element(self) -> None:
        expected = PublicationExpectation(
            version="1.6.0",
            build_version="1000",
            channel="stable",
            download_url="https://example.com/TypeWhisper-v1.6.0.zip",
        )
        body = appcast_item(
            version=expected.version,
            build_version=expected.build_version,
            channel=None,
            download_url=expected.download_url,
        )

        verified, detail = verify_appcast(body, expected)

        self.assertTrue(verified, detail)

    def test_rejects_stale_public_feed(self) -> None:
        body = appcast_item(
            version="1.6.0-daily.20260713",
            build_version="960",
            channel="daily",
            download_url="https://example.com/old.zip",
        )

        verified, detail = verify_appcast(body, self.expected)

        self.assertFalse(verified)
        self.assertIn("not public yet", detail)

    def test_rejects_wrong_release_metadata(self) -> None:
        body = appcast_item(
            version=self.expected.version,
            build_version="960",
            channel="release-candidate",
            download_url="https://example.com/wrong.zip",
            signature="wrong-signature",
            length="999",
        )

        verified, detail = verify_appcast(body, self.expected)

        self.assertFalse(verified)
        self.assertIn("build version", detail)
        self.assertIn("channel", detail)
        self.assertIn("download URL", detail)
        self.assertIn("signature", detail)
        self.assertIn("archive length", detail)

    def test_enforces_documented_cache_bound(self) -> None:
        body = appcast_item(
            version=self.expected.version,
            build_version=self.expected.build_version,
            channel=self.expected.channel,
            download_url=self.download_url,
        )

        verified, detail = verify_response(
            body,
            {"Cache-Control": "max-age=601"},
            self.expected,
            maximum_cache_age_seconds=600,
        )

        self.assertFalse(verified)
        self.assertIn("exceeding", detail)

    @patch("verify_appcast_publication.time.sleep")
    @patch("verify_appcast_publication.fetch")
    def test_waits_for_stale_feed_to_publish(self, mock_fetch, mock_sleep) -> None:
        stale_body = appcast_item(
            version="1.6.0-daily.20260713",
            build_version="960",
            channel="daily",
            download_url="https://example.com/old.zip",
        )
        current_body = appcast_item(
            version=self.expected.version,
            build_version=self.expected.build_version,
            channel=self.expected.channel,
            download_url=self.download_url,
        )
        headers = {"Cache-Control": "max-age=600", "X-Cache": "HIT"}
        mock_fetch.side_effect = [(stale_body, headers), (current_body, headers)]

        wait_for_publication(
            "https://example.com/appcast.xml",
            self.expected,
            maximum_cache_age_seconds=600,
            timeout_seconds=1,
            poll_interval_seconds=0.01,
        )

        self.assertEqual(mock_fetch.call_count, 2)
        mock_sleep.assert_called_once()


if __name__ == "__main__":
    unittest.main()
