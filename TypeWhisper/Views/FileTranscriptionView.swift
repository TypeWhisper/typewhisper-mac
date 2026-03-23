import SwiftUI
import UniformTypeIdentifiers

struct FileTranscriptionView: View {
    @ObservedObject private var viewModel = FileTranscriptionViewModel.shared
    @ObservedObject private var watchFolder = WatchFolderViewModel.shared

    @State private var isDragTargeted = false
    @State private var showFilePicker = false
    @State private var expandedFileId: UUID?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if viewModel.files.isEmpty {
                    dropZone
                } else {
                    fileList
                    controls
                }
            }
            .padding()

            Divider()
                .padding(.horizontal)

            // MARK: - Watch Folder

            Form {
                Section(String(localized: "watchFolder.folders")) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: "watchFolder.watchFolder"))
                                .font(.body)
                            if let path = watchFolder.watchFolderPath {
                                Text(path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            } else {
                                Text(String(localized: "watchFolder.noFolder"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button(String(localized: "watchFolder.selectFolder")) {
                            watchFolder.selectWatchFolder()
                        }
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(localized: "watchFolder.outputFolder"))
                                .font(.body)
                            if let path = watchFolder.outputFolderPath {
                                Text(path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            } else {
                                Text(String(localized: "watchFolder.outputFolder.sameAsWatch"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if watchFolder.outputFolderPath != nil {
                            Button {
                                watchFolder.clearOutputFolder()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        Button(String(localized: "watchFolder.selectFolder")) {
                            watchFolder.selectOutputFolder()
                        }
                    }
                }

                Section(String(localized: "fileTranscription.transcription")) {
                    Picker(String(localized: "watchFolder.engine"), selection: $watchFolder.selectedEngine) {
                        Text(String(localized: "watchFolder.engine.default")).tag(nil as String?)
                        Divider()
                        ForEach(watchFolder.availableEngines, id: \.providerId) { engine in
                            HStack {
                                Text(engine.providerDisplayName)
                                if !engine.isConfigured {
                                    Text("(\(String(localized: "not ready")))")
                                        .foregroundStyle(.secondary)
                                }
                            }.tag(engine.providerId as String?)
                        }
                    }

                    if let engine = watchFolder.resolvedEngine {
                        let models = engine.transcriptionModels
                        if models.count > 1 {
                            Picker(String(localized: "Model"), selection: $watchFolder.selectedModel) {
                                Text(String(localized: "watchFolder.model.default")).tag(nil as String?)
                                Divider()
                                ForEach(models, id: \.id) { model in
                                    Text(model.displayName).tag(model.id as String?)
                                }
                            }
                        }
                    }

                    Picker(String(localized: "watchFolder.language"), selection: Binding(
                        get: { watchFolder.language ?? "__auto__" },
                        set: { watchFolder.language = $0 == "__auto__" ? nil : $0 }
                    )) {
                        Text(String(localized: "watchFolder.language.auto")).tag("__auto__")
                        let languages = watchFolder.selectedEngineSupportedLanguages
                        if !languages.isEmpty {
                            Divider()
                            ForEach(languages, id: \.self) { code in
                                Text(Locale.current.localizedString(forLanguageCode: code) ?? code)
                                    .tag(code)
                            }
                        }
                    }
                }

                Section(String(localized: "watchFolder.settings")) {
                    Picker(String(localized: "watchFolder.outputFormat"), selection: $watchFolder.outputFormat) {
                        Text("Markdown (.md)").tag("md")
                        Text(String(localized: "watchFolder.plainText")).tag("txt")
                    }

                    Toggle(String(localized: "watchFolder.deleteSource"), isOn: $watchFolder.deleteSourceFiles)

                    Toggle(String(localized: "watchFolder.autoStart"), isOn: $watchFolder.autoStartOnLaunch)
                }

                Section {
                    HStack {
                        Button {
                            watchFolder.toggleWatching()
                        } label: {
                            Label(
                                watchFolder.watchFolderService.isWatching
                                    ? String(localized: "watchFolder.stopWatching")
                                    : String(localized: "watchFolder.startWatching"),
                                systemImage: watchFolder.watchFolderService.isWatching ? "stop.fill" : "play.fill"
                            )
                        }
                        .disabled(watchFolder.watchFolderPath == nil)

                        if let processing = watchFolder.watchFolderService.currentlyProcessing {
                            Spacer()
                            Label(processing, systemImage: "arrow.trianglehead.2.counterclockwise")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }

                    Text(String(localized: "watchFolder.description"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(String(localized: "watchFolder.history")) {
                    if watchFolder.watchFolderService.processedFiles.isEmpty {
                        Text(String(localized: "watchFolder.history.empty"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(watchFolder.watchFolderService.processedFiles.prefix(20)) { item in
                            HStack {
                                Image(systemName: item.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(item.success ? .green : .red)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.fileName)
                                        .lineLimit(1)
                                    if let error = item.errorMessage {
                                        Text(error)
                                            .font(.caption)
                                            .foregroundStyle(.red)
                                            .lineLimit(1)
                                    } else {
                                        Text(item.date, style: .relative)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }

                        if !watchFolder.watchFolderService.processedFiles.isEmpty {
                            Button(String(localized: "watchFolder.history.clear"), role: .destructive) {
                                watchFolder.watchFolderService.clearHistory()
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 500, minHeight: 400)
        .onDrop(of: [.fileURL], isTargeted: $isDragTargeted) { providers in
            handleDrop(providers)
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: FileTranscriptionViewModel.allowedContentTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                viewModel.addFiles(urls)
            }
        }
        .onAppear {
            if viewModel.showFilePickerFromMenu {
                viewModel.showFilePickerFromMenu = false
                showFilePicker = true
            }
        }
    }

    // MARK: - Drop Zone

    @ViewBuilder
    private var dropZone: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "arrow.down.doc")
                .font(.largeTitle)
                .foregroundStyle(isDragTargeted ? .blue : .secondary)

            Text(String(localized: "Drop audio or video files here"))
                .font(.headline)

            Text(String(localized: "or"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(String(localized: "Choose Files...")) {
                showFilePicker = true
            }
            .buttonStyle(.bordered)

            Text("WAV, MP3, M4A, FLAC, MP4, MOV")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isDragTargeted ? Color.blue.opacity(0.1) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(
                            isDragTargeted ? Color.blue : Color.secondary.opacity(0.3),
                            style: StrokeStyle(lineWidth: 2, dash: [8])
                        )
                )
        )
    }

    // MARK: - File List

    @ViewBuilder
    private var fileList: some View {
        LazyVStack(spacing: 8) {
            ForEach(viewModel.files) { item in
                fileRow(item)
            }
        }
    }

    @ViewBuilder
    private func fileRow(_ item: FileTranscriptionViewModel.FileItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                fileStatusIcon(item.state)

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.fileName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)

                    if let error = item.errorMessage {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    } else if let result = item.result {
                        Text(String(localized: "\(String(format: "%.1f", result.duration))s - \(String(format: "%.1f", result.processingTime))s processing"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if item.state == .done {
                    fileActionButtons(item)
                }

                if viewModel.batchState != .processing {
                    Button {
                        viewModel.removeFile(item)
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .contentShape(Rectangle())
            .onTapGesture {
                if item.state == .done {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        expandedFileId = expandedFileId == item.id ? nil : item.id
                    }
                }
            }

            if expandedFileId == item.id, let result = item.result {
                Text(result.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
    }

    @ViewBuilder
    private func fileStatusIcon(_ state: FileTranscriptionViewModel.FileItemState) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        case .loading:
            ProgressView()
                .controlSize(.small)
        case .transcribing:
            ProgressView()
                .controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func fileActionButtons(_ item: FileTranscriptionViewModel.FileItem) -> some View {
        HStack(spacing: 4) {
            Button {
                viewModel.copyText(for: item)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .help(String(localized: "Copy"))

            if let result = item.result, !result.segments.isEmpty {
                Menu {
                    Button("SRT") { viewModel.exportSubtitles(for: item, format: .srt) }
                    Button("VTT") { viewModel.exportSubtitles(for: item, format: .vtt) }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
                .menuStyle(.borderlessButton)
                .frame(width: 20)
                .help(String(localized: "Export Subtitles"))
            }
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private var controls: some View {
        HStack {
            Button(String(localized: "Add Files...")) {
                showFilePicker = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(viewModel.batchState == .processing)

            if viewModel.supportsTranslation {
                Picker(String(localized: "Task"), selection: $viewModel.selectedTask) {
                    ForEach(TranscriptionTask.allCases) { task in
                        Text(task.displayName).tag(task)
                    }
                }
                .frame(width: 180)
                .controlSize(.small)
            }

            Spacer()

            if viewModel.hasResults {
                Menu(String(localized: "Export All")) {
                    Button(String(localized: "Copy All Text")) { viewModel.copyAllText() }
                    Divider()
                    Button(String(localized: "Export All as SRT")) { viewModel.exportAllSubtitles(format: .srt) }
                    Button(String(localized: "Export All as VTT")) { viewModel.exportAllSubtitles(format: .vtt) }
                }
                .controlSize(.small)
            }

            if viewModel.batchState == .processing {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(String(localized: "\(viewModel.completedFiles)/\(viewModel.totalFiles)"))
                        .font(.caption)
                        .monospacedDigit()
                }
            } else {
                Button {
                    viewModel.transcribeAll()
                } label: {
                    Label(String(localized: "Transcribe All"), systemImage: "waveform")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!viewModel.canTranscribe)
            }

            Button {
                viewModel.reset()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.batchState == .processing)
            .help(String(localized: "Clear All"))
        }
    }

    // MARK: - Drop Handling

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

                let ext = url.pathExtension.lowercased()
                guard AudioFileService.supportedExtensions.contains(ext) else { return }

                Task { @MainActor in
                    viewModel.addFiles([url])
                }
            }
            handled = true
        }
        return handled
    }
}
