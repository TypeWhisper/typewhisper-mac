import SwiftUI
import Combine
import TypeWhisperPluginSDK

/// Lightweight state tracker for MenuBarView that only re-publishes
/// on menu-relevant changes, avoiding high-frequency audioLevel updates.
@MainActor
private final class MenuBarState: ObservableObject {
    @Published var statusText: String
    @Published var statusImage: String
    @Published var isModelReady: Bool
    @Published var hasRecentTranscriptions: Bool
    @Published var canCopyLastTranscription: Bool
    @Published var canUndoLastDictation: Bool
    @Published var canRestoreRawTranscript: Bool
    @Published var hasLastTranscribedText: Bool
    @Published var hasRecoverableRecording: Bool
    @Published var recorderState: AudioRecorderViewModel.RecorderState
    @Published var canToggleRecorder: Bool
    @Published var dictationHotkeysPaused: Bool
    @Published var recentTranscriptionsMenuShortcut: HotkeyService.MenuShortcutDescriptor?
    @Published var copyLastTranscriptionMenuShortcut: HotkeyService.MenuShortcutDescriptor?
    @Published var pasteLastTranscriptionMenuShortcut: HotkeyService.MenuShortcutDescriptor?
    @Published var recorderToggleMenuShortcut: HotkeyService.MenuShortcutDescriptor?
    @Published var undoLastDictationMenuShortcut: HotkeyService.MenuShortcutDescriptor?
    @Published var restoreRawTranscriptMenuShortcut: HotkeyService.MenuShortcutDescriptor?

    private var cancellables = Set<AnyCancellable>()

    init() {
        let dictation = DictationViewModel.shared
        let modelManager = ServiceContainer.shared.modelManagerService
        let audioRecordingService = ServiceContainer.shared.audioRecordingService
        let historyService = ServiceContainer.shared.historyService
        let recentTranscriptionStore = ServiceContainer.shared.recentTranscriptionStore
        let recorder = AudioRecorderViewModel.shared
        let hotkeyService = ServiceContainer.shared.hotkeyService

        // Set initial values immediately
        self.isModelReady = modelManager.isModelReady
        let hasRecentTranscriptions = recentTranscriptionStore.latestEntry(historyRecords: historyService.recentRecords) != nil
        self.hasRecentTranscriptions = hasRecentTranscriptions
        self.canCopyLastTranscription = hasRecentTranscriptions
        self.canUndoLastDictation = dictation.dictationUndoService.canUndo
        self.canRestoreRawTranscript = dictation.dictationUndoService.canRestoreRaw
        self.hasLastTranscribedText = dictation.lastTranscribedText != nil
        self.hasRecoverableRecording = audioRecordingService.latestRecoveryRecordingURL != nil
        self.recorderState = recorder.state
        self.canToggleRecorder = recorder.canToggleRecording
        self.dictationHotkeysPaused = hotkeyService.dictationHotkeysPaused
        self.recentTranscriptionsMenuShortcut = DictationSettingsHandler.loadMenuShortcutDescriptor(for: .recentTranscriptions)
        self.copyLastTranscriptionMenuShortcut = DictationSettingsHandler.loadMenuShortcutDescriptor(for: .copyLastTranscription)
        self.pasteLastTranscriptionMenuShortcut = DictationSettingsHandler.loadMenuShortcutDescriptor(for: .pasteLastTranscription)
        self.recorderToggleMenuShortcut = DictationSettingsHandler.loadMenuShortcutDescriptor(for: .recorderToggle)
        self.undoLastDictationMenuShortcut = DictationSettingsHandler.loadMenuShortcutDescriptor(for: .undoLastDictation)
        self.restoreRawTranscriptMenuShortcut = DictationSettingsHandler.loadMenuShortcutDescriptor(for: .restoreRawTranscript)
        let modelStatus = Self.idleModelStatus(from: modelManager)
        self.statusText = modelStatus.text
        self.statusImage = modelStatus.image

        // React to dictation state changes (not audioLevel/duration/partialText)
        dictation.$state
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.update(state: state)
            }
            .store(in: &cancellables)

