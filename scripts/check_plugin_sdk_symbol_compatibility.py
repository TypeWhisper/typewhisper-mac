#!/usr/bin/env python3
"""Verify a plugin only imports symbols exported by its minimum host SDK.

Plugins are built against the SDK on ``main`` but are loaded against the
``TypeWhisperPluginSDK.framework`` embedded in the installed host app. A plugin
that imports a newer SDK symbol cannot be opened by an older host even when its
manifest claims that host through ``minHostVersion``.

The checker compares each plugin architecture against both the SDK used for the
build and the SDK shipped by the declared minimum host. Intersecting plugin
imports with build-SDK exports identifies Swift, Objective-C, and C SDK symbols;
the Swift module-name fallback also keeps diagnostics useful for older artifacts
when only a host SDK is available during investigation.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


SDK_MODULE_MANGLING = "20TypeWhisperPluginSDK"


def parse_undefined_symbols(nm_output: str) -> set[str]:
    """Parse ``nm -u`` output into undefined symbol names."""
    symbols: set[str] = set()
    for raw_line in nm_output.splitlines():
        line = raw_line.strip()
        if not line or line.endswith(":"):
            continue
        symbols.add(line.split()[-1])
    return symbols


def parse_exported_symbols(nm_output: str) -> set[str]:
    """Parse ``nm -gU`` output into exported symbol names."""
    symbols: set[str] = set()
    for raw_line in nm_output.splitlines():
        line = raw_line.strip()
        if not line or line.endswith(":"):
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        symbols.add(parts[-1])
    return symbols


def swift_sdk_symbols(symbols: set[str]) -> set[str]:
    """Return symbols whose Swift mangling identifies the Plugin SDK module."""
    return {symbol for symbol in symbols if SDK_MODULE_MANGLING in symbol}


def imported_sdk_symbols(
    plugin_undefined: set[str],
    build_sdk_exported: set[str],
) -> set[str]:
    """Return plugin imports owned by the SDK used for the plugin build."""
    return (plugin_undefined & build_sdk_exported) | swift_sdk_symbols(
        plugin_undefined
    )


def missing_sdk_symbols(
    plugin_undefined: set[str],
    build_sdk_exported: set[str],
    host_sdk_exported: set[str],
) -> list[str]:
    """Return build-SDK imports absent from the minimum host SDK."""
    return sorted(
        imported_sdk_symbols(plugin_undefined, build_sdk_exported)
        - host_sdk_exported
    )


def architectures_to_check(
    plugin_architectures: list[str],
    build_sdk_architectures: set[str],
    host_sdk_architectures: set[str],
) -> list[str]:
    """Require SDK slices for every architecture shipped in the plugin."""
    missing_from_build = sorted(
        set(plugin_architectures) - build_sdk_architectures
    )
    missing_from_host = sorted(set(plugin_architectures) - host_sdk_architectures)
    errors: list[str] = []
    if missing_from_build:
        errors.append(
            "build SDK is missing plugin architecture(s): "
            + ", ".join(missing_from_build)
        )
    if missing_from_host:
        errors.append(
            "minimum host SDK is missing plugin architecture(s): "
            + ", ".join(missing_from_host)
        )
    if errors:
        raise ValueError("; ".join(errors))
    return plugin_architectures


def _run(command: list[str]) -> str:
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise RuntimeError(
            f"command failed: {' '.join(command)}\n{result.stderr.strip()}"
        )
    return result.stdout


def architectures(binary: Path) -> list[str]:
    """Return the Mach-O architectures in a binary."""
    return _run(["lipo", "-archs", str(binary)]).split()


def undefined_symbols(binary: Path, architecture: str) -> set[str]:
    """Return undefined symbols for one binary architecture."""
    return parse_undefined_symbols(
        _run(["nm", "-arch", architecture, "-u", str(binary)])
    )


def exported_symbols(binary: Path, architecture: str) -> set[str]:
    """Return globally exported symbols for one binary architecture."""
    return parse_exported_symbols(
        _run(["nm", "-arch", architecture, "-gU", str(binary)])
    )


def demangle(symbols: list[str]) -> dict[str, str]:
    """Best-effort Swift demangling for readable failure output."""
    if not symbols:
        return {}
    try:
        result = subprocess.run(
            ["xcrun", "swift-demangle", "--compact", *symbols],
            capture_output=True,
            text=True,
            check=False,
        )
    except FileNotFoundError:
        return {}
    if result.returncode != 0:
        return {}
    demangled = result.stdout.splitlines()
    if len(demangled) != len(symbols):
        return {}
    return dict(zip(symbols, demangled))


def check(
    plugin_binary: Path,
    build_sdk: Path,
    host_sdk: Path,
    min_host_version: str,
) -> int:
    """Compare SDK imports and exports for every plugin architecture."""
    try:
        plugin_architectures = architectures(plugin_binary)
        checked_architectures = architectures_to_check(
            plugin_architectures,
            set(architectures(build_sdk)),
            set(architectures(host_sdk)),
        )
    except (RuntimeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    failures = 0
    for architecture in checked_architectures:
        try:
            plugin_undefined = undefined_symbols(plugin_binary, architecture)
            build_exports = exported_symbols(build_sdk, architecture)
            host_exports = exported_symbols(host_sdk, architecture)
        except RuntimeError as error:
            print(f"error: {error}", file=sys.stderr)
            return 1

        required = imported_sdk_symbols(plugin_undefined, build_exports)
        missing = missing_sdk_symbols(
            plugin_undefined,
            build_exports,
            host_exports,
        )
        if not missing:
            print(
                f"{architecture}: OK - {len(required)} Plugin SDK import(s) "
                f"exist in host {min_host_version}"
            )
            continue

        failures += 1
        readable = demangle(missing)
        print(
            f"{architecture}: {len(missing)} Plugin SDK symbol(s) missing "
            f"from host {min_host_version}:",
            file=sys.stderr,
        )
        for symbol in missing:
            print(f"  {readable.get(symbol, symbol)}", file=sys.stderr)

    if failures:
        print(
            "\nThe plugin cannot load on the host version declared by its "
            "manifest.\nRaise minHostVersion to the first host release that "
            "exports these symbols,\nor remove the newer SDK API usage from "
            "the plugin.",
            file=sys.stderr,
        )
        return 1

    return 0


def main(argv: list[str] | None = None) -> int:
    """Parse CLI arguments and run the compatibility check."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--plugin-binary",
        required=True,
        type=Path,
        help="Built plugin executable",
    )
    parser.add_argument(
        "--build-sdk",
        required=True,
        type=Path,
        help="TypeWhisperPluginSDK binary used to link the plugin",
    )
    parser.add_argument(
        "--host-sdk",
        required=True,
        type=Path,
        help="TypeWhisperPluginSDK binary from the minHostVersion release",
    )
    parser.add_argument(
        "--min-host-version",
        required=True,
        help="minHostVersion declared in the plugin manifest",
    )
    args = parser.parse_args(argv)

    for path in (args.plugin_binary, args.build_sdk, args.host_sdk):
        if not path.is_file():
            print(f"error: not a file: {path}", file=sys.stderr)
            return 1

    return check(
        args.plugin_binary,
        args.build_sdk,
        args.host_sdk,
        args.min_host_version,
    )


if __name__ == "__main__":
    raise SystemExit(main())
