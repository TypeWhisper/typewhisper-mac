# Plan: Local STT Open-Source App + TypeWhisper Integration

## Context

TypeWhisper currently relies exclusively on cloud transcription (`api.typewhisper.com`). To differentiate from competitors, offline support is planned. The solution: A **standalone open-source macOS app** for local speech recognition that:
- Works standalone as a dictation tool and file transcription tool
- Can be used by TypeWhisper as a local transcription provider via XPC/IPC
- Supports both engines: WhisperKit (Whisper CoreML) + FluidAudio (Parakeet TDT v3 CoreML)

## Engine Comparison

| | WhisperKit | FluidAudio (Parakeet v3) |
|---|---|---|
| Languages | 99+ (incl. German) | 25 European (incl. German) |
| Accuracy | ~7.4% WER (large-v3) | ~14.7% WER multilingual |
| Speed | Good (streaming capable) | Extremely fast (~190x RTF) |
| Model sizes | Tiny 39MB → Large 1.5GB | Single model ~600MB |
| Streaming | Yes | No (announced) |
| License | MIT | Apache 2.0 |
| Swift SPM | Yes | Yes |
| macOS min | 14.0 | 14.0 |

## Project Structure

```
typewhisper/
├── TypeWhisper/
│   ├── App/
│   │   ├── TypeWhisperApp.swift          # @main, MenuBarExtra
│   │   └── ServiceContainer.swift        # DI container
│   ├── Models/
│   │   ├── EngineType.swift              # .whisper / .parakeet
│   │   ├── ModelInfo.swift               # Model size, status, path
│   │   └── TranscriptionResult.swift     # Unified result type
│   ├── Services/
│   │   ├── Engine/
│   │   │   ├── TranscriptionEngine.swift # Protocol
│   │   │   ├── WhisperEngine.swift       # WhisperKit wrapper
│   │   │   └── ParakeetEngine.swift      # FluidAudio wrapper
│   │   ├── HTTPServer/
│   │   │   ├── HTTPResponse.swift        # HTTP response value type
│   │   │   ├── HTTPRequestParser.swift   # HTTP/1.1 + multipart parser
│   │   │   ├── APIRouter.swift           # Method+path router
│   │   │   ├── HTTPServer.swift          # NWListener on localhost
│   │   │   └── APIHandlers.swift         # Endpoint implementations
│   │   ├── ModelManagerService.swift     # Download, cache, lifecycle
│   │   ├── AudioFileService.swift        # Audio file to PCM conversion
│   │   ├── AudioRecordingService.swift   # Mic capture via AVAudioEngine
│   │   ├── HotkeyService.swift           # Global hotkey (KeyboardShortcuts)
│   │   └── TextInsertionService.swift    # Paste via clipboard + CGEvent
│   ├── ViewModels/
│   │   ├── FileTranscriptionViewModel.swift
│   │   ├── ModelManagerViewModel.swift
│   │   ├── SettingsViewModel.swift
│   │   ├── DictationViewModel.swift      # Dictation state machine
│   │   └── APIServerViewModel.swift      # HTTP API toggle + port
│   ├── Views/
│   │   ├── MenuBarView.swift             # Menu bar popover
│   │   ├── FileTranscriptionView.swift   # Drag & drop UI
│   │   ├── ModelManagerView.swift        # Model download/management
│   │   ├── SettingsView.swift
│   │   ├── APISettingsView.swift         # API server settings tab
│   │   ├── DictationOverlayPanel.swift   # Floating NSPanel
│   │   └── DictationOverlayView.swift    # Overlay pill UI
│   └── Resources/
│       └── Info.plist
├── TypeWhisper.xcodeproj
├── LICENSE (MIT)
└── PLAN.md
```

## Roadmap

### Phase 1: MVP - Project Setup + Batch Transcription ✅

**Goal**: Foundation is in place, user can download a model and transcribe audio files.

1. ✅ Create Xcode project (macOS App, SwiftUI, Menu Bar)
2. ✅ SPM dependencies: WhisperKit + FluidAudio
3. ✅ `TranscriptionEngine` protocol + `WhisperEngine` + `ParakeetEngine`
4. ✅ `ModelManagerService` with download + status tracking
5. ✅ Settings view: choose engine, download model
6. ✅ File transcription: file picker → transcription → display text
7. ✅ Translation support (Whisper: German in → English out)

### Phase 2: Dictation ✅

1. ✅ AudioRecordingService (AVAudioEngine mic capture → 16kHz mono Float32)
2. ✅ HotkeyService (KeyboardShortcuts SPM, push-to-talk + toggle dual-mode)
3. ✅ TextInsertionService (clipboard + CGEvent Cmd+V, AX cursor position)
4. ✅ DictationViewModel (state machine: idle → recording → processing → inserting)
5. ✅ DictationOverlayPanel + DictationOverlayView (floating pill near cursor)
6. ✅ Settings: Dictation tab with hotkey recorder + permission management
7. ✅ MenuBarView: dictation status + permission warnings

### Phase 3: Streaming + Polish ✅

1. ✅ Real-time streaming with WhisperKit (periodic buffer transcription + TranscriptionCallback)
2. ✅ Show partial results in overlay (dynamic panel sizing, scrollable text)
3. ✅ Silence detection (auto-stop after 2s in toggle mode, engine-agnostic)
4. ✅ Whisper mode (gain boost 4x, Settings toggle, persisted in UserDefaults)

### Phase 4: Local HTTP API ✅

1. ✅ HTTPResponse value type with JSON/error factories, CORS headers
2. ✅ HTTPRequestParser with HTTP/1.1 parsing + multipart form-data support (100 MB limit)
3. ✅ APIRouter with method+path dispatch, OPTIONS/CORS, 404 fallback
4. ✅ HTTPServer using NWListener on 127.0.0.1 (localhost only)
5. ✅ APIHandlers: POST /v1/transcribe, GET /v1/status, GET /v1/models
6. ✅ APIServerViewModel with toggle + port (persisted in UserDefaults)
7. ✅ APISettingsView: Settings tab with toggle, port config, status, curl examples
8. ✅ Menu bar API status indicator, network.server entitlement

### Phase 5: Polish + Release

1. Auto-start option (Login Item)
2. Model recommendation based on hardware
3. SRT/VTT export for file transcription
4. Batch processing of multiple files
5. Localization (DE + EN)
6. README, GitHub repo

## References

- [WhisperKit (Argmax)](https://github.com/argmaxinc/WhisperKit) - MIT, Swift SPM
- [FluidAudio (Parakeet CoreML)](https://github.com/FluidInference/FluidAudio) - Apache 2.0, Swift SPM
- [Parakeet TDT v3 CoreML](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml)
