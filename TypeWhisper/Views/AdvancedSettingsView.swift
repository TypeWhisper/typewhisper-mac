import SwiftUI
import UniformTypeIdentifiers

struct AdvancedSettingsView: View {
    @ObservedObject private var viewModel = APIServerViewModel.shared
    @ObservedObject private var memoryService = ServiceContainer.shared.memoryService
    @ObservedObject private var promptProcessingService = ServiceContainer.shared.promptProcessingService
    @ObservedObject private var modelManager = ServiceContainer.shared.modelManagerService
    @ObservedObject private var workflowService = ServiceContainer.shared.workflowService
    @ObservedObject private var dictation = DictationViewModel.shared
    @ObservedObject private var speechFeedbackService = ServiceContainer.shared.speechFeedbackService
    @ObservedObject private var pluginManager = PluginManager.shared
    @ObservedObject private var errorLogService = ServiceContainer.shared.errorLogService
    @State private var cliInstalled = false
    @State private var cliSymlinkTarget = ""
    @State private var raycastInstalled = false
    @State private var showClearMemoryConfirmation = false
    @State private var showClearUsageStatisticsConfirmation = false
    @State private var showDiagnosticsExportError = false
    @State private var diagnosticsExportErrorMessage = ""

    @State private var showBackupError = false
    @State private var backupErrorMessage = ""
    @State private var showBackupImportResult = false
    @State private var backupImportResultMessage = ""
    @State private var isImportingBackup = false

    @AppStorage(UserDefaultsKeys.historyEnabled) private var historyEnabled: Bool = true
    @AppStorage(UserDefaultsKeys.historyRetentionDays) private var historyRetentionDays: Int = 0
    @AppStorage(UserDefaultsKeys.saveAudioWithHistory) private var saveAudioWithHistory: Bool = false

