import SwiftUI
import UniformTypeIdentifiers
import TypeWhisperPluginSDK

struct FileTranscriptionView: View {
    @ObservedObject private var viewModel = FileTranscriptionViewModel.shared
    @ObservedObject private var watchFolder = WatchFolderViewModel.shared
    // Names the default engine in the pickers and follows its changes.
    @ObservedObject private var modelManager = ServiceContainer.shared.modelManagerService

    @State private var isDragTargeted = false
    @State private var showFilePicker = false
    @State private var expandedFileId: UUID?

    var body: some View {
        VStack(spacing: 0) {
            SettingsPageHeader(String(localized: "File Transcription"))
            Divider()

            ScrollView {
                VStack(spacing: SettingsLayoutMetrics.sectionSpacing) {
                    if viewModel.files.isEmpty {
                        dropZone
                    } else {
                        fileList
                        controls
                    }
                }
                .padding(SettingsLayoutMetrics.pagePadding)

                Divider()
                    .padding(.horizontal, SettingsLayoutMetrics.pagePadding)

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
                        .accessibilityLabel(localizedAppText(
                            "Select Watch Folder…",
                            de: "Überwachten Ordner auswählen …",
                            ja: "ウォッチフォルダを選択…",
                            zh: "选择监控文件夹…"
                        ))
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
                            .help(clearOutputFolderLabel)
                            .accessibilityLabel(clearOutputFolderLabel)
                        }
                        Button(String(localized: "watchFolder.selectFolder")) {
                            watchFolder.selectOutputFolder()
                        }
                        .accessibilityLabel(localizedAppText(
                            "Select Output Folder…",
                            de: "Ausgabeordner auswählen …",
                            ja: "出力フォルダを選択…",
                            zh: "选择输出文件夹…"
                        ))
                    }
                }

                Section(localizedAppText("Watch Folder Transcription", de: "Ordner-Transkription")) {
                    Picker(String(localized: "watchFolder.engine"), selection: $watchFolder.engineChoice) {
                        Text(defaultEngineTitle).tag(nil as String?)
                        Divider()
                        ForEach(watchFolder.availableEngines, id: \.providerId) { engine in
                            HStack {
                                Text(engine.providerDisplayName)
                                if !watchFolder.canPrepareForTranscription(engine) {
                                    Text("(\(String(localized: "not ready")))")
                                        .foregroundStyle(.secondary)
                                }
                            }.tag(engine.providerId as String?)
                        }
                    }

                    if watchFolder.engineChoice == nil {
                        DefaultEngineSettingsLink()
                    }

                    if let engine = watchFolder.resolvedEngine {
                        let models = engine.transcriptionModels
                        if models.count > 1 {
                            Picker(String(localized: "Model"), selection: $watchFolder.modelChoice) {
                                Text(String(localized: "watchFolder.model.default")).tag(nil as String?)
                                Divider()
                                ForEach(models, id: \.id) { model in
                                    Text(model.displayName).tag(model.id as String?)
                                }
                            }
                        }
                    }

                    LanguageSelectionEditor(
                        selection: $watchFolder.languageSelection,
                        availableLanguages: localizedAppLanguageOptions(for: watchFolder.selectedEngineSupportedLanguages)
                            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                            .map { (code: $0.code, name: $0.name) },
                        hintBehavior: LanguageSelectionHintBehavior(engine: watchFolder.resolvedEngine),
                        autoDetectionBehavior: LanguageAutoDetectionBehavior(engine: watchFolder.resolvedEngine)
                    )
                }

