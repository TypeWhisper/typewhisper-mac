import SwiftUI
import TypeWhisperPluginSDK

struct AudioRecorderView: View {
    @ObservedObject var viewModel: AudioRecorderViewModel
    @ObservedObject private var pluginManager = PluginManager.shared
    @ObservedObject private var modelManager = ServiceContainer.shared.modelManagerService
    @ObservedObject private var settingsNavigation = SettingsNavigationCoordinator.shared

    private var isEditingLocked: Bool {
        viewModel.state != .idle
    }

    private func transcriptionAuthNotice(for engines: [TranscriptionEnginePlugin]) -> String? {
        engines
            .map { modelManager.transcriptionAuthStatus(for: $0) }
            .first { !$0.isAvailable }?
            .unavailableReason
    }

    @ViewBuilder
    private func enginePickerLabel(for engine: TranscriptionEnginePlugin) -> some View {
        let authStatus = modelManager.transcriptionAuthStatus(for: engine)
        HStack {
            Text(engine.providerDisplayName)
            if !authStatus.isAvailable {
                Text("(\(String(localized: "unavailable")))")
                    .foregroundStyle(.secondary)
            } else if !engine.isConfigured {
                Text("(\(String(localized: "not ready")))")
                    .foregroundStyle(.secondary)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsPageHeader(String(localized: "settings.tab.recorder"))
            Divider()

            if settingsNavigation.recorderPart == .meetings {
                SettingsPremiumPart(
                    backTitle: String(localized: "settings.tab.recorder"),
                    onBack: { settingsNavigation.recorderPart = .recorder }
                ) {
                    PremiumCalendarMeetingSettingsWindow(
                        licenseService: .shared,
                        premiumAccount: ServiceContainer.shared.premiumAccountService,
                        controllerFactory: { ServiceContainer.shared.calendarMeetingAutomationController },
                        onManageAccess: { PremiumSettingsWindowManager.shared.present(.access) }
                    )
                }
            } else {
            PremiumActiveFeatureOverview.link(to: .calendarMeeting)
                .padding(.horizontal, SettingsLayoutMetrics.pagePadding)
                .padding(.top, SettingsLayoutMetrics.pagePadding)

            Form {
            // Recording Controls
            Section {
                VStack(spacing: SettingsLayoutMetrics.sectionSpacing) {
                    // Duration display
                    Text(viewModel.formattedDuration(viewModel.duration))
                        .font(.system(size: 48, weight: .light, design: .monospaced))
                        .foregroundStyle(viewModel.state == .recording ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel(localizedAppText(
                            "Recording time",
                            de: "Aufnahmezeit",
                            ja: "録音時間",
                            zh: "录音时长"
                        ))
                        .accessibilityValue(recorderSpokenDuration(viewModel.duration))
                        .accessibilityAddTraits(.updatesFrequently)

                    // Record/Stop button
                    Button {
                        viewModel.toggleRecording()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: viewModel.state == .recording ? "stop.fill" : "record.circle")
                                .font(.title2)
                                .accessibilityHidden(true)
                            Text(recordButtonTitle)
                        }
                        .frame(minWidth: 200)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(viewModel.state == .recording ? .red : .accentColor)
                    .controlSize(.large)
                    .disabled(!viewModel.canToggleRecording)
                    .accessibilityLabel(recordButtonTitle)
                    .accessibilityValue(recorderStateDescription)

                    if viewModel.isHistoryRetranscribing {
                        Label(String(localized: "history.retranscribe.busy"), systemImage: "hourglass")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    // Level meters
                    if viewModel.state == .recording {
                        VStack(spacing: 8) {
                            if viewModel.micEnabled {
                                LevelMeterRow(
                                    label: String(localized: "recorder.mic"),
                                    icon: "mic.fill",
                                    level: viewModel.micLevel
                                )
                            }
                            if viewModel.systemAudioEnabled {
                                LevelMeterRow(
                                    label: String(localized: "recorder.systemAudio"),
                                    icon: "speaker.wave.2.fill",
                                    level: viewModel.systemLevel
                                )
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.vertical, 8)

                if let error = viewModel.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .accessibilityElement(children: .ignore)
                        .accessibilityAddTraits(.isStaticText)
                        .accessibilityLabel(String(localized: "Error: \(error)"))
                }

                if let warning = viewModel.systemAudioWarningMessage {
                    Label(warning, systemImage: "speaker.slash")
                        .foregroundStyle(.orange)
                        .font(.callout)
                        .accessibilityElement(children: .ignore)
                        .accessibilityAddTraits(.isStaticText)
                        .accessibilityLabel(localizedAppText(
                            "Warning: \(warning)",
                            de: "Warnung: \(warning)",
                            ja: "警告: \(warning)",
                            zh: "警告：\(warning)",
                            es: "Advertencia: \(warning)"
                        ))
                }
            }

            // Transcribing indicator after stop
            if viewModel.state == .finalizing {
                Section {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(String(localized: "recorder.transcribing"))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isStaticText)
                    .accessibilityLabel(String(localized: "recorder.transcribing"))
                }
            }

            // Transcripts of stopped recordings, made one at a time in the background
            if !viewModel.pendingTranscriptions.isEmpty {
                Section(String(localized: "recorder.transcriptionQueue")) {
                    ForEach(viewModel.pendingTranscriptions) { pending in
                        PendingTranscriptionRow(pending: pending)
                    }
                    if viewModel.isLivePreviewWaiting {
                        Text(String(localized: "recorder.livePreviewWaitsForQueue"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Audio Sources
            Section(String(localized: "recorder.sources")) {
                Toggle(String(localized: "recorder.mic"), isOn: $viewModel.micEnabled)
                    .disabled(isEditingLocked)

                Toggle(String(localized: "recorder.systemAudio"), isOn: $viewModel.systemAudioEnabled)
                    .disabled(isEditingLocked)

                if viewModel.systemAudioEnabled {
                    Label(
                        String(localized: "recorder.systemAudioPermission"),
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Picker(String(localized: "recorder.format"), selection: $viewModel.outputFormat) {
                    Text(String(localized: "WAV")).tag(AudioRecorderService.OutputFormat.wav)
                    Text(String(localized: "M4A")).tag(AudioRecorderService.OutputFormat.m4a)
                }
                .disabled(isEditingLocked)

                if viewModel.micEnabled && viewModel.systemAudioEnabled {
                    Picker(String(localized: "recorder.trackMode"), selection: $viewModel.trackMode) {
                        ForEach(AudioRecorderService.TrackMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .disabled(isEditingLocked)
                }

                Picker(String(localized: "Echo Handling"), selection: $viewModel.micDuckingMode) {
                    ForEach(AudioRecorderService.MicDuckingMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .disabled(
                    isEditingLocked
                    || !viewModel.micEnabled
                    || !viewModel.systemAudioEnabled
                    || viewModel.trackMode == .separate
                )

                Text(String(localized: "Affects only TypeWhisper recordings and transcriptions, not your live meeting microphone."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Transcription Settings
            Section(String(localized: "recorder.transcription")) {
                Toggle(String(localized: "recorder.createTranscriptAfterRecording"), isOn: $viewModel.transcriptionEnabled)
                    .disabled(isEditingLocked)

                Text(String(localized: "recorder.createTranscriptAfterRecording.description"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    recorderSummaryRow(
                        title: String(localized: "recorder.effectiveEngine"),
                        value: viewModel.activeEngineName ?? String(localized: "recorder.noEngineSelected")
                    )
                    recorderSummaryRow(
                        title: String(localized: "recorder.effectiveModel"),
                        value: viewModel.activeModelName ?? String(localized: "watchFolder.model.default")
                    )
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                let engines = pluginManager.transcriptionEngines
                Picker(String(localized: "Engine"), selection: $viewModel.engineChoice) {
                    Text(DefaultEngineChoice.title(engineName: modelManager.defaultEngine?.providerDisplayName))
                        .tag(nil as String?)
                    Divider()
                    ForEach(engines, id: \.providerId) { engine in
                        enginePickerLabel(for: engine)
                            .tag(engine.providerId as String?)
                            .disabled(!viewModel.canUseForTranscription(engine))
                    }
                }
                .disabled(isEditingLocked || !viewModel.transcriptionEnabled)

                if viewModel.engineChoice == nil {
                    DefaultEngineSettingsLink()
                        .disabled(isEditingLocked || !viewModel.transcriptionEnabled)
                }

                if let notice = transcriptionAuthNotice(for: engines) {
                    Label(notice, systemImage: "key")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let engine = viewModel.resolvedEngine,
                   viewModel.canUseForTranscription(engine) {
                    let models = engine.transcriptionModels
                    if models.count > 1 {
                        Picker(String(localized: "Model"), selection: $viewModel.modelChoice) {
                            Text(String(localized: "watchFolder.model.default")).tag(nil as String?)
                            Divider()
                            ForEach(models, id: \.id) { model in
                                Text(model.displayName).tag(model.id as String?)
                            }
                        }
                        .disabled(isEditingLocked || !viewModel.transcriptionEnabled)
                    }
                }

                let languageOptions: [(code: String, name: String)] = {
                    let supportedLanguages = viewModel.selectedEngineSupportedLanguages
                    guard !supportedLanguages.isEmpty else {
                        return SettingsViewModel.shared.availableLanguages
                    }
                    return localizedAppLanguageOptions(for: supportedLanguages)
                        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                        .map { (code: $0.code, name: $0.name) }
                }()

                LanguageSelectionEditor(
                    selection: $viewModel.languageSelection,
                    availableLanguages: languageOptions,
                    hintBehavior: LanguageSelectionHintBehavior(engine: viewModel.resolvedEngine),
                    autoDetectionBehavior: LanguageAutoDetectionBehavior(engine: viewModel.resolvedEngine)
                )
                .disabled(isEditingLocked || !viewModel.transcriptionEnabled)

                if viewModel.supportsTranslation {
                    TranscriptionTaskPicker(
                        task: $viewModel.selectedTask,
                        translationTarget: $viewModel.translationTarget,
                        translationTargets: viewModel.translationTargets
                    )
                    .disabled(isEditingLocked || !viewModel.transcriptionEnabled)
                }

                if !viewModel.transcriptionEnabled {
                    Label(String(localized: "recorder.transcriptionSettingsDisabledHint"), systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SpeakerDetectionToggle(
                    isOn: $viewModel.detectSpeakers,
                    isDisabled: isEditingLocked || !viewModel.transcriptionEnabled
                )

                Toggle(String(localized: "recorder.showLiveTranscriptWhileRecording"), isOn: $viewModel.livePreviewEnabled)
                    .disabled(isEditingLocked || !viewModel.transcriptionEnabled)

                if viewModel.livePreviewEnabled {
                    if let engine = viewModel.resolvedEngine,
                       !modelManager.supportsLiveTranscriptionSession(
                           engineOverrideId: engine.providerId,
                           cloudModelOverride: viewModel.availableSelectedModel
                       ) {
                        Label(
                            String(localized: "recorder.livePreviewLightweightHint"),
                            systemImage: "info.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    if isLiveTranscriptPluginActive {
                        Label(
                            String(localized: "recorder.liveTranscriptActive"),
                            systemImage: "text.quote"
                        )
                        .font(.caption)
                        .foregroundStyle(.green)
                    } else {
                        Label(
                            String(localized: "recorder.liveTranscriptHint"),
                            systemImage: "info.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .onAppear {
                modelManager.restoreProviderSelection()
                viewModel.reconcileSelectionWithAvailablePlugins()
            }

            RecorderFolderSettingsSection(
                store: ServiceContainer.shared.recorderFolderStore,
                isLocked: isEditingLocked || viewModel.retranscribingRecordingURL != nil,
                watchFolderPath: { ServiceContainer.shared.watchFolderViewModel.watchFolderPath },
                onFoldersChanged: { viewModel.loadRecordings() }
            )

            // Recordings list
            Section {
                if viewModel.recordings.isEmpty {
                    Text(String(localized: "recorder.noRecordings"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                } else {
                    ForEach(viewModel.recordings) { item in
                        RecordingRow(item: item, viewModel: viewModel)
                    }
                }
            } header: {
                HStack {
                    Text(String(localized: "recorder.recordings"))
                    Spacer()
                    if !viewModel.recordings.isEmpty {
                        Button {
                            viewModel.openRecordingsFolder()
                        } label: {
                            Label(String(localized: "recorder.revealInFinder"), systemImage: "folder")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            }
            .formStyle(.grouped)
            .padding(.horizontal, SettingsLayoutMetrics.pagePadding)
            .padding(.bottom, SettingsLayoutMetrics.pagePadding)
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        // Coming back to the page later starts on the page itself.
        .onDisappear { settingsNavigation.recorderPart = .recorder }
        .onAppear {
            viewModel.loadRecordingsIfNeeded()
        }
    }

    private var recordButtonTitle: String {
        viewModel.state == .recording
            ? String(localized: "recorder.stopRecording")
            : String(localized: "recorder.startRecording")
    }

    /// Spoken state of the recorder, so VoiceOver does not depend on the button tint.
    private var recorderStateDescription: String {
        switch viewModel.state {
        case .idle:
            localizedAppText("Stopped", de: "Gestoppt", ja: "停止中", zh: "已停止")
        case .recording:
            localizedAppText("Recording", de: "Aufnahme läuft", ja: "録音中", zh: "正在录音")
        case .finalizing:
            String(localized: "recorder.transcribing")
        }
    }

    private var isLiveTranscriptPluginActive: Bool {
        pluginManager.loadedPlugins.contains { $0.manifest.id == "com.typewhisper.livetranscript" && $0.isEnabled }
    }

    private func recorderSummaryRow(title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Level Meter Row

private struct LevelMeterRow: View {
    let label: String
    let icon: String
    let level: Float
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let maxRms: Float = 0.8

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .font(.caption)
                .frame(width: 16)
                .accessibilityHidden(true)

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)

            GeometryReader { geo in
                let levelWidth = max(0, geo.size.width * CGFloat(normalizedLevel))

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.quaternary)

                    RoundedRectangle(cornerRadius: 3)
                        .fill(levelColor(level).gradient)
                        .frame(width: levelWidth)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: level)
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(localizedAppText(
            "\(label) input level",
            de: "Eingangspegel \(label)",
            ja: "\(label)の入力レベル",
            zh: "\(label)输入电平",
            es: "Nivel de entrada de \(label)"
        ))
        .accessibilityValue(accessibilityLevelValue)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var normalizedLevel: Float {
        min(max(level, 0), Self.maxRms) / Self.maxRms
    }

    /// Mirrors the meter colors (green, yellow, red) as words plus a percentage.
    private var accessibilityLevelValue: String {
        let band: String
        if level > 0.7 {
            band = localizedAppText("High", de: "Hoch", ja: "高", zh: "高")
        } else if level > 0.4 {
            band = localizedAppText("Medium", de: "Mittel", ja: "中", zh: "中")
        } else {
            band = localizedAppText("Low", de: "Niedrig", ja: "低", zh: "低")
        }
        let percent = Double(normalizedLevel).formatted(
            .percent.precision(.fractionLength(0)).locale(Locale(identifier: preferredAppLanguageCode()))
        )
        return "\(band), \(percent)"
    }

    private func levelColor(_ level: Float) -> Color {
        if level > 0.7 {
            return .red
        } else if level > 0.4 {
            return .yellow
        }
        return .green
    }
}

// MARK: - Pending Transcription Row

private struct PendingTranscriptionRow: View {
    let pending: AudioRecorderViewModel.PendingTranscription

    var body: some View {
        HStack(spacing: 8) {
            Group {
                switch pending.status {
                case .transcribing:
                    ProgressView()
                        .controlSize(.small)
                case .waiting:
                    Image(systemName: "clock")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 18)
            .accessibilityHidden(true)

            Text(pending.fileName)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text(recorderTranscriptionStatusTitle(pending.status, hasTranscript: false))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The status shown for a recording whose transcript is not saved yet.
private func recorderTranscriptionStatusTitle(
    _ status: AudioRecorderViewModel.PendingTranscription.Status,
    hasTranscript: Bool
) -> String {
    switch status {
    case .transcribing:
        hasTranscript ? String(localized: "recorder.retranscribing") : String(localized: "recorder.transcribing")
    case .waiting:
        String(localized: "recorder.transcriptionWaiting")
    }
}

// MARK: - Recording Row

private struct RecordingRow: View {
    let item: AudioRecorderViewModel.RecordingItem
    @ObservedObject var viewModel: AudioRecorderViewModel
    @State private var showTranscript = false
    @State private var showRetranscriptionConfirmation = false
    @State private var showDeletionConfirmation = false

    /// The transcript is being made, or waits in the queue.
    private var transcriptionStatus: AudioRecorderViewModel.PendingTranscription.Status? {
        viewModel.transcriptionStatus(for: item)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.fileName)
                        .font(.body)
                        .lineLimit(1)

                    HStack(spacing: 12) {
                        Label(formattedDate(item.date), systemImage: "calendar")
                        Label(viewModel.formattedDuration(item.duration), systemImage: "clock")
                            .accessibilityLabel(localizedAppText(
                                "Duration \(recorderSpokenDuration(item.duration))",
                                de: "Dauer \(recorderSpokenDuration(item.duration))",
                                ja: "長さ \(recorderSpokenDuration(item.duration))",
                                zh: "时长 \(recorderSpokenDuration(item.duration))",
                                es: "Duración \(recorderSpokenDuration(item.duration))"
                            ))
                        Label(viewModel.formattedFileSize(item.fileSize), systemImage: "doc")
                        if item.transcript != nil {
                            Label(String(localized: "recorder.hasTranscript"), systemImage: "text.quote")
                        }
                        if item.transcriptionFailure != nil {
                            Label(String(localized: "recorder.transcriptionFailed"), systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)

                Spacer()

                HStack(spacing: 4) {
                    if let transcript = item.transcript {
                        Button {
                            showTranscript.toggle()
                        } label: {
                            Image(systemName: showTranscript ? "text.quote" : "text.quote")
                                .foregroundStyle(showTranscript ? .accent : .secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(String(localized: "recorder.showTranscript"))
                        .accessibilityLabel(showTranscript
                            ? localizedAppText(
                                "Hide transcript of \(item.fileName)",
                                de: "Transkript von \(item.fileName) ausblenden",
                                ja: "\(item.fileName)の文字起こしを非表示",
                                zh: "隐藏\(item.fileName)的转录",
                                es: "Ocultar la transcripción de \(item.fileName)"
                            )
                            : localizedAppText(
                                "Show transcript of \(item.fileName)",
                                de: "Transkript von \(item.fileName) anzeigen",
                                ja: "\(item.fileName)の文字起こしを表示",
                                zh: "显示\(item.fileName)的转录",
                                es: "Mostrar la transcripción de \(item.fileName)"
                            ))

                        Button {
                            viewModel.copyTranscript(transcript)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help(String(localized: "recorder.copyTranscript"))
                        .accessibilityLabel(localizedAppText(
                            "Copy transcript of \(item.fileName)",
                            de: "Transkript von \(item.fileName) kopieren",
                            ja: "\(item.fileName)の文字起こしをコピー",
                            zh: "复制\(item.fileName)的转录",
                            es: "Copiar la transcripción de \(item.fileName)"
                        ))
                        .accessibilityIdentifier("recorder.recording.copyTranscript")
                    }

                    if let transcriptionStatus {
                        let statusTitle = recorderTranscriptionStatusTitle(
                            transcriptionStatus,
                            hasTranscript: item.transcript != nil
                        )
                        HStack(spacing: 5) {
                            if transcriptionStatus == .waiting {
                                Image(systemName: "clock")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            if item.transcript == nil {
                                Text(statusTitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .help(statusTitle)
                        .accessibilityElement(children: .ignore)
                        .accessibilityAddTraits(.isStaticText)
                        .accessibilityLabel(statusTitle)
                    } else if item.transcript == nil {
                        Button {
                            requestTranscription()
                        } label: {
                            Label(transcriptionActionTitle, systemImage: "text.viewfinder")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .fixedSize()
                        .help(transcriptionActionTitle)
                        .disabled(!viewModel.canTranscribeRecording(item))
                        .accessibilityIdentifier("recorder.recording.transcribe")
                    } else {
                        Button {
                            requestTranscription()
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.borderless)
                        .help(transcriptionActionTitle)
                        .disabled(!viewModel.canTranscribeRecording(item))
                        .accessibilityLabel(localizedAppText(
                            "Re-transcribe \(item.fileName)",
                            de: "\(item.fileName) erneut transkribieren",
                            ja: "\(item.fileName)を再文字起こし",
                            zh: "重新转录\(item.fileName)",
                            es: "Volver a transcribir \(item.fileName)"
                        ))
                    }

                    Button {
                        viewModel.revealInFinder(item)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "recorder.revealInFinder"))
                    .disabled(viewModel.isRetranscribing(item))
                    .accessibilityLabel(localizedAppText(
                        "Show \(item.fileName) in Finder",
                        de: "\(item.fileName) im Finder anzeigen",
                        ja: "\(item.fileName)をFinderで表示",
                        zh: "在访达中显示\(item.fileName)",
                        es: "Mostrar \(item.fileName) en el Finder"
                    ))

                    Button(role: .destructive) {
                        showDeletionConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "recorder.delete"))
                    // The recording keeps its files until its transcript is done.
                    .disabled(transcriptionStatus != nil)
                    .accessibilityLabel(localizedAppText(
                        "Delete \(item.fileName)",
                        de: "\(item.fileName) löschen",
                        ja: "\(item.fileName)を削除",
                        zh: "删除\(item.fileName)",
                        es: "Eliminar \(item.fileName)"
                    ))
                }
            }

            if !viewModel.isRetranscribing(item),
               let failureSummary = viewModel.transcriptionFailureSummary(for: item) {
                Label(failureSummary, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(String(localized: "Error: \(failureSummary)"))
            }

            // Expandable transcript
            if showTranscript, let transcript = item.transcript {
                VStack(alignment: .leading, spacing: 4) {
                    Text(transcript)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    Button {
                        viewModel.copyTranscript(transcript)
                    } label: {
                        Label(String(localized: "recorder.copyTranscript"), systemImage: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.top, 4)
                .padding(.leading, 4)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.fileName)
        .contextMenu {
            if let transcript = item.transcript {
                Button(String(localized: "recorder.copyTranscript")) {
                    viewModel.copyTranscript(transcript)
                }
                Divider()
            }
            Button(transcriptionActionTitle) {
                requestTranscription()
            }
            .disabled(!viewModel.canTranscribeRecording(item))
            Button(String(localized: "recorder.revealInFinder")) {
                viewModel.revealInFinder(item)
            }
            .disabled(viewModel.isRetranscribing(item))
            Divider()
            Button(String(localized: "recorder.delete"), role: .destructive) {
                showDeletionConfirmation = true
            }
            .disabled(transcriptionStatus != nil)
        }
        .confirmationDialog(
            String(localized: "recorder.retranscribeConfirmation.title"),
            isPresented: $showRetranscriptionConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "recorder.retranscribe"), role: .destructive) {
                viewModel.transcribeRecording(item)
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(
                String(
                    format: String(localized: "recorder.retranscribeConfirmation.message"),
                    item.fileName
                )
            )
        }
        .confirmationDialog(
            String(format: String(localized: "recorder.deleteConfirmation.title"), item.fileName),
            isPresented: $showDeletionConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "recorder.moveToTrash"), role: .destructive) {
                viewModel.deleteRecording(item)
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "recorder.deleteConfirmation.message"))
        }
    }

    private var transcriptionActionTitle: String {
        item.transcript == nil
            ? String(localized: "recorder.transcribe")
            : String(localized: "recorder.retranscribe")
    }

    private func requestTranscription() {
        if item.transcript == nil {
            viewModel.transcribeRecording(item)
        } else {
            showRetranscriptionConfirmation = true
        }
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

/// Spells out a duration ("1 minute, 5 seconds") for VoiceOver instead of "1:05".
private func recorderSpokenDuration(_ duration: TimeInterval) -> String {
    Duration.seconds(max(0, Int(duration))).formatted(
        .units(allowed: [.hours, .minutes, .seconds], width: .wide)
            .locale(Locale(identifier: preferredAppLanguageCode()))
    )
}
