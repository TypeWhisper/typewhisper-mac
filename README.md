# TypeWhisper

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![macOS](https://img.shields.io/badge/macOS-15.0%2B-black.svg)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5-orange.svg)](https://swift.org)

Local speech-to-text for macOS. Transcribe audio using on-device AI models — no cloud, no subscriptions, fully private.

## Features

- **On-device transcription** — All processing happens locally on your Mac
- **Two AI engines** — WhisperKit (99+ languages, streaming, translation) and Parakeet TDT v3 (25 European languages, extremely fast)
- **System-wide dictation** — Push-to-talk or toggle mode via global hotkey, auto-pastes into any app
- **Streaming preview** — See partial transcription in real-time while speaking (WhisperKit)
- **File transcription** — Batch-process multiple audio/video files with drag & drop
- **Subtitle export** — Export transcriptions as SRT or WebVTT with timestamps
- **Local HTTP API** — REST API for integration with external tools and scripts
- **Whisper mode** — Boosted microphone gain for quiet speech
- **Launch at Login** — Start automatically with macOS
- **Multilingual UI** — English and German

## System Requirements

- macOS 15.0 (Sequoia) or later
- Apple Silicon (M1 or later) recommended
- 8 GB RAM minimum, 16 GB+ recommended for larger models

## Model Recommendations

| RAM | Recommended Models |
|-----|-------------------|
| < 8 GB | Whisper Tiny, Whisper Base |
| 8–16 GB | Whisper Small, Whisper Large v3 Turbo, Parakeet TDT v3 |
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

3. Select the TypeWhisper scheme and build (Cmd+B). Swift Package dependencies (WhisperKit, FluidAudio, KeyboardShortcuts) resolve automatically.

4. Run the app. It appears as a menu bar icon — open Settings to download a model.

## HTTP API

Enable the API server in Settings > API Server (default port: 8787).

### Check Status

```bash
curl http://localhost:8787/v1/status
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
curl -X POST http://localhost:8787/v1/transcribe \
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
- `language` — ISO 639-1 code (e.g., `en`, `de`). Omit for auto-detection.
- `task` — `transcribe` (default) or `translate` (translates to English, WhisperKit only).

### List Models

```bash
curl http://localhost:8787/v1/models
```

## Architecture

```
TypeWhisper/
├── App/                    # App entry point, dependency injection
├── Models/                 # Data models (ModelInfo, TranscriptionResult, EngineType)
├── Services/
│   ├── Engine/             # WhisperEngine, ParakeetEngine, TranscriptionEngine protocol
│   ├── HTTPServer/         # Local REST API (HTTPServer, APIRouter, APIHandlers)
│   ├── SubtitleExporter    # SRT/VTT export
│   ├── ModelManagerService # Model download, loading, transcription dispatch
│   ├── AudioFileService    # Audio/video → 16kHz PCM conversion
│   ├── AudioRecordingService
│   ├── HotkeyService
│   └── TextInsertionService
├── ViewModels/             # MVVM view models with Combine
├── Views/                  # SwiftUI views
└── Resources/              # Info.plist, entitlements, localization
```

**Patterns:** MVVM with `ServiceContainer` singleton for dependency injection. ViewModels use a static `_shared` pattern. Localization via `String(localized:)` with `Localizable.xcstrings`.

## License

GPLv3 — see [LICENSE](LICENSE) for details. Commercial licensing available — see [LICENSE-COMMERCIAL.md](LICENSE-COMMERCIAL.md).
