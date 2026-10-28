import AppKit
import SwiftUI

struct HistorySectionHeader: View {
    let group: HistoryDateGroup
    let count: Int
    let isCollapsed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .accessibilityHidden(true)
                Text(group.displayName)
                Text(count, format: .number)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isCollapsed ? String(localized: "Collapsed") : String(localized: "Expanded"))
    }
}

struct HistoryRecordRow: View {
    let record: TranscriptionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(rowText)
                .lineLimit(1)
                .font(.body.weight(.semibold))

            HStack(spacing: 5) {
                Text(record.appName ?? record.source.displayName)
                    .lineLimit(1)
                if record.appName != nil {
                    Text("·")
                    Text(record.source.displayName)
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Text(relativeTimestamp)
                if record.durationSeconds > 0 {
                    Text("·")
                    Text(duration(record.durationSeconds))
                        .monospacedDigit()
                }
                Spacer(minLength: 4)
                statusIndicators
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
        // One spoken line per row: text, app, time, duration and every status,
        // so the status icons and their tooltips are not the only cue.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isStaticText)
    }

    private var accessibilityLabel: String {
        var parts = [HistoryAccessibilityText.preview(rowText)]
        parts.append(record.appName ?? record.source.displayName)
        if record.appName != nil {
            parts.append(record.source.displayName)
        }
        parts.append(HistoryAccessibilityText.relativeTime(record.timestamp))
        if record.durationSeconds > 0 {
            parts.append(HistoryAccessibilityText.duration(record.durationSeconds))
        }
        parts += statusDescriptions.filter { $0 != rowText }
        return parts.joined(separator: ", ")
    }

    /// The statuses the row shows as icons, in the same order.
    private var statusDescriptions: [String] {
        var statuses: [String] = []
        if record.isOpenInInbox {
            statuses.append(String(localized: "Open in Inbox"))
        }
        if record.processingState == .importing || record.processingState == .transcribing {
            statuses.append(String(localized: "Processing"))
        }
        if record.processingState == .failed {
            statuses.append(String(localized: "Processing failed"))
        }
        if record.audioFileName != nil {
            statuses.append(String(localized: "Audio available"))
        }
        if isSynchronizedFromOtherDevice {
            statuses.append(String(localized: "Synchronized"))
        }
        return statuses
    }

    private var isSynchronizedFromOtherDevice: Bool {
        let originPlatform = record.originPlatformRaw
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !originPlatform.isEmpty
            && originPlatform.caseInsensitiveCompare("macOS") != .orderedSame
    }

    private var rowText: String {
        let text = record.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        return switch record.processingState {
        case .importing: String(localized: "Importing…")
        case .transcribing:
            String.localizedStringWithFormat(
                String(localized: "Processing on %@…"),
                record.source.displayName
            )
        case .failed: record.processingFailureMessage ?? String(localized: "Processing failed")
        case .ready: String(localized: "Empty transcription")
        }
    }

    private var relativeTimestamp: String {
        let elapsed = max(60, Date().timeIntervalSince(record.timestamp))
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: elapsed)
            ?? record.timestamp.formatted(date: .abbreviated, time: .shortened)
    }

    @ViewBuilder
    private var statusIndicators: some View {
        if record.isOpenInInbox {
            Image(systemName: "tray.full")
                .help(String(localized: "Open in Inbox"))
                .accessibilityLabel(String(localized: "Open in Inbox"))
        }
        if record.processingState == .importing || record.processingState == .transcribing {
            Image(systemName: "hourglass")
                .help(String(localized: "Processing"))
                .accessibilityLabel(String(localized: "Processing"))
        }
        if record.processingState == .failed {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .help(String(localized: "Processing failed"))
                .accessibilityLabel(String(localized: "Processing failed"))
        }
        if record.audioFileName != nil {
            Image(systemName: "waveform")
                .help(String(localized: "Audio available"))
                .accessibilityLabel(String(localized: "Audio available"))
        }
        if isSynchronizedFromOtherDevice {
            Image(systemName: "icloud")
                .help(String(localized: "Synchronized"))
                .accessibilityLabel(String(localized: "Synchronized"))
        }
    }

