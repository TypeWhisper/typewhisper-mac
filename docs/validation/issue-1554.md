# Speaker profile API validation (#1554)

Validated locally on 2026-10-12 on branch `seofood/1554-speaker-profile-api`.

## Results

- 133 selected tests passed, including 22 speaker API tests.
- The production HTTP server accepted name/enroll/retry requests over a real
  loopback connection against disposable History and voice-profile stores.
- Twelve concurrent enrollment requests learned a sample only once.
- Reloading both stores preserved the enrollment receipt and confirmed names.
- An injected History write failure after a voice commit was recovered by retry
  without increasing the learning weight. A filesystem failure in the voice
  store did not publish a profile or confirm a name.
- Naming, enrollment, confirmation, Premium requirements, mandatory tokens,
  stale revisions, model changes, deleted profiles,
  explicit profile IDs, equal names, and existing workspace behavior were tested.
- Review regressions cover stale requests after merge, assign and split,
  receipt provenance across speaker renumbering and restart, partly learned
  merges and explicit relearning, failed correction persistence, legacy links,
  Unicode joiners, duplicate-name selection, and receipt cleanup on deletion.
- Missing transcript versions are rejected. History reports the current version
  and Premium-dependent voice state. Ambiguous name-only UI enrollment cannot
  silently choose one of several profiles.
- A later recording produced a profile suggestion from controlled embeddings;
  confirmation and replay preserved the expected accumulated speech duration.
- Both direct-distribution and App Store development editions built, were
  signed with Apple Development, and launched successfully.
- The running signed direct-distribution Dev app returned 401 without a token
  and 400 for an authenticated empty payload on all three new endpoints.
  These smoke requests did not modify existing user records.

The fixture audio contains silence and uses controlled speaker embeddings. These
results establish API, storage, matching, and recovery behavior, not fresh
speaker-diarization quality or recognition across real meeting recordings.

## Commands

```sh
xcodebuild test -skipPackagePluginValidation -disableAutomaticPackageResolution \
  -project TypeWhisper.xcodeproj -scheme TypeWhisper \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/typewhisper-1554-tests \
  -clonedSourcePackagesDirPath "$HOME/Projects/typewhisper-mac-dev/DerivedData/SourcePackages" \
  -parallel-testing-enabled NO \
  -only-testing:TypeWhisperTests/SpeakerProfileAPITests \
  -only-testing:TypeWhisperTests/SpeakerVoiceProfileServiceTests \
  -only-testing:TypeWhisperTests/VoiceProfileStoreTests \
  -only-testing:TypeWhisperTests/VoiceProfileMatchingTests \
  -only-testing:TypeWhisperTests/HistoryServiceTests \
  -only-testing:TypeWhisperTests/HTTPRequestParserTests \
  -only-testing:TypeWhisperTests/SpeakerSyncHistoryTests \
  -only-testing:TypeWhisperTests/SpeakerWorkspaceTests \
  -only-testing:TypeWhisperTests/SpeakerWorkspaceModelTests \
  -only-testing:TypeWhisperTests/TextProcessingAPITests \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

"$HOME/Projects/typewhisper-dev-tools/build-typewhisper-mac-dev.sh" --run "$PWD"

git diff --check
bash scripts/check_first_party_warnings.sh /tmp/typewhisper-1554-review-final-tests.log
```

The warning check reports warnings in unchanged `PluginSettingsView.swift`
(Combine imports), `AudioRecorderService.swift` (AVAudioFile Sendable availability),
and `AudioEngineRecoverySupportTests.swift` (inherited Sendable declaration).
No warnings were reported in the files changed for this issue. The warning
check is therefore not a clean pass, despite successful tests and both builds.
