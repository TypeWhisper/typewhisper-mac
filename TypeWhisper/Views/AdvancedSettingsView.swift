import SwiftUI

struct AdvancedSettingsView: View {
    @ObservedObject private var viewModel = APIServerViewModel.shared
    @ObservedObject private var memoryService = ServiceContainer.shared.memoryService
    @ObservedObject private var promptProcessingService = ServiceContainer.shared.promptProcessingService
    @ObservedObject private var modelManager = ServiceContainer.shared.modelManagerService
    @ObservedObject private var dictation = DictationViewModel.shared
    #if !APPSTORE
    @State private var cliInstalled = false
    @State private var cliSymlinkTarget = ""
    #endif
    @State private var raycastInstalled = false
    @State private var showClearMemoryConfirmation = false

    @AppStorage(UserDefaultsKeys.historyRetentionDays) private var historyRetentionDays: Int = 0
    @AppStorage(UserDefaultsKeys.saveAudioWithHistory) private var saveAudioWithHistory: Bool = false

    var body: some View {
        Form {
            // MARK: - Memory
            Section(String(localized: "Memory")) {
                Toggle(String(localized: "Enable Memory"), isOn: $memoryService.isEnabled)
                Text(String(localized: "Automatically extracts facts, preferences and patterns from your transcriptions using an LLM. Memories are injected into prompt context."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if memoryService.isEnabled {
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
                            Text(String(localized: "Min. text length"))
                            Spacer()
                            Text("\(memoryService.minimumTextLength)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(String(localized: "Transcriptions shorter than this are skipped for memory extraction."))
                        .font(.caption)
                        .foregroundStyle(.secondary)

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
                Picker(String(localized: "Auto-unload model"), selection: Binding(
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
                }

                Text(String(localized: "Automatically unloads local models from memory after inactivity. It reloads when needed. Does not affect cloud engines."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(String(localized: "Spoken feedback"), isOn: $dictation.spokenFeedbackEnabled)

                Text(String(localized: "Reads back the transcribed text via speech synthesis after each dictation."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // MARK: - History
            Section(String(localized: "History")) {
                Toggle(String(localized: "Save audio with transcriptions"), isOn: $saveAudioWithHistory)
                Text(String(localized: "Stores a WAV recording alongside each transcription. Uses approximately 1 MB per 30 seconds."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker(String(localized: "Auto-delete after"), selection: $historyRetentionDays) {
                    Text(String(localized: "Unlimited")).tag(0)
                    Text(String(localized: "30 days")).tag(30)
                    Text(String(localized: "60 days")).tag(60)
                    Text(String(localized: "90 days")).tag(90)
                    Text(String(localized: "180 days")).tag(180)
                }
                Text(String(localized: "Older entries are automatically removed at app launch."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // MARK: - API Server
            Section(String(localized: "API Server")) {
                Toggle(String(localized: "Enable API Server"), isOn: $viewModel.isEnabled)
                    .onChange(of: viewModel.isEnabled) { _, enabled in
                        if enabled {
                            viewModel.startServer()
                        } else {
                            viewModel.stopServer()
                        }
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

            #if !APPSTORE
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
                    Button(String(localized: "Install Command Line Tool")) {
                        installCLI()
                    }
                }

                Text(String(localized: "Requires the API server to be running. The CLI tool connects to TypeWhisper's API for fast transcription without model cold starts."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #endif

            // MARK: - Usage Examples
            if viewModel.isEnabled {
                Section(String(localized: "Usage Examples")) {
                    #if !APPSTORE
                    if cliInstalled {
                        cliExamples
                    } else {
                        curlExamples
                    }
                    #else
                    curlExamples
                    #endif
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
                            Text(String(localized: "Start dictation, search history and switch profiles directly from Raycast."))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(String(localized: "TypeWhisper works with Raycast. Start dictation and more directly from your launcher."))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }

                        if raycastInstalled {
                            Button(String(localized: "Open in Raycast")) {
                                NSWorkspace.shared.open(URL(string: "raycast://extensions/SeoFood/typewhisper")!)
                            }
                        } else {
                            Button(String(localized: "Learn More")) {
                                NSWorkspace.shared.open(URL(string: "https://www.raycast.com/SeoFood/typewhisper")!)
                            }
                        }

                        Text(String(localized: "Requires the API server to be running."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
            #if !APPSTORE
            checkCLIInstallation()
            #endif
        }
    }

    // MARK: - Examples

    #if !APPSTORE
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
    #endif

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

    // MARK: - CLI Installation

    #if !APPSTORE
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

    private func runOsascript(_ source: String, completion: @escaping () -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.terminationHandler = { _ in
            DispatchQueue.main.async { completion() }
        }
        try? process.run()
    }
    #endif
}
