#!/usr/bin/env python3

import argparse
import re
import sys
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from typing import Mapping


SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
CACHE_MAX_AGE_RE = re.compile(r"(?:^|,)\s*max-age\s*=\s*\"?(\d+)\"?", re.IGNORECASE)


def qname(tag: str) -> str:
    return f"{{{SPARKLE_NS}}}{tag}"


@dataclass(frozen=True)
class PublicationExpectation:
    version: str
    build_version: str
    channel: str
    download_url: str
    signature: str | None = None
    length: str | None = None


def cache_max_age(cache_control: str) -> int | None:
    match = CACHE_MAX_AGE_RE.search(cache_control)
    return int(match.group(1)) if match else None


def item_channel(item: ET.Element) -> str:
    channel = item.findtext(qname("channel"))
    return channel.strip() if channel else "stable"


def verify_appcast(body: bytes, expected: PublicationExpectation) -> tuple[bool, str]:
    try:
        root = ET.fromstring(body)
    except ET.ParseError as error:
        return False, f"response is not valid XML: {error}"

    channel = root.find("channel")
    if channel is None:
        return False, "appcast has no channel element"

    published_versions: list[str] = []
    version_candidates: list[ET.Element] = []
    for item in channel.findall("item"):
        version = item.findtext(qname("shortVersionString"), default="").strip()
        if version:
            published_versions.append(version)
        if version == expected.version:
            version_candidates.append(item)

    if not version_candidates:
        visible = ", ".join(published_versions) if published_versions else "none"
        return False, f"version {expected.version} is not public yet; visible versions: {visible}"

    mismatches: list[str] = []
    for item in version_candidates:
        build_version = item.findtext(qname("version"), default="").strip()
        channel_name = item_channel(item)
        enclosure = item.find("enclosure")
        download_url = enclosure.get("url", "") if enclosure is not None else ""
        signature = enclosure.get(qname("edSignature"), "") if enclosure is not None else ""
        length = enclosure.get("length", "") if enclosure is not None else ""

        item_mismatches: list[str] = []
        if build_version != expected.build_version:
            item_mismatches.append(
                f"build version is {build_version or 'missing'}, expected {expected.build_version}"
            )
        if channel_name != expected.channel:
            item_mismatches.append(
                f"channel is {channel_name or 'missing'}, expected {expected.channel}"
            )
        if download_url != expected.download_url:
            item_mismatches.append(
                f"download URL is {download_url or 'missing'}, expected {expected.download_url}"
            )
        if expected.signature is not None and signature != expected.signature:
            item_mismatches.append("Sparkle signature does not match the published ZIP")
        if expected.length is not None and length != expected.length:
            item_mismatches.append(
                f"archive length is {length or 'missing'}, expected {expected.length}"
            )

        if not item_mismatches:
            return True, (
                f"version {expected.version} build {expected.build_version} "
                f"is public on the {expected.channel} channel"
            )
        mismatches.extend(item_mismatches)

    return False, "; ".join(mismatches)


def header_value(headers: Mapping[str, str], name: str) -> str:
    expected_name = name.lower()
    for key, value in headers.items():
        if key.lower() == expected_name:
            return value
    return ""


def verify_response(
    body: bytes,
    headers: Mapping[str, str],
    expected: PublicationExpectation,
    maximum_cache_age_seconds: int,
) -> tuple[bool, str]:
    cache_control = header_value(headers, "cache-control")
    max_age = cache_max_age(cache_control)
    if max_age is None:
        return False, f"response does not advertise max-age: {cache_control or 'header missing'}"
    if max_age > maximum_cache_age_seconds:
        return False, (
            f"response max-age is {max_age} seconds, exceeding the documented "
            f"{maximum_cache_age_seconds}-second limit"
        )
    return verify_appcast(body, expected)


def fetch(url: str) -> tuple[bytes, dict[str, str]]:
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/xml",
            "User-Agent": "TypeWhisper-Appcast-Publication-Verification/1.0",
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read(), {key.lower(): value for key, value in response.headers.items()}


def format_headers(headers: Mapping[str, str]) -> str:
    names = ("cache-control", "age", "x-cache", "etag", "last-modified", "date")
    values = [
        f"{name}={value}"
        for name in names
        if (value := header_value(headers, name))
    ]
    return ", ".join(values) if values else "no cache headers"


def wait_for_publication(
    url: str,
    expected: PublicationExpectation,
    maximum_cache_age_seconds: int,
    timeout_seconds: float,
    poll_interval_seconds: float,
) -> None:
    deadline = time.monotonic() + timeout_seconds
    attempt = 0

    while True:
        attempt += 1
        headers: dict[str, str] = {}
        try:
            body, headers = fetch(url)
            verified, last_detail = verify_response(
                body,
                headers,
                expected,
                maximum_cache_age_seconds,
            )
        except (OSError, urllib.error.URLError) as error:
            verified = False
            last_detail = f"request failed: {error}"

        print(
            f"Attempt {attempt}: {last_detail} ({format_headers(headers)})",
            flush=True,
        )
        if verified:
            return

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError(
                f"appcast publication was not verified within {timeout_seconds:g} seconds: "
                f"{last_detail}"
            )
        time.sleep(min(poll_interval_seconds, remaining))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Wait until the canonical public Sparkle appcast contains a release."
    )
    parser.add_argument("--url", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build-version", required=True)
    parser.add_argument(
        "--channel",
        required=True,
        choices=["stable", "release-candidate", "daily"],
    )
    parser.add_argument("--download-url", required=True)
    parser.add_argument("--signature")
    parser.add_argument("--length")
    parser.add_argument("--maximum-cache-age-seconds", type=int, default=600)
    parser.add_argument("--timeout-seconds", type=float, default=900)
    parser.add_argument("--poll-interval-seconds", type=float, default=15)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.maximum_cache_age_seconds < 0:
        raise SystemExit("--maximum-cache-age-seconds must not be negative")
    if args.timeout_seconds < 0:
        raise SystemExit("--timeout-seconds must not be negative")
    if args.poll_interval_seconds <= 0:
        raise SystemExit("--poll-interval-seconds must be positive")

    expected = PublicationExpectation(
        version=args.version,
        build_version=args.build_version,
        channel=args.channel,
        download_url=args.download_url,
        signature=args.signature,
        length=args.length,
    )
    try:
        wait_for_publication(
            args.url,
            expected,
            args.maximum_cache_age_seconds,
            args.timeout_seconds,
            args.poll_interval_seconds,
        )
    except RuntimeError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
