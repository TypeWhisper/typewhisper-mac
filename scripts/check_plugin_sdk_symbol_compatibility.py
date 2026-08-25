#!/usr/bin/env python3
"""Verify a built plugin only imports Plugin SDK symbols its minHostVersion exports.

A plugin bundle is dlopen'ed by the host app and resolves ``TypeWhisperPluginSDK``
symbols against the framework embedded in that host. Plugins are built from ``main``,
so a plugin released after the SDK gains a new API links against a symbol that older
hosts do not export. The host then fails to load the bundle with a bare
"The bundle could not be loaded", and the plugin's enable toggle silently flips back.

``minHostVersion`` in manifest.json is the gate that is supposed to prevent that, but
it is only validated as a well-formed semantic version, never against the ABI the
binary actually requires.

This check closes that gap: it compares the undefined SDK symbols in the built plugin
binary against the symbols exported by the SDK inside the released host named by
``minHostVersion``.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


# Swift mangles module names length-prefixed, so every symbol originating in the
# Plugin SDK module contains this substring (e.g. `_$s20TypeWhisperPluginSDK...`).
SDK_MODULE_MANGLING = "20TypeWhisperPluginSDK"


def parse_undefined_symbols(nm_output: str) -> set[str]:
    """Parse `nm -u` output into a set of undefined symbol names."""
    symbols: set[str] = set()
    for raw_line in nm_output.splitlines():
        line = raw_line.strip()
        if not line or line.endswith(":"):
            # Blank separators and `path (for architecture arm64):` headers.
            continue
        # `nm -u` prints bare names; `nm -m -u` prints `<addr> U _name`.
        symbols.add(line.split()[-1])
    return symbols


def parse_exported_symbols(nm_output: str) -> set[str]:
    """Parse `nm -gU` output into a set of exported symbol names."""
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


def sdk_symbols(symbols: set[str]) -> set[str]:
    """Restrict a symbol set to symbols vended by the Plugin SDK module."""
    return {symbol for symbol in symbols if SDK_MODULE_MANGLING in symbol}


def missing_sdk_symbols(
    plugin_undefined: set[str],
    host_exported: set[str],
) -> list[str]:
    """SDK symbols the plugin imports that the host SDK does not export."""
    return sorted(sdk_symbols(plugin_undefined) - sdk_symbols(host_exported))


def _run(command: list[str]) -> str:
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise SystemExit(f"command failed: {' '.join(command)}\n{result.stderr.strip()}")
    return result.stdout


def architectures(binary: Path) -> list[str]:
    return _run(["lipo", "-archs", str(binary)]).split()


def undefined_symbols(binary: Path, arch: str) -> set[str]:
    return parse_undefined_symbols(_run(["nm", "-arch", arch, "-u", str(binary)]))


def exported_symbols(binary: Path, arch: str) -> set[str]:
    return parse_exported_symbols(_run(["nm", "-arch", arch, "-gU", str(binary)]))


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


def check(plugin_binary: Path, host_sdk: Path, min_host_version: str) -> int:
    plugin_archs = architectures(plugin_binary)
    host_archs = set(architectures(host_sdk))
    shared_archs = [arch for arch in plugin_archs if arch in host_archs]

    if not shared_archs:
        print(
            f"error: plugin architectures {plugin_archs} share none with "
            f"host SDK architectures {sorted(host_archs)}",
            file=sys.stderr,
        )
        return 1

    failures = 0
    for arch in shared_archs:
        missing = missing_sdk_symbols(
            undefined_symbols(plugin_binary, arch),
            exported_symbols(host_sdk, arch),
        )
        if not missing:
            print(f"{arch}: OK - all Plugin SDK symbols exist in host {min_host_version}")
            continue

        failures += 1
        readable = demangle(missing)
        print(
            f"{arch}: {len(missing)} Plugin SDK symbol(s) missing from host "
            f"{min_host_version}:",
            file=sys.stderr,
        )
        for symbol in missing:
            print(f"  {readable.get(symbol, symbol)}", file=sys.stderr)

    if failures:
        print(
            "\nThis plugin cannot be loaded by the host version its manifest claims to "
            f"support.\nRaise minHostVersion above {min_host_version} to the first "
            "release that exports these\nsymbols, or remove the new SDK API usage from "
            "the plugin.",
            file=sys.stderr,
        )
        return 1

    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--plugin-binary",
        required=True,
        type=Path,
        help="Built plugin executable, e.g. build/Release/WhisperKitPlugin.bundle/Contents/MacOS/WhisperKitPlugin",
    )
    parser.add_argument(
        "--host-sdk",
        required=True,
        type=Path,
        help="TypeWhisperPluginSDK binary from the host release named by minHostVersion",
    )
    parser.add_argument(
        "--min-host-version",
        required=True,
        help="minHostVersion declared in the plugin manifest (used for messages)",
    )
    args = parser.parse_args(argv)

    for path in (args.plugin_binary, args.host_sdk):
        if not path.is_file():
            print(f"error: not a file: {path}", file=sys.stderr)
            return 1

    return check(args.plugin_binary, args.host_sdk, args.min_host_version)


if __name__ == "__main__":
    raise SystemExit(main())
