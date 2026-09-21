# Issue #1352: recoverable successful dictations

## Problem and implementation

[Issue #1352](https://github.com/TypeWhisper/typewhisper-mac/issues/1352) reports
successful Groq responses with missing speech. The success path previously deleted
the recovery recording, so a user with History audio disabled could not retry.

The success path now retains the complete original recording in a separate rolling
retry buffer: the newest three successful dictations, expiring after 24 hours.
Retention is enforced on startup, recording start, preservation, and recovery
lookup/refresh. Failed recordings keep the existing user-selected retention and
are not displaced by successes. Immediately disables both forms of recovery storage.
Cancellation still discards the active recording. History audio remains independent.

Groq's dictionary-context option defaults to the previous enabled behavior. Turning
it off removes the prompt field, including on the existing WAV retry path. Turning
it on again sends the original prompt unchanged. Post-transcription dictionary
corrections are unaffected. No prompt framing, smaller budget, automatic chunking,
upload-format switch, or completeness classifier is introduced.

Final-transcription logs include engine/model, input duration, word count/rate,
segment count/end/tail, invalid timestamp count, and primary prompt character count.
These are diagnostic measurements, not a guarantee of completeness. Neither prompt
contents nor transcript contents are included in these new log fields.

## Live provider evidence, 2026-09-21

The separate benchmark experiment `bench/experiments/issue-1352/` contains 174
successful live Groq API responses, uploaded audio hashes, source references and
exact prompts. The first 138 requests compare prompt variants, encoding and pause
controls. The additional 36 test whole WAV and overlapping WAV chunks with the
concrete PR #1353 prompt rules. Three repeats per condition check reproducibility;
they are not independent source recordings or a population failure-rate estimate.

Two natural German recordings, approximately 39 and 43 seconds, lose substantial
speech with the PR's 402-character framed prompt when encoded with the app's Apple
AAC settings. Both fail in all three repetitions; the unchanged PR assessor misses
all six. The same files with no prompt or the representative existing 598-character
bare list retain their speech content, with normal recognition differences.

For the 39-second case, whole WAV and 25-second WAV chunks with 2-second overlap
still lose speech with the PR prompt in all three repeats. The first chunk is
already incomplete before stitching. Therefore neither intervention is justified
as a general fix. The reporter's original audio and exact prompt were unavailable.

## Automated validation

Xcode 27.0 (27A266a), macOS, Swift 6:

- 20 `DictationRecoveryAudioStoreTests`: passed, including rolling count, expiry,
  restart, deletion, cancellation, disabled storage, and preservation of failures.
- Six targeted application integration tests: passed, covering apparently
  successful/incomplete output, disabled storage, provider errors, empty output,
  and timeout feedback with/without recoverable audio.
- The two new success-path integration tests were then run again explicitly with
  `saveAudioWithHistory=false`: both passed. A 40-second recording with the measured
  truncated response completes normally while the full 640,000-sample WAV remains
  recoverable. Immediately leaves no recovery audio.
- Five Groq plugin tests: passed, including persistence of the opt-out, omission
  from both M4A and WAV retry requests, and restoration of the unchanged prompt.
- Localization JSON validation (German, Japanese, Simplified Chinese) and
  `git diff --check`: passed.

The signed development app and Groq plugin were built, installed, and launched
locally. The running process loaded the new Groq plugin bundle. Recovery and Groq
settings were visually checked in isolated screenshot instances with synthetic
data; see [the before/after captures](../../.github/pr-assets/1352/README.md).
No end-to-end manual microphone/retranscription result has been recorded. The live
API calls are provider experiments; they do not substitute for app integration tests.

Local development build and launch commands (private development helpers):

```sh
"$HOME/Projects/typewhisper-dev-tools/build-typewhisper-plugin-dev.sh" GroqPlugin --enable-plugin com.typewhisper.groq "$PWD"
"$HOME/Projects/typewhisper-dev-tools/build-typewhisper-mac-dev.sh" --run "$PWD"
```

### Application tests

From this checkout:

```sh
xcodebuild test \
  -project TypeWhisper.xcodeproj \
  -scheme TypeWhisper \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/typewhisper-1352-derived \
  -clonedSourcePackagesDirPath "$HOME/Projects/typewhisper-mac-dev/DerivedData/SourcePackages" \
  -skipPackagePluginValidation \
  -only-testing:TypeWhisperTests/DictationRecoveryAudioStoreTests \
  -only-testing:TypeWhisperTests/TypeWhisperIntegrationTests/testSuccessfulButIncompleteTranscriptionKeepsCompleteRecoveryAudio \
  -only-testing:TypeWhisperTests/TypeWhisperIntegrationTests/testSuccessfulDictationWithImmediatelyRetentionCreatesNoRecoveryAudio \
  -only-testing:TypeWhisperTests/TypeWhisperIntegrationTests/testFailedTranscriptionSurfacesNewRecoveryAndOpenAction \
  -only-testing:TypeWhisperTests/TypeWhisperIntegrationTests/testEmptyTranscriptionSurfacesNewRecoveryAndOpenAction \
  -only-testing:TypeWhisperTests/TypeWhisperIntegrationTests/testTranscriptionTimeoutFeedbackWithoutRecoveryDescribesOnlyTheTimeout \
  -only-testing:TypeWhisperTests/TypeWhisperIntegrationTests/testTranscriptionTimeoutFeedbackSurfacesPreservedRecoveryAndOpenAction \
  CODE_SIGNING_ALLOWED=NO
```

The final success-path rerun used the same command with just its two success-path
`-only-testing` arguments.

### Groq tests

A temporary SwiftPM harness compiles the actual SDK, test support and Groq sources,
without resolving unrelated local-model dependencies. It does not replace product
code with stubs; only HTTP responses use the existing SDK test harness.

```sh
python3 - <<'PY'
from pathlib import Path
p = Path('/tmp/typewhisper-1352-plugin-tests')
p.mkdir(exist_ok=True)
root = Path.cwd() / 'TypeWhisperPluginSDK'
for name, target in [
    ('SDK', root / 'Sources/TypeWhisperPluginSDK'),
    ('Testing', root / 'Sources/TypeWhisperPluginSDKTesting'),
    ('Groq', root / 'Plugins/GroqPlugin'),
]:
    link = p / name
    if not link.exists():
        link.symlink_to(target, target_is_directory=True)
(p / 'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "GroqValidation", platforms: [.macOS(.v14)], targets: [
    .target(name: "TypeWhisperPluginSDK", path: "SDK"),
    .target(name: "TypeWhisperPluginSDKTesting", dependencies: ["TypeWhisperPluginSDK"], path: "Testing"),
    .target(name: "GroqPlugin", dependencies: ["TypeWhisperPluginSDK"], path: "Groq", exclude: ["Tests"], resources: [.process("Localizable.xcstrings"), .process("manifest.json")]),
    .testTarget(name: "GroqPluginTests", dependencies: ["GroqPlugin", "TypeWhisperPluginSDKTesting"], path: "Groq/Tests")
])
''')
PY
swift test --package-path /tmp/typewhisper-1352-plugin-tests
```
