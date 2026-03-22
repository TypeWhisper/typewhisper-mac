import SwiftUI

enum SettingsTab: Hashable {
    case home, general, recording, recorder
    case fileTranscription, history, dictionary, snippets, profiles, prompts, integrations, advanced
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
                }
            }

            Section(String(localized: "Hotkeys")) {
                HotkeyRecorderView(
                    label: dictation.hybridHotkeyLabel,
                    title: String(localized: "Hybrid"),
                    subtitle: String(localized: "Short press to toggle, hold to push-to-talk."),
                    onRecord: { hotkey in
                        if let conflict = dictation.isHotkeyAssigned(hotkey, excluding: .hybrid) {
                            dictation.clearHotkey(for: conflict)
                        }
                        dictation.setHotkey(hotkey, for: .hybrid)
                    },
                    onClear: { dictation.clearHotkey(for: .hybrid) }
                )

                HotkeyRecorderView(
                    label: dictation.pttHotkeyLabel,
                    title: String(localized: "Push-to-Talk"),
                    subtitle: String(localized: "Hold to record, release to stop."),
                    onRecord: { hotkey in
                        if let conflict = dictation.isHotkeyAssigned(hotkey, excluding: .pushToTalk) {
                            dictation.clearHotkey(for: conflict)
                        }
                        dictation.setHotkey(hotkey, for: .pushToTalk)
                    },
                    onClear: { dictation.clearHotkey(for: .pushToTalk) }
                )

                HotkeyRecorderView(
                    label: dictation.toggleHotkeyLabel,
                    title: String(localized: "Toggle"),
                    subtitle: String(localized: "Press to start, press again to stop."),
                    onRecord: { hotkey in
                        if let conflict = dictation.isHotkeyAssigned(hotkey, excluding: .toggle) {
                            dictation.clearHotkey(for: conflict)
                        }
                        dictation.setHotkey(hotkey, for: .toggle)
                    },
                    onClear: { dictation.clearHotkey(for: .toggle) }
                )
            }

            Section(String(localized: "Prompt Palette")) {
                HotkeyRecorderView(
                    label: dictation.promptPaletteHotkeyLabel,
                    title: String(localized: "Palette shortcut"),
                    onRecord: { hotkey in
                        if let conflict = dictation.isHotkeyAssigned(hotkey, excluding: .promptPalette) {
                            dictation.clearHotkey(for: conflict)
                        }
                        dictation.setHotkey(hotkey, for: .promptPalette)
                    },
                    onClear: { dictation.clearHotkey(for: .promptPalette) }
                )

                Text(String(localized: "Select text in any app, press the shortcut, and choose a prompt to process the text."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

                Toggle(String(localized: "Spoken feedback"), isOn: $dictation.spokenFeedbackEnabled)

                Text(String(localized: "Reads back the transcribed text via speech synthesis after each dictation."))
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

            Section(String(localized: "Permissions")) {
                HStack {
                    Label(
                        String(localized: "Microphone"),
                        systemImage: dictation.needsMicPermission ? "mic.slash" : "mic.fill"
                    )
                    .foregroundStyle(dictation.needsMicPermission ? .orange : .green)

                    Spacer()

                    if dictation.needsMicPermission {
                        Button(String(localized: "Grant Access")) {
                            dictation.requestMicPermission()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else {
                        Text(String(localized: "Granted"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Label(
                        String(localized: "Accessibility"),
                        systemImage: dictation.needsAccessibilityPermission ? "lock.shield" : "lock.shield.fill"
                    )
                    .foregroundStyle(dictation.needsAccessibilityPermission ? .orange : .green)

                    Spacer()

                    if dictation.needsAccessibilityPermission {
                        Button(String(localized: "Grant Access")) {
                            dictation.requestAccessibilityPermission()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else {
                        Text(String(localized: "Granted"))
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

// MARK: - Hotkey Recorder

struct HotkeyRecorderView: View {
    let label: String
    var title: String = String(localized: "Dictation shortcut")
    var subtitle: String? = nil
    let onRecord: (UnifiedHotkey) -> Void
    let onClear: () -> Void

    @State private var isRecording = false
    @State private var pendingModifiers: NSEvent.ModifierFlags = []
    @State private var peakModifiers: NSEvent.ModifierFlags = []
    @State private var localMonitor: Any?
    @State private var globalMonitor: Any?
    @State private var modifierReleaseTimer: DispatchWorkItem?
    private static var activeRecorder: UUID?
    @State private var id = UUID()

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isRecording {
                Button {
                    cancelRecording()
                } label: {
                    Text(pendingModifierString.isEmpty
                        ? String(localized: "Press a key…")
                        : pendingModifierString)
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(String(localized: "Recording shortcut - press a key or Escape to cancel"))
            } else if label.isEmpty {
                Button {
                    startRecording()
                } label: {
                    Text(String(localized: "Record Shortcut"))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(String(localized: "Record shortcut for \(title)"))
            } else {
                HStack(spacing: 4) {
                    Button {
                        startRecording()
                    } label: {
                        Text(label)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Current shortcut: \(label). Click to change."))
                    Button {
                        onClear()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Clear shortcut"))
                }
            }
        }
    }

    private var pendingModifierString: String {
        var parts: [String] = []
        if pendingModifiers.contains(.function) { parts.append("Fn") }
        if pendingModifiers.contains(.control) { parts.append("⌃") }
        if pendingModifiers.contains(.option) { parts.append("⌥") }
        if pendingModifiers.contains(.shift) { parts.append("⇧") }
        if pendingModifiers.contains(.command) { parts.append("⌘") }
        return parts.joined()
    }

    private func startRecording() {
        if let activeId = Self.activeRecorder, activeId != id {
            return
        }
        Self.activeRecorder = id
        isRecording = true
        pendingModifiers = []
        peakModifiers = []
        ServiceContainer.shared.hotkeyService.suspendMonitoring()

        // Local monitor - can swallow events (return nil)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            let handled = handleRecorderEvent(event)
            return handled ? nil : event
        }

        // Global monitor - captures events intercepted by macOS (e.g. Ctrl+Space for input switching)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handleRecorderEvent(event)
        }
    }

    /// Shared event processing for both local and global monitors.
    /// Returns true if the event was handled (consumed).
    @discardableResult
    private func handleRecorderEvent(_ event: NSEvent) -> Bool {
        guard isRecording else { return false }

        if event.type == .flagsChanged {
            let relevantMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]
            let current = event.modifierFlags.intersection(relevantMask)

            // Track peak modifier set (most modifiers held simultaneously)
            if current.isSuperset(of: peakModifiers) {
                peakModifiers = current
            }

            if current.isEmpty, !pendingModifiers.isEmpty {
                let modifierList: [NSEvent.ModifierFlags] = [.command, .option, .control, .shift, .function]
                let peakCount = modifierList.filter { peakModifiers.contains($0) }.count

                if peakCount > 1 {
                    // Multi-modifier combo (e.g. CMD+OPT, Fn+CMD)
                    let comboFlags = peakModifiers
                    let work = DispatchWorkItem { [self] in
                        finishRecording(UnifiedHotkey(keyCode: UnifiedHotkey.modifierComboKeyCode, modifierFlags: comboFlags.rawValue, isFn: false))
                    }
                    modifierReleaseTimer = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
                    pendingModifiers = []
                    peakModifiers = []
                    return true
                } else if peakModifiers.contains(.function) {
                    // Fn alone
                    let work = DispatchWorkItem { [self] in
                        finishRecording(UnifiedHotkey(keyCode: 0, modifierFlags: 0, isFn: true))
                    }
                    modifierReleaseTimer = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
                    pendingModifiers = []
                    peakModifiers = []
                    return true
                } else if HotkeyService.modifierKeyCodes.contains(event.keyCode) {
                    // Single modifier key (CMD, OPT, etc.)
                    let keyCode = event.keyCode
                    let work = DispatchWorkItem { [self] in
                        finishRecording(UnifiedHotkey(keyCode: keyCode, modifierFlags: 0, isFn: false))
                    }
                    modifierReleaseTimer = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
                    pendingModifiers = []
                    peakModifiers = []
                    return true
                }
            }

            pendingModifiers = current
            return true
        }

        if event.type == .keyDown {
            modifierReleaseTimer?.cancel()
            modifierReleaseTimer = nil

            if event.keyCode == 0x35, pendingModifiers.isEmpty {
                cancelRecording()
                return true
            }

            let relevantMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]
            let modifiers = event.modifierFlags.intersection(relevantMask).rawValue

            finishRecording(UnifiedHotkey(keyCode: event.keyCode, modifierFlags: modifiers, isFn: false))
            return true
        }

        return false
    }

    private func finishRecording(_ hotkey: UnifiedHotkey) {
        modifierReleaseTimer?.cancel()
        modifierReleaseTimer = nil
        if Self.activeRecorder == id {
            Self.activeRecorder = nil
        }
        isRecording = false
        pendingModifiers = []
        peakModifiers = []
        removeMonitors()
        ServiceContainer.shared.hotkeyService.resumeMonitoring()
        onRecord(hotkey)
    }

    private func cancelRecording() {
        modifierReleaseTimer?.cancel()
        modifierReleaseTimer = nil
        if Self.activeRecorder == id {
            Self.activeRecorder = nil
        }
        isRecording = false
        pendingModifiers = []
        peakModifiers = []
        removeMonitors()
        ServiceContainer.shared.hotkeyService.resumeMonitoring()
    }

    private func removeMonitors() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
    }
}
