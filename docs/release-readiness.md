# TypeWhisper 1.x Release Readiness

This document defines the release gates for the current `1.x` product path leading into the stable `1.3.0` release.

TypeWhisper `1.x` is a stable direct-download release line for macOS. The Mac App Store remains out of scope. For `1.3`, the focus is spoken feedback, per-request engine control, multilingual hints, hotkey robustness, and streaming-dictionary support in plugins.

## Audience

- macOS users who want system-wide dictation with their own engine choice
- Users who want to transcribe audio or video files locally or through the API
- Power users who need prompt processing, profiles, plugins, and local automation
- Automation users who drive TypeWhisper through the HTTP API or CLI

## Officially Supported Core

- System-wide dictation with a global hotkey and text insertion
- File transcription, including batch processing and export
- Prompt processing with bundled presets and custom actions
- Profiles for app- and URL-based control, with a default fallback profile
- History, Dictionary, and Snippets
- Bundled default integrations and bundled plugins

## Supported Advanced Surfaces

These surfaces remain part of `1.x`, but they are positioned as advanced or automation surfaces:

- Local HTTP API under `/v1/*` with per-request engine and model selection
- `typewhisper` CLI with `--engine` and `--model` flags
- Plugin SDK and plugin manifests, including TTS and streaming-dictionary hooks
- Widgets
- Watch Folder

## `1.3` Focus Areas

- Spoken feedback (TTS) with a new bundled `System Voice` plugin, scoped to transcription readback
- Per-request STT engine/model selection through the HTTP API and CLI
- Multilingual language hints with a multi-select picker and selected-count indicator
- Fn press-and-release and press-and-hold hotkey strategies
- GPT-5/Codex compatibility for the bundled OpenAI plugin
- Dictionary terms forwarded through streaming transcription providers without breaking sessions
- Qwen3 context-bias formatter refactor
- Audio recovery hardening around Bluetooth route changes
- Fixes landed from the 1.2.3 review pass (K1-K4, M1/M7/M8)

## Stability Contracts for `1.x`

### HTTP API

- Documented endpoints under `/v1/*` remain stable for `1.x`.
- Response fields must not be removed before `2.0` without deprecation.
- The API is loopback-only, disabled by default, and intended for local automation.
- Per-request `engine` and `model` parameters fall back to the active profile defaults when omitted.

### CLI

- `typewhisper status`
- `typewhisper models`
- `typewhisper transcribe`
- Flags: `--port`, `--json`, `--language`, `--language-hint`, `--task`, `--translate-to`, `--engine`, `--model`

### Plugin SDK

- `manifest.json`
- `TypeWhisperPlugin`
- `PostProcessorPlugin`
- `LLMProviderPlugin`
- `TranscriptionEnginePlugin`
- `ActionPlugin`
- `TTSProviderPlugin`
- `HostServices`

## Release Gates

`1.3.0` is only tagged once all of the following conditions are met:

- `xcodebuild test` for the app scheme passes.
- `swift test --package-path TypeWhisperPluginSDK` passes.
- The app release build passes.
- There are no first-party build warnings.
- Plugin manifests validate successfully.
- README, security guidance, support matrix, and plugin documentation are up to date.
- The `1.3.0-rc*` line ran on real machines for multiple days without P0/P1 blockers before the stable tag.
- The default channel remains `stable`; `release-candidate` and `daily` exist as Sparkle channels for preview builds.
- `1.3.0-rc*` and daily builds are distributed as GitHub prereleases, appear in the shared Sparkle appcast only on their own channels, and do not update Homebrew.
- The appcast entry for preview builds advertises `minimumSystemVersion` `14.0`.

## Manual Smoke Checks Before Tagging

- Fresh install on a clean machine
- Permission flow: microphone, accessibility, recovery after revoked access
- First successful dictation
- File transcription
- Prompt action from the app
- Prompt wizard flow across tabs
- History edit/export
- History entry shows both STT and AI-processed text where applicable
- Profile matching for app and URL, including the default fallback profile
- Auto Enter profile behavior
- Plugin enable/disable
- Community term pack download and apply
- Sound feedback settings and sound switching
- Spoken feedback (TTS) enable/disable, voice and speed selection, scope limited to transcription readback
- Per-request engine/model selection through the HTTP API and CLI
- Multilingual language hints: picker, search, multi-select, selected count, dictation verification
- Fn hotkey in press-and-release and press-and-hold strategies
- CLI against a running local server, including `--engine` and `--model`
- HTTP API `status`, `models`, `transcribe`
- Notch, Overlay, and Minimal indicator styles
- Transcript preview toggle
- MLX plugin settings for HuggingFace token storage and removal
- Dictionary terms streamed through AssemblyAI, Soniox, and SpeechAnalyzer without session breakage
- Very short speech clips and streaming-preview/no-speech guard behavior
- Audio preview and recording after device changes, especially AirPods/Bluetooth profile switches; no crash during Bluetooth route changes
- Upgrade from `1.2.2` with History, Profiles, Dictionary, Snippets, hotkeys, enabled plugins, and update channel preserved

## Release Outputs

- Stable releases publish DMG and ZIP assets
- RC and daily releases publish GitHub prereleases only
- Stable releases update Homebrew and the stable appcast entry
- RC and daily releases update only their own Sparkle channels

## Support and Diagnostics

- Support requests should always include the JSON diagnostics export from the Error Log.
- The export includes the app version, macOS version, API status, active plugins, and privacy-safe settings metadata.
- The export contains no API keys, no audio data, and no transcription history.