    private func duration(_ seconds: Double) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
    }
}

struct HistoryRecordDetailView: View {
    private struct DiffInput: Equatable {
        let recordID: UUID
        let rawText: String
        let finalText: String
    }

    let record: TranscriptionRecord
    @ObservedObject var viewModel: HistoryViewModel
    @ObservedObject private var coordinator: SpeakerTranscriptCoordinator
    /// Speakers, playback and corrections; one player for every record with audio.
    @StateObject private var speakers: SpeakerWorkspaceModel
    @State private var showsSpeakers = true
    @State private var pendingSpeakerCount: SpeakerCountChoice?

    private enum SpeakerCountChoice: Identifiable, Equatable {
        case automatic
        case fixed(Int)

        var id: Int { count ?? 0 }
        var count: Int? {
            if case .fixed(let count) = self { return count }
            return nil
        }
    }

    init(record: TranscriptionRecord, viewModel: HistoryViewModel) {
        self.record = record
        self.viewModel = viewModel
        let coordinator = ServiceContainer.shared.speakerTranscriptCoordinator
        self.coordinator = coordinator
        _speakers = StateObject(wrappedValue: SpeakerWorkspaceModel(
            recordID: record.id,
            historyService: ServiceContainer.shared.historyService,
            voices: coordinator.voices
        ))
    }

