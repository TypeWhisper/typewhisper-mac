# Workflows Implementation Plan

## Ziel

Dieser Plan übersetzt den freigegebenen Workflow-Spec in eine konkrete, code-nahe Umsetzungsreihenfolge.

Er ist auf den aktuellen Stand des Repos zugeschnitten:
- `Profile` ist heute das aktive Laufzeitobjekt in [TypeWhisper/Models/Profile.swift](/Users/marco/.t3/worktrees/typewhisper-mac/t3code-c5f10b51/TypeWhisper/Models/Profile.swift)
- `PromptAction` ist heute das aktive LLM-/Preset-Objekt in [TypeWhisper/Models/PromptAction.swift](/Users/marco/.t3/worktrees/typewhisper-mac/t3code-c5f10b51/TypeWhisper/Models/PromptAction.swift)
- `ProfileService` matcht Regeln für Runtime und Hotkeys in [TypeWhisper/Services/ProfileService.swift](/Users/marco/.t3/worktrees/typewhisper-mac/t3code-c5f10b51/TypeWhisper/Services/ProfileService.swift)
- `PromptActionService` liefert Prompt-Presets, Prompt-Lookups und Prompt-Persistenz in [TypeWhisper/Services/PromptActionService.swift](/Users/marco/.t3/worktrees/typewhisper-mac/t3code-c5f10b51/TypeWhisper/Services/PromptActionService.swift)
- `DictationViewModel` hängt aktuell direkt an `ProfileService` und `PromptActionService` in [TypeWhisper/ViewModels/DictationViewModel.swift](/Users/marco/.t3/worktrees/typewhisper-mac/t3code-c5f10b51/TypeWhisper/ViewModels/DictationViewModel.swift)
- Settings zeigt derzeit getrennte Tabs `Rules` und `Prompts` in [TypeWhisper/Views/SettingsView.swift](/Users/marco/.t3/worktrees/typewhisper-mac/t3code-c5f10b51/TypeWhisper/Views/SettingsView.swift)

## Leitplanken

- Neue Features werden nur noch auf dem neuen `Workflow`-Modell gebaut.
- Bestehende `profiles.store` und `prompt-actions.store` bleiben in `v1` unangetastet und bilden die Legacy-Grenze.
- `Legacy` ist read-only, sichtbar und importierbar, aber nicht ausführbar.
- Die neue Runtime führt ausschließlich `Workflows` aus.
- Der Umbau erfolgt in einer Reihenfolge, die jederzeit ein sauberes Branch-Endergebnis zulässt. Temporäre interne Parallelität ist in der Implementierung erlaubt, aber kein Zwischenzustand darf shipped werden, in dem alte und neue Runtime gleichzeitig aktiv arbeiten.

## Wichtige Architekturentscheidung

### Alte SwiftData-Modelle nicht vorschnell umbenennen

Obwohl das neue Produktmodell intern ebenfalls `Workflow` heißen soll, sollten die bestehenden SwiftData-Typen `Profile` und `PromptAction` in `v1` nicht direkt physisch umbenannt werden.

Grund:
- diese Typen hängen an bestehenden Persistenzdateien
- eine harte Umbenennung der `@Model`-Typen erhöht das Risiko für Store-Resets oder unerwartete Schema-Brüche
- der eigentliche Gewinn liegt darin, dass neue Codepfade nicht mehr von ihnen abhängen

Konsequenz:
- neues System bekommt durchgehend neue `Workflow`-Typen
- altes System wird über eine explizite Legacy-Schicht gekapselt
- physische Umbenennung alter `@Model`-Typen kann später separat erfolgen, wenn Legacy wirklich entfernt wird

## Zielarchitektur

### Neues aktives System

- `Workflow`
- `WorkflowTemplate`
- `WorkflowTrigger`
- `WorkflowBehavior`
- `WorkflowOutput`
- `WorkflowService`
- `WorkflowMatcher`
- `WorkflowImportMapper`
- `WorkflowsViewModel`
- `WorkflowBuilderViewModel`

### Legacy-Grenze

- `ProfileService` bleibt als Persistenzzugang für `profiles.store`
- `PromptActionService` bleibt als Persistenzzugang für `prompt-actions.store`
- darüber liegt ein neuer read-only Adapter:
  - `LegacyWorkflowService`
  - `LegacyWorkflow`
  - `LegacyImportDraft`

Der Rest der App soll nach der Migration nicht mehr direkt mit `Profile` oder `PromptAction` arbeiten, außer innerhalb dieser Legacy-Schicht.

