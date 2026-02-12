# Plan: Lokale STT Open-Source App + TypeWhisper-Integration

## Context

TypeWhisper nutzt aktuell ausschließlich Cloud-Transkription (`api.typewhisper.com`). Um sich von der Konkurrenz abzuheben, soll Offline-Support kommen. Die Lösung: Eine **eigenständige Open-Source macOS-App** für lokale Spracherkennung, die:
- Standalone als Diktiertool und Datei-Transkriptionstool funktioniert
- Über XPC/IPC von TypeWhisper als lokaler Transkriptions-Provider genutzt werden kann
- Beide Engines unterstützt: WhisperKit (Whisper CoreML) + FluidAudio (Parakeet TDT v3 CoreML)

## Engine-Vergleich

| | WhisperKit | FluidAudio (Parakeet v3) |
|---|---|---|
| Sprachen | 99+ (inkl. Deutsch) | 25 europäische (inkl. Deutsch) |
| Genauigkeit | ~7.4% WER (large-v3) | ~14.7% WER multilingual |
| Geschwindigkeit | Gut (Streaming möglich) | Extrem schnell (~190x RTF) |
| Modellgrößen | Tiny 39MB → Large 1.5GB | Ein Modell ~600MB |
| Streaming | Ja | Nein (angekündigt) |
| Lizenz | MIT | Apache 2.0 |
| Swift SPM | Ja | Ja |
| macOS min | 14.0 | 14.0 |

## Projektstruktur

```
typewhisper-local/
├── TypeWhisperLocal/
│   ├── App/
│   │   ├── TypeWhisperLocalApp.swift     # @main, MenuBarExtra
│   │   └── ServiceContainer.swift        # DI-Container
│   ├── Models/
│   │   ├── EngineType.swift              # .whisper / .parakeet
│   │   ├── ModelInfo.swift               # Modellgröße, Status, Pfad
│   │   └── TranscriptionResult.swift     # Einheitliches Ergebnis
│   ├── Services/
│   │   ├── Engine/
│   │   │   ├── TranscriptionEngine.swift # Protocol
│   │   │   ├── WhisperEngine.swift       # WhisperKit-Wrapper
│   │   │   └── ParakeetEngine.swift      # FluidAudio-Wrapper
│   │   ├── ModelManagerService.swift     # Download, Cache, Lifecycle
│   │   └── AudioFileService.swift        # Audio-Datei zu PCM-Konvertierung
│   ├── ViewModels/
│   │   ├── FileTranscriptionViewModel.swift
│   │   ├── ModelManagerViewModel.swift
│   │   └── SettingsViewModel.swift
│   ├── Views/
│   │   ├── MenuBarView.swift             # Menü-Bar-Popover
│   │   ├── FileTranscriptionView.swift   # Drag & Drop UI
│   │   ├── ModelManagerView.swift        # Modell-Download/Verwaltung
│   │   └── SettingsView.swift
│   └── Resources/
│       ├── Info.plist
│       └── TypeWhisperLocal.entitlements
├── TypeWhisperLocal.xcodeproj
├── LICENSE (MIT)
└── PLAN.md
```

## Phasenplan

### Phase 1: MVP - Projekt-Setup + Batch-Transkription ✅ (aktuell)

**Ziel**: Grundgerüst steht, man kann ein Modell herunterladen und Audio transkribieren.

1. ✅ Xcode-Projekt erstellen (macOS App, SwiftUI, Menu Bar)
2. ✅ SPM-Dependencies: WhisperKit + FluidAudio
3. ✅ `TranscriptionEngine` Protocol + `WhisperEngine` + `ParakeetEngine`
4. ✅ `ModelManagerService` mit Download + Status-Tracking
5. ✅ Settings-View: Engine wählen, Modell downloaden
6. ✅ Datei-Transkription: File-Picker → Transkription → Text anzeigen
7. ✅ Translation-Support (Whisper: Deutsch rein → Englisch raus)

### Phase 2: Diktierfunktion

1. AudioRecordingService (Mikrofon-Capture)
2. HotkeyService (globaler Shortcut)
3. RecordingOverlayView (minimales Overlay)
4. TextInsertionService (CGEvent-Paste)
5. RecordingViewModel (Orchestrierung)

### Phase 3: Streaming + Polish

1. Echtzeit-Streaming mit WhisperKit
2. Partial Results im Overlay anzeigen
3. Silence Detection
4. Audio-Level-Visualisierung
5. Whisper Mode (Gain-Verstärkung)

### Phase 4: XPC-Integration

1. XPC Service Target erstellen
2. `TypeWhisperLocalXPCProtocol` implementieren
3. XPC Listener + Delegate
4. TypeWhisper-seitiger `LocalTranscriptionProvider`
5. TypeWhisper Settings: "Lokal (via TypeWhisper Local)" als Provider-Option

### Phase 5: Polish + Release

1. Auto-Start Option (Login Item)
2. Modell-Empfehlung basierend auf Hardware
3. SRT/VTT-Export für Datei-Transkription
4. Batch-Verarbeitung mehrerer Dateien
5. Lokalisierung (DE + EN)
6. README, GitHub-Repo

## Quellen

- [WhisperKit (Argmax)](https://github.com/argmaxinc/WhisperKit) - MIT, Swift SPM
- [FluidAudio (Parakeet CoreML)](https://github.com/FluidInference/FluidAudio) - Apache 2.0, Swift SPM
- [Parakeet TDT v3 CoreML](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml)
