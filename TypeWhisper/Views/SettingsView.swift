import SwiftUI

enum SettingsTab: Hashable {
    case home, general, recording, hotkeys, recorder
    case fileTranscription, history, dictionary, snippets, profiles, prompts, integrations, advanced, about
}

struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .home
    @ObservedObject private var fileTranscription = FileTranscriptionViewModel.shared
    @ObservedObject private var registryService = PluginRegistryService.shared
    @ObservedObject private var homeViewModel = HomeViewModel.shared
    @AppStorage(UserDefaultsKeys.showRecorderTab) private var showRecorderTab = false

    var body: some View {
        Group {
            if #available(macOS 15, *) {
                TabView(selection: $selectedTab) {
                    SettingsMainTabs(pluginUpdatesBadge: registryService.availableUpdatesCount, showRecorderTab: showRecorderTab)
                }
                .tabViewStyle(.sidebarAdaptable)
            } else {
                TabView(selection: $selectedTab) {
                    Group {
                        HomeSettingsView()
                            .tabItem { Label(String(localized: "Home"), systemImage: "house") }
                            .tag(SettingsTab.home)
                        GeneralSettingsView()
                            .tabItem { Label(String(localized: "General"), systemImage: "gear") }
                            .tag(SettingsTab.general)
                        RecordingSettingsView()
                            .tabItem { Label(String(localized: "Recording"), systemImage: "mic.fill") }
                            .tag(SettingsTab.recording)
                        HotkeySettingsView()
                            .tabItem { Label(String(localized: "Hotkeys"), systemImage: "keyboard") }
                            .tag(SettingsTab.hotkeys)
                        FileTranscriptionView()
                            .tabItem { Label(String(localized: "File Transcription"), systemImage: "doc.text") }
                            .tag(SettingsTab.fileTranscription)
                        HistoryView()
                            .tabItem { Label(String(localized: "History"), systemImage: "clock.arrow.circlepath") }
                            .tag(SettingsTab.history)
                    }
                    Group {
                        if showRecorderTab {
                            AudioRecorderView(viewModel: AudioRecorderViewModel.shared)
                                .tabItem { Label(String(localized: "settings.tab.recorder"), systemImage: "waveform.circle") }
                                .tag(SettingsTab.recorder)
                        }
                        DictionarySettingsView()
                            .tabItem { Label(String(localized: "Dictionary"), systemImage: "book.closed") }
                            .tag(SettingsTab.dictionary)
                        SnippetsSettingsView()
                            .tabItem { Label(String(localized: "Snippets"), systemImage: "text.badge.plus") }
                            .tag(SettingsTab.snippets)
                        ProfilesSettingsView()
                            .tabItem { Label(String(localized: "Profiles"), systemImage: "person.crop.rectangle.stack") }
                            .tag(SettingsTab.profiles)
                        PromptActionsSettingsView()
                            .tabItem { Label(String(localized: "Prompts"), systemImage: "sparkles") }
                            .tag(SettingsTab.prompts)
                        PluginSettingsView()
                            .tabItem { Label(String(localized: "Integrations"), systemImage: "puzzlepiece.extension") }
                            .tag(SettingsTab.integrations)
                        AdvancedSettingsView()
                            .tabItem { Label(String(localized: "Advanced"), systemImage: "gearshape.2") }
                            .tag(SettingsTab.advanced)
                        AboutSettingsView()
                            .tabItem { Label(String(localized: "About"), systemImage: "info.circle") }
                            .tag(SettingsTab.about)
                    }
                }
            }
        }
        .frame(minWidth: 950, idealWidth: 1050, minHeight: 550, idealHeight: 600)
        .onAppear { navigateToFileTranscriptionIfNeeded() }
        .onChange(of: fileTranscription.showFilePickerFromMenu) { _, _ in
            navigateToFileTranscriptionIfNeeded()
        }
        .onChange(of: homeViewModel.navigateToHistory) { _, navigate in
            if navigate {
                selectedTab = .history
                homeViewModel.navigateToHistory = false
            }
        }
    }

    private func navigateToFileTranscriptionIfNeeded() {
        if fileTranscription.showFilePickerFromMenu {
            selectedTab = .fileTranscription
        }
    }
}

