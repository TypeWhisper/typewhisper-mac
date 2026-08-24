# TypeWhisper for Mac

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![macOS](https://img.shields.io/badge/macOS-14.0%2B-black.svg)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6-orange.svg)](https://swift.org)

Speech-to-text and AI text processing for macOS. Transcribe audio using
on-device AI models or cloud APIs (Groq, OpenAI, xAI/Grok), then transform the
result with reusable workflows. Your voice data stays on your Mac with local
models - or use cloud APIs for faster processing.

TypeWhisper `1.6` is the current stable release for macOS. It adds a redesigned
Settings experience, privacy-friendly statistics and portable backups, faster
and more resilient recording, calendar-aware meeting automation, expanded
workflow integrations, Simplified Chinese localization, and reliability
improvements across dictation, Recorder, local models, and cloud providers.

See the [1.6.0 release notes](docs/release-notes/1.6.0.md),
[release readiness guide](docs/release-readiness.md),
[support matrix](docs/support-matrix.md), and
[release validation process](docs/release-checklist.md) for the shipped feature
set and ongoing `1.x` maintenance gates. Manual ship checks are tracked per
candidate with the
[release checklist issue template](.github/ISSUE_TEMPLATE/release-checklist.md).

<p align="center">
  <video src="https://github.com/user-attachments/assets/22fe922d-4a4c-47d1-805e-684a148ebd03" autoplay loop muted playsinline width="270"></video>
</p>

## Screenshots

<!-- readme-screenshots:start -->

<p align="center">
  <a href=".github/screenshots/home.png"><img src=".github/screenshots/home.png" width="270" alt="Home Dashboard"></a>
  <a href=".github/screenshots/recording.png"><img src=".github/screenshots/recording.png" width="270" alt="Recording"></a>
  <a href=".github/screenshots/recovery.png"><img src=".github/screenshots/recovery.png" width="270" alt="Recovery"></a>
</p>

<p align="center">
  <a href=".github/screenshots/indicator-settings.png"><img src=".github/screenshots/indicator-settings.png" width="270" alt="Indicator Settings"></a>
  <a href=".github/screenshots/indicator.png"><img src=".github/screenshots/indicator.png" width="270" alt="Active Dictation Indicator"></a>
</p>

<p align="center">
  <a href=".github/screenshots/hotkeys.png"><img src=".github/screenshots/hotkeys.png" width="270" alt="Hotkeys"></a>
  <a href=".github/screenshots/workflows.png"><img src=".github/screenshots/workflows.png" width="270" alt="Workflows"></a>
  <a href=".github/screenshots/file-transcription.png"><img src=".github/screenshots/file-transcription.png" width="270" alt="File Transcription"></a>
</p>

<p align="center">
  <a href=".github/screenshots/recorder.png"><img src=".github/screenshots/recorder.png" width="270" alt="Recorder API"></a>
  <a href=".github/screenshots/history.png"><img src=".github/screenshots/history.png" width="270" alt="History"></a>
  <a href=".github/screenshots/dictionary.png"><img src=".github/screenshots/dictionary.png" width="270" alt="Dictionary"></a>
</p>

<p align="center">
  <a href=".github/screenshots/dictionary-term-packs.png"><img src=".github/screenshots/dictionary-term-packs.png" width="270" alt="Dictionary Term Packs"></a>
  <a href=".github/screenshots/snippets.png"><img src=".github/screenshots/snippets.png" width="270" alt="Snippets"></a>
  <a href=".github/screenshots/plugins.png"><img src=".github/screenshots/plugins.png" width="270" alt="Installed Integrations"></a>
</p>

<p align="center">
  <a href=".github/screenshots/integrations-available.png"><img src=".github/screenshots/integrations-available.png" width="270" alt="Integration Marketplace"></a>
  <a href=".github/screenshots/statistics.png"><img src=".github/screenshots/statistics.png" width="270" alt="Statistics"></a>
  <a href=".github/screenshots/license.png"><img src=".github/screenshots/license.png" width="270" alt="License"></a>
</p>

<p align="center">
  <a href=".github/screenshots/premium.png"><img src=".github/screenshots/premium.png" width="270" alt="Premium Overview"></a>
  <a href=".github/screenshots/premium-access.png"><img src=".github/screenshots/premium-access.png" width="270" alt="Premium Access"></a>
  <a href=".github/screenshots/premium-calendar.png"><img src=".github/screenshots/premium-calendar.png" width="270" alt="Premium Calendar"></a>
</p>

<p align="center">
  <a href=".github/screenshots/premium-learning.png"><img src=".github/screenshots/premium-learning.png" width="270" alt="Premium Correction Learning"></a>
  <a href=".github/screenshots/premium-sync.png"><img src=".github/screenshots/premium-sync.png" width="270" alt="Premium Cloud Sync"></a>
  <a href=".github/screenshots/premium-locked.png"><img src=".github/screenshots/premium-locked.png" width="270" alt="Premium Locked"></a>
</p>

<p align="center">
  <a href=".github/screenshots/general.png"><img src=".github/screenshots/general.png" width="270" alt="General Settings"></a>
  <a href=".github/screenshots/advanced.png"><img src=".github/screenshots/advanced.png" width="270" alt="Advanced Settings"></a>
  <a href=".github/screenshots/about.png"><img src=".github/screenshots/about.png" width="270" alt="About"></a>
</p>

<!-- readme-screenshots:end -->

The localized macOS screenshot workflow is documented in [docs/screenshot-automation.md](docs/screenshot-automation.md).

## What's New in 1.6

- **Redesigned Settings, statistics, and backups** - A consistent native
  Settings experience now includes privacy-friendly usage insights plus portable
  Backup & Restore for workflows, dictionary entries, snippets, profiles, prompt
  actions, hotkeys, installed community plugins, history text, and supported
  preferences
- **Faster, more resilient recording** - Recording startup moved off the main
  actor, eligible microphones are prewarmed, microphone priorities and route
  recovery are more robust, and controlled tests measured lower
  request-to-first-buffer times for built-in, USB, and AirPods inputs
- **Calendar-aware meeting automation** - Optional reminders, countdown
  controls, local meeting-activity checks, automatic Recorder sessions, sortable
  filenames, transcript metadata, and Obsidian-ready Markdown sidecars support
  Zoom, Microsoft Teams, Google Meet, and FaceTime meetings
- **Improved dictation and indicators** - Live transcript updates can write
  into active text fields, final insertion remains authoritative, contextual
  insertion and target-app correction learning are more reliable, and Notch,
  Overlay, and Minimal indicators gained better placement, visibility,
  interaction, and screen-capture controls
- **Expanded workflows and automation** - Ordered LLM provider fallbacks,
  explicit API-driven dictation, the MCP Client action add-on, Obsidian live
  sync and templates, bulk plugin updates, and clearer active-provider status
  extend local automation
- **Broader model and provider support** - Soniox live transcription, local
  Cohere Transcribe, context-aware OpenAI transcription, dynamic ChatGPT model
  discovery, richer OpenAI-compatible profiles, and reliability work across
  Qwen3, Gemma 4, Granite, Voxtral, Parakeet, and WhisperKit expand the engine
  ecosystem
- **Localization and platform polish** - Simplified Chinese joins the existing
  English, German, and Japanese UI, while macOS 27 Settings compatibility,
  calendar permissions, distributed-build entitlements, and stable release
  packaging received dedicated fixes

## Features

### Transcription

- **Local and cloud engines** - Choose from WhisperKit, Parakeet TDT v3, Apple
  SpeechAnalyzer, Granite Speech, Qwen3 ASR, Voxtral, Cohere Transcribe, Groq
  Whisper, OpenAI Whisper, Soniox, Smallest Pulse, xAI/Grok STT, OpenAI
  Compatible, and additional bundled or community providers
- **On-device or cloud** - Keep audio on your Mac with a local engine, or
  explicitly configure a cloud API for faster processing and additional model
  choices
- **Streaming preview** - See partial transcription in real-time while speaking (WhisperKit)
- **Short-clip handling** - Better retention of brief utterances and fewer false no-speech discards
- **File transcription** - Batch-process multiple audio/video files with drag & drop
- **Subtitle export** - Export transcriptions as SRT or WebVTT with timestamps

### Dictation

- **System-wide** - Push-to-talk, toggle, or hybrid mode via global hotkey, auto-pastes into any app
- **Modifier-key hotkeys** - Use a single modifier key (Command, Shift, Option, Control) as your hotkey
- **Indicator styles** - Choose Notch, Overlay, or Minimal, with optional live transcript preview where supported
- **Sound feedback** - Audio cues for recording start, transcription success, and errors
- **Microphone selection** - Choose a specific input device with live preview and improved recovery after route changes

### AI Processing

- **Workflows** - Build reusable transformations for translation, rewriting, extraction, formatting, and app-specific automation. Workflows can run automatically by app, website, or app + website combinations, from a dedicated hotkey, as a global fallback, or manually from the Workflow Palette. Hotkey workflows can either start dictation or process the current selection/clipboard directly.
- **LLM provider fallbacks** - Order Apple Intelligence (macOS 26+), Groq, OpenAI / ChatGPT, xAI/Grok, Gemini, OpenAI Compatible, and local providers in one global provider/model list. Prompts and workflows inherit that order by default; a workflow with an explicit provider stays on that single provider
- **Speech providers** - System voices, xAI/Grok TTS, and experimental local Supertonic TTS can provide spoken feedback and readback
- **Local prompt processing** - Gemma 4 via MLX runs on-device on Apple Silicon, with the current verified release path limited to the E2B/E4B 4-bit models
- **Translation** - Translate transcriptions on-device using Apple Translate

### Personalization

- **Workflow triggers** - Per-app, per-website, combined app + website, hotkey, global fallback, and manual palette-only triggers for language, task, engine, prompt, and auto-submit behavior. Website matching supports subdomains
- **Dictionary** - Terms improve cloud recognition accuracy. Corrections fix common transcription mistakes automatically. Auto-learns high-confidence local single-word manual corrections, while broader rewrites and deletions are skipped. Includes importable term packs
- **Localized term packs** - Built-in term pack names and descriptions are localized in English and German
- **Snippets** - Text shortcuts with trigger/replacement. Supports placeholders like `{{DATE}}`, `{{TIME}}`, and `{{CLIPBOARD}}`
- **History** - Searchable transcription history with inline editing, correction detection, app context tracking, timeline grouping, filters, bulk delete, multi-select export, auto-retention, and a standalone window accessible from the tray menu

### Premium

- **Meeting automation** - Connect selected calendars for local reminders, start
  and stop countdowns, optional automatic Recorder sessions, and structured
  transcript output for supported meeting providers
- **Correction learning** - Learn deliberate manual corrections in supported
  target apps using conservative local matching and dictionary integration
- **Cloud Folder Sync** - Sync Dictionary and Snippets data through a
  user-selected iCloud Drive, Dropbox, OneDrive, Syncthing, or custom folder;
  automatic private iCloud sync remains disabled in current distributed builds
- **Clear entitlement states** - The Premium hub shows account access and the
  exact availability of each feature for the current license or signed-in
  Premium account

### Integration & Extensibility

- **Plugin system** - Extend TypeWhisper with custom LLM providers,
  transcription engines, TTS providers, post-processors, memory providers, and
  action plugins. Bundled and registry integrations include local engines, major
  cloud providers, MCP Client, Obsidian, Linear, Script Runner, Webhook
  Notifications, and additional automation tools. See the
  [plugin catalog](TypeWhisperPluginSDK/Plugins/README.md)
- **Local model download controls** - Bundled Qwen3, Granite, Voxtral, and Supertonic plugins support an optional HuggingFace token for higher rate limits and clearer download errors. Supertonic requires explicit OpenRAIL-M model-license acceptance before model assets download.
- **HTTP API** - Local REST API for integration with external tools and scripts
- **CLI tool** - Shell-friendly transcription and settings backup via the command line
- **Discord claim service** - Optional external service for Polar supporter and GitHub Sponsors Discord role claims

### General

- **Home dashboard** - Usage statistics, activity chart, and onboarding tutorial
- **Statistics and backups** - Inspect local aggregate usage and export or
  restore supported settings and user data without uploading them to TypeWhisper
- **Auto-update** - Built-in updates via Sparkle with stable, release-candidate, and daily channels
- **Universal binary** - Runs natively on Apple Silicon and Intel Macs
- **Widgets** - Desktop widgets for usage stats, last transcription, activity chart, and transcription history
- **Multilingual UI** - English, German, Japanese, and Simplified Chinese
- **Launch at Login** - Start automatically with macOS

## Install

### Homebrew

```bash
brew install --cask typewhisper/tap/typewhisper
```

### Direct Download

Download the latest DMG from [GitHub Releases](https://github.com/TypeWhisper/typewhisper-mac/releases/latest).

Stable direct-download releases use the default Sparkle channel. Release candidates such as `1.6.0-rc*` and daily builds such as `v1.6.0-daily.*` are published as GitHub prereleases, update the shared Sparkle appcast on their own channels, and are excluded from Homebrew.
Installed builds can switch channels in `Settings -> About` via the `Update Channel` picker.

## Quick Start

1. Install TypeWhisper from Homebrew or the latest DMG.
2. Open Settings and grant Microphone plus Accessibility access.
3. Pick an engine and, if needed, download a local model.
4. Trigger the global hotkey and complete your first dictation.

## Manual Uninstall (macOS)

These steps are for official TypeWhisper release builds on macOS. They remove the app itself, its local state, widget data, and stored secrets so you can reinstall from a clean slate.

If you installed via Homebrew, you can optionally start with:

```bash
brew uninstall --cask typewhisper
```

That removes the app bundle, but it does not reliably remove all files in `~/Library` or TypeWhisper entries in Keychain.

If `~/Library` is hidden in Finder, use `Go -> Go to Folder...` and paste the paths below.

1. Quit TypeWhisper if it is running.
2. Delete the app bundle:
   ```bash
   rm -rf /Applications/TypeWhisper.app
   ```
3. Delete app data and plugins:
   ```bash
   rm -rf ~/Library/Application\ Support/TypeWhisper
   ```
4. Delete preferences:
   ```bash
   rm -f ~/Library/Preferences/com.typewhisper.mac.plist
   ```
5. Delete widget and app group data used by official releases:
   ```bash
   rm -rf ~/Library/Group\ Containers/2D8ALY3LCL.com.typewhisper.mac
   ```
6. Remove TypeWhisper secrets from Keychain:
   - In Keychain Access, search for `com.typewhisper.mac.apikey` and delete matching items.
   - This includes API and plugin secrets stored under the `com.typewhisper.mac.apikey.*` service prefix.
   - Also remove the license items stored under service `com.typewhisper.mac.apikey.license`, especially the `polar-license` and `polar-supporter` accounts.
7. If you installed the CLI tool from Settings > Advanced, remove it too:
   ```bash
   rm -f /usr/local/bin/typewhisper
   ```
8. Optional: if you want to remove exported user files as well, delete:
   ```bash
   rm -rf ~/Documents/TypeWhisper\ Recordings
   ```
9. Restart your Mac, then install the latest build again.

If a fresh install still crashes immediately after these steps, please open an issue and include your macOS version, how you installed TypeWhisper, and whether the crash happens on first launch or after granting permissions.

## System Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon (M1 or later) recommended
- 8 GB RAM minimum, 16 GB+ recommended for larger models
- Some features (Apple Translate, improved Settings UI) require macOS 15+. Apple Intelligence and SpeechAnalyzer require macOS 26+.

## Gemma 4 Support

TypeWhisper includes a bundled local Gemma 4 plugin powered by MLX for on-device prompt processing on Apple Silicon. In the current verified release path, Gemma 4 support is limited to the dense `E2B 4-bit` and `E4B 4-bit` variants; larger or unverified variants stay visible in the UI but remain disabled until they are validated end to end.

## Model Recommendations

| RAM | Recommended Models |
|-----|-------------------|
| < 8 GB | Whisper Tiny, Whisper Base |
| 8-16 GB | Whisper Small, Whisper Large v3 Turbo, Parakeet TDT v3, Voxtral Mini 4B |
| > 16 GB | Whisper Large v3 |

## Build

1. Clone the repository:
   ```bash
   git clone https://github.com/TypeWhisper/typewhisper-mac.git
   cd typewhisper-mac
   ```

2. Open in Xcode 16+:
   ```bash
   open TypeWhisper.xcodeproj
   ```

3. Select the TypeWhisper scheme and build (Cmd+B). Swift Package dependencies (WhisperKit, FluidAudio, Sparkle, TypeWhisperPluginSDK) resolve automatically.

4. Run the app. It appears as a menu bar icon - open Settings to download a model.

5. Run the automated checks before shipping changes:
   ```bash
   xcodebuild test -project TypeWhisper.xcodeproj -scheme TypeWhisper -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO CODE_SIGN_IDENTITY='-' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
   swift test --package-path TypeWhisperPluginSDK
   ```

## HTTP API

The HTTP API is an advanced local automation surface. It binds to `127.0.0.1` only, is disabled by default, and is intended for local tools and scripts.

Enable the API server in Settings > Advanced (default port: `8978`).

### Check Status

```bash
curl http://localhost:8978/v1/status
```

```json
{
  "status": "ready",
  "engine": "whisper",
  "model": "openai_whisper-large-v3_turbo",
  "supports_streaming": true,
  "supports_translation": true
}
```

### Transcribe Audio

```bash
curl -X POST http://localhost:8978/v1/transcribe \
  -F "file=@recording.wav" \
  -F "language=en"

curl -X POST http://localhost:8978/v1/transcribe \
  -F "file=@recording.wav" \
  -F "language_hint=de" \
  -F "language_hint=en"
```

```json
{
  "text": "Hello, world!",
  "language": "en",
  "duration": 2.5,
  "processing_time": 0.8,
  "engine": "whisper",
  "model": "openai_whisper-large-v3_turbo"
}
```

Optional parameters:
- `language` - ISO 639-1 code (e.g., `en`, `de`). Omit for full auto-detection.
- `language_hint` - Repeatable, ordered language hint for restricted auto-detection. Hint-aware engines receive the full list; other engines use the first hint as the requested language. Do not combine with `language`.
- `task` - `transcribe` (default) or `translate` (translates to English, WhisperKit only).
- `target_language` - ISO 639-1 code for translation target language (e.g., `es`, `fr`). Uses Apple Translate.
- `apply_corrections` - Boolean, default `true`. Set to `false` to return raw transcription text without Dictionary Corrections. For raw body uploads, send `x-apply-corrections: false`.

Uploads to `/v1/transcribe` are limited to 256 MiB, including stdin uploads from the CLI. Requests above that size return `413 Payload Too Large`. Local CLI file paths use a direct handoff to the running TypeWhisper app instead of uploading the file bytes.

### List Models

```bash
curl http://localhost:8978/v1/models
```

```json
{
  "models": [
    {
      "id": "openai_whisper-large-v3_turbo",
      "engine": "whisper",
      "name": "Large v3 Turbo",
      "status": "ready",
      "selected": true,
      "downloaded": true,
      "loaded": true
    }
  ]
}
```

### Manage Models

Download (if needed), load, and select a model. The request returns after the model is ready or the load fails:

```bash
curl -X POST http://localhost:8978/v1/models/load \
  -H "Content-Type: application/json" \
  -d '{"engine":"whisper","model":"openai_whisper-large-v3_turbo"}'
```

Unload the active model while keeping its downloaded files:

```bash
curl -X POST http://localhost:8978/v1/models/unload \
  -H "Content-Type: application/json" \
  -d '{"engine":"whisper"}'
```

Delete downloaded model files:

```bash
curl -X DELETE "http://localhost:8978/v1/models?engine=whisper&model=openai_whisper-large-v3_turbo"
```

Deleting the final downloaded model for a plugin disables that plugin. If API authentication is enabled, include the same bearer token used by the other protected endpoints.

### History

```bash
# Search history
curl "http://localhost:8978/v1/history?q=meeting&limit=10&offset=0"

# Delete entry
curl -X DELETE "http://localhost:8978/v1/history?id=<uuid>"
```

### Dictionary

```bash
# List recognition terms
curl http://localhost:8978/v1/dictionary/terms

# Merge terms, or set replace=true to replace all terms
curl -X PUT http://localhost:8978/v1/dictionary/terms \
  -H "Content-Type: application/json" \
  -d '{"terms":["TypeWhisper","WhisperKit"],"replace":false}'

# Delete one term
curl -X DELETE http://localhost:8978/v1/dictionary/terms \
  -H "Content-Type: application/json" \
  -d '{"term":"TypeWhisper"}'

# List post-transcription corrections
curl http://localhost:8978/v1/dictionary/corrections

# Add or update one correction by original text
curl -X PUT http://localhost:8978/v1/dictionary/corrections \
  -H "Content-Type: application/json" \
  -d '{"original":"teh","replacement":"the","caseSensitive":false}'

# Delete one correction
curl -X DELETE http://localhost:8978/v1/dictionary/corrections \
  -H "Content-Type: application/json" \
  -d '{"original":"teh"}'
```

### Settings Backup

The settings endpoints use the same JSON backup schema and merge/skip behavior as Settings > Advanced > Backup & Restore. Import applies every category present in the backup. While the API server is running, scripts can read its current bearer token from the owner-only discovery file:

```bash
TYPEWHISPER_API_TOKEN="$(jq -r '.token' "$HOME/Library/Application Support/TypeWhisper/api-discovery.json")"

# Export the current settings backup
(
  settings_backup_tmp="$(mktemp ./typewhisper-settings.json.tmp.XXXXXX)" || exit
  trap 'rm -f "$settings_backup_tmp"' EXIT
  curl --fail --silent --show-error http://localhost:8978/v1/settings/export \
    -H "Authorization: Bearer $TYPEWHISPER_API_TOKEN" \
    --output "$settings_backup_tmp" && \
    mv "$settings_backup_tmp" typewhisper-settings.json
)

# Import all categories from a settings backup
curl --fail --silent --show-error -X POST http://localhost:8978/v1/settings/import \
  -H "Authorization: Bearer $TYPEWHISPER_API_TOKEN" \
  -H "Content-Type: application/json" \
  --data-binary @typewhisper-settings.json
```

### Workflows

```bash
# List all workflow-backed rules
curl http://localhost:8978/v1/rules

# Toggle a workflow-backed rule on/off
curl -X PUT "http://localhost:8978/v1/rules/toggle?id=<uuid>"
```

### Dictation Control

```bash
# Start dictation (returns session id)
curl -X POST http://localhost:8978/v1/dictation/start

# Stop dictation (returns same session id)
curl -X POST http://localhost:8978/v1/dictation/stop

# Check whether dictation is currently recording
curl http://localhost:8978/v1/dictation/status

# Fetch status/result for a specific dictation session
curl "http://localhost:8978/v1/dictation/transcription?id=<uuid>"
```

Dictation control records microphone audio for system-wide insertion. A completed dictation session returns text that TypeWhisper can paste back into the active app.

### Recorder Control

Recorder control uses the same recorder path as the TypeWhisper UI, including microphone capture, optional system audio capture, mixing, finalization, and final transcription. Use it for automations that need a saved recording file or meeting/system-audio transcription without auto-pasting into another app.

```bash
# Start recorder with microphone and system audio
curl -X POST "http://localhost:8978/v1/recorder/start?mic=true&system_audio=true"

# Stop the active API recorder session
curl -X POST http://localhost:8978/v1/recorder/stop

# Check whether the recorder is currently recording
curl http://localhost:8978/v1/recorder/status

# Fetch status/result for a specific recorder session
curl "http://localhost:8978/v1/recorder/session?id=<uuid>"
```

`POST /v1/recorder/start` accepts optional query flags:
- `mic` - `true`, `false`, `1`, or `0`. If omitted, TypeWhisper uses the current recorder microphone setting.
- `system_audio` - `true`, `false`, `1`, or `0`. If omitted, TypeWhisper uses the current recorder system-audio setting.

At least one source must be enabled. If both resolved sources are disabled, the API returns `400 Bad Request`.

Start response:

```json
{
  "id": "8F8C1F45-6D03-44D2-A38C-0C4DE4F7E5F7",
  "status": "recording"
}
```

Stop response:

```json
{
  "id": "8F8C1F45-6D03-44D2-A38C-0C4DE4F7E5F7",
  "status": "finalizing"
}
```

Status response:

```json
{
  "recording": true
}
```

Session response:

```json
{
  "id": "8F8C1F45-6D03-44D2-A38C-0C4DE4F7E5F7",
  "status": "completed",
  "text": "Meeting notes from the recording.",
  "output_file": "/Users/alex/Documents/TypeWhisper Recordings/Recording 2026-05-20 14-30-00.m4a"
}
```

Recorder sessions move through `recording -> finalizing -> completed` or `failed`. If recorder transcription is disabled or produces no transcript, `text` is omitted and `output_file` still points to the finalized recording when available. Failed sessions include an `error` field.

Conflict and lookup behavior:
- Starting while the recorder is already recording or finalizing returns `409 Conflict`.
- Stopping without an active API recorder session returns `409 Conflict`.
- Polling with a missing or invalid `id` returns `400 Bad Request`.
- Polling a valid but unknown session id returns `404 Not Found`.

## CLI Tool

TypeWhisper includes a command-line tool for shell-friendly transcription. It is part of the advanced automation surface and connects to the running local API server.

### Installation

Install via Settings > Advanced > CLI Tool > Install. This places the `typewhisper` binary in `/usr/local/bin`.

### Commands

```bash
typewhisper status              # Show server status
typewhisper models              # List available models
typewhisper transcribe file.wav # Transcribe an audio file
typewhisper export settings.json # Export all supported settings
typewhisper import settings.json # Import all categories in a backup
```

### Options

| Option | Description |
|--------|-------------|
| `--port <N>` | Server port (default: auto-detect) |
| `--json` | Output as JSON |
| `--language <code>` | Source language (e.g. `en`, `de`) |
| `--language-hint <code>` | Repeatable, ordered language hint for restricted auto-detection; engines without hint support use the first hint |
| `--task <task>` | `transcribe` (default) or `translate` |
| `--translate-to <code>` | Target language for translation |
| `--no-corrections` | Return raw transcription text without Dictionary Corrections |

### Examples

```bash
# Transcribe with language and JSON output
typewhisper transcribe recording.wav --language de --json

# Restrict auto-detection to a shortlist
typewhisper transcribe recording.wav --language-hint de --language-hint en

# Pipe audio from stdin
cat audio.wav | typewhisper transcribe -

# Use in a script
typewhisper transcribe meeting.m4a --json | jq -r '.text'

# Keep a portable backup in a dotfiles repository
typewhisper export ~/.config/typewhisper/settings.json

# Restore it and receive a machine-readable import summary
typewhisper import ~/.config/typewhisper/settings.json --json
```

The CLI requires the API server to be running (Settings > Advanced) and follows the documented command and flag surface for the current stable release.

Dictionary Corrections apply to CLI transcriptions by default. Use `--no-corrections` when a script needs the raw engine output.

Local file paths are handed to the running TypeWhisper app directly, so large files do not need to fit inside an HTTP upload body. Stdin usage (`typewhisper transcribe -`) still uses the regular `/v1/transcribe` upload endpoint and is limited to 256 MiB.

## Workflows

Workflows let you configure transcription, transformation, and automation behavior per application, website, combined app + website context, hotkey, global fallback, or manual palette-only workflow. For example:

- **Mail** - German language, Whisper Large v3
- **Slack** - English language, Parakeet TDT v3
- **Terminal** - English language, auto-submit enabled
- **github.com** - English cleanup workflow that matches in any browser
- **docs.google.com** - German dictation workflow that translates to English

Create workflows in Settings > Workflows. Choose a template, then use Automatic to enable app, website, hotkey, or any combination of those trigger components. Always stays the global fallback, and Manual keeps the workflow palette-only. Hotkey workflows choose whether the shortcut starts dictation or processes the current selection/clipboard through the same insertion path as the Workflow Palette. Spoken language can be left on full auto-detect, fixed to one exact language, or restricted to a shortlist of likely languages for better detection accuracy. Website patterns support subdomain matching - e.g. `google.com` also matches `docs.google.com`.

LLM Prompt workflows inherit the ordered global LLM fallback list shown at the top of Settings > Workflows. TypeWhisper moves to the next provider/model when an inherited attempt is unavailable, cannot restore, is rate-limited, hits a network or API error, or returns no text. Selecting a provider inside a workflow disables that fallback behavior for the workflow and makes one strict provider call instead.

When you start dictating, TypeWhisper matches the active app and browser URL against enabled workflows with the following priority:
1. **App + URL match** - highest specificity (e.g. Chrome + github.com)
2. **URL-only match** - cross-browser workflows (e.g. github.com in any browser)
3. **App-only match** - generic app workflows (e.g. all of Chrome)
4. **Always fallback** - global workflow when no more specific workflow matches

Hotkeys are direct workflow shortcuts, not context conditions in the app/URL matching order. Manual workflows are excluded from automatic dictation matching. They appear only in the Workflow Palette and use the existing Workflow Palette hotkey.

The active workflow name is shown as a badge in the indicator, together with a short explanation of why it matched.

Multiple engines can be loaded simultaneously during a session for instant switching between workflows. Note that loading multiple local models increases memory usage. Set `Auto-unload model` to `Never` if you want TypeWhisper to restore previously loaded local models at launch; any active auto-unload policy keeps startup lazy and reloads the selected/downloaded model on first real use. Cloud engines (Groq, OpenAI, xAI/Grok) have negligible memory overhead.

## Plugins

TypeWhisper supports plugins for adding custom LLM providers, transcription engines, TTS providers, post-processors, and action plugins. Plugins are macOS `.bundle` files placed in `~/Library/Application Support/TypeWhisper/Plugins/`.

Bundled engines and integrations (WhisperKit, Parakeet, SpeechAnalyzer, Granite, Qwen3, Voxtral, Supertonic, Groq, OpenAI, xAI/Grok, OpenAI Compatible, Gemini, Linear, Webhook, and more) are implemented as plugins and serve as reference implementations.

See [TypeWhisperPluginSDK/Plugins/README.md](TypeWhisperPluginSDK/Plugins/README.md) for the full plugin development guide, including the event bus, host services API, and manifest format.

## Architecture

```
TypeWhisper/
├── typewhisper-cli/           # Command-line tool (transcription and settings backup)
├── PluginRegistry/            # Source registry entries for community plugin feeds
├── Plugins/                # Redirect docs and legacy entrypoint for moved first-party plugin sources
├── TypeWhisperPluginSDK/   # Plugin SDK (Swift package)
│   ├── Plugins/            # First-party plugin sources and manifests
├── TypeWhisperWidgetExtension/ # WidgetKit widgets (stats, activity, history)
├── TypeWhisperWidgetShared/    # Shared widget data models
├── App/                    # App entry point, dependency injection
├── Models/                 # Data models (TranscriptionResult, Profile, PromptAction, etc.)
├── Services/
│   ├── Cloud/              # KeychainService, WavEncoder (shared cloud utilities)
│   ├── LLM/               # Apple Intelligence provider (cloud LLM providers are plugins)
│   ├── HTTPServer/         # Local REST API (HTTPServer, APIRouter, APIHandlers)
│   ├── ModelManagerService # Transcription dispatch (delegates to plugins)
│   ├── AudioRecordingService
│   ├── AudioFileService    # Audio/video - 16kHz PCM conversion
│   ├── HotkeyService
│   ├── TextInsertionService
│   ├── WorkflowService     # Workflow matching and persistence
│   ├── HistoryService      # Transcription history persistence (SwiftData)
│   ├── DictionaryService   # Custom term corrections
│   ├── SnippetService      # Text snippets with placeholders
│   ├── PromptActionService # Prompt action persistence (SwiftData)
│   ├── PromptProcessingService # LLM orchestration for prompt execution
│   ├── PluginManager       # Plugin discovery, loading, and lifecycle
│   ├── PluginRegistryService # Plugin marketplace (download, install, update)
│   ├── PostProcessingPipeline # Priority-based text processing chain
│   ├── EventBus            # Typed publish/subscribe event system
│   ├── TranslationService  # On-device translation via Apple Translate
│   ├── SubtitleExporter    # SRT/VTT export
│   └── SoundService        # Audio feedback for recording events
├── ViewModels/             # MVVM view models with Combine
├── Views/                  # SwiftUI views
└── Resources/              # Info.plist, entitlements, localization, sounds
```

**Patterns:** MVVM with `ServiceContainer` singleton for dependency injection. ViewModels use a static `_shared` pattern. Localization via `String(localized:)` with `Localizable.xcstrings`.

## License

GPLv3 - see [LICENSE](LICENSE) for details. Commercial licensing available - see [LICENSE-COMMERCIAL.md](LICENSE-COMMERCIAL.md).
