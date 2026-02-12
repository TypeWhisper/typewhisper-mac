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
│   │   ├── ModelManagerService.swift     # Download, cache, lifecycle
│   │   ├── AudioFileService.swift        # Audio file to PCM conversion
│   │   ├── AudioRecordingService.swift   # Mic capture via AVAudioEngine
│   │   ├── HotkeyService.swift           # Global hotkey (KeyboardShortcuts)
│   │   └── TextInsertionService.swift    # Paste via clipboard + CGEvent
│   ├── ViewModels/
│   │   ├── FileTranscriptionViewModel.swift
│   │   ├── ModelManagerViewModel.swift
│   │   ├── SettingsViewModel.swift
│   │   └── DictationViewModel.swift      # Dictation state machine
│   ├── Views/
│   │   ├── MenuBarView.swift             # Menu bar popover
│   │   ├── FileTranscriptionView.swift   # Drag & drop UI
│   │   ├── ModelManagerView.swift        # Model download/management
│   │   ├── SettingsView.swift
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

### Phase 3: Streaming + Polish

1. Real-time streaming with WhisperKit
2. Show partial results in overlay
3. Silence detection
4. Whisper mode (gain boost)

### Phase 4: XPC Integration

1. Create XPC Service target
2. Implement `TypeWhisperLocalXPCProtocol`
3. XPC Listener + Delegate
4. TypeWhisper-side `LocalTranscriptionProvider`
5. TypeWhisper Settings: "Local (via TypeWhisper Local)" as provider option

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
