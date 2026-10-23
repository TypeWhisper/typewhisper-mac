# CodeQL Swift analysis

The `Analyze (swift)` job in [`.github/workflows/codeql.yml`](../.github/workflows/codeql.yml)
runs nightly at 03:26 UTC (default branch), on non-daily `v*` tags and on manual
dispatch, and always builds every target. Pull requests and branch pushes run only the
Actions and Python analyses. It is not a required status check.

From 2026-10-11 to 2026-10-18 the job also ran on every pull request with the target
selection below. On the Intel runner it took 27 to 83 minutes per push and used 4,120
of the repository's 12,407 macOS runner minutes in that week, a third of the total,
while the Build DMG jobs waited for free macOS runners. Only one Swift alert was
opened in that week. Pull requests now rely on the nightly scan.

Concurrency groups include the event type and the pull request number or full ref.
New commits cancel earlier runs for the same pull request or branch push. Scheduled,
manual and release-tag full scans are allowed to finish; branch pushes and pull
requests cannot cancel them.

## What gets built

[`scripts/codeql-build-swift.sh`](../scripts/codeql-build-swift.sh) runs one traced
`xcodebuild build` with explicit `-target` arguments. In CI it builds every target:

- app targets: `TypeWhisper`, `typewhisper-cli`, `TypeWhisperICloudBridge`,
  `TypeWhisperWidgetExtension`, `TypeWhisperTranscribeAction` (and through them the
  `TypeWhisperPluginSDK` package target)
- one target per `TypeWhisperPluginSDK/Plugins/*/manifest.json`, by directory name

Every maintained plugin has a target of the same name in `TypeWhisper.xcodeproj`
(also the ones without an SPM target in `TypeWhisperPluginSDK/Package.swift`, such
as `WhisperKitPlugin`, `LocalLLMPlugin`, `DeepgramPlugin` or `GoogleCloudSTTPlugin`).
A plugin directory without that target fails the build instead of being skipped.

For partial runs outside CI, `python3 scripts/codeql_swift_targets.py changed <file>`
selects targets from a list of changed files; `CODEQL_SWIFT_TARGETS` limits the build
script to them and `scripts/codeql_swift_coverage.py --targets` checks only their
areas. Sources are Swift files plus C and Objective-C files and headers, which Swift
sees through the bridging header:

| Changed files | Targets |
| --- | --- |
| `.github/workflows/codeql.yml`, the CodeQL scripts, `TypeWhisper.xcodeproj/`, `CodeSigning.xcconfig`, any `Package.swift` or `Package.resolved` | all |
| Sources in `TypeWhisperPluginSDK/Sources/TypeWhisperPluginSDK/` | all, because the app and every plugin call into the SDK |
| Sources in `TypeWhisper/`, `typewhisper-cli/`, `TypeWhisperICloudBridge/`, `TypeWhisperTranscribeAction/`, `TypeWhisperWidgetExtension/`, `TypeWhisperWidgetShared/` | the five app targets |
| Sources in `TypeWhisperPluginSDK/Plugins/<Name>/` | `<Name>` |
| anything else: tests, docs, resources | none |

To print the full target list: `bash scripts/codeql-build-swift.sh --print-targets`.

## Coverage check

After the analysis, [`scripts/codeql_swift_coverage.py`](../scripts/codeql_swift_coverage.py)
reads the SARIF file and lists, per area, how many tracked Swift files CodeQL reports as
successfully extracted. The job fails when any tracked Swift file in an area the built
targets cover (the app and its extensions, the SDK sources, each built plugin) was not
extracted, and prints the missing files. A green build alone is not proof of coverage: before this check, the
tag-only Swift job reported "CodeQL scanned 32 out of 451 Swift files" for `v1.7.0`.

The analysis runs with `upload: never`; the SARIF is uploaded only after the check
passes, so a partial extraction cannot close alerts in files it skipped. CodeQL
extraction errors in tracked files are shown as warnings; they do not fail the job. A
pull request job would need `CODEQL_ACTION_FILE_COVERAGE_ON_PRS=true`: since v4.33.0
the CodeQL Action omits the per-file extraction diagnostics on pull requests.

## Not analyzed

| Sources | Reason |
| --- | --- |
| `TypeWhisperTests/`, `TypeWhisperPluginSDK/Tests/`, `Plugins/*/Tests/`, other `*Tests.swift` | Test code; not part of the shipped app or plugins. |
| `TypeWhisperPluginSDK/Sources/TypeWhisperPluginSDKTesting/` | Test support library. |
| Swift package dependencies | Built outside the source root; CodeQL extracts their signatures only. |

## Toolchain and runtime

- Runner `macos-26-intel`, Xcode 26.6, CodeQL bundle from `github/codeql-action` v4.38.2
  (CodeQL 2.27.2).
