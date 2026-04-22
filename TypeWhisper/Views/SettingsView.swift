import SwiftUI
import AppKit

enum SettingsTab: Hashable {
    case home, general, recording, hotkeys, recorder
    case fileTranscription, history, dictionary, snippets, workflows, legacyWorkflows, profiles, prompts, integrations, advanced, license, about
}

private struct SettingsDestination: Identifiable, Hashable {
    let tab: SettingsTab
    let title: String
    let systemImage: String
    let badge: Int?

    var id: SettingsTab { tab }
}

private struct SettingsDestinationSection: Identifiable {
    let id: String
    let destinations: [SettingsDestination]
}

struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .home
    @ObservedObject private var fileTranscription = FileTranscriptionViewModel.shared
    @ObservedObject private var registryService = PluginRegistryService.shared
    @ObservedObject private var homeViewModel = HomeViewModel.shared
    @ObservedObject private var promptActionsViewModel = PromptActionsViewModel.shared
    @ObservedObject private var settingsNavigation = SettingsNavigationCoordinator.shared
    @ObservedObject private var legacyWorkflowService = ServiceContainer.shared.legacyWorkflowService

    private var destinations: [SettingsDestination] {
        var items = [
            SettingsDestination(tab: .home, title: String(localized: "Home"), systemImage: "house", badge: nil),
            SettingsDestination(tab: .general, title: String(localized: "General"), systemImage: "gear", badge: nil),
            SettingsDestination(tab: .recording, title: String(localized: "Recording"), systemImage: "mic.fill", badge: nil),
            SettingsDestination(tab: .hotkeys, title: String(localized: "Hotkeys"), systemImage: "keyboard", badge: nil),
            SettingsDestination(
                tab: .recorder,
                title: String(localized: "settings.tab.recorder"),
                systemImage: "waveform.circle",
                badge: nil
            ),
            SettingsDestination(tab: .fileTranscription, title: String(localized: "File Transcription"), systemImage: "doc.text", badge: nil),
            SettingsDestination(tab: .history, title: String(localized: "History"), systemImage: "clock.arrow.circlepath", badge: nil),
            SettingsDestination(tab: .dictionary, title: String(localized: "Dictionary"), systemImage: "book.closed", badge: nil),
            SettingsDestination(tab: .snippets, title: String(localized: "Snippets"), systemImage: "text.badge.plus", badge: nil),
            SettingsDestination(
                tab: .workflows,
                title: localizedAppText("Workflows", de: "Workflows"),
                systemImage: "point.3.connected.trianglepath.dotted",
                badge: nil
            )
        ]

        if !legacyWorkflowService.items.isEmpty {
            items.append(
                SettingsDestination(
                    tab: .legacyWorkflows,
                    title: localizedAppText("Legacy", de: "Legacy"),
                    systemImage: "archivebox",
                    badge: legacyWorkflowService.items.count
                )
            )
        }

        items.append(
            contentsOf: [
                SettingsDestination(
                    tab: .integrations,
                    title: String(localized: "Integrations"),
                    systemImage: "puzzlepiece.extension",
                    badge: registryService.availableUpdatesCount > 0 ? registryService.availableUpdatesCount : nil
                ),
                SettingsDestination(tab: .advanced, title: String(localized: "Advanced"), systemImage: "gearshape.2", badge: nil),
                SettingsDestination(tab: .license, title: String(localized: "License"), systemImage: "key", badge: nil),
                SettingsDestination(tab: .about, title: String(localized: "About"), systemImage: "info.circle", badge: nil)
            ]
        )

        return items
    }

    private var destinationSections: [SettingsDestinationSection] {
        settingsDestinationSections(destinations)
    }

    var body: some View {
        Group {
            if #available(macOS 15, *) {
                SettingsModernShell(
                    selectedTab: $selectedTab,
                    sections: destinationSections,
                    detail: { tab in AnyView(settingsDetail(for: tab)) }
                )
            } else {
                SettingsSidebarShell(
                    selectedTab: $selectedTab,
                    sections: destinationSections,
                    detail: settingsDetail(for:)
                )
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
        .onChange(of: promptActionsViewModel.navigateToIntegrations) { _, navigate in
            if navigate {
                selectedTab = .integrations
                promptActionsViewModel.navigateToIntegrations = false
            }
        }
        .onReceive(settingsNavigation.$request.compactMap { $0 }) { request in
            switch request.tab {
            case .profiles:
                if legacyWorkflowService.items.isEmpty {
                    selectedTab = .workflows
                    WorkflowsNavigationCoordinator.shared.showMine()
                } else {
                    selectedTab = .legacyWorkflows
                    WorkflowsNavigationCoordinator.shared.showLegacy(focus: .rule)
                }
            case .prompts:
                if legacyWorkflowService.items.isEmpty {
                    selectedTab = .workflows
                    WorkflowsNavigationCoordinator.shared.showMine()
                } else {
                    selectedTab = .legacyWorkflows
                    WorkflowsNavigationCoordinator.shared.showLegacy(focus: .prompt)
                }
            case .workflows:
                selectedTab = .workflows
                WorkflowsNavigationCoordinator.shared.showMine()
            default:
                selectedTab = request.tab
            }
        }
        .onChange(of: legacyWorkflowService.items.count) { _, count in
            if count == 0 && selectedTab == .legacyWorkflows {
                selectedTab = .workflows
                WorkflowsNavigationCoordinator.shared.showMine()
            }
        }
    }

    private func navigateToFileTranscriptionIfNeeded() {
        if fileTranscription.showFilePickerFromMenu {
            selectedTab = .fileTranscription
        }
    }

    @ViewBuilder
    private func settingsDetail(for tab: SettingsTab) -> some View {
        switch tab {
        case .home:
            HomeSettingsView()
        case .general:
            GeneralSettingsView()
        case .recording:
            RecordingSettingsView()
        case .hotkeys:
            HotkeySettingsView()
        case .recorder:
            AudioRecorderView(viewModel: AudioRecorderViewModel.shared)
        case .fileTranscription:
            FileTranscriptionView()
        case .history:
            HistoryView()
        case .dictionary:
            DictionarySettingsView()
        case .snippets:
            SnippetsSettingsView()
        case .workflows:
            WorkflowsSettingsView()
        case .legacyWorkflows:
            LegacyWorkflowsSettingsView()
        case .profiles:
            WorkflowsSettingsView()
        case .prompts:
            LegacyWorkflowsSettingsView()
        case .integrations:
            PluginSettingsView()
        case .advanced:
            AdvancedSettingsView()
        case .license:
            LicenseSettingsView()
        case .about:
            AboutSettingsView()
        }
    }
}

