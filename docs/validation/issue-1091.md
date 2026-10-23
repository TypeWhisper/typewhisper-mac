# Issue #1091: failed WhisperKit chunks returned as successful transcripts

The [October 8 report](https://github.com/TypeWhisper/typewhisper-mac/issues/1091#issuecomment-6062426814)
describes a very short meeting transcript with WhisperKit Large v3 and no error.
The screenshot shows English selected for a Dutch meeting and live preview disabled.
The affected audio and inference logs are unavailable, so the exact cause of that
recording's omissions remains unconfirmed.

## Reproduced failure

The pinned WhisperKit revision is `80d96762fa727f816ffceab76a6529cd12c2726f`.
Its long-audio VAD path calls `transcribeWithOptions`, then
`AudioChunking.updateSeekOffsetsForResults`. The latter logs failed chunks at
debug level and omits them from the returned results instead of throwing.

The regression fixture uses that dependency's real VAD chunker, batch scheduler
and timestamp adjustment. Only `runTranscribeTask` (model inference) is replaced
with controlled successes and failures. Three 30-second chunks, with the middle
chunk failing, previously returned `part 1 part 3` as a successful transcript.
The final timestamp was still 90 seconds, so the Recorder's audible-tail check
could not detect the missing middle chunk. Both new chunk-error tests failed
before the fix.

Two Recorder integration tests also failed before their fix: a failed final
WhisperKit call was replaced with the live preview, and a failed dictionary-free
retry was replaced with the already truncated initial result. Both sessions were
incorrectly marked completed.

## Changes

- Both WhisperKit transcription entry points inspect every VAD batch result.
  Failed chunks are retried once, serially after the batch, keeping the selected
  language, task and prompt. Successful chunks are not transcribed again.
- Retry discovery callbacks report segment and word times in the full input's
  timeline. Returned results remain chunk-local until stitching applies their
  offsets once. A regression reproduces a middle chunk reporting 30 seconds of
  progress instead of 60 seconds before this correction.
- Source progress keeps the greatest reported position for each transcription.
  Earlier positions from retries or parallel chunks are ignored, and callback
  delivery is serialized with that comparison. Three callback regressions failed
  before this correction and now cover backward updates, concurrent updates and
  independent transcription runs. Segment timestamps are not changed by this guard.
- A remaining failure includes its chunk number and reaches the
  Recorder's existing error display and `.transcription-failure.json` path.
  Neither the live preview nor the initial truncated result masks that failure.
- Cancellation from a task, a chunk, or the progress callback never becomes a
  successful partial transcript or triggers recovery work.
- WhisperKit's default VAD padding and batch progress total are preserved. Result
  timestamps and ordering are preserved across batches and recovery, including
  a shorter final chunk. This does not change WhisperKit's treatment of subsecond
  trailing audio.
- Logs include chunk retry counts and Recorder result measurements (duration,
  word count, timestamps and prompt length). These new fields contain neither
  transcript nor dictionary contents. Measurements do not establish completeness.
  Chunk log times refer to the plugin input, which the Recorder may have compacted
  to speech. The error shown to the user therefore omits a recording time range.

## Failure behavior

If one chunk still fails after retrying, the attempt fails and its newly decoded
partial text is not saved, even when most chunks succeeded. The audio remains
available for another transcription, which processes the recording again. A
failed dictionary-free retry also fails the attempt instead of saving the first
result; the audible-tail heuristic that triggered that retry can be wrong.

This change deliberately avoids marking either result complete. Recoverable
partial transcripts need an explicit incomplete state and gap metadata in the
plugin contract and Recorder UI. Adding transcript text to the diagnostic failure
JSON would also change what users share when they attach that file for support;
this change keeps that file limited to existing failure metadata.

## Verification

On October 13, 2026, all 169 selected tests passed with Xcode 27.0 (27A266a),
including eleven new regression tests. The direct-distribution test build passed
after both retry-callback corrections. An unsigned App Store compile check passed
before publication; the latest review follow-up also built and launched the signed,
sandboxed edition with WhisperKit marked installed for that launch.
`git diff --check` passed.

The signed App Store build passed `codesign --verify --deep --strict`, has an
Apple Development signature and `com.apple.security.app-sandbox = true`, and
its fresh process was verified after relaunch. The process mapped the WhisperKit
executable from its own `Contents/PlugIns/WhisperKitPlugin.bundle`. Visual Recorder
inspection was attempted but blocked by a ScreenCaptureKit stream error
(`SCStreamErrorDomain -3811`), so no visual UI or real-model inference validation
is claimed.

The repository PR preflight passed on the initial PR head: script tests, plugin
and localization policies, release-helper self-tests, and 1,148 SDK/plugin tests
across 42 test bundles (13 skipped, zero failures).

The separate `scripts/check_first_party_warnings.sh` check still fails on a
missing restated Sendable conformance in the unchanged
`AudioEngineRecoverySupportTests.swift`. The earlier build also reported missing
explicit Combine imports in `PluginSettingsView.swift` and the availability of
`AVAudioFile`'s Sendable conformance in `AudioRecorderService.swift`, both unchanged.
None of the changed files emitted a warning in either build variant.

Run from the checkout:

```sh
xcodebuild test -skipPackagePluginValidation -disableAutomaticPackageResolution \
  -project TypeWhisper.xcodeproj -scheme TypeWhisper \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/typewhisper-1091-tests \
  -clonedSourcePackagesDirPath "$HOME/Projects/typewhisper-mac-dev/DerivedData/SourcePackages" \
  -parallel-testing-enabled NO \
  -only-testing:TypeWhisperTests/WhisperKitPluginLifecycleTests \
  -only-testing:TypeWhisperTests/WhisperKitPluginCompatibilityTests \
  -only-testing:TypeWhisperTests/AudioRecorderViewModelTests \
  -only-testing:TypeWhisperTests/FileTranscriptionViewModelTests \
  -only-testing:TypeWhisperTests/SpeechOnlyAudioTests \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

bash scripts/pr-preflight.sh
```

The fixture does not load a Core ML model or reproduce acoustic recognition on
the reporter's meeting. A successful inference that omits speech without throwing
is a separate case; this change does not claim to detect every such omission.
Retesting the same saved recording with matching Recorder/File Transcription
language settings and Large v3 is still needed. Direct-distribution delivery
requires the updated WhisperKit plugin as well as the host's Recorder changes.
