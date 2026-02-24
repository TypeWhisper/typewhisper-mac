import SwiftUI
import Combine

/// Lightweight state tracker for MenuBarView that only re-publishes
/// on menu-relevant changes, avoiding high-frequency audioLevel updates.
@MainActor
private final class MenuBarState: ObservableObject {
    @Published var statusText: String
    @Published var statusImage: String
    @Published var isModelReady: Bool

    private var cancellables = Set<AnyCancellable>()

    init() {
        let dictation = DictationViewModel.shared
        let modelManager = ModelManagerViewModel.shared

        // Set initial values immediately
        self.isModelReady = modelManager.isModelReady
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
    }

    private func update(state: DictationViewModel.State) {
        let modelManager = ModelManagerViewModel.shared
        switch state {
        case .recording, .paused:
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
}

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var status = MenuBarState()

    var body: some View {
        Label(status.statusText, systemImage: status.statusImage)

        Divider()

        Button {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            openWindow(id: "settings")
        } label: {
            Label(String(localized: "Settings..."), systemImage: "gear")
        }
        .keyboardShortcut(",")

        Button {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            openWindow(id: "history")
        } label: {
            Label(String(localized: "History"), systemImage: "clock.arrow.circlepath")
        }

        Button {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
            openWindow(id: "settings")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                FileTranscriptionViewModel.shared.showFilePickerFromMenu = true
            }
        } label: {
            Label(String(localized: "Transcribe File..."), systemImage: "doc.text")
        }
        .disabled(!status.isModelReady)

        #if !APPSTORE
        Button(String(localized: "Check for Updates...")) {
            UpdateChecker.shared?.checkForUpdates()
        }
        .disabled(UpdateChecker.shared?.canCheckForUpdates() != true)
        #endif

        Divider()

        Button(String(localized: "Quit")) {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