@available(macOS 15, *)
private struct SettingsModernShell: View {
    @Binding var selectedTab: SettingsTab
    let sections: [SettingsDestinationSection]
    let detail: (SettingsTab) -> AnyView

    @State private var sidebarSearchText = ""

    private var filteredSections: [SettingsDestinationSection] {
        let query = sidebarSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sections }

        return sections
            .map { section in
                SettingsDestinationSection(
                    id: section.id,
                    destinations: section.destinations.filter { destination in
                        destination.title.localizedCaseInsensitiveContains(query)
                    }
                )
            }
            .filter { !$0.destinations.isEmpty }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                ForEach(filteredSections) { section in
                    Section {
                        ForEach(section.destinations) { destination in
                            SettingsSidebarRow(destination: destination)
                                .tag(destination.tab)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(
                text: $sidebarSearchText,
                placement: .sidebar,
                prompt: Text(localizedAppText("Search Settings", de: "Einstellungen durchsuchen"))
            )
            .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 320)
        } detail: {
            detail(selectedTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private func settingsDestination(_ destinations: [SettingsDestination], _ tab: SettingsTab) -> SettingsDestination {
    destinations.first(where: { $0.tab == tab })!
}

private func settingsTitle(_ destinations: [SettingsDestination], _ tab: SettingsTab) -> String {
    settingsDestination(destinations, tab).title
}

private func settingsSystemImage(_ destinations: [SettingsDestination], _ tab: SettingsTab) -> String {
    settingsDestination(destinations, tab).systemImage
}

private func settingsBadge(_ destinations: [SettingsDestination], _ tab: SettingsTab) -> Int? {
    settingsDestination(destinations, tab).badge
}

private func settingsDestinationSections(_ destinations: [SettingsDestination]) -> [SettingsDestinationSection] {
    var workspaceDestinations = [
        settingsDestination(destinations, .history),
        settingsDestination(destinations, .dictionary),
        settingsDestination(destinations, .snippets),
        settingsDestination(destinations, .workflows)
    ]

    if let legacyDestination = destinations.first(where: { $0.tab == .legacyWorkflows }) {
        workspaceDestinations.append(legacyDestination)
    }

    workspaceDestinations.append(settingsDestination(destinations, .integrations))

    return [
        SettingsDestinationSection(
            id: "home",
            destinations: [settingsDestination(destinations, .home)]
        ),
        SettingsDestinationSection(
            id: "core",
            destinations: [
                settingsDestination(destinations, .general),
                settingsDestination(destinations, .recording),
                settingsDestination(destinations, .hotkeys),
                settingsDestination(destinations, .fileTranscription),
                settingsDestination(destinations, .recorder)
            ]
        ),
        SettingsDestinationSection(
            id: "workspace",
            destinations: workspaceDestinations
        ),
        SettingsDestinationSection(
            id: "system",
            destinations: [
                settingsDestination(destinations, .advanced),
                settingsDestination(destinations, .license),
                settingsDestination(destinations, .about)
            ]
        )
    ]
}

private struct SettingsSidebarShell<DetailContent: View>: View {
    @Binding var selectedTab: SettingsTab
    let sections: [SettingsDestinationSection]
    let detail: (SettingsTab) -> DetailContent

    @State private var isSidebarVisible = true

    var body: some View {
        HStack(spacing: 0) {
            if isSidebarVisible {
                List(selection: $selectedTab) {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.destinations) { destination in
                                SettingsSidebarRow(destination: destination)
                                    .tag(destination.tab)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 240)

                Divider()
            }

            detail(selectedTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // macOS 14 glitches when the default NavigationSplitView sidebar reveal animates.
        // Use a custom zero-duration toggle instead.
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: toggleSidebar) {
                    Image(systemName: "sidebar.leading")
                }
                .help(localizedAppText("Toggle Sidebar", de: "Seitenleiste ein-/ausblenden"))
                .accessibilityLabel(localizedAppText("Toggle Sidebar", de: "Seitenleiste ein-/ausblenden"))
            }
        }
    }

    private func toggleSidebar() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            withAnimation(nil) {
                isSidebarVisible.toggle()
            }
        }
    }
}

private struct SettingsSidebarRow: View {
    let destination: SettingsDestination