    var body: some View {
        Form {
            // MARK: - Support Diagnostics
            Section(localizedAppText("Support Diagnostics", de: "Support-Diagnose")) {
                HStack {
                    Button {
                        exportDiagnostics()
                    } label: {
                        Label(
                            localizedAppText("Export Diagnostics", de: "Diagnose exportieren"),
                            systemImage: "square.and.arrow.up"
                        )
                    }

                    SettingsInfoButton(text: localizedAppText(
                        "Creates a JSON support report with app, system, permission, plugin, settings and audio device diagnostics.",
                        de: "Erstellt einen JSON-Supportbericht mit App-, System-, Berechtigungs-, Plugin-, Einstellungs- und Audiogeräte-Diagnose."
                    ))
                }
            }

            // MARK: - Backup & Restore
            Section(localizedAppText("Backup & Restore", de: "Sicherung & Wiederherstellung")) {
                HStack {
                    Button {
                        performBackupExport()
                    } label: {
                        Label(
                            localizedAppText("Export Settings…", de: "Einstellungen exportieren…"),
                            systemImage: "square.and.arrow.up"
                        )
                    }
                    .disabled(isImportingBackup)

                    Button {
                        isImportingBackup = true
                        Task {
                            await performBackupImport()
                            isImportingBackup = false
                        }
                    } label: {
                        Label(
                            localizedAppText("Import Settings…", de: "Einstellungen importieren…"),
                            systemImage: "square.and.arrow.down"
                        )
                    }
                    .disabled(isImportingBackup)

                    if isImportingBackup {
                        ProgressView()
                            .controlSize(.small)
                    }

                    SettingsInfoButton(text: localizedAppText(
                        "Exports workflows, dictionary entries, snippets, profiles, prompt actions, hotkey bindings, installed community plugins, transcription history (text only, no saved audio), the update channel, and preferences from the General, Dictation, Dictation Recovery, File Transcription, and Recorder tabs to a single file you can import on another Mac. Reinstalled plugins fetch whatever version is currently latest in the marketplace, and installing them requires network access. Provider API keys, license, Launch at Login, selected engines/models, and other machine-specific settings are not included.",
                        de: "Exportiert Workflows, Wörterbucheinträge, Snippets, Profile, Prompt-Aktionen, Hotkey-Zuordnungen, installierte Community-Plugins, den Transkriptionsverlauf (nur Text, keine gespeicherten Audioaufnahmen), den Update-Kanal sowie Einstellungen aus den Tabs Allgemein, Diktat, Diktat-Wiederherstellung, Dateitranskription und Recorder in eine Datei, die du auf einem anderen Mac importieren kannst. Wiederhergestellte Plugins laden die jeweils aktuelle Marketplace-Version, das Installieren erfordert eine Internetverbindung. Anbieter-API-Schlüssel, Lizenz, „Bei Anmeldung öffnen“, ausgewählte Engines/Modelle und andere gerätespezifische Einstellungen sind nicht enthalten."
                    ))
                }
            }

            // MARK: - Memory
            Section(String(localized: "Memory")) {
                Toggle(isOn: $memoryService.isEnabled) {
                    SettingsInfoLabel(
                        title: String(localized: "Enable Memory"),
                        info: String(localized: "Automatically extracts facts, preferences and patterns from your transcriptions using an LLM. Memories are injected into prompt context.")
                    )
                }

                if memoryService.isEnabled {
                    Picker(selection: $memoryService.captureScope) {
                        ForEach(MemoryCaptureScope.allCases) { scope in
                            Text(scope.localizedTitle).tag(scope)
                        }
                    } label: {
                        SettingsInfoLabel(
                            title: String(localized: "Capture From"),
                            info: memoryService.captureScope.localizedDescription
                        )
                    }

                    Picker(String(localized: "Extraction Provider"), selection: $memoryService.extractionProviderId) {
                        Text(String(localized: "None")).tag("")
                        ForEach(promptProcessingService.availableProviders, id: \.id) { provider in
                            Text(provider.displayName).tag(provider.id)
                        }
                    }

                    if !memoryService.extractionProviderId.isEmpty {
                        let models = promptProcessingService.modelsForProvider(memoryService.extractionProviderId)
                        if !models.isEmpty {
                            Picker(String(localized: "Extraction Model"), selection: $memoryService.extractionModel) {
                                Text(String(localized: "Default")).tag("")
                                ForEach(models, id: \.id) { model in
                                    Text(model.displayName).tag(model.id)
                                }
                            }
                        }
                    }

                    Stepper(value: $memoryService.minimumTextLength, in: 10...200, step: 10) {
                        HStack {
                            SettingsInfoLabel(
                                title: String(localized: "Min. text length"),
                                info: String(localized: "Transcriptions shorter than this are skipped for memory extraction.")
                            )
                            Spacer()
                            Text("\(memoryService.minimumTextLength)")
                                .foregroundStyle(.secondary)
                        }
                    }

                    DisclosureGroup(String(localized: "Extraction Prompt")) {
                        TextEditor(text: $memoryService.extractionPrompt)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 120)
                            .border(.separator)

                        Button(String(localized: "Reset to Default")) {
                            memoryService.extractionPrompt = MemoryService.defaultExtractionPrompt
                        }
                        .font(.caption)
                    }

                    let pluginCount = PluginManager.shared.memoryStoragePlugins.count
                    HStack {
                        Image(systemName: "circle.fill")
                            .foregroundStyle(pluginCount > 0 && !memoryService.extractionProviderId.isEmpty ? .green : .orange)
                            .font(.caption2)
                            .accessibilityHidden(true)
                        if pluginCount == 0 {
                            Text(String(localized: "No memory storage plugins active. Enable one in Integrations."))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else if memoryService.extractionProviderId.isEmpty {
                            Text(String(localized: "Select an extraction provider to start collecting memories."))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(String(localized: "\(pluginCount) storage plugin(s) active"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button(role: .destructive) {
                        showClearMemoryConfirmation = true
                    } label: {
                        Label(String(localized: "Clear All Memories"), systemImage: "trash")
                    }
                    .confirmationDialog(
                        String(localized: "Clear All Memories?"),
                        isPresented: $showClearMemoryConfirmation
                    ) {
                        Button(String(localized: "Clear All"), role: .destructive) {
                            Task { await memoryService.clearAllMemories() }
                        }
                    } message: {
                        Text(String(localized: "This will permanently delete all stored memories from all plugins. This cannot be undone."))
                    }
                }
            }

            // MARK: - Recording
            Section(String(localized: "Recording")) {
                Picker(selection: Binding(
                    get: { modelManager.autoUnloadSeconds },
                    set: { modelManager.autoUnloadSeconds = $0 }
                )) {
                    Text(String(localized: "Never")).tag(0)
                    Divider()
                    Text(String(localized: "Immediate")).tag(-1)
                    Text(String(localized: "After 2 minutes")).tag(120)
                    Text(String(localized: "After 5 minutes")).tag(300)
                    Text(String(localized: "After 10 minutes")).tag(600)
                    Text(String(localized: "After 30 minutes")).tag(1800)
                    Text(String(localized: "After 1 hour")).tag(3600)
                } label: {
                    SettingsInfoLabel(
                        title: String(localized: "Auto-unload model"),
                        info: String(localized: "Automatically unloads local models from memory after inactivity. It reloads when needed. Does not affect cloud engines.")
                    )
                }

                Toggle(isOn: $dictation.transcribeShortQuietClipsAggressively) {
                    SettingsInfoLabel(
                        title: String(localized: "Transcribe short / quiet clips more aggressively"),
                        info: String(localized: "Still discards accidental ultra-short taps, but keeps more very short or quiet recordings instead of classifying them as no speech.")
                    )
                }

                Toggle(isOn: $dictation.requireSecondEscapeToCancelRecording) {
                    SettingsInfoLabel(
                        title: String(localized: "Require second Esc press to cancel recording"),
                        info: String(localized: "When disabled, pressing Esc once immediately discards the active recording.")
                    )
                }

                Toggle(isOn: $dictation.microphoneBoostEnabled) {
                    SettingsInfoLabel(
                        title: localizedAppText("Whisper Mode (AGC)", de: "Whisper-Modus (AGC)"),
                        info: localizedAppText(
                            "Automatically raises quiet microphone input before transcription. Useful for low-gain microphones, but very noisy rooms may sound louder too.",
                            de: "Hebt leise Mikrofoneingaben vor der Transkription automatisch an. Hilft bei Mikrofonen mit niedrigem Pegel, kann in lauten Räumen aber auch Störgeräusche verstärken."
                        )
                    )
                }

                LabeledContent {
                    HStack(spacing: 8) {
                        if workflowService.shortTranscriptionMinimumWords > 0 {
                            Text(localizedAppText("under", de: "unter"))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }

                        TextField(
                            "",
                            value: $workflowService.shortTranscriptionMinimumWords,
                            format: .number
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 44)
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel(localizedAppText("Minimum words", de: "Mindestanzahl Wörter"))

                        Text(workflowService.shortTranscriptionMinimumWords == 0
                             ? localizedAppText("Off", de: "Aus")
                             : localizedAppText("words", de: "Wörtern"))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                } label: {
                    SettingsInfoLabel(
                        title: localizedAppText(
                            "Skip AI post-processing",
                            de: "KI-Nachbearbeitung überspringen"
                        ),
                        info: localizedAppText(
                            "For short dictations, the matched workflow still controls output and actions, but the AI enhancement step is skipped. Values are limited to 0-10 words; 0 disables the skip.",
                            de: "Bei kurzen Diktaten steuert der erkannte Workflow weiterhin Ausgabe und Aktionen, aber die KI-Nachbearbeitung wird übersprungen. Werte sind auf 0-10 Wörter begrenzt; 0 deaktiviert das Überspringen."
                        )
                    )
                }

                if speechFeedbackService.hasAvailableProviders {
                    Toggle(isOn: $dictation.spokenFeedbackEnabled) {
                        SettingsInfoLabel(
                            title: String(localized: "Spoken feedback"),
                            info: String(localized: "Reads back the final transcribed text after each dictation using the selected speech provider. Recording, error, and prompt announcements are only spoken through VoiceOver accessibility announcements.")
                        )
                    }

                    if dictation.spokenFeedbackEnabled {
                        let providerSelection = Binding(
                            get: { speechFeedbackService.effectiveProviderId ?? speechFeedbackService.selectedProviderId },
                            set: { speechFeedbackService.selectedProviderId = $0 }
                        )

                        Picker(String(localized: "Speech Provider"), selection: providerSelection) {
                            ForEach(speechFeedbackService.availableProviders, id: \.id) { provider in
                                Text(provider.displayName).tag(provider.id)
                            }
                        }

                        if let summary = speechFeedbackService.currentSettingsSummary {
                            Text(summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let activeProviderId = speechFeedbackService.effectiveProviderId,
                           let plugin = pluginManager.loadedTTSPlugin(for: activeProviderId),
                           plugin.instance.settingsView != nil {
                            Button(String(localized: "Configure Voice & Speed…")) {
                                PluginSettingsWindowManager.shared.present(plugin)
                            }
                        }
                    }
                }
            }

            SpokenPunctuationSettingsSection()

            // MARK: - History
            Section(String(localized: "History")) {
                Toggle(isOn: $historyEnabled) {
                    SettingsInfoLabel(
                        title: String(localized: "Save history"),
                        info: String(localized: "Saves transcriptions to the history tab.")
                    )
                }

                if historyEnabled {
                    Toggle(isOn: $saveAudioWithHistory) {
                        SettingsInfoLabel(
                            title: String(localized: "Save audio with transcriptions"),
                            info: String(localized: "Stores a WAV recording alongside each transcription. Uses approximately 1 MB per 30 seconds.")
                        )
                    }

                    Picker(selection: $historyRetentionDays) {
                        Text(String(localized: "Unlimited")).tag(0)
                        Text(String(localized: "30 days")).tag(30)
                        Text(String(localized: "60 days")).tag(60)
                        Text(String(localized: "90 days")).tag(90)
                        Text(String(localized: "180 days")).tag(180)
                    } label: {
                        SettingsInfoLabel(
                            title: String(localized: "Auto-delete after"),
                            info: String(localized: "Older entries are automatically removed at app launch.")
                        )
                    }
                }

                Button(role: .destructive) {
                    showClearUsageStatisticsConfirmation = true
                } label: {
                    Label(String(localized: "Clear Usage Statistics"), systemImage: "trash")
                }
                .confirmationDialog(
                    String(localized: "Clear Usage Statistics?"),
                    isPresented: $showClearUsageStatisticsConfirmation
                ) {
                    Button(String(localized: "Clear Statistics"), role: .destructive) {
                        ServiceContainer.shared.usageStatisticsService.clearUsageStatistics()
                    }
                } message: {
                    Text(String(localized: "This will permanently delete aggregate word, app, time-saved, and activity statistics. Transcription history entries are unchanged."))
                }
            }

            // MARK: - API Server
            Section(String(localized: "API Server")) {
                Toggle(isOn: $viewModel.isEnabled) {
                    SettingsInfoLabel(
                        title: String(localized: "Enable API Server"),
                        info: String(localized: "Advanced automation interface for local tools. Disabled by default and bound to 127.0.0.1 only.")
                    )
                }
                    .onChange(of: viewModel.isEnabled) { _, enabled in
                        if enabled {
                            viewModel.startServer()
                        } else {
                            viewModel.stopServer()
                        }
                    }

                Toggle(isOn: $viewModel.requiresAuthentication) {
                    SettingsInfoLabel(
                        title: String(localized: "Require API Token"),
                        info: String(localized: "Off by default for compatibility with existing local integrations. New clients can use api-discovery.json or send the bearer token.")
                    )
                }

                if viewModel.isEnabled {
                    HStack {
                        Image(systemName: "circle.fill")
                            .foregroundStyle(viewModel.isRunning ? .green : .orange)
                            .font(.caption2)
                            .accessibilityHidden(true)
                        Text(viewModel.isRunning
                             ? String(localized: "Running on port \(String(viewModel.port))")
                             : String(localized: "Not running"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    if let error = viewModel.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                    }
                }
            }

            // MARK: - Command Line Tool
            Section(String(localized: "Command Line Tool")) {
                HStack {
                    Image(systemName: "circle.fill")
                        .foregroundStyle(cliInstalled ? .green : .orange)
                        .font(.caption2)
                        .accessibilityHidden(true)
                    if cliInstalled {
                        Text(String(localized: "Installed at /usr/local/bin/typewhisper"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(String(localized: "Not installed"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if cliInstalled {
                    Button(String(localized: "Uninstall")) {
                        uninstallCLI()
                    }
                } else {
                    HStack {
                        Button(String(localized: "Install Command Line Tool")) {
                            installCLI()
                        }

                        SettingsInfoButton(text: String(localized: "Requires the API server to be running. The CLI tool connects to TypeWhisper's API for fast transcription without model cold starts."))
                    }
                }
            }

            // MARK: - Usage Examples
            if viewModel.isEnabled {
                Section(String(localized: "Usage Examples")) {
                    if cliInstalled {
                        cliExamples
                    } else {
                        curlExamples
                    }
                }
            }

            // MARK: - Integrations
            Section(String(localized: "Integrations")) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "command.square")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(localized: "Raycast Extension"))
                            .font(.headline)

                        if raycastInstalled {
                            HStack {
                                Button(String(localized: "Open in Raycast")) {
                                    NSWorkspace.shared.open(URL(string: "raycast://extensions/SeoFood/typewhisper")!)
                                }

                                SettingsInfoButton(text: String(localized: "Start dictation, search history and switch profiles directly from Raycast. Requires the API server to be running."))
                            }
                        } else {
                            HStack {
                                Button(String(localized: "Learn More")) {
                                    NSWorkspace.shared.open(URL(string: "https://www.raycast.com/SeoFood/typewhisper")!)
                                }

                                SettingsInfoButton(text: String(localized: "TypeWhisper works with Raycast. Start dictation and more directly from your launcher. Requires the API server to be running."))
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 500, minHeight: 300)
        .onAppear {
            raycastInstalled = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.raycast.macos"
            ) != nil
            checkCLIInstallation()
            syncSpeechFeedbackAvailability()
        }
        .onReceive(pluginManager.$loadedPlugins) { _ in
            syncSpeechFeedbackAvailability()
        }
        .alert(localizedAppText("Export Failed", de: "Export fehlgeschlagen"), isPresented: $showDiagnosticsExportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(diagnosticsExportErrorMessage)
        }
        .alert(localizedAppText("Backup Failed", de: "Sicherung fehlgeschlagen"), isPresented: $showBackupError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(backupErrorMessage)
        }
        .alert(localizedAppText("Import Complete", de: "Import abgeschlossen"), isPresented: $showBackupImportResult) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(backupImportResultMessage)
        }
    }

    // MARK: - Examples

    private var cliExamples: some View {
        VStack(alignment: .leading, spacing: 8) {
            exampleRow(String(localized: "Show help:"), "typewhisper --help")
            Divider()
            exampleRow(String(localized: "Check status:"), "typewhisper status")
            Divider()
            exampleRow(String(localized: "Transcribe audio:"), "typewhisper transcribe audio.wav")
            Divider()
            exampleRow(String(localized: "Transcribe with language:"), "typewhisper transcribe audio.wav --language de")
            Divider()
            exampleRow(String(localized: "JSON output:"), "typewhisper transcribe audio.wav --json")
            Divider()
            exampleRow(String(localized: "Pipe to clipboard:"), "typewhisper transcribe audio.wav | pbcopy")
            Divider()
            exampleRow(String(localized: "List models:"), "typewhisper models")
        }
    }

    private var curlExamples: some View {
        VStack(alignment: .leading, spacing: 8) {
            exampleRow(String(localized: "Check status:"), "curl http://127.0.0.1:\(viewModel.port)/v1/status")
            Divider()
            exampleRow(String(localized: "Transcribe audio:"), "curl -X POST http://127.0.0.1:\(viewModel.port)/v1/transcribe \\\n  -F \"file=@audio.wav\"")
            Divider()
            exampleRow(String(localized: "List models:"), "curl http://127.0.0.1:\(viewModel.port)/v1/models")
        }
    }

    private func exampleRow(_ label: String, _ command: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Text(command)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Copy"))
            }
        }
    }

    // MARK: - Support Diagnostics

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.title = localizedAppText("Export Diagnostics", de: "Diagnose exportieren")
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = diagnosticsFilename()

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    try await errorLogService.exportDiagnostics(to: url)
                } catch {
                    diagnosticsExportErrorMessage = error.localizedDescription
                    showDiagnosticsExportError = true
                }
            }
        }
    }

    private func diagnosticsFilename() -> String {
        let timestamp = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return "typewhisper-diagnostics-\(timestamp).json"
    }

    // MARK: - Backup & Restore

    private func performBackupExport() {
        guard let url = SettingsBackupExporter.presentSavePanel() else { return }
        let container = ServiceContainer.shared
        let backup = SettingsBackupExporter.buildBackup(
            workflowService: container.workflowService,
            dictionaryService: container.dictionaryService,
            snippetService: container.snippetService,
            profileService: container.profileService,
            promptActionService: container.promptActionService,
            pluginManager: container.pluginManager,
            historyService: container.historyService
        )
        do {
            try SettingsBackupExporter.saveToFile(backup, to: url)
        } catch {
            backupErrorMessage = error.localizedDescription
            showBackupError = true
        }
    }

    private func performBackupImport() async {
        guard let url = SettingsBackupExporter.presentOpenPanel() else { return }
        do {
            let data = try Data(contentsOf: url)
            let backup = try SettingsBackupExporter.parse(data)

            let container = ServiceContainer.shared
            let result = await SettingsBackupExporter.importBackup(
                backup,
                workflowService: container.workflowService,
                dictionaryService: container.dictionaryService,
                snippetService: container.snippetService,
                profileService: container.profileService,
                promptActionService: container.promptActionService,
                pluginManager: container.pluginManager,
                pluginRegistryService: container.pluginRegistryService,
                historyService: container.historyService,
                usageStatisticsService: container.usageStatisticsService
            )

            backupImportResultMessage = backupImportSummary(result)
            showBackupImportResult = true
        } catch {
            backupErrorMessage = error.localizedDescription
            showBackupError = true
        }
    }

    private func backupImportSummary(_ result: SettingsBackupExporter.ImportResult) -> String {
        var lines: [String] = []
        lines.append(String(format: String(localized: "Workflows: %d imported"), result.workflowsImported))
        lines.append(String(format: String(localized: "Dictionary: %d imported, %d skipped (already present)"), result.dictionaryImported, result.dictionarySkipped))
        lines.append(String(format: String(localized: "Snippets: %d imported, %d skipped (already present)"), result.snippetsImported, result.snippetsSkipped))
        lines.append(String(format: String(localized: "Prompt Actions: %d imported"), result.promptActionsImported))
        lines.append(String(format: String(localized: "Profiles: %d imported"), result.profilesImported))
        lines.append(String(format: String(localized: "Hotkeys: %d applied, %d skipped (already bound)"), result.hotkeysApplied, result.hotkeysSkipped))
        lines.append(String(format: String(localized: "Plugins: %d installed, %d skipped (already installed or unavailable)"), result.pluginsInstalled, result.pluginsSkipped))
        lines.append(String(format: String(localized: "History: %d imported"), result.historyImported))
        if result.updateChannelApplied {
            lines.append(String(localized: "Update channel applied"))
        }
        if result.preferencesApplied > 0 {
            lines.append(String(format: String(localized: "Preferences: %d applied"), result.preferencesApplied))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - CLI Installation

    private static let symlinkPath = "/usr/local/bin/typewhisper"

    private var cliBinaryPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/typewhisper-cli").path
    }

    private func checkCLIInstallation() {
        let fm = FileManager.default
        guard let dest = try? fm.destinationOfSymbolicLink(atPath: Self.symlinkPath) else {
            cliInstalled = false
            return
        }
        cliSymlinkTarget = dest
        cliInstalled = dest == cliBinaryPath
    }

    private func installCLI() {
        let target = cliBinaryPath
        let link = Self.symlinkPath
        let script = """
            do shell script "mkdir -p /usr/local/bin && ln -sf '\(target)' '\(link)'" with administrator privileges
            """
        runOsascript(script) {
            checkCLIInstallation()
        }
    }

    private func uninstallCLI() {
        let link = Self.symlinkPath
        let script = """
            do shell script "rm -f '\(link)'" with administrator privileges
            """
        runOsascript(script) {
            checkCLIInstallation()
        }
    }

    private func runOsascript(_ source: String, completion: @escaping @MainActor @Sendable () -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.terminationHandler = { _ in
            Task { @MainActor in completion() }
        }
        try? process.run()
    }

    private func syncSpeechFeedbackAvailability() {
        guard !speechFeedbackService.hasAvailableProviders else { return }
        if dictation.spokenFeedbackEnabled {
            dictation.spokenFeedbackEnabled = false
        } else {
            _ = speechFeedbackService.disableIfNoProvidersAvailable()
        }
    }
}

struct SettingsInfoLabel: View {
    let title: String
    let info: String

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            SettingsInfoButton(text: info)
        }
    }
}

struct SettingsInfoButton: View {
    let text: String

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .imageScale(.small)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(text)
        .accessibilityLabel(String(localized: "More information"))
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(width: 300, alignment: .leading)
        }
    }
}
