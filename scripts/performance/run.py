#!/usr/bin/env python3
"""Benchmark actual production Swift sources, optionally from an immutable git ref."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCES = [
    "TypeWhisper/Services/Cloud/WavEncoder.swift",
    "TypeWhisper/Services/TextDiffService.swift",
    "TypeWhisper/Services/SpeechPunctuationService.swift",
    "TypeWhisper/Services/PunctuationRulesLoader.swift",
    "TypeWhisper/Models/PunctuationRules.swift",
    "TypeWhisper/Models/DictationPunctuationProfile.swift",
    "TypeWhisperPluginSDK/Sources/TypeWhisperPluginSDK/PluginManifest.swift",
]
SDK_SOURCE = "TypeWhisperPluginSDK/Sources/TypeWhisperPluginSDK/HostServices.swift"
CASES = ["wav-app-10s", "wav-app-60s", "wav-sdk-60s", "wav-sdk-600s",
         "diff-identical", "diff-middle-edit", "diff-last-edit", "diff-rewrite",
         "punctuation-short", "punctuation-long", "punctuation-spaces", "punctuation-cold",
         "plugin-sort-64"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ref", help="Read production sources from this git ref")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--compare", type=Path, help="Require identical output digests")
    args = parser.parse_args()

    def read(relative):
        if args.ref:
            return subprocess.check_output(["git", "show", f"{args.ref}:{relative}"], cwd=ROOT)
        return (ROOT / relative).read_bytes()

    hashes = {}
    with tempfile.TemporaryDirectory(prefix="typewhisper-performance-") as directory:
        scratch = Path(directory)
        paths = []
        for relative in SOURCES:
            data = read(relative)
            hashes[relative] = hashlib.sha256(data).hexdigest()
            target = scratch / Path(relative).name
            target.write_bytes(data)
            paths.append(str(target))
        # Compile the complete SDK encoder verbatim, without pulling in unrelated
        # model runtimes. Fail loudly if its declaration boundaries change.
        sdk = read(SDK_SOURCE)
        hashes[SDK_SOURCE] = hashlib.sha256(sdk).hexdigest()
        encoder = sdk.decode().split("public struct PluginWavEncoder {", 1)[1].split(
            "\npublic struct PluginAudioUploadFile:", 1)[0]
        target = scratch / "PluginWavEncoder.swift"
        target.write_text("import Foundation\npublic struct PluginWavEncoder {" + encoder)
        paths.append(str(target))
        relative = "TypeWhisper/Services/PluginManager.swift"
        manager = read(relative)
        hashes[relative] = hashlib.sha256(manager).hexdigest()
        methods = manager.decode().split("    func sortedPluginBundleURLs(", 1)[1].split(
            "\n    func loadPlugin(", 1)[0]
        target = scratch / "PluginSortingFixture.swift"
        target.write_text("import Foundation\nfinal class PluginSortingFixture {\n    func sortedPluginBundleURLs(" + methods + "\n}\n")
        paths.append(str(target))
        resources = scratch / "rules"
        resources.mkdir()
        for language in ["de", "en", "it", "ja"]:
            relative = f"TypeWhisper/Resources/PunctuationRules/{language}.json"
            data = read(relative)
            hashes[relative] = hashlib.sha256(data).hexdigest()
            (resources / f"{language}.json").write_bytes(data)
        harness = ROOT / "scripts/performance/Benchmark.swift"
        hashes["scripts/performance/Benchmark.swift"] = hashlib.sha256(harness.read_bytes()).hexdigest()
        binary = scratch / "benchmark"
        command = ["xcrun", "swiftc", "-O", "-whole-module-optimization", "-swift-version", "6",
                   *paths, str(harness), "-o", str(binary)]
        subprocess.run(command, check=True, cwd=ROOT)
        results = []
        for case in ["verify", *CASES]:
            result = subprocess.check_output([str(binary), case, str(resources)], text=True)
            row = json.loads(result)
            results.append(row)
            print(json.dumps(row), flush=True)
        report = {
            "revision": subprocess.check_output(["git", "rev-parse", args.ref or "HEAD"], cwd=ROOT, text=True).strip(),
            "source": args.ref or "working-tree",
            "machine": platform.platform(),
            "cpu": subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
            "compiler": subprocess.check_output(["xcrun", "swiftc", "--version"], text=True, stderr=subprocess.STDOUT).strip(),
            "flags": "-O -whole-module-optimization -swift-version 6",
            "source_sha256": hashes,
            "results": results,
        }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    if args.compare:
        baseline = json.loads(args.compare.read_text())
        assert baseline["source_sha256"]["scripts/performance/Benchmark.swift"] == hashes["scripts/performance/Benchmark.swift"], "Harness changed; rerun baseline"
        previous = {row["case"]: row for row in baseline["results"]}
        for row in results:
            assert row["digest"] == previous[row["case"]]["digest"], f"Output changed: {row['case']}"
        print("All output digests match the baseline.")


if __name__ == "__main__":
    main()
