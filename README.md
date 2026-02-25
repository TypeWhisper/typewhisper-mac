# TypeWhisper for Mac

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![macOS](https://img.shields.io/badge/macOS-15.0%2B-black.svg)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6-orange.svg)](https://swift.org)

Speech-to-text and AI text processing for macOS. Transcribe audio using on-device AI models or cloud APIs (Groq, OpenAI), then process the result with custom LLM prompts. Your voice data stays on your Mac with local models - or use cloud APIs for faster processing.

<p align="center">
  <video src="https://github.com/user-attachments/assets/98e1aef9-de31-434b-aa13-cfd36c0f3155" autoplay loop muted playsinline width="700"></video>
</p>

## Screenshots

<p align="center">
  <img src=".github/screenshots/home.png" width="700" alt="Home Dashboard">
</p>

<p align="center">
  <img src=".github/screenshots/models.png" width="340" alt="Model Manager">
  <img src=".github/screenshots/prompts.png" width="340" alt="Custom Prompts">
</p>

<p align="center">
  <img src=".github/screenshots/dictation.png" width="700" alt="Hotkey Configuration">
</p>

<p align="center">
  <img src=".github/screenshots/dictionary.png" width="340" alt="Dictionary">
  <img src=".github/screenshots/snippets.png" width="340" alt="Snippets">
</p>

<p align="center">
  <img src=".github/screenshots/general.png" width="340" alt="General Settings">
</p>

<p align="center">
  <img src=".github/screenshots/history.png" width="700" alt="Transcription History">
</p>

<p align="center">
  <img src=".github/screenshots/profiles.png" width="700" alt="Profiles with App & URL Matching">
</p>

<p align="center">
  <img src=".github/screenshots/plugins.png" width="700" alt="Plugin Integrations">
</p>

## Features

### Transcription

- **Five engines** - WhisperKit (99+ languages, streaming, translation), Parakeet TDT v3 (25 European languages, extremely fast), Apple SpeechAnalyzer (macOS 26+, no model download needed), Groq Whisper, and OpenAI Whisper
- **On-device or cloud** - All processing happens locally on your Mac, or use Groq/OpenAI Whisper APIs for faster processing
- **Streaming preview** - See partial transcription in real-time while speaking (WhisperKit)
- **File transcription** - Batch-process multiple audio/video files with drag & drop
- **Subtitle export** - Export transcriptions as SRT or WebVTT with timestamps

### Dictation

- **System-wide** - Push-to-talk, toggle, or hybrid mode via global hotkey, auto-pastes into any app
- **Modifier-key hotkeys** - Use a single modifier key (Command, Shift, Option, Control) as your hotkey
- **Silence-pause mode** - Continuous dictation that automatically pauses when silence is detected
- **Global default prompt** - Set a default LLM prompt that is applied to all transcriptions automatically
- **Whisper mode** - Boosted microphone gain for quiet speech
- **Sound feedback** - Audio cues for recording start, transcription success, and errors
- **Microphone selection** - Choose a specific input device with live preview

### AI Processing

- **Custom prompts** - Process transcriptions (or any text) with LLM prompts. 8 presets included (Translate, Formal, Summarize, Fix Grammar, Email, List, Shorter, Explain). Standalone Prompt Palette via global hotkey - a floating panel for AI text processing independent of dictation
- **LLM providers** - Apple Intelligence (macOS 26+), Groq, OpenAI, and Gemini with per-prompt provider and model override
- **Translation** - Translate transcriptions on-device using Apple Translate

### Personalization

- **Profiles** - Per-app and per-website overrides for language, task, engine, whisper mode, prompt, hotkey, and auto-submit. Match by app (bundle ID) and/or domain with subdomain support
- **Dictionary** - Terms improve cloud recognition accuracy. Corrections fix common transcription mistakes automatically. Auto-learns from manual corrections. Includes importable term packs
- **Snippets** - Text shortcuts with trigger/replacement. Supports placeholders like `{{DATE}}`, `{{TIME}}`, and `{{CLIPBOARD}}`
- **History** - Searchable transcription history with inline editing, correction detection, app context tracking, timeline grouping, filters, bulk delete, multi-select export, auto-retention, and a standalone window accessible from the tray menu

### Integration & Extensibility

- **Plugin system** - Extend TypeWhisper with custom LLM providers, transcription engines, post-processors, and action plugins. Groq, OpenAI, Gemini, Linear, and Webhook ship as bundled plugins. Linear plugin enables voice-to-issue creation. See [Plugins/README.md](Plugins/README.md)
- **HTTP API** - Local REST API for integration with external tools and scripts
- **CLI tool** - Shell-friendly transcription via the command line

### General

- **Home dashboard** - Usage statistics, activity chart, and onboarding tutorial
- **Auto-update** - Built-in updates via Sparkle
- **Universal binary** - Runs natively on Apple Silicon and Intel Macs
- **Multilingual UI** - English and German
- **Launch at Login** - Start automatically with macOS

## System Requirements

- macOS 15.0 (Sequoia) or later
- Apple Silicon (M1 or later) recommended
- 8 GB RAM minimum, 16 GB+ recommended for larger models

## Model Recommendations

| RAM | Recommended Models |
|-----|-------------------|
| < 8 GB | Whisper Tiny, Whisper Base |
| 8-16 GB | Whisper Small, Whisper Large v3 Turbo, Parakeet TDT v3 |
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

## HTTP API

Enable the API server in Settings > Advanced (default port: 8978).

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
- `language` - ISO 639-1 code (e.g., `en`, `de`). Omit for auto-detection.
- `task` - `transcribe` (default) or `translate` (translates to English, WhisperKit only).
- `target_language` - ISO 639-1 code for translation target language (e.g., `es`, `fr`). Uses Apple Translate.

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
      "ready": true
    }
  ]
}
```

### History

```bash
# Search history
curl "http://localhost:8978/v1/history?q=meeting&limit=10&offset=0"