        // React to model changes via objectWillChange (covers model loading/selection)
        modelManager.objectWillChange
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let ready = modelManager.isModelReady
                self.isModelReady = ready
                // Only update text if not in recording/processing state
                if case .idle = dictation.state {
                    self.update(state: .idle)
                }
            }
            .store(in: &cancellables)

        recentTranscriptionStore.$sessionEntries
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshCopyAvailability()
            }
            .store(in: &cancellables)

        dictation.dictationUndoService.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshUndoAvailability()
            }
            .store(in: &cancellables)

        historyService.$recentRecords
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshCopyAvailability()
            }
            .store(in: &cancellables)

        audioRecordingService.$recoverableRecordingURL
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in
                self?.hasRecoverableRecording = url != nil
            }
            .store(in: &cancellables)

        dictation.$lastTranscribedText
            .map { $0 != nil }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hasText in
                self?.hasLastTranscribedText = hasText
            }
            .store(in: &cancellables)

        Publishers.CombineLatest3(
            recorder.$state.removeDuplicates(),
            recorder.$micEnabled.removeDuplicates(),
            recorder.$systemAudioEnabled.removeDuplicates()
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] state, micEnabled, systemAudioEnabled in
            self?.refreshRecorderToggle(
                state: state,
                micEnabled: micEnabled,
                systemAudioEnabled: systemAudioEnabled
            )
        }
        .store(in: &cancellables)

        dictation.$hotkeyLabelsVersion
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshMenuShortcuts()
            }
            .store(in: &cancellables)

        hotkeyService.$dictationHotkeysPaused
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] paused in
                self?.dictationHotkeysPaused = paused
                self?.update(state: dictation.state)
            }
            .store(in: &cancellables)
    }

    private func update(state: DictationViewModel.State) {
        let modelManager = ServiceContainer.shared.modelManagerService
        if dictationHotkeysPaused, state == .idle {
            statusText = String(localized: "Dictation hotkeys paused")
            statusImage = "pause.circle.fill"
            isModelReady = modelManager.isModelReady
            return
        }

        switch state {
        case .recording:
            statusText = String(localized: "Recording...")
            statusImage = "record.circle.fill"
        case .processing:
            statusText = String(localized: "Transcribing...")
            statusImage = "arrow.triangle.2.circlepath"
        default:
            let modelStatus = Self.idleModelStatus(from: modelManager)
            statusText = modelStatus.text
            statusImage = modelStatus.image
        }
        isModelReady = modelManager.isModelReady
    }

    private static func idleModelStatus(from modelManager: ModelManagerService) -> (text: String, image: String) {
        guard modelManager.activeModelName != nil else {
            return (String(localized: "No model loaded"), "exclamationmark.triangle.fill")
        }

        // The model itself is named by the Model quick selector below the status line.
        if modelManager.isModelReady {
            return (String(localized: "Ready"), "checkmark.circle.fill")
        }

        return (localizedAppText("Model selected", de: "Modell ausgewählt"), "clock.fill")
    }

    private func refreshCopyAvailability() {
        let historyService = ServiceContainer.shared.historyService
        let recentTranscriptionStore = ServiceContainer.shared.recentTranscriptionStore
        let hasRecentTranscriptions = recentTranscriptionStore.latestEntry(historyRecords: historyService.recentRecords) != nil
        self.hasRecentTranscriptions = hasRecentTranscriptions
        canCopyLastTranscription = hasRecentTranscriptions
    }

    private func refreshRecorderToggle(
        state: AudioRecorderViewModel.RecorderState,
        micEnabled: Bool,
        systemAudioEnabled: Bool
    ) {
        recorderState = state
        canToggleRecorder = AudioRecorderViewModel.canToggleRecording(
            state: state,
            micEnabled: micEnabled,
            systemAudioEnabled: systemAudioEnabled
        )
    }

    private func refreshMenuShortcuts() {
        recentTranscriptionsMenuShortcut = DictationSettingsHandler.loadMenuShortcutDescriptor(for: .recentTranscriptions)
        copyLastTranscriptionMenuShortcut = DictationSettingsHandler.loadMenuShortcutDescriptor(for: .copyLastTranscription)
        pasteLastTranscriptionMenuShortcut = DictationSettingsHandler.loadMenuShortcutDescriptor(for: .pasteLastTranscription)
        recorderToggleMenuShortcut = DictationSettingsHandler.loadMenuShortcutDescriptor(for: .recorderToggle)
        undoLastDictationMenuShortcut = DictationSettingsHandler.loadMenuShortcutDescriptor(for: .undoLastDictation)
        restoreRawTranscriptMenuShortcut = DictationSettingsHandler.loadMenuShortcutDescriptor(for: .restoreRawTranscript)
    }

    private func refreshUndoAvailability() {
        let undoService = DictationViewModel.shared.dictationUndoService
        canUndoLastDictation = undoService.canUndo
        canRestoreRawTranscript = undoService.canRestoreRaw
    }
}

