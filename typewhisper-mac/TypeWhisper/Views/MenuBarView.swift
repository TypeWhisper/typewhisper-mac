import SwiftUI

struct MenuBarView: View {
    @ObservedObject private var modelManager = ModelManagerViewModel.shared
    @ObservedObject private var dictation = DictationViewModel.shared

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: "waveform")
                    .foregroundStyle(.secondary)
                Text("TypeWhisper")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal)

            Divider()

            if let modelName = modelManager.activeModelName, modelManager.isModelReady {
                Label(
                    String(localized: "\(modelName) ready"),
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            } else {
                Label(
                    String(localized: "No model loaded"),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            }

            // Dictation status
            if case .recording = dictation.state {
                Label(
                    String(localized: "Recording..."),
                    systemImage: "record.circle.fill"
                )
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            } else if case .processing = dictation.state {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(String(localized: "Transcribing..."))
                        .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            }

            // Permission warnings
            if dictation.needsMicPermission {
                Label(
                    String(localized: "Microphone access needed"),
                    systemImage: "mic.slash"
                )
                .foregroundStyle(.orange)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            }

            if dictation.needsAccessibilityPermission {
                Label(
                    String(localized: "Accessibility access needed"),
                    systemImage: "lock.shield"
                )
                .foregroundStyle(.orange)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
            }

            Divider()

            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                Label(String(localized: "Settings..."), systemImage: "gear")
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)

            Button {
                if let url = URL(string: "typewhisperlocal://transcribe-file") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label(String(localized: "Transcribe File..."), systemImage: "doc.text")
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .disabled(!modelManager.isModelReady)

            Divider()

            Button(String(localized: "Quit")) {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
        .frame(width: 240)
    }
}