@available(macOS 15, *)
private struct SettingsMainTabs: TabContent {
    var pluginUpdatesBadge: Int
    var showRecorderTab: Bool
    var body: some TabContent<SettingsTab> {
        Tab(String(localized: "Home"), systemImage: "house", value: SettingsTab.home) {
            HomeSettingsView()
        }
        Tab(String(localized: "General"), systemImage: "gear", value: SettingsTab.general) {
            GeneralSettingsView()
        }
        Tab(String(localized: "Recording"), systemImage: "mic.fill", value: SettingsTab.recording) {
            RecordingSettingsView()
        }
        Tab(String(localized: "Hotkeys"), systemImage: "keyboard", value: SettingsTab.hotkeys) {
            HotkeySettingsView()
        }
        Tab(String(localized: "File Transcription"), systemImage: "doc.text", value: SettingsTab.fileTranscription) {
            FileTranscriptionView()
        }
        if showRecorderTab {
            Tab(String(localized: "settings.tab.recorder"), systemImage: "waveform.circle", value: SettingsTab.recorder) {
                AudioRecorderView(viewModel: AudioRecorderViewModel.shared)
            }
        }
        Tab(String(localized: "History"), systemImage: "clock.arrow.circlepath", value: SettingsTab.history) {
            HistoryView()
        }
        SettingsExtraTabs(pluginUpdatesBadge: pluginUpdatesBadge)
    }
}

@available(macOS 15, *)
private struct SettingsExtraTabs: TabContent {
    var pluginUpdatesBadge: Int
    var body: some TabContent<SettingsTab> {
        Tab(String(localized: "Dictionary"), systemImage: "book.closed", value: SettingsTab.dictionary) {
            DictionarySettingsView()
        }
        Tab(String(localized: "Snippets"), systemImage: "text.badge.plus", value: SettingsTab.snippets) {
            SnippetsSettingsView()
        }
        Tab(String(localized: "Profiles"), systemImage: "person.crop.rectangle.stack", value: SettingsTab.profiles) {
            ProfilesSettingsView()
        }
        Tab(String(localized: "Prompts"), systemImage: "sparkles", value: SettingsTab.prompts) {
            PromptActionsSettingsView()
        }
        Tab(String(localized: "Integrations"), systemImage: "puzzlepiece.extension", value: SettingsTab.integrations) {
            PluginSettingsView()
        }
        .badge(self.pluginUpdatesBadge)
        Tab(String(localized: "Advanced"), systemImage: "gearshape.2", value: SettingsTab.advanced) {
            AdvancedSettingsView()
        }
        Tab(String(localized: "About"), systemImage: "info.circle", value: SettingsTab.about) {
            AboutSettingsView()
        }
    }
}

struct RecordingSettingsView: View {
    @ObservedObject private var dictation = DictationViewModel.shared
    @ObservedObject private var audioDevice = ServiceContainer.shared.audioDeviceService
    @ObservedObject private var pluginManager = PluginManager.shared
    @ObservedObject private var modelManager = ServiceContainer.shared.modelManagerService
    @State private var selectedProvider: String?

    private var needsPermissions: Bool {
        dictation.needsMicPermission || dictation.needsAccessibilityPermission
    }

