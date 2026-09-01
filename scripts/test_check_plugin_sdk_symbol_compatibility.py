#!/usr/bin/env python3
"""Tests for plugin/host Plugin SDK symbol compatibility checking."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_plugin_sdk_symbol_compatibility import (
    architectures_to_check,
    imported_sdk_symbols,
    missing_sdk_symbols,
    parse_exported_symbols,
    parse_undefined_symbols,
    swift_sdk_symbols,
)


ENSURE_NETWORK_ACCESS = (
    "_$s20TypeWhisperPluginSDK0C10HTTPClientO28ensureNetworkAccessIsAllowedyyKFZ"
)
HTTP_CLIENT_DATA = (
    "_$s20TypeWhisperPluginSDK0C10HTTPClientO4data3for10Foundation4DataV_"
    "So13NSURLResponseCtAF10URLRequestV_tYaKFZ"
)
SDK_OBJC_CLASS = "_OBJC_CLASS_$_TypeWhisperSDKObject"
FOUNDATION_OBJC_CLASS = "_OBJC_CLASS_$_NSURLSession"


class ParseUndefinedSymbolsTests(unittest.TestCase):
    def test_parses_bare_and_annotated_symbol_names(self) -> None:
        output = (
            f"{ENSURE_NETWORK_ACCESS}\n"
            f"                 U {FOUNDATION_OBJC_CLASS}\n"
        )
        self.assertEqual(
            parse_undefined_symbols(output),
            {ENSURE_NETWORK_ACCESS, FOUNDATION_OBJC_CLASS},
        )

    def test_skips_architecture_headers_and_blank_lines(self) -> None:
        output = (
            "Gemma4Plugin (for architecture arm64):\n"
            "\n"
            f"  {ENSURE_NETWORK_ACCESS}\n"
        )
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
            "malformed\n"
            f"0000000000003d3c T {HTTP_CLIENT_DATA}\n"
        )
        self.assertEqual(parse_exported_symbols(output), {HTTP_CLIENT_DATA})


class SDKSymbolTests(unittest.TestCase):
    def test_swift_filter_keeps_only_plugin_sdk_module_symbols(self) -> None:
        symbols = {
            ENSURE_NETWORK_ACCESS,
            "_$s10ArgmaxCore12ModelManagerCMa",
            FOUNDATION_OBJC_CLASS,
        }
        self.assertEqual(swift_sdk_symbols(symbols), {ENSURE_NETWORK_ACCESS})

    def test_imported_symbols_include_swift_objc_and_c_sdk_exports(self) -> None:
        plugin_undefined = {
            ENSURE_NETWORK_ACCESS,
            SDK_OBJC_CLASS,
            FOUNDATION_OBJC_CLASS,
        }
        build_exports = {ENSURE_NETWORK_ACCESS, SDK_OBJC_CLASS}
        self.assertEqual(
            imported_sdk_symbols(plugin_undefined, build_exports),
            {ENSURE_NETWORK_ACCESS, SDK_OBJC_CLASS},
        )

    def test_missing_symbols_reports_only_sdk_imports_absent_from_host(self) -> None:
        plugin_undefined = {
            ENSURE_NETWORK_ACCESS,
            HTTP_CLIENT_DATA,
            FOUNDATION_OBJC_CLASS,
        }
        build_exports = {ENSURE_NETWORK_ACCESS, HTTP_CLIENT_DATA}
        host_exports = {HTTP_CLIENT_DATA}
        self.assertEqual(
            missing_sdk_symbols(plugin_undefined, build_exports, host_exports),
            [ENSURE_NETWORK_ACCESS],
        )

    def test_missing_symbols_passes_when_host_exports_every_sdk_import(self) -> None:
        plugin_undefined = {HTTP_CLIENT_DATA, FOUNDATION_OBJC_CLASS}
        build_exports = {HTTP_CLIENT_DATA}
        host_exports = {HTTP_CLIENT_DATA, ENSURE_NETWORK_ACCESS}
        self.assertEqual(
            missing_sdk_symbols(plugin_undefined, build_exports, host_exports),
            [],
        )

    def test_missing_symbols_result_is_sorted(self) -> None:
        first = "_$s20TypeWhisperPluginSDK1ayyF"
        second = "_$s20TypeWhisperPluginSDK1byyF"
        self.assertEqual(
            missing_sdk_symbols(
                {second, first},
                {second, first},
                set(),
            ),
            [first, second],
        )


class ArchitectureTests(unittest.TestCase):
    def test_checks_every_plugin_architecture(self) -> None:
        self.assertEqual(
            architectures_to_check(
                ["x86_64", "arm64"],
                {"x86_64", "arm64"},
                {"x86_64", "arm64"},
            ),
            ["x86_64", "arm64"],
        )

    def test_rejects_architecture_missing_from_build_sdk(self) -> None:
        with self.assertRaisesRegex(ValueError, "build SDK is missing.*x86_64"):
            architectures_to_check(
                ["x86_64", "arm64"],
                {"arm64"},
                {"x86_64", "arm64"},
            )

    def test_rejects_architecture_missing_from_minimum_host_sdk(self) -> None:
        with self.assertRaisesRegex(
            ValueError, "minimum host SDK is missing.*arm64"
        ):
            architectures_to_check(
                ["arm64"],
                {"arm64"},
                {"x86_64"},
            )


if __name__ == "__main__":
    unittest.main()