- The runner is Intel on purpose. The CodeQL tracer runs relocated copies of
  Apple-signed tools (`bash`, `xcodebuild`, `clang`, `ld`, `git`, `swift-driver`) as
  x86_64, and the Swift extractor, which runs after every `swift-frontend` job, is
  x86_64 only. On the Apple Silicon `macos-26` runner the traced build therefore ran
  under Rosetta, and every fresh runner first had to translate those binaries,
  including the 174 MB extractor (about 3 minutes on its own). That cost appeared in
  xcodebuild's "Resolve Package Graph" phase: 11 to 25 minutes on Apple Silicon, 2 to 5
  minutes on Intel. Compiling is slower on Intel, so full builds take about as long on
  both runners; pull requests that build a few targets are faster on Intel.
- Two other fixes for that phase did not help and are not used: starting
  `xcodebuild` as arm64 under tracing crashed the relocated `xcodebuild`, and caching
  `~/Library/Caches/org.swift.swiftpm/manifests` between runs never produced a hit.
  SwiftPM keys that cache on the process environment, and the tracer adds per-process
  values such as `CODEQL_PARENT_ID` to it. A rerun that restored the exact cache from
  its first attempt still spent 21 minutes in that phase.
- Debug configuration, arm64 only (cross-compiled on the Intel runner), no code signing,
  index store off.
- `SWIFT_ENABLE_EXPLICIT_MODULES=NO`. With the Xcode 26 default (explicit modules) the
  extractor processed 1 of 226 app files in a traced build; without it, all 226.
- Under CodeQL tracing, the `metal` stub in Xcode's default toolchain reports a missing
  Metal Toolchain, so the MLX plugins (Qwen3, Canary, Granite, Voxtral, LocalLLM) fail
  to build. Setting `TOOLCHAINS` to the downloaded Metal toolchain's identifier did not
  change this with Xcode 26.6. The workflow therefore installs a one-tool toolchain in
  `~/Library/Developer/Toolchains` whose `metal` forwards to `xcrun --find metal`, and
  selects it with `TOOLCHAINS` for the build. Swift and Clang still come from the
  default toolchain. This was diagnosed on Apple Silicon; the Intel runs use the same
  setup. A local run of the build script outside CI does not need it.
- Only package checkouts are restored from the `spm-*` cache that the build workflow
  saves on Apple Silicon; the checkouts do not depend on the runner architecture.
  Compiled artifacts are never cached: a file that is not compiled under tracing is not
  extracted.
- Packages are resolved before CodeQL initialization. The traced build runs with
  `-disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile
  -skipPackageUpdates -scmProvider xcode`, so it does not resolve or fetch packages
  under tracing. The Metal toolchain check also runs before initialization.
- Xcode 27 ships arm64-only tools and does not run on the Intel runner. Moving this job
  to Xcode 27 means moving back to Apple Silicon and measuring again.

## Runtime

Job durations on GitHub-hosted runners on 2026-10-11, with a package cache hit. The
traced build is split into xcodebuild's "Resolve Package Graph" phase and compiling.

| Targets | `macos-26` (Apple Silicon) | `macos-26-intel` |
| --- | --- | --- |
| One cloud plugin (`GroqPlugin`) | 22-35 min (5 runs); resolve 12-24, compile 5 | 12 min; resolve 2, compile 4 |
| One MLX plugin (`Qwen3Plugin`) | 42-53 min (4 runs); resolve 11-23, compile 18-23 | 36 min; resolve 3, compile 22 |
| Five app targets | 42-52 min (4 runs); resolve 17-25, compile 20-22 | 39 min; resolve 3, compile 25 |
| All 58 targets | 71-79 min (2 runs); resolve 20-21, compile 43-51 | 81 min; resolve 5, compile 61 |

The Intel numbers are single runs of a timing workflow with the same build steps (run
[38161962868](https://github.com/TypeWhisper/typewhisper-mac/actions/runs/38161962868)).
The Apple Silicon numbers come from the same timing workflow and from both attempts of
PR run [38149847950](https://github.com/TypeWhisper/typewhisper-mac/actions/runs/38149847950).
Analysis, coverage check and upload add 1 to 3 minutes to a selective run on Apple
Silicon and 2 to 6 minutes on Intel; for a full run, 3 to 5 minutes against 10.

The full Intel run reported "CodeQL scanned 340 out of 504 Swift files"; the coverage
check found all 339 tracked first-party files extracted. The 504 include test files and
other Swift files outside the analyzed areas.

CI runs are full scans (last row). The other rows apply to partial runs with a target
selection. The Swift job timeout is 180 minutes.

The full scan of [main run 38180344636](https://github.com/TypeWhisper/typewhisper-mac/actions/runs/38180344636)
spent 100 minutes 31 seconds building and another 14 minutes 27 seconds analyzing
before reaching the former 120-minute job limit. It was triggered by plugin metadata
and test changes, which also cancelled the preceding full scan. The nightly schedule
avoids rebuilding all targets after every merge, and the longer timeout leaves room
for full-build runtime variation.
