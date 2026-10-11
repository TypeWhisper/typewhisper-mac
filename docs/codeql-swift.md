# CodeQL Swift analysis

The `Analyze (swift)` job in [`.github/workflows/codeql.yml`](../.github/workflows/codeql.yml)
runs on every pull request to `main` and `release/**`, on pushes to those branches and
on non-daily `v*` tags, on the weekly schedule (default branch) and on manual dispatch.
It is not a required status check.

## What gets built

[`scripts/codeql-build-swift.sh`](../scripts/codeql-build-swift.sh) runs one traced
`xcodebuild build` with explicit `-target` arguments:

- app targets: `TypeWhisper`, `typewhisper-cli`, `TypeWhisperICloudBridge`,
  `TypeWhisperWidgetExtension`, `TypeWhisperTranscribeAction` (and through them the
  `TypeWhisperPluginSDK` package target)
- one target per `TypeWhisperPluginSDK/Plugins/*/manifest.json`, by directory name

Every maintained plugin has a target of the same name in `TypeWhisper.xcodeproj`
(also the ones without an SPM target in `TypeWhisperPluginSDK/Package.swift`, such
as `WhisperKitPlugin`, `LocalLLMPlugin`, `DeepgramPlugin` or `GoogleCloudSTTPlugin`).
A plugin directory without that target fails the build instead of being skipped.

To print the target list: `bash scripts/codeql-build-swift.sh --print-targets`.

## Coverage check

After the analysis, [`scripts/codeql_swift_coverage.py`](../scripts/codeql_swift_coverage.py)
reads the SARIF file and lists, per area, how many tracked Swift files CodeQL reports as
successfully extracted. The job fails when any tracked Swift file of the app, its
extensions, the SDK sources or a plugin directory was not extracted, and prints the
missing files. A green build alone is not proof of coverage: before this check, the
tag-only Swift job reported "CodeQL scanned 32 out of 451 Swift files" for `v1.7.0`.

The analysis runs with `upload: never`; the SARIF is uploaded only after the check
passes, so a partial extraction cannot close alerts in files it skipped. The job sets
`CODEQL_ACTION_FILE_COVERAGE_ON_PRS=true` because the CodeQL Action omits the per-file
extraction diagnostics on pull requests by default. CodeQL extraction errors in tracked
files are shown as warnings; they do not fail the job.

## Not analyzed

| Sources | Reason |
| --- | --- |
| `TypeWhisperTests/`, `TypeWhisperPluginSDK/Tests/`, `Plugins/*/Tests/`, other `*Tests.swift` | Test code; not part of the shipped app or plugins. |
| `TypeWhisperPluginSDK/Sources/TypeWhisperPluginSDKTesting/` | Test support library. |
| `AppStore/Sources/` and `#if APPSTORE` branches | The Mac App Store edition is a separate XcodeGen project with the `APPSTORE` flag. Building it in the same database would mix two variants of the same types; a separate analysis would add another full macOS build. |
| Swift package dependencies | Built outside the source root; CodeQL extracts their signatures only. |

## Toolchain and runtime

- Runner `macos-26`, Xcode 26.6, CodeQL bundle from `github/codeql-action` v4.38.2.
- Debug configuration, arm64 only, no code signing, index store off.
- `SWIFT_ENABLE_EXPLICIT_MODULES=NO`. With the Xcode 26 default (explicit modules) the
  extractor processed 1 of 226 app files in a traced build; without it, all 226.
- Under CodeQL tracing, the `metal` stub in Xcode's default toolchain reports a missing
  Metal Toolchain, so the MLX plugins (Qwen3, Canary, Granite, Voxtral, LocalLLM) fail
  to build. Setting `TOOLCHAINS` to the downloaded Metal toolchain's identifier did not
  change this with Xcode 26.6. The workflow therefore installs a one-tool toolchain in
  `~/Library/Developer/Toolchains` whose `metal` forwards to `xcrun --find metal`, and
  selects it with `TOOLCHAINS` for the build. Swift and Clang still come from the
  default toolchain. A local run of the build script outside CI does not need this.
- Only package checkouts are restored from the `spm-*` cache that the build workflow
  saves. Compiled artifacts are never cached: a file that is not compiled under tracing
  is not extracted.

## Runtime

Measured on GitHub-hosted `macos-26` runners on 2026-10-11 (PR #1572, run
[38134266612](https://github.com/TypeWhisper/typewhisper-mac/actions/runs/38134266612)):

| Step | Duration |
| --- | --- |
| Package cache restore (hit, about 1.2 GB) and resolution | 1 min |
| CodeQL init and Metal toolchain check | 3 min |
| Traced build (5 app targets, 53 plugin targets) | 74 min |
| Analysis and upload | 4 min |
| Job total | 83 min |

Result: "CodeQL scanned 340 out of 503 Swift files"; the coverage check found all 339
tracked first-party files extracted. The 503 include test files and other Swift files
outside the analyzed areas.

All measured runs restored the package cache; a run without it adds the package
download. The job also waits for a free macOS runner when the build workflow's macOS
jobs for the same push are queued (about 20 minutes in one run). The job timeout is
120 minutes. Concurrent runs for the same pull request are cancelled.
