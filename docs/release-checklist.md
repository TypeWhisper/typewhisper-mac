# Release Checklist

## Before the RC Tag

- `xcodebuild test -project TypeWhisper.xcodeproj -scheme TypeWhisper -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO CODE_SIGN_IDENTITY='-' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
- `swift test --package-path TypeWhisperPluginSDK`
- `xcodebuild -project TypeWhisper.xcodeproj -scheme TypeWhisper -configuration Release -derivedDataPath build -destination 'generic/platform=macOS' CODE_SIGN_IDENTITY='-' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`
- `bash scripts/check_first_party_warnings.sh build.log`
- Review `README.md`, `SECURITY.md`, `docs/support-matrix.md`, `docs/1.1-readiness.md`, `Plugins/README.md`, and `TypeWhisperPluginSDK/README.md`
- Confirm `MARKETING_VERSION = 1.2.0` across the app, CLI, and widgets
- Prepare or refresh `docs/release-notes/1.2.0-rc2.md`
- If you want to edit the notes directly on GitHub, create or update the draft release for `v1.2.0-rc2` before pushing the tag
- Otherwise the release workflow will publish `docs/release-notes/1.2.0-rc2.md` automatically when no release already exists

## RC Smoke Checks

- Publish `1.2.0-rc*` on the `release-candidate` channel and daily builds on the `daily` channel
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
- Profile matching for app and URL
- Notch, Overlay, and Minimal indicator styles
- Transcript preview toggle for Notch and Overlay
- Plugin enable/disable
- MLX plugin settings: save and remove HuggingFace token, then verify download error copy for Qwen3, Granite, and Voxtral
- Community term pack download and apply
- Built-in term packs render localized metadata in English and German
- App audio recording with separate tracks
- Google Cloud Speech-to-Text plugin
- Sound feedback settings (enable, disable, and custom sounds)
- Non-blocking model download
- Dictionary JSON export and import
- Parakeet V2/V3 model version selection
- Very short speech clips with and without actual speech
- Streaming preview versus the no-speech guard
- Media pause during recording (play music, start recording, verify pause, stop recording, verify resume)
- Mouse button shortcut (configure and trigger dictation)
- Remapped Hyperkey shortcut (record, stop, and prompt palette paths)
- Audio preview and recording after input-device changes, especially AirPods and Bluetooth profile switches
- Auto Enter profile setting (enable in profile, verify Enter is sent after dictation)
- Disable history saving (toggle off, dictate, verify no entry created)
- STT and AI-processed text both shown in the history entry
- Verify CLI and HTTP API locally
- Upgrade from `1.1.0`

## Before `1.2.0`

- Observe `1.2.0-rc2` on real machines for multiple days
- No open P0/P1 bugs in the core workflow
- Finalize release notes
- RC and daily tags must not update Homebrew or trigger stable website messaging
- Verify DMG, ZIP, and the `release-candidate` appcast entry with `minimumSystemVersion` set to `14.0`
- Verify Homebrew and the stable appcast update only at the final `1.2.0`