    var body: some View {
        let audioURL = viewModel.audioFileURL(for: record)
        VStack(spacing: 0) {
            identityHeader
            Divider()

            if record.processingState == .importing || record.processingState == .transcribing {
                processingState
                Divider()
            } else if record.processingState == .failed {
                failureState
                Divider()
            }

            HistorySpeakerDetectionRow(
                record: record,
                hasAudio: audioURL != nil,
                coordinator: coordinator,
                onStart: { showsSpeakers = true }
            )

            if showsSpeakerTranscript {
                SpeakerWorkspaceView(
                    record: record,
                    audioURL: audioURL,
                    coordinator: coordinator,
                    model: speakers
                )
            } else {
                textSurface
            }

            if audioURL != nil {
                SpeakerPlayerBar(
                    model: speakers,
                    playback: speakers.playback,
                    title: record.appName ?? record.source.displayName,
                    audioURL: audioURL
                )
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            if let audioURL { speakers.playback.load(url: audioURL) }
        }
        .onDisappear { speakers.playback.unload() }
        .onChange(of: audioURL) { _, url in
            if let url { speakers.playback.load(url: url) } else { speakers.playback.unload() }
        }
        .onChange(of: record.speakerTranscriptData) { speakers.reload() }
        .onChange(of: record.speakerNamesData) { speakers.reload() }
        .onChange(of: record.speakerWordsData) { speakers.reload() }
        .onChange(of: coordinator.stages[record.id] != nil) { wasDetecting, isDetecting in
            guard wasDetecting, !isDetecting else { return }
            announceSpeakerDetectionResult()
        }
        .confirmationDialog(
            String(localized: "speakers.redetect.title"),
            isPresented: Binding(
                get: { pendingSpeakerCount != nil },
                set: { if !$0 { pendingSpeakerCount = nil } }
            ),
            presenting: pendingSpeakerCount
        ) { choice in
            Button(String(localized: "speakers.action.detectAgain"), role: .destructive) {
                speakers.playback.pause()
                showsSpeakers = true
                coordinator.start(recordID: record.id, speakerCount: choice.count)
            }
        } message: { _ in
            Text(String(localized: "speakers.redetect.message"))
        }
    }

    private var hasSpeakerTranscript: Bool {
        record.speakerTranscriptData != nil
    }

    /// Detection runs in the background and only changes the page, so
    /// VoiceOver users hear how it ended. A failed or cancelled run keeps an
    /// earlier transcript, so the run's own outcome decides the message.
    private func announceSpeakerDetectionResult() {
        guard let outcome = coordinator.outcomes[record.id] else { return }
        ServiceContainer.shared.accessibilityAnnouncementService.announce(
            Self.speakerDetectionAnnouncement(for: outcome),
            isUrgent: outcome == .failed
        )
    }

    static func speakerDetectionAnnouncement(for outcome: SpeakerTranscriptCoordinator.Outcome) -> String {
        switch outcome {
        case .succeeded:
            localizedAppText("Speakers detected", de: "Sprecher erkannt", ja: "話者を検出しました", zh: "已检测到说话人", zhHant: "已偵測到說話者")
        case .failed:
            String(localized: "speakers.status.failed")
        case .cancelled:
            localizedAppText(
                "Speaker detection cancelled",
                de: "Sprechererkennung abgebrochen",
                ja: "話者の検出をキャンセルしました",
                zh: "已取消说话人检测",
                zhHant: "已取消說話者偵測"
            )
        }
    }

    private var showsSpeakerTranscript: Bool {
        hasSpeakerTranscript && showsSpeakers
    }

    private var identityHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(record.timestamp, format: .dateTime.weekday().day().month().year().hour().minute())
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                headerControls
                if record.isOpenInInbox {
                    Label(String(localized: "Inbox"), systemImage: "tray.full")
                        .foregroundStyle(.tint)
                } else if record.inboxState == .completed {
                    Label(String(localized: "Completed"), systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 7) {
                Label(record.source.displayName, systemImage: sourceImage)
                if record.durationSeconds > 0 {
                    Text("·")
                        .accessibilityHidden(true)
                    Text(Duration.seconds(record.durationSeconds).formatted(.time(pattern: .minuteSecond)))
                        .accessibilityLabel(HistoryAccessibilityText.duration(record.durationSeconds))
                }
                if let appName = record.appName {
                    Text("·")
                        .accessibilityHidden(true)
                    Text(appName)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)

            DisclosureGroup(String(localized: "Details")) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                    metadataRow(
                        String(localized: "Language"),
                        record.language?.uppercased() ?? "—",
                        spokenValue: record.language.map { localizedAppLanguageName(for: $0) }
                    )
                    metadataRow(String(localized: "Engine"), record.modelUsed ?? record.engineUsed)
                    if let llmUsage = record.llmUsage {
                        metadataRow(String(localized: "LLM"), HistoryLLMUsageText.providers(llmUsage))
                        if let tokens = HistoryLLMUsageText.tokens(llmUsage) {
                            metadataRow(String(localized: "history.llmUsage.tokens"), tokens)
                        }
                    }
                    metadataRow(String(localized: "Words"), record.wordsCount.formatted())
                    metadataRow(String(localized: "Origin"), record.originPlatformRaw)
                }
                .font(.caption)
                .padding(.top, 5)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.bar)
    }