                Section(String(localized: "watchFolder.settings")) {
                    Picker(String(localized: "watchFolder.outputFormat"), selection: $watchFolder.outputFormat) {
                        Text(WatchFolderOutputFormat.markdown.displayName).tag(WatchFolderOutputFormat.markdown)
                        Text(WatchFolderOutputFormat.plainText.displayName).tag(WatchFolderOutputFormat.plainText)
                        Text(WatchFolderOutputFormat.srt.displayName).tag(WatchFolderOutputFormat.srt)
                        Text(WatchFolderOutputFormat.vtt.displayName).tag(WatchFolderOutputFormat.vtt)
                    }

                    SpeakerDetectionToggle(
                        isOn: $watchFolder.detectSpeakers,
                        descriptionKey: "speakers.toggle.watchFolderDescription"
                    )

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
                                .accessibilityLabel(localizedAppText(
                                    "Processing \(processing)",
                                    de: "\(processing) wird verarbeitet",
                                    ja: "\(processing)を処理中",
                                    zh: "正在处理\(processing)",
                                    es: "Procesando \(processing)"
                                ))
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
                                    .accessibilityLabel(item.success
                                        ? String(localized: "Done")
                                        : String(localized: "Failed"))
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
                            .accessibilityElement(children: .combine)
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
                .padding(.horizontal, SettingsLayoutMetrics.pagePadding)
                .padding(.bottom, SettingsLayoutMetrics.pagePadding)
            }
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
                .accessibilityHidden(true)

            Text(String(localized: "Drop audio or video files here"))
                .font(.headline)