enum MenuBarMenuItem: Hashable {
    case settings
    case history
    case errorLog
    case toggleRecorder
    case toggleDictationHotkeysPause
    case transcribeFile
    case recoverLastRecording
    case lastTranscription
    case recentTranscriptions
    case copyLastTranscription
    case pasteLastTranscription
    case readBackLastTranscription
    case undoLastDictation
    case restoreRawTranscript
    case checkForUpdates
}

enum MenuBarMenuSection: String, CaseIterable, Hashable {
    case general = "General"
    case transcription = "Transcription"

    var titleLocalizationKey: String {
        rawValue
    }

    var titleResource: LocalizedStringResource {
        switch self {
        case .general:
            "General"
        case .transcription:
            "Transcription"
        }
    }

    var items: [MenuBarMenuItem] {
        items(hasRecoverableRecording: true)
    }

    func items(hasRecoverableRecording: Bool) -> [MenuBarMenuItem] {
        switch self {
        case .general:
            [.settings, .history, .errorLog]
        case .transcription:
            hasRecoverableRecording
                ? [.toggleDictationHotkeysPause, .transcribeFile, .recoverLastRecording, .lastTranscription]
                : [.toggleDictationHotkeysPause, .transcribeFile, .lastTranscription]
        }
    }
}

@MainActor
enum MenuBarActionDispatcher {
    static func performAfterMenuDismissal(
        _ action: @escaping @MainActor @Sendable () -> Void
    ) {
        RunLoop.main.perform(inModes: [.default]) {
            Task { @MainActor in
                action()
            }
        }
    }
}

private struct PluginCommandButton: View {
    let pluginId: String
    let command: PluginCommandDescriptor
    @ObservedObject var pluginManager: PluginManager

    var body: some View {
        Button {
            pluginManager.performPluginCommand(pluginId: pluginId, commandId: command.id)
        } label: {
            if let systemImageName = command.systemImageName {
                Label {
                    Text(verbatim: command.title)
                } icon: {
                    Image(systemName: systemImageName)
                }
            } else {
                Text(verbatim: command.title)
            }
        }
        .disabled(!command.isEnabled)
    }
}

struct PluginAppCommands: Commands {
    @ObservedObject var pluginManager: PluginManager