## Phasen

## Phase 1: Neues Workflow-Domain-Modell und Store

### Ziel

Ein eigenständiges aktives Workflow-System schaffen, ohne bestehende Legacy-Daten zu verändern.

### Arbeitspakete

- Neues SwiftData-Modell anlegen:
  - `TypeWhisper/Models/Workflow.swift`
- Neue modellnahe Hilfstypen anlegen:
  - `WorkflowTemplate`
  - `WorkflowTrigger`
  - `WorkflowBehavior`
  - `WorkflowOutput`
- Neuen Store/Service anlegen:
  - `TypeWhisper/Services/WorkflowService.swift`
  - Persistenzdatei z. B. `workflows.store`
- Sortierung, Aktivierung, CRUD und `nextSortOrder()` für Workflows aufbauen
- Template-Katalog als neues System definieren, nicht aus `PromptAction.presets` ableiten
  - z. B. `WorkflowTemplateCatalog`
- `ServiceContainer` um `WorkflowService` erweitern

### Bewusste Abgrenzung

- `ProfileService` und `PromptActionService` bleiben unverändert aktiv im Code, aber nur als Legacy-Abhängigkeit
- keine UI-Anbindung an alte `ProfilesViewModel`-/`PromptActionsViewModel`-Flows mehr neu bauen

### Exit-Kriterien

- Workflows lassen sich unabhängig vom Legacy-Bestand speichern und laden
- `ServiceContainer` kann `WorkflowService` sauber initialisieren
- Basis-Tests für CRUD, Sortierung und Persistenz stehen

## Phase 2: Workflow-Runtime und Matching

### Ziel

Die aktive Laufzeit von `Profile`/`PromptAction` auf `Workflow` umstellen.

### Aktuelle Nahtstellen

- `ProfileService.matchRule(...)`
- `DictationViewModel.startRecording(...)`
- `DictationViewModel.scheduleDeferredRecordingMetadataCapture(...)`
- `DictationViewModel.buildLLMHandler(...)`
- `DictationSettingsHandler.syncProfileHotkeys(...)`
- `HotkeyService.registerProfileHotkeys(...)`

### Arbeitspakete

- Neuen Matcher einführen:
  - `WorkflowMatcher` oder Workflow-Matching direkt in `WorkflowService`
- Matching-Regeln für `App`, `Website`, `Hotkey` definieren
- `Global`-Fallback komplett entfernen
- `DictationViewModel` auf `WorkflowService` umstellen:
  - `matchedProfile`/`ruleMatch` durch Workflow-Pendants ersetzen
  - LLM-Postprocessing aus `WorkflowBehavior` ableiten
  - Output/Auto-Enter aus `WorkflowOutput` ableiten
- `DictationSettingsHandler` auf Workflow-Hotkeys umstellen
  - entweder umbenennen oder durch neuen `WorkflowHotkeySync` ersetzen
- `HotkeyService.registerProfileHotkeys(...)` durch workflow-neutrale API ersetzen
  - z. B. `registerWorkflowHotkeys(...)` oder `registerTriggerHotkeys(...)`
- Prompt Palette Runtime entfernen:
  - `promptPalette`-Slot nicht mehr für aktive Features verwenden
  - `PromptPaletteHandler` nicht mehr in den neuen Laufzeitpfad hängen

### Nebenwirkungen, die mitgezogen werden müssen

- `MemoryService` prüft heute `payload.ruleName` gegen `Profile`
  - auf Workflow-ID oder Workflow-Name umstellen
- `HostServicesImpl.availableRuleNames`
  - auf Workflow-Namen umstellen
- EventBus-Payloads mit `ruleName`
  - konsistent auf Workflow-Semantik bringen

### Exit-Kriterien

- Diktat ohne Legacy-Regeln funktioniert vollständig über Workflows
- Hotkey-Trigger für Workflows funktionieren
- Es gibt keinen aktiven Runtime-Pfad mehr, der `ProfileService.matchRule(...)` für neue Ausführung verwendet

## Phase 3: Neue Workflows-Oberfläche in Settings

### Ziel

Die alte Trennung `Rules`/`Prompts` im UI durch einen einzigen `Workflows`-Bereich ersetzen.

### Aktuelle Nahtstellen

- `SettingsView` mit Tabs `.profiles` und `.prompts`
- `ProfilesSettingsView`
- `PromptActionsSettingsView`

### Arbeitspakete