    private var processingState: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(String.localizedStringWithFormat(
                    String(localized: "Processing on %@"),
                    record.source.displayName
                ))
                    .font(.subheadline.weight(.medium))
                Text(String(localized: "The result will update here automatically."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityElement(children: .combine)
    }

    private var failureState: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Processing Failed"))
                    .font(.subheadline.weight(.medium))
                Text(record.processingFailureMessage ?? String(localized: "The origin device could not finish this transcription."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityElement(children: .combine)
    }

    /// Text version, the switch between the transcript by speaker and the
    /// text, and the speaker actions.
    private var headerControls: some View {
        HStack(spacing: 10) {
            if record.wasPostProcessed, !showsSpeakerTranscript {
                Picker(String(localized: "Text Version"), selection: $viewModel.detailViewMode) {
                    Text(String(localized: "Final")).tag(HistoryDetailViewMode.final)
                    Text(String(localized: "Original")).tag(HistoryDetailViewMode.original)
                    Text(String(localized: "Changes")).tag(HistoryDetailViewMode.changes)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .help(String(localized: "Text Version"))
            }

            if hasSpeakerTranscript {
                Toggle(String(localized: "speakers.view.speakers"), isOn: $showsSpeakers)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help(String(localized: "speakers.view.toggle.help"))

                SpeakerRedetectMenu(
                    coordinator: coordinator,
                    record: record,
                    onDetectAgain: { pendingSpeakerCount = $0.map(SpeakerCountChoice.fixed) ?? .automatic }
                )
                SpeakerExportMenu(model: speakers, title: record.appName)
            }
        }
        .font(.body)
        .foregroundStyle(.primary)
    }

    private var textSurface: some View {
        VStack(spacing: 0) {
            if viewModel.showCorrectionBanner, !viewModel.correctionSuggestions.isEmpty {
                Label(String(localized: "Corrections added to the dictionary"), systemImage: "book.badge.checkmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }

            switch viewModel.detailViewMode {
            case .final:
                if hasSpeakerTranscript {
                    // Text with speakers is edited by paragraph in the
                    // conversation, so the transcript and the text stay in step.
                    readOnlyText(AttributedString(record.finalText))
                } else {
                    TextEditor(text: $viewModel.editedText)
                        .font(.body)
                        .padding(14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .disabled(!viewModel.canEditSelectedRecord)
                        .accessibilityLabel(localizedAppText(
                            "Transcript",
                            de: "Transkript",
                            ja: "文字起こし",
                            zh: "转写文本",
                            zhHant: "轉錄文字"
                        ))
                }
            case .original:
                readOnlyText(AttributedString(record.rawText))
            case .changes:
                changesContent
                    .task(id: DiffInput(recordID: record.id, rawText: record.rawText, finalText: record.finalText)) {
                        await viewModel.loadDiffPresentation(for: record)
                    }
            }
        }
    }

    @ViewBuilder
    private var changesContent: some View {
        switch viewModel.diffPresentation(for: record) {
        case .segments(let segments):
            // Colour, strikethrough and underline are not spoken, so VoiceOver
            // reads the removed and added words with a word in front of them.
            readOnlyText(diffAttributedString(segments), accessibilityText: diffAccessibilityText(segments))
        case .tooLarge:
            ContentUnavailableView(
                String(localized: "Changes Unavailable"),
                systemImage: "text.badge.xmark",
                description: Text(String(localized: "This entry is too long to compare word by word. Use Final or Original to read the full text."))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case nil:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(String(localized: "Loading"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func readOnlyText(_ text: AttributedString, accessibilityText: String? = nil) -> some View {
        ScrollView {
            if let accessibilityText {
                readOnlyTextBody(text)
                    .accessibilityLabel(accessibilityText)
            } else {
                readOnlyTextBody(text)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func readOnlyTextBody(_ text: AttributedString) -> some View {
        Text(text)
            .textSelection(.enabled)
            .font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
    }

    private func diffAccessibilityText(_ segments: [DiffSegment]) -> String {
        segments.map { segment in
            switch segment {
            case .unchanged(let text):
                text
            case .removed(let text):
                localizedAppText(
                    "(Removed: \(text))",
                    de: "(Entfernt: \(text))",
                    ja: "（削除: \(text)）",
                    zh: "（已删除：\(text)）",
                    zhHant: "（已刪除：\(text)）",
                    es: "(Eliminado: \(text))"
                )
            case .added(let text):
                localizedAppText(
                    "(Added: \(text))",
                    de: "(Hinzugefügt: \(text))",
                    ja: "（追加: \(text)）",
                    zh: "（已添加：\(text)）",
                    zhHant: "（已新增：\(text)）",
                    es: "(Agregado: \(text))"
                )
            }
        }
        .joined(separator: " ")
    }

    private var sourceImage: String {
        switch record.source {
        case .mac: "macbook"
        case .iPhone, .iPad: "iphone"
        case .appleWatch: "applewatch"
        case .keyboard: "keyboard"
        case .shortcut: "square.stack.3d.up"
        case .importedFile: "doc"
        case .windows: "desktopcomputer"
        case .recorder: "record.circle"
        case .other: "ellipsis.circle"
        }
    }

    private func metadataRow(_ label: String, _ value: String, spokenValue: String? = nil) -> some View {
        GridRow {
            Text(label).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            // Read as one "label, value" pair instead of two unrelated texts.
            Text(value).textSelection(.enabled)
                .accessibilityLabel(label)
                .accessibilityValue(spokenValue ?? value)
        }
    }

    private func diffAttributedString(_ segments: [DiffSegment]) -> AttributedString {
        var result = AttributedString()
        for (index, segment) in segments.enumerated() {
            let value: String
            switch segment {
            case .unchanged(let text), .removed(let text), .added(let text): value = text
            }
            var attributed = AttributedString(value)
            switch segment {
            case .unchanged:
                break
            case .removed:
                attributed.foregroundColor = .red
                attributed.strikethroughStyle = .single
                attributed.backgroundColor = .red.opacity(0.12)
            case .added:
                attributed.foregroundColor = .green
                attributed.underlineStyle = .single
                attributed.backgroundColor = .green.opacity(0.12)
            }
            result += attributed
            if index < segments.count - 1 { result += AttributedString(" ") }
        }
        return result
    }
}

/// Spoken forms of values that the History shows in a compact visual form.
enum HistoryAccessibilityText {
    /// Spoken units follow the app language, like the localized words around them.
    static var locale: Locale { Locale(identifier: preferredAppLanguageCode()) }

    /// "2 months ago", in the app language.
    static func relativeTime(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named, unitsStyle: .wide).locale(locale))
    }

    /// Rows show a single line, so VoiceOver reads the beginning of a long
    /// text; the detail pane has the full text.
    static func preview(_ text: String, limit: Int = 160) -> String {
        guard text.count > limit else { return text }
        let prefix = text.prefix(limit)
        let cut = prefix.lastIndex(of: " ").map { prefix[..<$0] } ?? prefix
        return String(cut) + "…"
    }

    /// "Duration 1 minute, 12 seconds" instead of "1:12".
    static func duration(_ seconds: Double) -> String {
        // Truncated like the visible "0:06".
        let spoken = Duration.seconds(seconds.rounded(.towardZero))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide).locale(locale))
        return localizedAppText(
            "Duration \(spoken)",
            de: "Dauer \(spoken)",
            ja: "長さ \(spoken)",
            zh: "时长 \(spoken)",
            zhHant: "時長 \(spoken)",
            es: "Duración \(spoken)"
        )
    }
}

/// An entry's LLM usage in the History details.
enum HistoryLLMUsageText {
    /// One line per provider and model, such as "Claude · claude-sonnet-4-5".
    static func providers(_ usage: HistoryLLMUsage) -> String {
        usage.entries.map { entry in
            let model = entry.model?.trimmingCharacters(in: .whitespacesAndNewlines)
            return [entry.displayProviderName, model?.isEmpty == false ? model : nil]
                .compactMap { $0 }
                .joined(separator: " · ")
        }
        .joined(separator: "\n")
    }

    /// "1,234 input · 256 output · 3 requests": the reported totals, and the
    /// number of requests when there was more than one. Nil when no request
    /// reported token counts.
    static func tokens(_ usage: HistoryLLMUsage, locale: Locale = .current) -> String? {
        guard usage.hasTokenCounts else { return nil }
        let number = IntegerFormatStyle<Int>.number.locale(locale)
        var parts: [String] = []
        if let input = usage.inputTokens {
            parts.append(String(format: String(localized: "history.llmUsage.input"), input.formatted(number)))
        }
        if let output = usage.outputTokens {
            parts.append(String(format: String(localized: "history.llmUsage.output"), output.formatted(number)))
        }
        if usage.requestCount > 1 {
            parts.append(String(
                format: String(localized: "history.llmUsage.requests"),
                usage.requestCount.formatted(number)
            ))
        }
        return parts.joined(separator: " · ")
    }
}