            Text(String(localized: "or"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(String(localized: "Choose Files...")) {
                showFilePicker = true
            }
            .buttonStyle(.bordered)

            Text(String(localized: "WAV, MP3, M4A, FLAC, MP4, MOV"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: SettingsLayoutMetrics.cardCornerRadius)
                .fill(
                    isDragTargeted
                        ? Color.blue.opacity(0.1)
                        : Color(nsColor: .controlBackgroundColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: SettingsLayoutMetrics.cardCornerRadius)
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
        LazyVStack(spacing: SettingsLayoutMetrics.cardSpacing) {
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
                        Text(String(localized: "Audio \(String(format: "%.1f", result.duration))s - processed in \(String(format: "%.1f", result.processingTime))s"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let phase = item.phaseDescription {
                        Text(statusSummary(for: item, phase: phase))
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
                    .accessibilityLabel(String(localized: "Remove \(item.fileName)"))
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
            // A finished file shows or hides its transcript with Space or Return, as on click.
            .keyboardActivatableCard(
                cornerRadius: SettingsLayoutMetrics.compactCornerRadius,
                isEnabled: item.state == .done && item.result != nil
            ) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedFileId = expandedFileId == item.id ? nil : item.id
                }
            }

            if expandedFileId == item.id, let result = item.result {
                Text(result.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            } else if item.state == .loading || item.state == .transcribing {
                activeFileDetails(item)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: SettingsLayoutMetrics.compactCornerRadius)
                .fill(.quaternary)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(item.fileName)
        .modifier(FileRowExpandAction(
            isAvailable: item.state == .done && item.result != nil,
            isExpanded: expandedFileId == item.id,
            toggle: {
                expandedFileId = expandedFileId == item.id ? nil : item.id
            }
        ))
    }

    @ViewBuilder
    private func fileStatusIcon(_ state: FileTranscriptionViewModel.FileItemState) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
                .accessibilityLabel(String(localized: "Pending"))
        case .loading:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(String(localized: "Loading"))
        case .transcribing:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(String(localized: "Transcribing"))
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel(String(localized: "Done"))
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel(String(localized: "Error"))
        case .cancelled:
            Image(systemName: "stop.circle.fill")
                .foregroundStyle(.secondary)
                .accessibilityLabel(String(localized: "Cancelled"))
        }
    }

    @ViewBuilder
    private func activeFileDetails(_ item: FileTranscriptionViewModel.FileItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let progress = item.progressFraction {
                ProgressView(value: progress)
                    .controlSize(.small)
                    .accessibilityLabel(localizedAppText(
                        "Transcription progress",
                        de: "Transkriptionsfortschritt",
                        ja: "文字起こしの進行状況",
                        zh: "转录进度"
                    ))
            }

            if let progressText = item.progressText, !progressText.isEmpty {
                Text(progressText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
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
            .accessibilityLabel(localizedAppText(
                "Copy transcript of \(item.fileName)",
                de: "Transkript von \(item.fileName) kopieren",
                ja: "\(item.fileName)の文字起こしをコピー",
                zh: "复制\(item.fileName)的转录",
                es: "Copiar la transcripción de \(item.fileName)"
            ))

            if let result = item.result, !result.segments.isEmpty {
                Menu {
                    Button(String(localized: "SRT")) { viewModel.exportSubtitles(for: item, format: .srt) }
                    Button(String(localized: "VTT")) { viewModel.exportSubtitles(for: item, format: .vtt) }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 20)
                .help(String(localized: "Export Subtitles"))
                .accessibilityLabel(localizedAppText(
                    "Export subtitles for \(item.fileName)",
                    de: "Untertitel für \(item.fileName) exportieren",
                    ja: "\(item.fileName)の字幕を書き出し",
                    zh: "导出\(item.fileName)的字幕",
                    es: "Exportar subtítulos de \(item.fileName)"
                ))
            }
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            fileTranscriptionSettings

            if viewModel.isHistoryRetranscribing {
                Label(String(localized: "history.retranscribe.busy"), systemImage: "hourglass")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            LanguageSelectionEditor(
                selection: $viewModel.languageSelection,
                availableLanguages: fileTranscriptionLanguageOptions,
                hintBehavior: LanguageSelectionHintBehavior(engine: viewModel.resolvedEngine),
                autoDetectionBehavior: LanguageAutoDetectionBehavior(engine: viewModel.resolvedEngine)
            )

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

                Spacer(minLength: 12)

                if viewModel.hasResults {
                    Menu(String(localized: "Export All")) {
                        Button(String(localized: "Copy All Text")) { viewModel.copyAllText() }
                        Divider()
                        Button(String(localized: "Export All as SRT")) { viewModel.exportAllSubtitles(format: .srt) }
                        Button(String(localized: "Export All as VTT")) { viewModel.exportAllSubtitles(format: .vtt) }
                    }
                    .controlSize(.small)
                    .fixedSize(horizontal: true, vertical: false)
                }

                if viewModel.batchState == .processing {
                    HStack(spacing: 10) {
                        processingSummary

                        Button(role: .destructive) {
                            viewModel.cancelTranscription()
                        } label: {
                            Label(String(localized: "Stop"), systemImage: "stop.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                } else {
                    Button {
                        viewModel.transcribeAll()
                    } label: {
                        Label(String(localized: "Transcribe All"), systemImage: "waveform")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(!viewModel.canTranscribe)
                }

                Button {
                    viewModel.reset()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .frame(width: 22, height: 22)
                .disabled(viewModel.batchState == .processing)
                .help(String(localized: "Clear All"))
                .accessibilityLabel(String(localized: "Clear All"))
            }
        }
    }

    @ViewBuilder
    private var processingSummary: some View {
        if viewModel.files.indices.contains(viewModel.currentIndex) {
            let item = viewModel.files[viewModel.currentIndex]
            HStack(spacing: 4) {
                Text(statusSummary(for: item, phase: item.phaseDescription ?? String(localized: "Processing...")))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("·")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(String(localized: "\(viewModel.processedFiles)/\(viewModel.totalFiles)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .accessibilityLabel(processedFilesAccessibilityLabel)
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
            .accessibilityElement(children: .combine)
        } else {
            Text(String(localized: "\(viewModel.processedFiles)/\(viewModel.totalFiles)"))
                .font(.caption)
                .monospacedDigit()
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel(processedFilesAccessibilityLabel)
        }
    }

    private var processedFilesAccessibilityLabel: String {
        let processed = viewModel.processedFiles
        let total = viewModel.totalFiles
        return localizedAppText(
            "\(processed) of \(total) files processed",
            de: "\(processed) von \(total) Dateien verarbeitet",
            ja: "\(total)件中\(processed)件のファイルを処理済み",
            zh: "已处理 \(processed)/\(total) 个文件",
            es: "\(processed) de \(total) archivos procesados"
        )
    }

    private var clearOutputFolderLabel: String {
        localizedAppText(
            "Clear Output Folder",
            de: "Ausgabeordner zurücksetzen",
            ja: "出力フォルダをクリア",
            zh: "清除输出文件夹"
        )
    }

    @ViewBuilder
    private var fileTranscriptionSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(String(localized: "Engine"), selection: $viewModel.engineChoice) {
                Text(defaultEngineTitle).tag(nil as String?)
                Divider()
                ForEach(viewModel.availableEngines, id: \.providerId) { engine in
                    enginePickerLabel(for: engine)
                        .tag(engine.providerId as String?)
                        .disabled(!viewModel.canUseForTranscription(engine))
                }
            }
            .controlSize(.small)
            .disabled(viewModel.batchState == .processing)

            if viewModel.engineChoice == nil {
                DefaultEngineSettingsLink()
            }

            if let engine = viewModel.resolvedEngine {
                let models = engine.transcriptionModels
                if models.count > 1 {
                    Picker(String(localized: "Model"), selection: $viewModel.modelChoice) {
                        Text(String(localized: "watchFolder.model.default")).tag(nil as String?)
                        Divider()
                        ForEach(models, id: \.id) { model in
                            Text(model.displayName).tag(model.id as String?)
                        }
                    }
                    .controlSize(.small)
                    .disabled(viewModel.batchState == .processing)
                }
            }
        }
    }

    private var defaultEngineTitle: String {
        DefaultEngineChoice.title(engineName: modelManager.defaultEngine?.providerDisplayName)
    }

    private var fileTranscriptionLanguageOptions: [(code: String, name: String)] {
        let supportedLanguages = viewModel.selectedEngineSupportedLanguages
        guard !supportedLanguages.isEmpty else {
            return SettingsViewModel.shared.availableLanguages
        }
        return localizedAppLanguageOptions(for: supportedLanguages)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { (code: $0.code, name: $0.name) }
    }

    @ViewBuilder
    private func enginePickerLabel(for engine: TranscriptionEnginePlugin) -> some View {
        HStack {
            Text(engine.providerDisplayName)
            if !viewModel.canUseForTranscription(engine) {
                Text("(\(String(localized: "not ready")))")
                    .foregroundStyle(.secondary)
            } else if !viewModel.canPrepareForTranscription(engine) {
                Text("(\(String(localized: "not ready")))")
                    .foregroundStyle(.secondary)
            }
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

    private func statusSummary(for item: FileTranscriptionViewModel.FileItem, phase: String) -> String {
        guard let elapsed = viewModel.elapsedTime(for: item) else { return phase }
        if let sourceProgress = item.sourceProgress {
            var parts = [
                "\(phase) - \(formattedSourceDuration(sourceProgress.processedDuration)) / \(formattedSourceDuration(sourceProgress.totalDuration)) \(String(localized: "processed"))"
            ]
            if let realtimeFactor = realtimeFactor(for: sourceProgress, elapsed: elapsed) {
                parts.append("\(realtimeFactor)x \(String(localized: "realtime"))")
            }
            parts.append(formattedElapsed(elapsed))
            return parts.joined(separator: " - ")
        }
        return "\(phase) - \(formattedElapsed(elapsed))"
    }

    private func formattedElapsed(_ elapsed: TimeInterval) -> String {
        let seconds = max(Int(elapsed.rounded()), 0)
        let minutes = seconds / 60
        let remainder = seconds % 60
        if minutes > 0 {
            return String(format: "%d:%02d", minutes, remainder)
        }
        return "\(remainder)s"
    }

    private func formattedSourceDuration(_ duration: TimeInterval) -> String {
        let seconds = max(Int(duration.rounded()), 0)
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainder = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }

    private func realtimeFactor(
        for sourceProgress: PluginTranscriptionSourceProgress,
        elapsed: TimeInterval
    ) -> String? {
        guard elapsed > 0,
              elapsed >= 5,
              sourceProgress.processedDuration >= 30 else {
            return nil
        }
        return String(format: "%.1f", sourceProgress.processedDuration / elapsed)
    }
}

/// Exposes the tap-to-expand transcript of a finished file as a named VoiceOver action.
private struct FileRowExpandAction: ViewModifier {
    let isAvailable: Bool
    let isExpanded: Bool
    let toggle: () -> Void

    func body(content: Content) -> some View {
        content.accessibilityActions {
            if isAvailable {
                Button(isExpanded
                    ? localizedAppText("Hide Transcript", de: "Transkript ausblenden", ja: "文字起こしを非表示", zh: "隐藏转录")
                    : String(localized: "recorder.showTranscript")
                ) {
                    toggle()
                }
            }
        }
    }
}