- `SettingsTab` umstellen:
  - neuer Tab `.workflows`
  - `profiles` und `prompts` aus der aktiven Navigation entfernen
- Neue Root-Ansicht:
  - `TypeWhisper/Views/WorkflowsSettingsView.swift`
- Interne Navigation im Workflows-Bereich:
  - `Meine Workflows`
  - `Legacy`
  - Push-Navigation für `Neuer Workflow` und `Workflow bearbeiten`
- Neue Listenansicht aufbauen:
  - lesbare Kurzbeschreibung
  - Badges für Vorlage, Trigger, Status
  - Suche, Aktivierung, Reihenfolge

### Wichtige Designregel

`Neuer Workflow` bleibt eine Aktion, kein fester Navigationspunkt.

### Exit-Kriterien

- Settings zeigt nur noch einen aktiven Workflows-Bereich
- `Prompts` ist aus der Hauptnavigation verschwunden
- die neue Liste ist vollständig an `WorkflowService` gebunden

## Phase 4: Workflow-Builder

### Ziel

Erstellen und Bearbeiten über denselben Builder-Shell abbilden.

### Arbeitspakete

- `WorkflowBuilderViewModel` aufbauen
- Builder-Seite anlegen:
  - `Vorlage`
  - `Verhalten`
  - `Trigger`
  - `Review`
- Vorlagen-Galerie als erster Abschnitt nur im Create-Flow
- Bearbeiten ohne Vorlagenwahl
- Template nach Erstellung sperren
- `Verhalten` aufteilen in:
  - vorlagenspezifische Felder
  - `Feinabstimmung`
  - `Erweitert` für Output
- Trigger-UI strikt auf genau einen Trigger beschränken:
  - App
  - Website
  - Hotkey
- Review-Satz aus dem neuen Workflow-Modell generieren

### Neue Hilfstypen

- `WorkflowDraft`
- `WorkflowTemplateDefinition`
- ggf. `WorkflowBehaviorFormState`
- ggf. `WorkflowImportWarning`

### Exit-Kriterien

- neuer Workflow kann vollständig erstellt und gespeichert werden
- bestehender Workflow kann bearbeitet werden
- die gewählte Vorlage bleibt im Edit-Flow unveränderlich

## Phase 5: Legacy-Seite und per-Eintrag-Import

### Ziel

Alte Daten lesbar halten, aber vollständig aus der aktiven Runtime herausnehmen.

### Arbeitspakete

- `LegacyWorkflowService` anlegen
  - liest `ProfileService` und `PromptActionService`
  - projiziert beides in read-only `LegacyWorkflow`-Einträge
- `Legacy`-Ansicht bauen:
  - read-only
  - klar als deprecated markiert
  - sichtbarer Import-Button pro Eintrag
- `WorkflowImportMapper` bauen:
  - `Profile` + optional `PromptAction` -> `WorkflowDraft`
  - `PromptAction` ohne klaren Trigger -> `Eigener Workflow`
  - unscharfe Fälle mit Import-Hinweis
- Import-Status persistieren
  - minimal z. B. über eigene Import-Metadaten im Workflow-Store oder kleinen Legacy-Status-Store
  - kein Link zurück zum neuen Workflow nötig

### Wichtige technische Entscheidung

Legacy wird in `v1` nicht in einen neuen Persistenzstore kopiert.

Stattdessen:
- bestehende `profiles.store` und `prompt-actions.store` bleiben die physische Quelle
- `LegacyWorkflowService` bildet daraus eine read-only Projektion

Das ist robuster und vermeidet unnötige Kopien alter Daten.

### Exit-Kriterien

- Legacy-Einträge sind sichtbar, aber nicht editierbar
- kein Legacy-Eintrag wird zur Laufzeit ausgeführt
- pro Eintrag lässt sich ein vorausgefüllter Workflow-Entwurf öffnen

## Phase 6: Nebenflächen und alte Produktbegriffe entfernen

### Ziel

Die restliche App sprachlich und funktional auf das neue Modell ausrichten.

### Arbeitspakete

- `HotkeySettingsView`
  - Prompt-Palette-Hotkey entfernen
  - nur noch globale Diktier-Hotkeys plus workflowbezogene Hotkeys im Builder
- `SetupWizardView`
  - Schritt `Prompts & AI` neu zuschneiden
  - keine Verweise mehr auf `Prompts`-Tab oder Prompt-Presets
- `LLMProvider.swift`
  - Copy `Settings > Prompts` auf `Settings > Workflows` bzw. neuen Ort anpassen
