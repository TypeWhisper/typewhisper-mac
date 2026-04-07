# Release Checklist

## Before the RC

- `xcodebuild test -project TypeWhisper.xcodeproj -scheme TypeWhisper -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO CODE_SIGN_IDENTITY='-' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
- `swift test --package-path TypeWhisperPluginSDK`
- `xcodebuild -project TypeWhisper.xcodeproj -scheme TypeWhisper -configuration Release -derivedDataPath build -destination 'generic/platform=macOS' CODE_SIGN_IDENTITY='-' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
- `bash scripts/check_first_party_warnings.sh build.log`
- Review README, Security Policy, and Support Matrix

## RC Smoke-Checks

- Publish `1.1.0-rc*` on the `release-candidate` channel and daily builds on the `daily` channel
- Stable builds must use only the default channel
- Fresh install
- Permission recovery
- First dictation
- File transcription
- Prompt action
- Prompt wizard step (cross-tab navigation)
- Prompt drag-and-drop reordering
- History edit/export
- Post-processing transparency in history and indicators
- Profile matching
- Plugin enable/disable
- Community term pack download and apply
- App audio recording with separate tracks
- Google Cloud Speech-to-Text plugin
- Sound feedback settings (enable/disable/change sounds)
- Non-blocking model download
- Dictionary JSON export and import
- Parakeet V2/V3 model version selection
- Media pause during recording (play music, start recording, verify pause, stop recording, verify resume)
- Mouse button shortcut (configure and trigger dictation)
- Auto Enter profile setting (enable in profile, verify Enter is sent after dictation)
- Disable history saving (toggle off, dictate, verify no entry created)
- STT and AI-processed text both shown in history entry
- Verify CLI and HTTP API locally
- Upgrade from `1.0.0`

## Before `1.1.0`

- Observe `1.1.0-rc1` on real machines for multiple days
- No open P0/P1 bugs in the core workflow
- Update release notes
- RC and daily tags must not update Homebrew
- Verify DMG, appcast, and Homebrew update only at the final `1.1.0`
