# TypeWhisper Support Matrix

Diese Matrix beschreibt den offiziell unterstuetzten `1.0`-Pfad fuer Direct-Download-Releases.

## Plattform

| Bereich | Support |
| --- | --- |
| Basis-Support | macOS 14+ |
| Empfohlene Hardware | Apple Silicon |
| Intel | Smoke-test vor Releases, solange Universal Binary versprochen wird |

## Feature-Matrix nach macOS-Version

| Feature | macOS 14 | macOS 15 | macOS 26+ | Hinweise |
| --- | --- | --- | --- | --- |
| Systemweite Dictation | Ja | Ja | Ja | Kernworkflow fuer `1.0` |
| Datei-Transkription | Ja | Ja | Ja | Kernworkflow fuer `1.0` |
| Prompt-Verarbeitung | Ja | Ja | Ja | Kernworkflow fuer `1.0` |
| Profiles, History, Dictionary, Snippets | Ja | Ja | Ja | Kernworkflow fuer `1.0` |
| Widgets | Ja | Ja | Ja | Nicht Teil des Kernpfads |
| HTTP API | Ja | Ja | Ja | Loopback-only, standardmaessig deaktiviert |
| CLI | Ja | Ja | Ja | Benoetigt laufenden lokalen API-Server |
| Apple Translate Integration | Nein | Ja | Ja | Advanced surface |
| Verbesserte Settings-UI | Nein | Ja | Ja | Optionaler Komfortgewinn |
| Apple Intelligence Provider | Nein | Nein | Ja | Optional, nicht Teil des Kernpfads |
| SpeechAnalyzer Engine | Nein | Nein | Ja | Optional, nicht Teil des Kernpfads |

## Engine-Hinweise

| Engine-Typ | Support in 1.0 | Hinweise |
| --- | --- | --- |
| Lokale Engines | Ja | Empfohlener Standardpfad |
| Cloud-Engines | Ja | Brauchen gueltige API-Keys |
| Gebuendelte Plugins | Ja | Teil des getesteten Produktpfads |
| Externe Drittanbieter-Plugins | Best effort | Kein Launch-Blocker fuer `1.0` |

## Automation-Hinweise

| Surface | Status in 1.0 |
| --- | --- |
| HTTP API `/v1/*` | Stabil fuer `1.x` |
| `typewhisper` CLI | Stabil fuer `1.0.x` |
| Plugin SDK | Stabil fuer `1.x` |