# Delete entry
curl -X DELETE "http://localhost:8978/v1/history?id=<uuid>"
```

### Profiles

```bash
# List all profiles
curl http://localhost:8978/v1/profiles

# Toggle a profile on/off
curl -X PUT "http://localhost:8978/v1/profiles/toggle?id=<uuid>"
```

### Dictation Control

```bash
# Start dictation
curl -X POST http://localhost:8978/v1/dictation/start

# Stop dictation
curl -X POST http://localhost:8978/v1/dictation/stop

# Check dictation status
curl http://localhost:8978/v1/dictation/status
```

## CLI Tool

TypeWhisper includes a command-line tool for shell-friendly transcription. It connects to the running API server.

### Installation

Install via Settings > Advanced > CLI Tool > Install. This places the `typewhisper` binary in `/usr/local/bin`.

### Commands

```bash
typewhisper status              # Show server status
typewhisper models              # List available models
typewhisper transcribe file.wav # Transcribe an audio file
```

### Options

| Option | Description |
|--------|-------------|
| `--port <N>` | Server port (default: auto-detect) |
| `--json` | Output as JSON |
| `--language <code>` | Source language (e.g. `en`, `de`) |
| `--task <task>` | `transcribe` (default) or `translate` |
| `--translate-to <code>` | Target language for translation |

### Examples

```bash
# Transcribe with language and JSON output
typewhisper transcribe recording.wav --language de --json

# Pipe audio from stdin
cat audio.wav | typewhisper transcribe -