    var body: some View {
        Form {
            if needsPermissions {
                PermissionsBanner(dictation: dictation)
            }

            Section(String(localized: "Engine")) {
                let engines = pluginManager.transcriptionEngines
                if engines.isEmpty {
                    Text(String(localized: "No transcription engines installed. Install engines via Integrations."))
                        .foregroundStyle(.secondary)
                } else {
                    Picker(String(localized: "Default Engine"), selection: $selectedProvider) {
                        Text(String(localized: "None")).tag(nil as String?)
                        Divider()
                        ForEach(engines, id: \.providerId) { engine in
                            HStack {
                                Text(engine.providerDisplayName)
                                if !engine.isConfigured {
                                    Text("(\(String(localized: "not ready")))")
                                        .foregroundStyle(.secondary)
                                }
                            }.tag(engine.providerId as String?)
                        }
                    }
                    .onChange(of: selectedProvider) { _, newValue in
                        if let newValue {
                            modelManager.selectProvider(newValue)
                        }
                    }

                    if let providerId = selectedProvider,
                       let engine = pluginManager.transcriptionEngine(for: providerId) {
                        let models = engine.transcriptionModels
                        if models.count > 1 {
                            Picker(String(localized: "Model"), selection: Binding(
                                get: { engine.selectedModelId },
                                set: { if let id = $0 { modelManager.selectModel(providerId, modelId: id) } }
                            )) {
                                ForEach(models, id: \.id) { model in
                                    Text(model.displayName).tag(model.id as String?)
                                }
                            }
                        }
                    }

                }
            }

            Section(String(localized: "Microphone")) {
                Picker(String(localized: "Input Device"), selection: $audioDevice.selectedDeviceUID) {
                    Text(String(localized: "System Default")).tag(nil as String?)
                    Divider()
                    ForEach(audioDevice.inputDevices) { device in
                        Text(device.name).tag(device.uid as String?)
                    }
                }

                if audioDevice.isPreviewActive {
                    HStack(spacing: 8) {
                        Image(systemName: "mic.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)

                        GeometryReader { geo in
                            let maxRms: Float = 0.15
                            let levelWidth = max(0, geo.size.width * CGFloat(min(audioDevice.previewRawLevel, maxRms) / maxRms))

                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(.quaternary)

                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.green.gradient)
                                    .frame(width: levelWidth)
                                    .animation(.easeOut(duration: 0.08), value: audioDevice.previewRawLevel)
                            }
                        }
                        .frame(height: 6)
                    }
                    .padding(.vertical, 4)
                }

                Button(audioDevice.isPreviewActive
                    ? String(localized: "Stop Preview")
                    : String(localized: "Test Microphone")
                ) {
                    if audioDevice.isPreviewActive {
                        audioDevice.stopPreview()
                    } else {
                        audioDevice.startPreview()
                    }
                }
                .disabled(!audioDevice.isPreviewActive && dictation.needsMicPermission)

                if let name = audioDevice.disconnectedDeviceName {
                    Label(
                        String(localized: "Microphone disconnected. Falling back to system default."),
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                            if audioDevice.disconnectedDeviceName == name {
                                audioDevice.disconnectedDeviceName = nil
                            }
                        }
                    }
                }
            }

            Section(String(localized: "Sound")) {
                Toggle(String(localized: "Play sound feedback"), isOn: $dictation.soundFeedbackEnabled)

                Text(String(localized: "Plays a sound when recording starts and when transcription completes."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

            }

            Section(String(localized: "Output Formatting")) {
                Toggle(String(localized: "App-aware formatting"), isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: UserDefaultsKeys.appFormattingEnabled) },
                    set: { UserDefaults.standard.set($0, forKey: UserDefaultsKeys.appFormattingEnabled) }
                ))

                Text(String(localized: "Automatically format transcribed text based on the target app. Configure the output format per profile."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "Audio Ducking")) {
                Toggle(String(localized: "Reduce system volume during recording"), isOn: $dictation.audioDuckingEnabled)

                if dictation.audioDuckingEnabled {
                    HStack {
                        Image(systemName: "speaker.slash")
                            .foregroundStyle(.secondary)
                        Slider(value: $dictation.audioDuckingLevel, in: 0...0.5, step: 0.05)
                        Image(systemName: "speaker.wave.2")
                            .foregroundStyle(.secondary)
                    }

                    Text(String(localized: "Percentage of your current volume to use during recording. 0% mutes completely."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if needsPermissions {
                Section(String(localized: "Permissions")) {
                    if dictation.needsMicPermission {
                        HStack {
                            Label(
                                String(localized: "Microphone"),
                                systemImage: "mic.slash"
                            )
                            .foregroundStyle(.orange)

                            Spacer()

                            Button(String(localized: "Grant Access")) {
                                dictation.requestMicPermission()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    if dictation.needsAccessibilityPermission {
                        HStack {
                            Label(
                                String(localized: "Accessibility"),
                                systemImage: "lock.shield"
                            )
                            .foregroundStyle(.orange)

                            Spacer()

                            Button(String(localized: "Grant Access")) {
                                dictation.requestAccessibilityPermission()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 500, minHeight: 300)
        .onAppear {
            selectedProvider = modelManager.selectedProviderId
        }
    }

}

// MARK: - Permissions Banner

struct PermissionsBanner: View {
    @ObservedObject var dictation: DictationViewModel

    var body: some View {
        Section {
            if dictation.needsMicPermission {
                HStack {
                    Label(
                        String(localized: "Microphone access required"),
                        systemImage: "mic.slash"
                    )
                    .foregroundStyle(.red)

                    Spacer()

                    Button(String(localized: "Grant Access")) {
                        dictation.requestMicPermission()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if dictation.needsAccessibilityPermission {
                HStack {
                    Label(
                        String(localized: "Accessibility access required"),
                        systemImage: "lock.shield"
                    )
                    .foregroundStyle(.red)

                    Spacer()

                    Button(String(localized: "Grant Access")) {
                        dictation.requestAccessibilityPermission()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }
}

