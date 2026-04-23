import SwiftUI
import Combine

/// Lightweight state tracker for MenuBarView that only re-publishes
/// on menu-relevant changes, avoiding high-frequency audioLevel updates.
@MainActor
private final class MenuBarState: ObservableObject {
    @Published var statusText: String
    @Published var statusImage: String
    @Published var isModelReady: Bool
    @Published var hasRecentTranscriptions: Bool
    @Published var canCopyLastTranscription: Bool
    @Published var recentTranscriptionsMenuShortcut: HotkeyService.MenuShortcutDescriptor?
    @Published var copyLastTranscriptionMenuShortcut: HotkeyService.MenuShortcutDescriptor?

    private var cancellables = Set<AnyCancellable>()

    init() {
        let dictation = DictationViewModel.shared
        let modelManager = ServiceContainer.shared.modelManagerService
        let historyService = ServiceContainer.shared.historyService
        let recentTranscriptionStore = ServiceContainer.shared.recentTranscriptionStore

        // Set initial values immediately
        self.isModelReady = modelManager.isModelReady
        let hasRecentTranscriptions = recentTranscriptionStore.latestEntry(historyRecords: historyService.records) != nil
        self.hasRecentTranscriptions = hasRecentTranscriptions
        self.canCopyLastTranscription = hasRecentTranscriptions
        self.recentTranscriptionsMenuShortcut = DictationSettingsHandler.loadMenuShortcutDescriptor(for: .recentTranscriptions)
        self.copyLastTranscriptionMenuShortcut = DictationSettingsHandler.loadMenuShortcutDescriptor(for: .copyLastTranscription)
        if let name = modelManager.activeModelName, modelManager.isModelReady {
            self.statusText = String(localized: "\(name) ready")
            self.statusImage = "checkmark.circle.fill"
        } else {
            self.statusText = String(localized: "No model loaded")
            self.statusImage = "exclamationmark.triangle.fill"
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

        historyService.$records
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshCopyAvailability()
            }
            .store(in: &cancellables)

        dictation.$hotkeyLabelsVersion
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshMenuShortcuts()
            }
            .store(in: &cancellables)
    }

    private func update(state: DictationViewModel.State) {
        let modelManager = ServiceContainer.shared.modelManagerService
        switch state {
        case .recording:
            statusText = String(localized: "Recording...")
            statusImage = "record.circle.fill"
        case .processing:
            statusText = String(localized: "Transcribing...")
            statusImage = "arrow.triangle.2.circlepath"
        default:
            if let name = modelManager.activeModelName, modelManager.isModelReady {
                statusText = String(localized: "\(name) ready")
                statusImage = "checkmark.circle.fill"
            } else {
                statusText = String(localized: "No model loaded")
                statusImage = "exclamationmark.triangle.fill"
            }
        }
        isModelReady = modelManager.isModelReady
    }

    private func refreshCopyAvailability() {
        let historyService = ServiceContainer.shared.historyService
        let recentTranscriptionStore = ServiceContainer.shared.recentTranscriptionStore
        let hasRecentTranscriptions = recentTranscriptionStore.latestEntry(historyRecords: historyService.records) != nil
        self.hasRecentTranscriptions = hasRecentTranscriptions
        canCopyLastTranscription = hasRecentTranscriptions
    }

    private func refreshMenuShortcuts() {
        recentTranscriptionsMenuShortcut = DictationSettingsHandler.loadMenuShortcutDescriptor(for: .recentTranscriptions)
        copyLastTranscriptionMenuShortcut = DictationSettingsHandler.loadMenuShortcutDescriptor(for: .copyLastTranscription)
    }
}

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var status = MenuBarState()

    var body: some View {
        Group {
            let _ = { ManagedAppWindowOpener.shared.openWindow = openWindow }()

            Label(status.statusText, systemImage: status.statusImage)

            Divider()

            Button {
                openManagedWindow("settings")
            } label: {
                Label(String(localized: "Settings..."), systemImage: "gear")
            }
            .keyboardShortcut(",")

            Button {
                openManagedWindow("history")
            } label: {
                Label(String(localized: "History"), systemImage: "clock.arrow.circlepath")
            }

            Button {
                openManagedWindow("errors")
            } label: {
                Label(String(localized: "Error Log"), systemImage: "exclamationmark.triangle")
            }

            Button {
                openManagedWindow("settings")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    FileTranscriptionViewModel.shared.showFilePickerFromMenu = true
                }
            } label: {
                Label(String(localized: "Transcribe File..."), systemImage: "doc.text")
            }
            .disabled(!status.isModelReady)

            Button {
                DictationViewModel.shared.triggerRecentTranscriptionsPalette()
            } label: {
                Label(String(localized: "Recent Transcriptions"), systemImage: "clock.arrow.circlepath")
            }
            .keyboardShortcut(keyboardShortcut(from: status.recentTranscriptionsMenuShortcut))
            .disabled(!status.hasRecentTranscriptions)

            Button {
                DictationViewModel.shared.copyLastTranscriptionToClipboard()
            } label: {
                Label(String(localized: "Copy Last Transcription"), systemImage: "doc.on.doc")
            }
            .keyboardShortcut(keyboardShortcut(from: status.copyLastTranscriptionMenuShortcut))
            .disabled(!status.canCopyLastTranscription)

            Button {
                DictationViewModel.shared.readBackLastTranscription()
            } label: {
                Label(String(localized: "Read Back Last Transcription"), systemImage: "speaker.wave.2")
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(DictationViewModel.shared.lastTranscribedText == nil)

            Button(String(localized: "Check for Updates...")) {
                UpdateChecker.shared?.checkForUpdates()
            }
            .disabled(UpdateChecker.shared?.canCheckForUpdates() != true)

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
