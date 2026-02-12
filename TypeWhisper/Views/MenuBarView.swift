import SwiftUI

struct MenuBarView: View {
    @ObservedObject private var modelManager = ModelManagerViewModel.shared
    @ObservedObject private var dictation = DictationViewModel.shared
    @ObservedObject private var apiServer = APIServerViewModel.shared

    var body: some View {
        if let modelName = modelManager.activeModelName, modelManager.isModelReady {
            Label(
                String(localized: "\(modelName) ready"),
                systemImage: "checkmark.circle.fill"
            )
        } else {
            Label(
                String(localized: "No model loaded"),
                systemImage: "exclamationmark.triangle.fill"
            )
        }

        if case .recording = dictation.state {
            Label(
                String(localized: "Recording..."),
                systemImage: "record.circle.fill"
            )
        } else if case .processing = dictation.state {
            Label(
                String(localized: "Transcribing..."),
                systemImage: "arrow.triangle.2.circlepath"
            )
        }

        if dictation.needsMicPermission {
            Label(
                String(localized: "Microphone access needed"),
                systemImage: "mic.slash"
            )
        }

        if dictation.needsAccessibilityPermission {
            Label(
                String(localized: "Accessibility access needed"),
                systemImage: "lock.shield"
            )
        }

        if apiServer.isRunning {
            Label(
                String(localized: "API: Port \(apiServer.port)"),
                systemImage: "network"
            )
        }

        Divider()

        Button {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } label: {
            Label(String(localized: "Settings..."), systemImage: "gear")
        }
        .keyboardShortcut(",")

        Button {
            if let url = URL(string: "typewhisperlocal://transcribe-file") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            Label(String(localized: "Transcribe File..."), systemImage: "doc.text")
        }
        .disabled(!modelManager.isModelReady)

        Divider()

        Button(String(localized: "Quit")) {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