# Use in a script
typewhisper transcribe meeting.m4a --json | jq -r '.text'
```

The CLI requires the API server to be running (Settings > Advanced).

## Profiles

Profiles let you configure transcription settings per application or website. For example:

- **Mail** - German language, Whisper Large v3
- **Slack** - English language, Parakeet TDT v3
- **Terminal** - Whisper mode always on
- **github.com** - English language (matches in any browser)
- **docs.google.com** - German language, translate to English

Create profiles in Settings > Profiles. Assign apps and/or URL patterns, set language/task/engine overrides, assign a custom prompt for automatic post-processing, configure a per-profile hotkey, enable auto-submit (automatically sends text in chat apps), and adjust priority. URL patterns support subdomain matching - e.g. `google.com` also matches `docs.google.com`. The domain autocomplete suggests domains from your transcription history.

When you start dictating, TypeWhisper matches the active app and browser URL against your profiles with the following priority:
1. **App + URL match** - highest specificity (e.g. Chrome + github.com)
2. **URL-only match** - cross-browser profiles (e.g. github.com in any browser)
3. **App-only match** - generic app profiles (e.g. all of Chrome)

The active profile name is shown as a badge in the recording overlay.

Multiple engines can be loaded simultaneously for instant switching between profiles. Note that loading multiple local models increases memory usage. Cloud engines (Groq, OpenAI) have negligible memory overhead.

## Plugins

TypeWhisper supports plugins for adding custom LLM providers, transcription engines, post-processors, and action plugins. Plugins are macOS `.bundle` files placed in `~/Library/Application Support/TypeWhisper/Plugins/`.

The built-in cloud providers (Groq, OpenAI, Gemini, Linear, Webhook) are implemented as bundled plugins and serve as reference implementations.

See [Plugins/README.md](Plugins/README.md) for the full plugin development guide, including the event bus, host services API, and manifest format.

## Architecture

```
TypeWhisper/
├── typewhisper-cli/           # Command-line tool (status, models, transcribe)
├── Plugins/                # Bundled plugins (Groq, OpenAI, Gemini, Linear, Webhook)
├── TypeWhisperPluginSDK/   # Plugin SDK (Swift package)
├── App/                    # App entry point, dependency injection
├── Models/                 # Data models (ModelInfo, TranscriptionResult, EngineType, Profile, etc.)
├── Services/
│   ├── Engine/             # WhisperEngine, ParakeetEngine, SpeechAnalyzerEngine, TranscriptionEngine protocol
│   ├── Cloud/              # CloudTranscriptionEngine, GroqEngine, OpenAIEngine
│   ├── LLM/               # LLM providers (Apple Intelligence, Groq, OpenAI) for custom prompts
│   ├── HTTPServer/         # Local REST API (HTTPServer, APIRouter, APIHandlers)
│   ├── SubtitleExporter    # SRT/VTT export
│   ├── ModelManagerService # Model download, loading, transcription dispatch
│   ├── AudioFileService    # Audio/video → 16kHz PCM conversion
│   ├── AudioRecordingService
│   ├── HotkeyService
│   ├── TextInsertionService
│   ├── ProfileService      # Per-app profile matching and persistence
│   ├── HistoryService      # Transcription history persistence (SwiftData)
│   ├── DictionaryService   # Custom term corrections
│   ├── SnippetService      # Text snippets with placeholders
│   ├── PromptActionService # Custom prompt management (SwiftData)
│   ├── PromptProcessingService # LLM orchestration for prompt execution
│   ├── PluginManager       # Plugin discovery, loading, and lifecycle
│   ├── PostProcessingPipeline # Priority-based text processing chain
│   ├── EventBus            # Typed publish/subscribe event system
│   ├── TranslationService  # On-device translation via Apple Translate
│   └── SoundService        # Audio feedback for recording events
├── ViewModels/             # MVVM view models with Combine
├── Views/                  # SwiftUI views
└── Resources/              # Info.plist, entitlements, localization, sounds
```

**Patterns:** MVVM with `ServiceContainer` singleton for dependency injection. ViewModels use a static `_shared` pattern. Localization via `String(localized:)` with `Localizable.xcstrings`.

## License

GPLv3 - see [LICENSE](LICENSE) for details. Commercial licensing available - see [LICENSE-COMMERCIAL.md](LICENSE-COMMERCIAL.md).