    var body: some Commands {
        CommandMenu(String(localized: "Integrations")) {
            let contributions = pluginManager.userInterfaceContributions.filter {
                !$0.appMenuCommands.isEmpty
            }
            if contributions.isEmpty {
                Button(String(localized: "No Integration Commands")) {}
                    .disabled(true)
            } else {
                ForEach(contributions, id: \.pluginId) { contribution in
                    Menu {
                        ForEach(contribution.appMenuCommands) { command in
                            PluginCommandButton(
                                pluginId: contribution.pluginId,
                                command: command,
                                pluginManager: pluginManager
                            )
                        }
                    } label: {
                        Text(verbatim: contribution.pluginName)
                    }
                }
            }
        }
    }
}

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var status = MenuBarState()
    @StateObject private var quickSelection = DictationQuickSelectionModel()
    @ObservedObject private var pluginManager: PluginManager

    init(pluginManager: PluginManager = PluginManager.shared) {
        self._pluginManager = ObservedObject(wrappedValue: pluginManager)
    }

    var body: some View {
        Group {
            let _ = { ManagedAppWindowOpener.shared.openWindow = openWindow }()

            Label(status.statusText, systemImage: status.statusImage)

            Divider()

            // Primary action, promoted above the grouped sections so it is
            // always the first actionable item under the status line.
            menuItem(for: .toggleRecorder)

            Divider()

            Section(localizedAppText("Dictation", de: "Diktat")) {
                microphoneQuickSelector
                languageQuickSelector
                modelQuickSelector
            }

            ForEach(MenuBarMenuSection.allCases, id: \.self) { section in
                Section(String(localized: section.titleResource)) {
                    ForEach(section.items(hasRecoverableRecording: status.hasRecoverableRecording), id: \.self) { item in
                        menuItem(for: item)
                    }
                }
            }

            let pluginContributions = pluginManager.userInterfaceContributions.filter {
                !$0.primaryMenuBarCommands.isEmpty
            }
            if !pluginContributions.isEmpty {
                Divider()
                Section(String(localized: "Integrations")) {
                    ForEach(pluginContributions, id: \.pluginId) { contribution in
                        Menu {
                            ForEach(contribution.primaryMenuBarCommands) { command in
                                PluginCommandButton(
                                    pluginId: contribution.pluginId,
                                    command: command,
                                    pluginManager: pluginManager
                                )
                            }
                        } label: {
                            Text(verbatim: contribution.pluginName)
                        }
                    }
                }
            }

            Divider()

            #if !APPSTORE
            menuItem(for: .checkForUpdates)
            #endif

            Button(String(localized: "Quit")) {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .onReceive(NotificationCenter.default.publisher(for: .openManagedAppWindow)) { notification in
            guard let id = notification.userInfo?["id"] as? String else { return }
            openWindow(id: id)
        }
    }

    private func openManagedWindow(_ id: String) {
        ManagedAppWindowOpener.shared.open(id: id)
    }

    @ViewBuilder
    private func menuItem(for item: MenuBarMenuItem) -> some View {
        switch item {
        case .settings:
            Button {
                openManagedWindow("settings")
            } label: {
                Label(String(localized: "Settings..."), systemImage: "gear")
            }
            .keyboardShortcut(",")

        case .history:
            Button {
                openManagedWindow("history")
            } label: {
                Label(String(localized: "History"), systemImage: "clock.arrow.circlepath")
            }

        case .errorLog:
            Button {
                openManagedWindow("errors")
            } label: {
                Label(String(localized: "Error Log"), systemImage: "exclamationmark.triangle")
            }

        case .toggleRecorder:
            Button {
                AudioRecorderViewModel.shared.toggleRecording()
            } label: {
                Label(recorderToggleTitle, systemImage: recorderToggleSystemImage)
            }
            .keyboardShortcut(keyboardShortcut(from: status.recorderToggleMenuShortcut))
            .disabled(!status.canToggleRecorder)

        case .toggleDictationHotkeysPause:
            Button {
                ServiceContainer.shared.hotkeyService.dictationHotkeysPaused.toggle()
            } label: {
                Label(dictationHotkeysPauseTitle, systemImage: dictationHotkeysPauseSystemImage)
            }

        case .transcribeFile:
            Button {
                openManagedWindow("settings")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    FileTranscriptionViewModel.shared.showFilePickerFromMenu = true
                }
            } label: {
                Label(String(localized: "Transcribe File..."), systemImage: "doc.text")
            }
            .disabled(!status.isModelReady)

        case .recoverLastRecording:
            Button {
                DictationViewModel.shared.recoverLastRecording()
            } label: {
                Label(String(localized: "Recover Last Recording"), systemImage: "waveform")
            }

        case .lastTranscription:
            Menu {
                recentTranscriptionsButton
                copyLastTranscriptionButton
                pasteLastTranscriptionButton
                readBackLastTranscriptionButton
                // Undo needs to read the target field through Accessibility,
                // which the App Sandbox does not allow.
                #if !APPSTORE
                Divider()
                undoLastDictationButton
                restoreRawTranscriptButton
                #endif
            } label: {
                Label(
                    localizedAppText("Last Transcription", de: "Letzte Transkription"),
                    systemImage: "clock.arrow.circlepath"
                )
            }
            .disabled(
                !status.hasRecentTranscriptions
                    && !status.canCopyLastTranscription
                    && !status.hasLastTranscribedText
                    && !status.canUndoLastDictation
            )

        case .recentTranscriptions:
            recentTranscriptionsButton

        case .copyLastTranscription:
            copyLastTranscriptionButton

        case .pasteLastTranscription:
            pasteLastTranscriptionButton

        case .readBackLastTranscription:
            readBackLastTranscriptionButton

        case .undoLastDictation:
            undoLastDictationButton

        case .restoreRawTranscript:
            restoreRawTranscriptButton

        case .checkForUpdates:
            Button(String(localized: "Check for Updates...")) {
                UpdateChecker.shared?.checkForUpdates()
            }
            .disabled(UpdateChecker.shared?.canCheckForUpdates() != true)
        }
    }

    // MARK: Dictation quick selectors

    private var microphoneQuickSelector: some View {
        let snapshot = quickSelection.snapshot
        return Menu {
            ForEach(snapshot.microphoneOptions) { option in
                quickSelectionItem(option, select: quickSelection.selectMicrophone)
            }
            Divider()
            dictationSettingsButton
        } label: {
            Label(
                localizedAppText(
                    "Microphone: \(snapshot.microphoneSummary)",
                    de: "Mikrofon: \(snapshot.microphoneSummary)"
                ),
                systemImage: "mic"
            )
        }
        .quickSelectorLock(snapshot.isLocked)
    }

    private var languageQuickSelector: some View {
        let snapshot = quickSelection.snapshot
        return Menu {
            if let note = snapshot.languageWorkflowNote {
                Text(verbatim: note)
                Divider()
            }
            ForEach(snapshot.languageOptions) { option in
                quickSelectionItem(option, select: quickSelection.selectLanguage)
            }
            if !snapshot.moreLanguageOptions.isEmpty {
                Menu(localizedAppText("More Languages", de: "Weitere Sprachen")) {
                    ForEach(snapshot.moreLanguageOptions) { option in
                        quickSelectionItem(option, select: quickSelection.selectLanguage)
                    }
                }
            }
            Divider()
            dictationSettingsButton
        } label: {
            Label(
                localizedAppText(
                    "Language: \(snapshot.languageSummary)",
                    de: "Sprache: \(snapshot.languageSummary)"
                ),
                systemImage: "globe"
            )
        }
        .quickSelectorLock(snapshot.isLocked)
    }

    private var modelQuickSelector: some View {
        let snapshot = quickSelection.snapshot
        return Menu {
            if let note = snapshot.modelWorkflowNote {
                Text(verbatim: note)
                Divider()
            }
            ForEach(snapshot.modelGroups) { group in
                if group.options.count == 1, let option = group.options.first, option.value.modelId == nil {
                    quickSelectionItem(option, select: quickSelection.selectModel)
                } else {
                    Section(group.title) {
                        ForEach(group.options) { option in
                            quickSelectionItem(option, select: quickSelection.selectModel)
                        }
                        if !group.setupRequiredOptions.isEmpty {
                            let count = group.setupRequiredOptions.count
                            Menu(localizedAppText("More Models (\(count))", de: "Weitere Modelle (\(count))")) {
                                ForEach(group.setupRequiredOptions) { option in
                                    quickSelectionItem(option, select: quickSelection.selectModel)
                                }
                            }
                        }
                    }
                }
            }
            Divider()
            dictationSettingsButton
        } label: {
            Label(
                localizedAppText(
                    "Model: \(snapshot.modelSummary)",
                    de: "Modell: \(snapshot.modelSummary)"
                ),
                systemImage: "waveform"
            )
        }
        .quickSelectorLock(snapshot.isLocked)
    }

    /// A checkmark menu item. Choosing the selected entry again does nothing, so it cannot
    /// reset state such as the microphone priority list.
    private func quickSelectionItem<Value: Hashable>(
        _ option: DictationQuickSelectionOption<Value>,
        select: @escaping (Value) -> Void
    ) -> some View {
        Toggle(isOn: Binding(
            get: { option.isSelected },
            set: { _ in
                guard !option.isSelected else { return }
                select(option.value)
            }
        )) {
            Text(verbatim: option.title)
        }
        .disabled(!option.isEnabled)
    }

    private var dictationSettingsButton: some View {
        Button(localizedAppText("Dictation Settings...", de: "Diktat-Einstellungen …")) {
            quickSelection.openDictationSettings()
        }
    }

    // These are factored out so the "Last Transcription" submenu can reuse them
    // without menuItem(for:) recursively referencing its own opaque return type.
    @ViewBuilder
    private var recentTranscriptionsButton: some View {
        Button {
            // MenuBarExtra uses NSMenu tracking. Defer creating the key NSPanel
            // until the menu action has returned and the native menu can close.
            MenuBarActionDispatcher.performAfterMenuDismissal {
                DictationViewModel.shared.triggerRecentTranscriptionsPalette()
            }
        } label: {
            Label(String(localized: "Recent Transcriptions"), systemImage: "clock.arrow.circlepath")
        }
        .keyboardShortcut(keyboardShortcut(from: status.recentTranscriptionsMenuShortcut))
        .disabled(!status.hasRecentTranscriptions)
    }

    @ViewBuilder
    private var copyLastTranscriptionButton: some View {
        Button {
            DictationViewModel.shared.copyLastTranscriptionToClipboard()
        } label: {
            Label(String(localized: "Copy Last Transcription"), systemImage: "doc.on.doc")
        }
        .keyboardShortcut(keyboardShortcut(from: status.copyLastTranscriptionMenuShortcut))
        .disabled(!status.canCopyLastTranscription)
    }

    @ViewBuilder
    private var pasteLastTranscriptionButton: some View {
        Button {
            DictationViewModel.shared.pasteLastTranscription()
        } label: {
            Label(String(localized: "Paste Last Transcription"), systemImage: "text.insert")
        }
        .keyboardShortcut(keyboardShortcut(from: status.pasteLastTranscriptionMenuShortcut))
        .disabled(!status.canCopyLastTranscription)
    }

    @ViewBuilder
    private var readBackLastTranscriptionButton: some View {
        Button {
            DictationViewModel.shared.readBackLastTranscription()
        } label: {
            Label(String(localized: "Read Back Last Transcription"), systemImage: "speaker.wave.2")
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(!status.hasLastTranscribedText)
    }

    @ViewBuilder
    private var undoLastDictationButton: some View {
        Button {
            DictationViewModel.shared.undoLastDictation()
        } label: {
            Label(
                localizedAppText("Undo Last Dictation", de: "Letztes Diktat rückgängig"),
                systemImage: "arrow.uturn.backward"
            )
        }
        .keyboardShortcut(keyboardShortcut(from: status.undoLastDictationMenuShortcut))
        .disabled(!status.canUndoLastDictation)
    }

    @ViewBuilder
    private var restoreRawTranscriptButton: some View {
        Button {
            DictationViewModel.shared.restoreRawTranscript()
        } label: {
            Label(
                localizedAppText("Restore Raw Transcript", de: "Rohtext wiederherstellen"),
                systemImage: "text.badge.checkmark"
            )
        }
        .keyboardShortcut(keyboardShortcut(from: status.restoreRawTranscriptMenuShortcut))
        .disabled(!status.canRestoreRawTranscript)
    }

    private var recorderToggleTitle: String {
        switch status.recorderState {
        case .idle:
            String(localized: "recorder.startRecording")
        case .recording:
            String(localized: "recorder.stopRecording")
        case .finalizing:
            String(localized: "recorder.transcribing")
        }
    }

    private var recorderToggleSystemImage: String {
        switch status.recorderState {
        case .idle:
            "record.circle"
        case .recording:
            "stop.fill"
        case .finalizing:
            "arrow.triangle.2.circlepath"
        }
    }

    private var dictationHotkeysPauseTitle: String {
        status.dictationHotkeysPaused
            ? String(localized: "Resume Dictation Hotkeys")
            : String(localized: "Pause Dictation Hotkeys")
    }

    private var dictationHotkeysPauseSystemImage: String {
        status.dictationHotkeysPaused ? "play.circle" : "pause.circle"
    }

    private func keyboardShortcut(
        from descriptor: HotkeyService.MenuShortcutDescriptor?
    ) -> KeyboardShortcut? {
        guard let descriptor else { return nil }
        return KeyboardShortcut(
            KeyEquivalent(descriptor.keyEquivalent),
            modifiers: eventModifiers(from: descriptor.modifiers)
        )
    }

    private func eventModifiers(from flags: NSEvent.ModifierFlags) -> EventModifiers {
        var modifiers: EventModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.function) { modifiers.insert(EventModifiers(rawValue: 1 << 23)) }
        return modifiers
    }
}

private extension View {
    /// Selections stay visible but cannot change while a recording or transcription
    /// runs, so the running session is never interrupted.
    func quickSelectorLock(_ isLocked: Bool) -> some View {
        disabled(isLocked)
            .help(isLocked
                ? localizedAppText(
                    "Available when the current recording or transcription has finished",
                    de: "Verfügbar, sobald die aktuelle Aufnahme oder Transkription beendet ist"
                )
                : "")
    }
}
