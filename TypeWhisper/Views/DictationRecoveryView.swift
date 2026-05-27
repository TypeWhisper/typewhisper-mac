import SwiftUI
import TypeWhisperPluginSDK

struct DictationRecoveryView: View {
    @ObservedObject private var viewModel = DictationRecoveryViewModel.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if viewModel.hasRecoveryContent {
                recoveryForm
            } else {
                ContentUnavailableView {
                    Label(
                        localizedAppText("No Recording to Recover", de: "Keine Aufnahme zur Wiederherstellung"),
                        systemImage: "waveform"
                    )
                }
            }
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    private var recoveryForm: some View {
        Form {
            if let lastSavedRecoveryFileName = viewModel.lastSavedRecoveryFileName {
                Section(String(localized: "History")) {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(localizedAppText("Saved to History", de: "In Verlauf gespeichert"))
                                .font(.body.weight(.medium))
                            Text(lastSavedRecoveryFileName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            openWindow(id: "history")
                        } label: {
                            Label(String(localized: "History"), systemImage: "clock.arrow.circlepath")
                        }
                        .disabled(viewModel.isProcessing)
                    }
                }
            }

            if viewModel.hasRecovery {
                Section(String(localized: "Recordings")) {
                    if viewModel.recoveries.count > 1 {
                        Picker(
                            localizedAppText("Recording", de: "Aufnahme"),
                            selection: $viewModel.selectedRecoveryID
                        ) {
                            ForEach(viewModel.recoveries) { recovery in
                                Text(recovery.fileName).tag(recovery.id as String?)
                            }
                        }
                        .disabled(viewModel.isProcessing)
                    }

                    if let recovery = viewModel.selectedRecovery {
                        recoveryRow(recovery)
                    }
                }

                Section(String(localized: "Transcription")) {
                    Picker(String(localized: "Engine"), selection: $viewModel.selectedEngine) {
                        Text(String(localized: "Default Engine")).tag(nil as String?)
                        Divider()
                        ForEach(viewModel.availableEngines, id: \.providerId) { engine in
                            enginePickerLabel(for: engine)
                                .tag(engine.providerId as String?)
                                .disabled(!viewModel.canUseForTranscription(engine))
                        }
                    }
                    .disabled(viewModel.isProcessing)

                    if let engine = viewModel.resolvedEngine {
                        let models = engine.transcriptionModels
                        if models.count > 1 {
                            Picker(String(localized: "Model"), selection: $viewModel.selectedModel) {
                                Text(String(localized: "watchFolder.model.default")).tag(nil as String?)
                                Divider()
                                ForEach(models, id: \.id) { model in
                                    Text(model.displayName).tag(model.id as String?)
                                }
                            }
                            .disabled(viewModel.isProcessing)
                        }
                    }

                    if viewModel.supportsTranslation {
                        Picker(String(localized: "Task"), selection: $viewModel.selectedTask) {
                            ForEach(TranscriptionTask.allCases) { task in
                                Text(task.displayName).tag(task)
                            }
                        }
                        .disabled(viewModel.isProcessing)
                    }

                    LanguageSelectionEditor(
                        selection: $viewModel.languageSelection,
                        availableLanguages: recoveryLanguageOptions,
                        hintBehavior: LanguageSelectionHintBehavior(engine: viewModel.resolvedEngine)
                    )
                    .disabled(viewModel.isProcessing)
                }

                Section {
                    HStack {
                        Spacer()

                        if viewModel.isProcessing {
                            ProgressView()
                                .controlSize(.small)
                        }

                        Button {
                            viewModel.transcribe()
                        } label: {
                            Label(String(localized: "Transcribe"), systemImage: "waveform")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!viewModel.canTranscribe)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func recoveryRow(_ recovery: DictationRecoveryViewModel.RecoveryItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: statusSystemImage(for: recovery.state))
                .foregroundStyle(statusColor(for: recovery.state))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(recovery.fileName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                if let errorMessage = recovery.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }

            Spacer()

            Button(role: .destructive) {
                viewModel.discardRecovery(recovery)
            } label: {
                Label(localizedAppText("Discard", de: "Verwerfen"), systemImage: "trash")
            }
            .disabled(viewModel.isProcessing)
        }
    }

    private var recoveryLanguageOptions: [(code: String, name: String)] {
        let supportedLanguages = viewModel.selectedEngineSupportedLanguages
        guard !supportedLanguages.isEmpty else {
            return SettingsViewModel.shared.availableLanguages
        }
        return localizedAppLanguageOptions(for: supportedLanguages)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { (code: $0.code, name: $0.name) }
    }

    private func statusSystemImage(for state: DictationRecoveryViewModel.RecoveryState) -> String {
        switch state {
        case .idle:
            "waveform"
        case .loading, .transcribing:
            "waveform"
        case .error:
            "exclamationmark.circle.fill"
        }
    }

    private func statusColor(for state: DictationRecoveryViewModel.RecoveryState) -> Color {
        switch state {
        case .idle, .loading, .transcribing:
            .secondary
        case .error:
            .red
        }
    }

    @ViewBuilder
    private func enginePickerLabel(for engine: TranscriptionEnginePlugin) -> some View {
        HStack {
            Text(engine.providerDisplayName)
            if !viewModel.canUseForTranscription(engine) {
                Text("(\(String(localized: "not ready")))")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