- `SettingsView`-Texte und lokalisierte Strings aktualisieren
- `ProfilesSettingsView`, `PromptActionsSettingsView`, `PromptPaletteHandler`, `PromptPalettePanel`
  - nach Abschluss der neuen Oberfläche entfernen oder klar auf Legacy reduzieren
- `PromptWizardSupport` und prompt-spezifische Wizard-Helfer entfernen, sofern keine Legacy-Abhängigkeit bleibt

### API- und Plugin-Kompatibilität

- HTTP-API in [TypeWhisper/Services/HTTPServer/APIHandlers.swift](/Users/marco/.t3/worktrees/typewhisper-mac/t3code-c5f10b51/TypeWhisper/Services/HTTPServer/APIHandlers.swift) heute mit `/v1/rules` und `/v1/profiles`
- für `v1` empfohlen:
  - bestehende Endpunkte als Kompatibilitätsalias behalten
  - Antwort intern aus `WorkflowService` speisen
  - neue Benennung erst ergänzen, nicht brechen
- Plugin-Host in [TypeWhisper/Services/HostServicesImpl.swift](/Users/marco/.t3/worktrees/typewhisper-mac/t3code-c5f10b51/TypeWhisper/Services/HostServicesImpl.swift)
  - `availableRuleNames` semantisch auf Workflow-Namen umstellen
  - API-Name kann in `v1` als Kompatibilitätsname bestehen bleiben, wenn SDK-Stabilität wichtiger ist

### Exit-Kriterien

- keine sichtbare Produktfläche spricht noch von `Prompt` oder `Rule`, außer im expliziten Legacy-Bereich
- Prompt Palette ist nicht mehr Teil des aktiven Produkts

## Phase 7: Test- und QA-Härtung

### Automatisierte Tests

- `WorkflowServiceTests`
  - CRUD
  - Sortierung
  - Persistenz
  - Aktivierung/Deaktivierung
- `WorkflowMatcherTests`
  - App-Match
  - Website-Match
  - Hotkey-Match
  - kein Global-Fallback
- `WorkflowBuilderViewModelTests`
  - Create/Edit
  - immutable Vorlage
  - Review-Text
- `LegacyWorkflowServiceTests`
  - Projektion aus `Profile` + `PromptAction`
  - read-only Verhalten
- `WorkflowImportMapperTests`
  - klare Rule-Fälle
  - Prompt-ohne-Trigger-Fälle
  - Fallback auf `Eigener Workflow`
- `DictationViewModel`-bezogene Tests
  - Runtime nutzt Workflows statt Profiles
  - LLM-Handler aus Workflow-Verhalten
  - Hotkey-Trigger ruft Workflow auf
- API-Kompatibilitätstests
  - `/v1/rules` liefert Workflow-basierten Output

### Manuelle QA

- Workflow mit App-Trigger
- Workflow mit Website-Trigger
- Workflow mit Hotkey-Trigger
- Workflow mit Feinabstimmung
- Workflow mit erweitertem Output
- Legacy-Liste sichtbar, read-only, nicht ausführbar
- Import eines Legacy-Eintrags in neuen Builder
- Setup-Wizard und Hotkey-Settings ohne alte Prompt-Palette-Begriffe

## Empfohlene Umsetzungsreihenfolge im Branch

1. Phase 1
2. Phase 2
3. Phase 3
4. Phase 4
5. Phase 5
6. Phase 6
7. Phase 7

Diese Reihenfolge ist absichtlich backend- und runtime-first.

Grund:
- der riskanteste Teil ist nicht die neue Oberfläche, sondern der saubere Schnitt zwischen neuer Workflow-Runtime und altem Legacy-Bestand
- sobald das neue aktive Modell steht, können UI und Import darauf stabil aufsetzen

## Explizit nicht Teil von v1

- automatische Bulk-Migration
- Legacy-Runtime parallel zu Workflows
- freier Canvas
- Multi-Trigger-Workflows
- Multi-App-Workflows
- Wiedereinführung einer globalen Fallback-Regel

## Ergebnis nach Abschluss

Nach Abschluss dieses Plans gilt:

- `Workflow` ist das einzige aktive Modell für neue Automationen
- `Legacy` ist Archiv und Importquelle, aber keine Runtime
- die App hat keinen aktiven `Prompts`-Tab mehr
- manuelle Aktionen laufen als `Hotkey`-Workflows
- die Benutzerführung ist auf ein einziges Objekt reduziert
