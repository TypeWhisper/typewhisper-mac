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
    /// Configured dictation shortcuts with their mode, empty when none is set.
    @Published var dictationShortcuts: [MenuBarStatusFormatting.DictationShortcut]
    @Published var needsEngineSetup: Bool
    @Published var lastDictationError: DictationViewModel.ErrorSummary?

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
        self.dictationShortcuts = MenuBarStatusFormatting.dictationShortcuts()
        self.needsEngineSetup = modelManager.activeModelName == nil
        self.lastDictationError = dictation.lastDictationError
        if let error = dictation.lastDictationError {
            self.statusText = MenuBarStatusFormatting.errorStatusText(error.message)
            self.statusImage = "exclamationmark.triangle.fill"
        } else {
            let modelStatus = Self.idleModelStatus(from: modelManager)
            self.statusText = modelStatus.text
            self.statusImage = modelStatus.image
        }

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

        dictation.$lastDictationError
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                self?.lastDictationError = error
                self?.update(state: dictation.state)
            }
            .store(in: &cancellables)
    }

    private func update(state: DictationViewModel.State) {
        let modelManager = ServiceContainer.shared.modelManagerService
        // Engine state is refreshed on every update, including while hotkeys are paused,
        // so "Choose Engine..." follows changes made in Settings in the meantime.
        isModelReady = modelManager.isModelReady
        needsEngineSetup = modelManager.activeModelName == nil

        switch state {
        case .recording:
            statusText = String(localized: "Recording...")
            statusImage = "record.circle.fill"
        case .processing:
            statusText = String(localized: "Transcribing...")
            statusImage = "arrow.triangle.2.circlepath"
        default:
            if let lastDictationError {
                // Feedback in the indicator fades after seconds; the menu keeps the
                // last error until the next dictation starts or the user acts on it,
                // ahead of the paused state, which has its own Resume entry below.
                statusText = MenuBarStatusFormatting.errorStatusText(lastDictationError.message)
                statusImage = "exclamationmark.triangle.fill"
            } else if dictationHotkeysPaused, state == .idle {
                statusText = String(localized: "Dictation hotkeys paused")
                statusImage = "pause.circle.fill"
            } else {
                let modelStatus = Self.idleModelStatus(from: modelManager)
                statusText = modelStatus.text
                statusImage = modelStatus.image
            }
        }
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
        dictationShortcuts = MenuBarStatusFormatting.dictationShortcuts()
    }

    private func refreshUndoAvailability() {
        let undoService = DictationViewModel.shared.dictationUndoService
        canUndoLastDictation = undoService.canUndo
        canRestoreRawTranscript = undoService.canRestoreRaw
    }
}

enum MenuBarStatusFormatting {
    struct DictationShortcut: Equatable, Hashable {
        let label: String
        let mode: String

        /// "Fn (Hybrid)"
        var title: String {
            "\(label) (\(mode))"
        }
    }

    /// Every configured dictation shortcut with its mode, hybrid first, in the order
    /// of the Hotkeys page. Empty when no dictation shortcut is set.
    @MainActor
    static func dictationShortcuts(
        labels: @MainActor (HotkeySlotType) -> [String] = DictationSettingsHandler.loadHotkeyLabels
    ) -> [DictationShortcut] {
        let slots: [(HotkeySlotType, String)] = [
            (.hybrid, String(localized: "Hybrid")),
            (.pushToTalk, String(localized: "Push-to-Talk")),
            (.toggle, String(localized: "Toggle")),
        ]
        return slots.flatMap { slot, mode in
            labels(slot).map { DictationShortcut(label: $0, mode: mode) }
        }
    }

    /// Menu rows do not wrap. Long messages keep their first sentence when it fits,
    /// since the fix hint that follows is one click away in "Fix in Settings...".
    nonisolated static func errorStatusText(_ message: String, limit: Int = 64) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        if let end = trimmed.firstIndex(where: \.endsSentence) {
            let sentence = String(trimmed[...end])
            if sentence.count <= limit { return sentence }
        }
        return String(trimmed.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

enum MenuBarMenuItem: Hashable {
    case settings
    case history
    case errorLog
    case toggleRecorder
    case dictationShortcut
    case chooseEngine
    case fixLastError
    case toggleDictationHotkeysPause
    case transcribeFile
    case recoverLastRecording
    case lastTranscription
    case recentTranscriptions
    case copyLastTranscription
    case pasteLastTranscription
    case undoLastDictation
    case restoreRawTranscript
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

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var status = MenuBarState()
    @StateObject private var quickSelection = DictationQuickSelectionModel()

    var body: some View {
        Group {
            let _ = { ManagedAppWindowOpener.shared.openWindow = openWindow }()

            Label(status.statusText, systemImage: status.statusImage)

            Divider()

            // The way out of a failed dictation, or to a working engine, comes first.
            if status.lastDictationError != nil {
                menuItem(for: .fixLastError)
            } else if status.needsEngineSetup {
                menuItem(for: .chooseEngine)
            }

            // Dictation starts with its shortcut. Showing it here keeps the Recorder
            // entry below from reading as the way to dictate.
            menuItem(for: .dictationShortcut)
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

            Divider()

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

        case .dictationShortcut:
            if let primary = status.dictationShortcuts.first {
                // The row names the first shortcut; the submenu lists the rest, so the
                // menu stays narrow with several shortcuts configured.
                Menu {
                    ForEach(status.dictationShortcuts, id: \.self) { shortcut in
                        Text(verbatim: shortcut.title)
                    }
                    Divider()
                    Button(String(localized: "Hotkey Settings...")) {
                        openSettingsTab(.hotkeys)
                    }
                } label: {
                    Label(
                        String(localized: "Dictation shortcut: \(primary.title)"),
                        systemImage: "keyboard"
                    )
                }
            } else {
                Button {
                    openSettingsTab(.hotkeys)
                } label: {
                    Label(String(localized: "Set a dictation shortcut..."), systemImage: "keyboard")
                }
            }

        case .chooseEngine:
            Button {
                quickSelection.openDictationSettings()
            } label: {
                Label(String(localized: "Choose Engine..."), systemImage: "waveform")
            }

        case .fixLastError:
            Button {
                let error = status.lastDictationError
                DictationViewModel.shared.clearLastDictationError()
                if let tab = error?.settingsTab {
                    openSettingsTab(tab)
                }
            } label: {
                Label(fixLastErrorTitle, systemImage: "wrench.and.screwdriver")
            }

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
                    && !status.canUndoLastDictation
            )

        case .recentTranscriptions:
            recentTranscriptionsButton

        case .copyLastTranscription:
            copyLastTranscriptionButton

        case .pasteLastTranscription:
            pasteLastTranscriptionButton

        case .undoLastDictation:
            undoLastDictationButton

        case .restoreRawTranscript:
            restoreRawTranscriptButton

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


    private var fixLastErrorTitle: String {
        status.lastDictationError?.settingsTab == nil
            ? String(localized: "Dismiss Error")
            : String(localized: "Fix in Settings...")
    }

    private func openSettingsTab(_ tab: SettingsTab) {
        SettingsNavigationCoordinator.shared?.navigate(to: tab)
        openManagedWindow("settings")
    }

    // Named after the feature so the entry is not mistaken for starting a dictation.
    private var recorderToggleTitle: String {
        switch status.recorderState {
        case .idle:
            String(localized: "Start Recorder")
        case .recording:
            String(localized: "Stop Recorder")
        case .finalizing:
            String(localized: "Recorder: Transcribing...")
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