    var body: some View {
        HStack(spacing: 10) {
            Label(destination.title, systemImage: destination.systemImage)

            Spacer(minLength: 8)

            if let badge = destination.badge {
                SettingsSidebarBadge(title: destination.title, count: badge)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct SettingsSidebarBadge: View {
    let title: String
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.tertiary, in: Capsule())
            .foregroundStyle(.secondary)
            .accessibilityLabel("\(title), \(count) updates")
    }
}

struct RecordingSettingsView: View {
    @ObservedObject private var dictation = DictationViewModel.shared
    @ObservedObject private var audioDevice = ServiceContainer.shared.audioDeviceService
    @ObservedObject private var pluginManager = PluginManager.shared
    @ObservedObject private var modelManager = ServiceContainer.shared.modelManagerService
    @State private var selectedProvider: String?
    @State private var customSounds: [String] = SoundChoice.installedCustomSounds()
    private let soundService = ServiceContainer.shared.soundService

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
                        Text(audioDevice.displayName(for: device)).tag(device.uid as String?)
                    }
                }

                if let message = audioDevice.selectedDeviceStatusMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
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

                if let error = audioDevice.previewError {
                    Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }

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

                if dictation.soundFeedbackEnabled {
                    SoundEventPicker(event: .recordingStarted, soundService: soundService, customSounds: $customSounds)
                    SoundEventPicker(event: .transcriptionSuccess, soundService: soundService, customSounds: $customSounds)
                    SoundEventPicker(event: .error, soundService: soundService, customSounds: $customSounds)
                }

                Text(String(localized: "Plays a sound when recording starts and when transcription completes."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

            }

            Section(String(localized: "Clipboard")) {
                Toggle(String(localized: "Preserve clipboard content"), isOn: $dictation.preserveClipboard)

                Text(String(localized: "Restores your clipboard after text insertion. Without this, your clipboard contains the transcribed text after dictation."))
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

            Section(String(localized: "Media Pause")) {
                Toggle(String(localized: "Pause media playback during recording"), isOn: $dictation.mediaPauseEnabled)

                Text(String(localized: "Automatically pauses music and videos while recording and resumes when done. Uses macOS system media controls - may not work with all apps."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            customSounds = SoundChoice.installedCustomSounds()
        }
    }

}

// MARK: - Sound Event Picker

private struct SoundEventPicker: View {
    let event: SoundEvent
    let soundService: SoundService
    @Binding var customSounds: [String]
    @State private var selection: String

    init(event: SoundEvent, soundService: SoundService, customSounds: Binding<[String]>) {
        self.event = event
        self.soundService = soundService
        self._customSounds = customSounds
        self._selection = State(initialValue: soundService.choice(for: event).storageKey)
    }

    var body: some View {
        HStack {
            Picker(event.displayName, selection: $selection) {
                Text(String(localized: "Default")).tag(event.defaultChoice.storageKey)

                Divider()

                ForEach(SoundChoice.bundledSounds, id: \.name) { sound in
                    Text(sound.displayName).tag(SoundChoice.bundled(sound.name).storageKey)
                }

                if !customSounds.isEmpty {
                    Divider()
                    ForEach(customSounds, id: \.self) { name in
                        Text(name).tag(SoundChoice.custom(name).storageKey)
                    }
                }

                Divider()

                ForEach(SoundChoice.systemSounds, id: \.self) { name in
                    Text(name).tag(SoundChoice.system(name).storageKey)
                }

                Divider()

                Text(String(localized: "None")).tag(SoundChoice.none.storageKey)
            }
            .onChange(of: selection) { _, newValue in
                let choice = SoundChoice(storageKey: newValue)
                soundService.updateChoice(for: event, choice: choice)
                soundService.preview(choice)
            }

            Button {
                soundService.preview(SoundChoice(storageKey: selection))
            } label: {
                Image(systemName: "speaker.wave.2")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Preview sound"))

            Button {
                importCustomSound()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Add custom sound"))
        }
    }

    private func importCustomSound() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SoundChoice.allowedContentTypes
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a sound file")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let filename = try soundService.importCustomSound(from: url)
            customSounds = SoundChoice.installedCustomSounds()
            selection = SoundChoice.custom(filename).storageKey
        } catch {
            // File copy failed - silently ignore
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
