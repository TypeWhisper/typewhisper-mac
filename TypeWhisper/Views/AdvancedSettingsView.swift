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
    @State private var showDiagnosticsExportError = false
    @State private var diagnosticsExportErrorMessage = ""

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
