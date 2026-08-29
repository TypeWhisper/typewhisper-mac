#!/usr/bin/env python3
"""Tests for plugin/host Plugin SDK symbol compatibility checking."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_plugin_sdk_symbol_compatibility import (
    missing_sdk_symbols,
    parse_exported_symbols,
    parse_undefined_symbols,
    sdk_symbols,
    validate_min_host_version,
)


# The real symbol that made WhisperKit 1.1.6 unloadable on host 1.6.0:
# PluginHTTPClient.ensureNetworkAccessIsAllowed() landed in the SDK after 1.6.0 shipped.
ENSURE_NETWORK_ACCESS = (
    "_$s20TypeWhisperPluginSDK0C10HTTPClientO28ensureNetworkAccessIsAllowedyyKFZ"
)
HTTP_CLIENT_DATA = (
    "_$s20TypeWhisperPluginSDK0C10HTTPClientO4data3for10Foundation4DataV_"
    "So13NSURLResponseCtAF10URLRequestV_tYaKFZ"
)


class ParseUndefinedSymbolsTests(unittest.TestCase):
    def test_parses_bare_symbol_names(self) -> None:
        output = f"{ENSURE_NETWORK_ACCESS}\n_OBJC_CLASS_$_NSObject\n"
        self.assertEqual(
            parse_undefined_symbols(output),
            {ENSURE_NETWORK_ACCESS, "_OBJC_CLASS_$_NSObject"},
        )

    def test_skips_architecture_headers_and_blank_lines(self) -> None:
        output = (
            "WhisperKitPlugin (for architecture arm64):\n"
            "\n"
            f"  {ENSURE_NETWORK_ACCESS}\n"
        )
        self.assertEqual(parse_undefined_symbols(output), {ENSURE_NETWORK_ACCESS})

    def test_parses_annotated_output(self) -> None:
        output = f"                 U {ENSURE_NETWORK_ACCESS}\n"
        self.assertEqual(parse_undefined_symbols(output), {ENSURE_NETWORK_ACCESS})


class ParseExportedSymbolsTests(unittest.TestCase):
    def test_parses_address_type_name_triples(self) -> None:
        output = (
            f"0000000000003d3c T {HTTP_CLIENT_DATA}\n"
            "000000000004b5b0 S _$s20TypeWhisperPluginSDK0C17HTTPClientSessionMp\n"
        )
        self.assertEqual(
            parse_exported_symbols(output),
            {HTTP_CLIENT_DATA, "_$s20TypeWhisperPluginSDK0C17HTTPClientSessionMp"},
        )

    def test_ignores_headers_and_short_lines(self) -> None:
        output = (
            "TypeWhisperPluginSDK (for architecture x86_64):\n"
            "\n"
            "malformed\n"
            f"0000000000003d3c T {HTTP_CLIENT_DATA}\n"
        )
        self.assertEqual(parse_exported_symbols(output), {HTTP_CLIENT_DATA})


class SDKSymbolFilterTests(unittest.TestCase):
    def test_keeps_only_plugin_sdk_module_symbols(self) -> None:
        symbols = {
            ENSURE_NETWORK_ACCESS,
            "_$s10ArgmaxCore12ModelManagerCMa",
            "_OBJC_CLASS_$_NSURLSession",
        }
        self.assertEqual(sdk_symbols(symbols), {ENSURE_NETWORK_ACCESS})


class MissingSDKSymbolsTests(unittest.TestCase):
    def test_reports_symbol_absent_from_host(self) -> None:
        plugin_undefined = {ENSURE_NETWORK_ACCESS, HTTP_CLIENT_DATA}
        host_exported = {HTTP_CLIENT_DATA}
        self.assertEqual(
            missing_sdk_symbols(plugin_undefined, host_exported),
            [ENSURE_NETWORK_ACCESS],
        )

    def test_passes_when_host_exports_everything(self) -> None:
        plugin_undefined = {HTTP_CLIENT_DATA}
        host_exported = {HTTP_CLIENT_DATA, ENSURE_NETWORK_ACCESS}
        self.assertEqual(missing_sdk_symbols(plugin_undefined, host_exported), [])

    def test_ignores_non_sdk_undefined_symbols(self) -> None:
        # Foundation/CoreML imports resolve against the OS, not the host SDK.
        plugin_undefined = {"_OBJC_CLASS_$_NSURLSession", "_$s10ArgmaxCore12ModelManagerCMa"}
        self.assertEqual(missing_sdk_symbols(plugin_undefined, set()), [])

    def test_result_is_sorted_for_stable_output(self) -> None:
        first = "_$s20TypeWhisperPluginSDK1ayyF"
        second = "_$s20TypeWhisperPluginSDK1byyF"
        self.assertEqual(
            missing_sdk_symbols({second, first}, set()),
            [first, second],
        )


class MinimumHostVersionTests(unittest.TestCase):
    def test_accepts_stable_16_and_newer_versions(self) -> None:
        for version in ("1.6.0", "1.6.0+build.1", "1.7.0-daily.20260828", "2.0.0"):
            with self.subTest(version=version):
                self.assertEqual(validate_min_host_version(version), version)

    def test_rejects_legacy_host_versions(self) -> None:
        for version in ("0.9.0", "0.14.0", "1.5.99", "1.6.0-rc2"):
            with self.subTest(version=version):
                with self.assertRaisesRegex(ValueError, "must be 1.6.0 or newer"):
                    validate_min_host_version(version)

    def test_rejects_missing_or_malformed_versions(self) -> None:
        for version in (
            None,
            "1.6",
            "v1.6.0",
            "1.6.0.0",
            "01.6.0",
            "1.6.1-alpha..1",
            "1.6.1-alpha.",
            "1.6.1-01",
        ):
            with self.subTest(version=version):
                with self.assertRaisesRegex(ValueError, "must be a semantic version"):
                    validate_min_host_version(version)


if __name__ == "__main__":
    unittest.main()
