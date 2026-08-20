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
        .accessibilityElement(children: .combine)
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
        let originPlatform = record.originPlatformRaw
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !originPlatform.isEmpty
            && originPlatform.caseInsensitiveCompare("macOS") != .orderedSame {
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
    let record: TranscriptionRecord
    @ObservedObject var viewModel: HistoryViewModel

    var body: some View {
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

            if record.audioFileName != nil {
                audioSurface
                Divider()
            }

            contentSurface
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var identityHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(record.timestamp, format: .dateTime.weekday().day().month().year().hour().minute())
                    .font(.headline)
                Spacer()
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
                    Text(Duration.seconds(record.durationSeconds).formatted(.time(pattern: .minuteSecond)))
                }
                if let appName = record.appName {
                    Text("·")
                    Text(appName)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            DisclosureGroup(String(localized: "Details")) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                    metadataRow(String(localized: "Language"), record.language?.uppercased() ?? "—")
                    metadataRow(String(localized: "Engine"), record.modelUsed ?? record.engineUsed)
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
    }

    private var failureState: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
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
    }

    @ViewBuilder
    private var audioSurface: some View {
        if let url = viewModel.audioFileURL(for: record) {
            HistoryAudioPlaybackStrip(
                audioURL: url,
                playbackService: viewModel.audioPlaybackService
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.bar)
        }
    }

    private var contentSurface: some View {
        VStack(spacing: 0) {
            if record.wasPostProcessed {
                Picker(String(localized: "Text Version"), selection: $viewModel.detailViewMode) {
                    Text(String(localized: "Final")).tag(HistoryDetailViewMode.final)
                    Text(String(localized: "Original")).tag(HistoryDetailViewMode.original)
                    Text(String(localized: "Changes")).tag(HistoryDetailViewMode.changes)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
                .padding(12)
            }

            if viewModel.showCorrectionBanner, !viewModel.correctionSuggestions.isEmpty {
                Label(String(localized: "Corrections added to the dictionary"), systemImage: "book.badge.checkmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            if viewModel.detailViewMode == .final {
                TextEditor(text: $viewModel.editedText)
                    .font(.body)
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .disabled(!viewModel.canEditSelectedRecord)
            } else {
                ScrollView {
                    Text(contentText)
                        .textSelection(.enabled)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var contentText: AttributedString {
        switch viewModel.detailViewMode {
        case .final: AttributedString(record.displayText)
        case .original: AttributedString(record.rawText)
        case .changes: diffAttributedString(viewModel.diffSegments(for: record))
        }
    }

    private var sourceImage: String {
        switch record.source {
        case .mac: "macbook"
        case .iPhone, .iPad: "iphone"
        case .appleWatch: "applewatch"
        case .keyboard: "keyboard"
        case .shortcut: "square.stack.3d.up"
        case .importedFile: "doc"
        case .other: "ellipsis.circle"
        }
    }

    private func metadataRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.tertiary)
            Text(value).textSelection(.enabled)
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

private struct HistoryAudioPlaybackStrip: View {
    let audioURL: URL
    @ObservedObject var playbackService: AudioPlaybackService

    var body: some View {
        HStack(spacing: 10) {
            Button {
                playbackService.togglePlayPause(url: audioURL)
            } label: {
                Image(systemName: playbackService.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 20)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(playbackService.isPlaying ? String(localized: "Pause") : String(localized: "Play"))

            if playbackService.duration > 0 {
                Slider(
                    value: Binding(
                        get: { playbackService.currentTime },
                        set: { value in playbackService.seek(to: value) }
                    ),
                    in: 0...playbackService.duration
                )
                .controlSize(.small)
                .accessibilityLabel(String(localized: "Playback position"))

                Text(time(playbackService.currentTime) + " / " + time(playbackService.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text(String(localized: "Audio"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([audioURL])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Show in Finder"))
        }
    }

    private func time(_ seconds: TimeInterval) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}
