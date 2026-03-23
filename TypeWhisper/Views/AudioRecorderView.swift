import SwiftUI

struct AudioRecorderView: View {
    @ObservedObject var viewModel: AudioRecorderViewModel
    @ObservedObject private var pluginManager = PluginManager.shared
    @ObservedObject private var modelManager = ServiceContainer.shared.modelManagerService
    @State private var selectedProvider: String?

    private var isEditingLocked: Bool {
        viewModel.state != .idle
    }

    var body: some View {
        Form {
            // Recording Controls
            Section {
                VStack(spacing: 16) {
                    // Duration display
                    Text(viewModel.formattedDuration(viewModel.duration))
                        .font(.system(size: 48, weight: .light, design: .monospaced))
                        .foregroundStyle(viewModel.state == .recording ? .primary : .secondary)
                        .frame(maxWidth: .infinity)

                    // Record/Stop button
                    Button {
                        if viewModel.state == .recording {
                            viewModel.stopRecording()
                        } else if viewModel.state == .idle {
                            viewModel.startRecording()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: viewModel.state == .recording ? "stop.fill" : "record.circle")
                                .font(.title2)
                            Text(viewModel.state == .recording
                                ? String(localized: "recorder.stopRecording")
                                : String(localized: "recorder.startRecording"))
                        }
                        .frame(minWidth: 200)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(viewModel.state == .recording ? .red : .accentColor)
                    .controlSize(.large)
                    .disabled(viewModel.state == .finalizing || (!viewModel.micEnabled && !viewModel.systemAudioEnabled))

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
                    Text("WAV").tag(AudioRecorderService.OutputFormat.wav)
                    Text("M4A").tag(AudioRecorderService.OutputFormat.m4a)
                }
                .disabled(isEditingLocked)

                Picker(String(localized: "Echo Handling"), selection: $viewModel.micDuckingMode) {
                    ForEach(AudioRecorderService.MicDuckingMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .disabled(isEditingLocked || !viewModel.micEnabled || !viewModel.systemAudioEnabled)

                Text(String(localized: "Affects only TypeWhisper recordings and transcriptions, not your live meeting microphone."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Transcription Settings
            Section(String(localized: "recorder.transcription")) {
                Toggle(String(localized: "recorder.liveTranscription"), isOn: $viewModel.transcriptionEnabled)
                    .disabled(isEditingLocked)

                if viewModel.transcriptionEnabled {
                    // Engine picker
                    let engines = pluginManager.transcriptionEngines
                    Picker(String(localized: "Engine"), selection: $selectedProvider) {
                        Text(String(localized: "None")).tag(nil as String?)
                        Divider()
                        ForEach(engines, id: \.providerId) { engine in
                            HStack {
                                Text(engine.providerDisplayName)
                                if !engine.isConfigured {
                                    Text("(\(String(localized: "not ready")))")
                                        .foregroundStyle(.secondary)
                                }
                            }.tag(engine.providerId as String?)
                        }
                    }
                    .onChange(of: selectedProvider) { _, newValue in
                        if let newValue {
                            modelManager.selectProvider(newValue)
                        }
                    }
                    .disabled(isEditingLocked)

                    // Model picker
                    if let providerId = selectedProvider,
                       let engine = pluginManager.transcriptionEngine(for: providerId) {
                        let models = engine.transcriptionModels
                        if models.count > 1 {
                            Picker(String(localized: "Model"), selection: Binding(
                                get: { engine.selectedModelId },
                                set: { if let id = $0 { modelManager.selectModel(providerId, modelId: id) } }
                            )) {
                                ForEach(models, id: \.id) { model in
                                    Text(model.displayName).tag(model.id as String?)
                                }
                            }
                            .disabled(isEditingLocked)
                        }
                    }

                    // Language picker
                    Picker(String(localized: "recorder.language"), selection: $viewModel.selectedLanguage) {
                        Text(String(localized: "Auto-detect")).tag(nil as String?)
                        Divider()
                        ForEach(SettingsViewModel.shared.availableLanguages, id: \.code) { lang in
                            Text(lang.name).tag(lang.code as String?)
                        }
                    }
                    .disabled(isEditingLocked)

                    // Task picker (transcribe/translate)
                    if viewModel.supportsTranslation {
                        Picker(String(localized: "Task"), selection: $viewModel.selectedTask) {
                            ForEach(TranscriptionTask.allCases) { task in
                                Text(task.displayName).tag(task)
                            }
                        }
                        .disabled(isEditingLocked)
                    }

                    // LiveTranscriptPlugin status
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
                selectedProvider = modelManager.selectedProviderId
            }

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
        .padding()
        .frame(minWidth: 500, minHeight: 400)
    }

    private var isLiveTranscriptPluginActive: Bool {
        pluginManager.loadedPlugins.contains { $0.manifest.id == "com.typewhisper.livetranscript" && $0.isEnabled }
    }
}

// MARK: - Level Meter Row

private struct LevelMeterRow: View {
    let label: String
    let icon: String
    let level: Float

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .font(.caption)
                .frame(width: 16)

            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)

            GeometryReader { geo in
                let maxRms: Float = 0.8
                let levelWidth = max(0, geo.size.width * CGFloat(min(level, maxRms) / maxRms))

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.quaternary)

                    RoundedRectangle(cornerRadius: 3)
                        .fill(levelColor(level).gradient)
                        .frame(width: levelWidth)
                        .animation(.easeOut(duration: 0.08), value: level)
                }
            }
            .frame(height: 6)
        }
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

// MARK: - Recording Row

private struct RecordingRow: View {
    let item: AudioRecorderViewModel.RecordingItem
    @ObservedObject var viewModel: AudioRecorderViewModel
    @State private var showTranscript = false

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
                        Label(viewModel.formattedFileSize(item.fileSize), systemImage: "doc")
                        if item.transcript != nil {
                            Label(String(localized: "recorder.hasTranscript"), systemImage: "text.quote")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 4) {
                    if item.transcript != nil {
                        Button {
                            showTranscript.toggle()
                        } label: {
                            Image(systemName: showTranscript ? "text.quote" : "text.quote")
                                .foregroundStyle(showTranscript ? .accent : .secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(String(localized: "recorder.showTranscript"))
                    }

                    Button {
                        viewModel.transcribeRecording(item)
                    } label: {
                        Image(systemName: "text.viewfinder")
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "recorder.transcribe"))

                    Button {
                        viewModel.revealInFinder(item)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "recorder.revealInFinder"))

                    Button(role: .destructive) {
                        viewModel.deleteRecording(item)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "recorder.delete"))
                }
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
        .contextMenu {
            if let transcript = item.transcript {
                Button(String(localized: "recorder.copyTranscript")) {
                    viewModel.copyTranscript(transcript)
                }
                Divider()
            }
            Button(String(localized: "recorder.transcribe")) {
                viewModel.transcribeRecording(item)
            }
            Button(String(localized: "recorder.revealInFinder")) {
                viewModel.revealInFinder(item)
            }
            Divider()
            Button(String(localized: "recorder.delete"), role: .destructive) {
                viewModel.deleteRecording(item)
            }
        }
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
