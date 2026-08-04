import SwiftUI
import TypeWhisperPluginSDK

struct DictationRecoveryView: View {
    @ObservedObject private var viewModel = DictationRecoveryViewModel.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            SettingsPageHeader(localizedAppText("Recovery", de: "Wiederherstellung"))
            Divider()

            recoveryForm
                .padding(.horizontal, SettingsLayoutMetrics.pagePadding)
                .padding(.bottom, SettingsLayoutMetrics.pagePadding)
        }
        .frame(minWidth: 500, minHeight: 400)
        .onAppear {
            viewModel.refreshRecoveries()
        }
    }

    private var recoveryForm: some View {
        Form {
            Section(String(localized: "Storage")) {
                Picker(
                    String(localized: "Auto-delete recovery recordings"),
                    selection: $viewModel.retentionPolicy
                ) {
                    ForEach(DictationRecoveryRetentionPolicy.allCases, id: \.self) { policy in
                        Text(retentionLabel(for: policy)).tag(policy)
                    }
                }
                .disabled(viewModel.isProcessing)

                Text(String(localized: "Recovery recordings are stored only on this Mac. Immediately prevents TypeWhisper from creating local recovery WAV files. History audio is controlled separately, and cloud engines may still receive audio for transcription."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
            } else if viewModel.isRecoveryStorageDisabled {
                Section {
                    Label(
                        String(localized: "Recovery recording is disabled"),
                        systemImage: "lock"
                    )
                    .foregroundStyle(.secondary)
                }
            } else if !viewModel.hasRecoveryContent {
                Section {
                    Label(
                        localizedAppText("No Recording to Recover", de: "Keine Aufnahme zur Wiederherstellung"),
                        systemImage: "waveform"
                    )
                    .foregroundStyle(.secondary)
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

                if viewModel.hasRecovery {
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
            }

            Section(localizedAppText("Automatic Fallback", de: "Automatischer Fallback")) {
                Toggle(isOn: $viewModel.automaticFallbackEnabled) {
                    Label(
                        localizedAppText("Retry failed dictations with this engine", de: "Fehlgeschlagene Diktate mit dieser Engine erneut versuchen"),
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .disabled(viewModel.isProcessing || !viewModel.canUseAutomaticFallback)

                if let message = viewModel.automaticFallbackUnavailableMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if viewModel.hasRecovery {
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

    private func retentionLabel(for policy: DictationRecoveryRetentionPolicy) -> String {
        switch policy {
        case .immediately:
            String(localized: "Immediately (disable recovery)")
        case .oneDay:
            String(localized: "1 day")
        case .sevenDays:
            String(localized: "7 days")
        case .thirtyDays:
            String(localized: "30 days")
        case .sixtyDays:
            String(localized: "60 days")
        case .ninetyDays:
            String(localized: "90 days")
        case .oneHundredEightyDays:
            String(localized: "180 days")
        case .never:
            String(localized: "Never")
        }
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
