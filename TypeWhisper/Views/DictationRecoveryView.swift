import SwiftUI
import TypeWhisperPluginSDK

struct DictationRecoveryView: View {
    @ObservedObject private var viewModel = DictationRecoveryViewModel.shared
    // Names the default engine in the engine picker and follows its changes.
    @ObservedObject private var modelManager = ServiceContainer.shared.modelManagerService
    @Environment(\.openWindow) private var openWindow
    @State private var showDiscardAllConfirmation = false

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
        // Recovering only changes the page, so VoiceOver users hear the outcome.
        .onChange(of: viewModel.lastSavedHistoryRecordID) { _, recordID in
            guard recordID != nil else { return }
            announce(localizedAppText(
                "Saved to History",
                de: "Im Verlauf gespeichert",
                ja: "履歴に保存しました",
                zh: "已保存到历史记录"
            ))
        }
        .onChange(of: recoveryErrors) { previous, current in
            for message in Self.newRecoveryErrors(previous: previous, current: current) {
                ServiceContainer.shared.accessibilityAnnouncementService.announceError(message)
            }
        }
    }

    /// The current error of each recording, keyed by recording.
    private var recoveryErrors: [String: String] {
        Dictionary(
            viewModel.recoveries.compactMap { item in item.errorMessage.map { (item.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Errors that a recording did not have before, compared per recording, so a second
    /// recording failing with the same message as another one is still announced.
    /// Recordings that fail with the same message at once are announced together with
    /// their number, because the announcement service speaks a repeated message once.
    static func newRecoveryErrors(previous: [String: String], current: [String: String]) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for (recordingID, message) in current.sorted(by: { $0.key < $1.key })
        where previous[recordingID] != message {
            if counts[message] == nil { order.append(message) }
            counts[message, default: 0] += 1
        }
        return order.map { message in
            let count = counts[message] ?? 1
            guard count > 1 else { return message }
            return localizedAppText(
                "\(message) (\(count) recordings)",
                de: "\(message) (\(count) Aufnahmen)",
                ja: "\(message)（\(count)件の録音）",
                zh: "\(message)（\(count) 个录音）",
                es: "\(message) (\(count) grabaciones)"
            )
        }
    }

    private func announce(_ message: String) {
        ServiceContainer.shared.accessibilityAnnouncementService.announce(message)
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

                Text(String(localized: "Recovery recordings are stored only on this Mac. Immediately prevents TypeWhisper from creating local recovery audio files. History audio is controlled separately, and cloud engines may still receive audio for transcription."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(String(localized: "The last three successful dictations are also kept for up to 24 hours so you can retry an incomplete result. Immediately disables this retry buffer too."))
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
                            Text(localizedAppText("Saved to History", de: "Im Verlauf gespeichert"))
                                .font(.body.weight(.medium))
                            Text(lastSavedRecoveryFileName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)

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
                    ForEach(viewModel.recoveries) { recovery in
                        recoveryRow(recovery)
                    }

                    if viewModel.recoveries.count > 1 {
                        HStack {
                            Spacer()

                            Button(role: .destructive) {
                                showDiscardAllConfirmation = true
                            } label: {
                                Label(localizedAppText("Discard All", de: "Alle verwerfen"), systemImage: "trash")
                            }
                            .disabled(viewModel.isProcessing)
                            .confirmationDialog(
                                localizedAppText("Discard All Recordings?", de: "Alle Aufnahmen verwerfen?"),
                                isPresented: $showDiscardAllConfirmation
                            ) {
                                Button(localizedAppText("Discard All", de: "Alle verwerfen"), role: .destructive) {
                                    viewModel.discardAllRecoveries()
                                }
                            } message: {
                                Text(localizedAppText(
                                    "This will permanently delete all \(viewModel.recoveries.count) recovery recordings.",
                                    de: "Dadurch werden alle \(viewModel.recoveries.count) Wiederherstellungsaufnahmen dauerhaft gelöscht.",
                                    es: "Esto eliminará de forma permanente las \(viewModel.recoveries.count) grabaciones de recuperación."
                                ))
                            }
                        }
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
                    Text(DefaultEngineChoice.title(engineName: modelManager.defaultEngine?.providerDisplayName))
                        .tag(nil as String?)
                    Divider()
                    ForEach(viewModel.availableEngines, id: \.providerId) { engine in
                        enginePickerLabel(for: engine)
                            .tag(engine.providerId as String?)
                            .disabled(!viewModel.canUseForTranscription(engine))
                    }
                }
                .disabled(viewModel.isProcessing)

                if viewModel.selectedEngine == nil {
                    DefaultEngineSettingsLink()
                }

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
                        TranscriptionTaskPicker(
                            task: $viewModel.selectedTask,
                            translationTarget: $viewModel.translationTarget,
                            translationTargets: viewModel.translationTargets
                        )
                        .disabled(viewModel.isProcessing)
                    }

                    LanguageSelectionEditor(
                        selection: $viewModel.languageSelection,
                        availableLanguages: recoveryLanguageOptions,
                        hintBehavior: LanguageSelectionHintBehavior(engine: viewModel.resolvedEngine),
                        autoDetectionBehavior: LanguageAutoDetectionBehavior(engine: viewModel.resolvedEngine)
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

                Toggle(isOn: $viewModel.hedgeEnabled) {
                    Label(
                        localizedAppText("Race this engine when the primary is slow", de: "Diese Engine starten, wenn die primäre Engine langsam ist"),
                        systemImage: "hare"
                    )
                }
                .disabled(viewModel.isProcessing || !viewModel.canUseAutomaticFallback || !viewModel.automaticFallbackEnabled)

                if viewModel.hedgeEnabled {
                    HStack {
                        Text(localizedAppText("Start racing after", de: "Rennen starten nach"))
                            .accessibilityHidden(true)
                        Spacer()
                        Stepper(
                            value: $viewModel.hedgeThresholdSeconds,
                            in: 1.0...15.0,
                            step: 0.5
                        ) {
                            Text(localizedAppText(
                                "\(hedgeThresholdLabelValue) seconds",
                                de: "\(hedgeThresholdLabelValue) Sekunden",
                                es: "\(hedgeThresholdLabelValue) segundos"
                            ))
                        }
                        // One element: the text in front of the stepper names it.
                        .accessibilityLabel(localizedAppText(
                            "Start racing after",
                            de: "Rennen starten nach",
                            ja: "並行実行を開始するまでの時間",
                            zh: "开始并行处理前的等待时间"
                        ))
                        .accessibilityValue(localizedAppText(
                            "\(hedgeThresholdLabelValue) seconds",
                            de: "\(hedgeThresholdLabelValue) Sekunden",
                            ja: "\(hedgeThresholdLabelValue) 秒",
                            zh: "\(hedgeThresholdLabelValue) 秒",
                            es: "\(hedgeThresholdLabelValue) segundos"
                        ))
                    }
                    .disabled(viewModel.isProcessing || !viewModel.canUseAutomaticFallback || !viewModel.automaticFallbackEnabled)

                    Text(localizedAppText(
                        "If the primary engine hasn't answered by then, the same audio is also sent to this engine; whichever finishes first is used and the other request is cancelled. A dispatched race costs one extra API call.",
                        de: "Antwortet die primäre Engine bis dahin nicht, wird dasselbe Audio zusätzlich an diese Engine gesendet; das schnellere Ergebnis wird verwendet, die andere Anfrage abgebrochen. Ein ausgelöstes Rennen kostet einen zusätzlichen API-Aufruf."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

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
                                .accessibilityLabel(String(localized: "Transcribing..."))
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
        let isSelectable = viewModel.recoveries.count > 1
        let isSelected = viewModel.selectedRecovery?.id == recovery.id

        return HStack(alignment: .top, spacing: 10) {
            // The row itself picks the recording that Transcribe acts on, so
            // every recording stays visible with its own Discard button.
            Button {
                viewModel.selectedRecoveryID = recovery.id
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    if isSelectable {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                            .accessibilityHidden(true)
                    }

                    Image(systemName: statusSystemImage(for: recovery.state))
                        .foregroundStyle(statusColor(for: recovery.state))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(recovery.fileName)
                            .font(.body.weight(.medium))
                            .lineLimit(1)

                        if DictationRecoveryAudioStore.isRecentSuccessfulRecording(recovery.url) {
                            Text(String(localized: "Recent successful dictation"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let errorMessage = recovery.errorMessage {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .lineLimit(2)
                        }
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isSelectable || viewModel.isProcessing)
            .accessibilityAddTraits(isSelectable && isSelected ? .isSelected : [])
            .accessibilityValue(recovery.isProcessing ? String(localized: "Transcribing...") : "")
            .accessibilityHint(isSelectable
                ? localizedAppText(
                    "Selects this recording for Transcribe.",
                    de: "Wählt diese Aufnahme für „Transkribieren“ aus.",
                    ja: "この録音を「音声認識」の対象に選択します。",
                    zh: "选择此录音进行转录。"
                )
                : "")

            Button(role: .destructive) {
                viewModel.discardRecovery(recovery)
            } label: {
                Label(localizedAppText("Discard", de: "Verwerfen"), systemImage: "trash")
            }
            .disabled(viewModel.isProcessing)
            .accessibilityLabel(localizedAppText(
                "Discard \(recovery.fileName)",
                de: "\(recovery.fileName) verwerfen",
                es: "Descartar \(recovery.fileName)"
            ))
        }
    }

    private var hedgeThresholdLabelValue: String {
        viewModel.hedgeThresholdSeconds.formatted(.number.precision(.fractionLength(1)))
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
