import SwiftUI

struct HistoryView: View {
    @ObservedObject private var viewModel = HistoryViewModel.shared

    private var hasSelection: Bool {
        viewModel.hasVisibleSelection
    }

    var body: some View {
        HStack(spacing: 0) {
            listPanel
                .frame(minWidth: 280)

            Divider()
                .opacity(hasSelection ? 1 : 0)
                .frame(width: hasSelection ? 1 : 0)

            detailPanelContainer
                .frame(
                    minWidth: hasSelection ? 300 : 0,
                    idealWidth: hasSelection ? 340 : 0,
                    maxWidth: hasSelection ? .infinity : 0
                )
                .clipped()
        }
        .frame(minHeight: 400)
    }

    // MARK: - List Panel

    private var listPanel: some View {
        VStack(spacing: 0) {
            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(String(localized: "Search..."), text: $viewModel.searchQuery)
                    .textFieldStyle(.plain)
                if !viewModel.searchQuery.isEmpty {
                    Button {
                        viewModel.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Clear search"))
                }
            }
            .padding(8)
            .background(.bar)

            // Filter pickers
            HStack(spacing: 6) {
                Picker(selection: Binding(
                    get: { viewModel.selectedAppFilter ?? "" },
                    set: { viewModel.selectedAppFilter = $0.isEmpty ? nil : $0 }
                )) {
                    Text(String(localized: "All Apps")).tag("")
                    if !viewModel.availableApps.isEmpty {
                        Divider()
                        ForEach(viewModel.availableApps) { app in
                            Text(app.name).tag(app.bundleId)
                        }
                    }
                } label: {
                    EmptyView()
                }
                .fixedSize()

                Picker(selection: $viewModel.selectedTimeRange) {
                    ForEach(HistoryTimeRange.allCases) { range in
                        Text(range.displayName).tag(range)
                    }
                } label: {
                    EmptyView()
                }
                .fixedSize()

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.bar)

            Divider()

            // List
            if viewModel.filteredRecords.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "No Entries"), systemImage: "clock")
                } description: {
                    if viewModel.hasActiveFilters || !viewModel.searchQuery.isEmpty {
                        Text(String(localized: "No results for the active filters."))
                    } else {
                        Text(String(localized: "Dictated text will appear here."))
                    }
                } actions: {
                    if viewModel.hasActiveFilters || !viewModel.searchQuery.isEmpty {
                        Button(String(localized: "Clear Filters")) {
                            viewModel.clearAllFilters()
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            } else {
                List(selection: $viewModel.selectedRecordIDs) {
                    ForEach(viewModel.groupedSections) { section in
                        Section {
                            if !viewModel.collapsedGroups.contains(section.group) {
                                ForEach(section.records, id: \.id) { record in
                                    RecordRow(record: record)
                                        .tag(record.id)
                                        .contextMenu {
                                            recordContextMenu(for: record)
                                        }
                                }
                            }
                        } header: {
                            SectionHeader(
                                group: section.group,
                                count: section.records.count,
                                isCollapsed: viewModel.collapsedGroups.contains(section.group)
                            ) {
                                viewModel.toggleSection(section.group)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }

            Divider()

            // Footer stats
            HStack {
                if viewModel.hasActiveFilters || !viewModel.searchQuery.isEmpty {
                    Text("\(viewModel.visibleRecordCount) \(String(localized: "entries")) (\(viewModel.totalRecords) \(String(localized: "total")))")
                } else {
                    Text("\(viewModel.totalRecords) \(String(localized: "entries"))")
                }
                Spacer()
                if !viewModel.filteredRecords.isEmpty {
                    Button(String(localized: "Delete All Visible"), role: .destructive) {
                        viewModel.showDeleteAllVisibleConfirmation = true
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .font(.caption)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
            .confirmationDialog(
                String(localized: "Delete Entries"),
                isPresented: $viewModel.showDeleteAllVisibleConfirmation,
                titleVisibility: .visible
            ) {
                Button(String(localized: "Delete"), role: .destructive) {
                    viewModel.deleteAllVisible()
                }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                if viewModel.hasActiveFilters || !viewModel.searchQuery.isEmpty {
                    Text("Delete \(viewModel.visibleRecordCount) entries matching current filters?")
                } else {
                    Text("Delete all \(viewModel.visibleRecordCount) entries? This cannot be undone.")
                }
            }
        }
    }

    // MARK: - Detail Panel

    @ViewBuilder
    private var detailPanelContainer: some View {
        if hasSelection {
            detailPanel
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private var detailPanel: some View {
        if viewModel.selectedRecordIDs.count > 1 {
            ContentUnavailableView {
                Label(String(localized: "\(viewModel.selectedRecordIDs.count) items selected"), systemImage: "checkmark.circle")
            } description: {
                Text(String(localized: "Right-click to export or delete selected entries."))
            }
        } else if let record = viewModel.selectedRecord {
            RecordDetailView(record: record, viewModel: viewModel)
        }
    }

    @ViewBuilder
    private func recordContextMenu(for record: TranscriptionRecord) -> some View {
        if viewModel.selectedRecordIDs.count > 1 && viewModel.selectedRecordIDs.contains(record.id) {
            let count = viewModel.selectedRecordIDs.count
            Button(String(localized: "Copy")) {
                let texts = viewModel.selectedRecords.map(\.finalText)
                viewModel.copyToClipboard(texts.joined(separator: "\n\n"))
            }

            Menu(String(localized: "Export \(count) entries as...")) {
                Button("Markdown (.md)") {
                    viewModel.exportSelectedRecords(format: .markdown)
                }
                Button("Plain Text (.txt)") {
                    viewModel.exportSelectedRecords(format: .plainText)
                }
                Button("JSON (.json)") {
                    viewModel.exportSelectedRecords(format: .json)
                }
            }

            Divider()
            Button(String(localized: "Delete \(count) entries"), role: .destructive) {
                viewModel.deleteSelectedRecords()
            }
        } else {
            Button(String(localized: "Copy")) {
                viewModel.copyToClipboard(record.finalText)
            }

            Menu(String(localized: "Export as...")) {
                Button("Markdown (.md)") {
                    viewModel.exportRecord(record, format: .markdown)
                }
                Button("Plain Text (.txt)") {
                    viewModel.exportRecord(record, format: .plainText)
                }
                Button("JSON (.json)") {
                    viewModel.exportRecord(record, format: .json)
                }
            }

            Divider()
            Button(String(localized: "Delete"), role: .destructive) {
                viewModel.deleteRecord(record)
            }
        }
    }
}

// MARK: - Section Header

private struct SectionHeader: View {
    let group: HistoryDateGroup
    let count: Int
    let isCollapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .animation(.easeInOut(duration: 0.15), value: isCollapsed)
                Text(group.displayName)
                Text("(\(count))")
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "\(group.displayName), \(count) entries"))
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isCollapsed ? String(localized: "Collapsed") : String(localized: "Expanded"))
    }
}

// MARK: - Record Row

private struct RecordRow: View {
    let record: TranscriptionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.preview)
                .lineLimit(2)
                .font(.body)

            HStack {
                Text(relativeTime(record.timestamp))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let appName = record.appName {
                    Text("- \(appName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let domain = record.appDomain {
                    Text("(\(domain))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Text(formatDuration(record.durationSeconds))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        let minutes = Int(seconds / 60)
        let hours = Int(seconds / 3600)
        let days = Int(seconds / 86400)

        if minutes < 1 {
            return String(localized: "just_now")
        } else if minutes < 60 {
            return String(localized: "\(minutes) min ago")
        } else if hours < 24 {
            return String(localized: "\(hours) hr ago")
        } else if Calendar.current.isDateInYesterday(date) {
            return String(localized: "yesterday")
        } else if days < 7 {
            return String(localized: "\(days) days ago")
        } else {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m \(s % 60)s"
    }
}

// MARK: - Record Detail

private struct RecordDetailView: View {
    let record: TranscriptionRecord
    @ObservedObject var viewModel: HistoryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.timestamp, format: .dateTime)
                            .font(.headline)
                        Text(formatDuration(record.durationSeconds) + " - " + "\(record.wordsCount) \(String(localized: "words"))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    actionButtons
                }

                // Metadata tags
                HistoryFlowLayout(spacing: 6) {
                    if let lang = record.language {
                        metadataTag(lang.uppercased(), icon: "globe")
                    }
                    metadataTag(record.modelUsed ?? record.engineUsed, icon: "cpu")
                    if let appName = record.appName {
                        metadataTag(appName, icon: "app")
                    }
                    if let domain = record.appDomain {
                        metadataTag(domain, icon: "globe.desk")
                    }
                    if !record.pipelineStepList.isEmpty {
                        ForEach(record.pipelineStepList, id: \.self) { step in
                            metadataTag(step, icon: "gearshape.2")
                        }
                    }
                }
            }
            .padding(10)
            .background(.bar)

            // Audio Playback
            if let audioURL = viewModel.audioFileURL(for: record) {
                Divider()
                AudioPlaybackBar(audioURL: audioURL, playbackService: viewModel.audioPlaybackService)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.bar)
            }

            Divider()

            // Correction Banner
            if viewModel.showCorrectionBanner, !viewModel.correctionSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "book.badge.checkmark")
                        Text(String(localized: "Corrections added to dictionary"))
                            .font(.subheadline.bold())
                        Spacer()
                        Button {
                            viewModel.dismissCorrectionBanner()
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                    }

                    ForEach(viewModel.correctionSuggestions) { suggestion in
                        HStack(spacing: 4) {
                            Text(suggestion.original)
                                .strikethrough()
                                .foregroundStyle(.secondary)
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                            Text(suggestion.replacement)
                                .bold()
                        }
                        .font(.caption)
                    }
                }
                .padding(10)
                .background(.orange.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 10)
                .padding(.top, 8)
            }

            // Raw/Processed/Diff toggle
            if record.wasPostProcessed && !viewModel.isEditing {
                Picker("", selection: $viewModel.detailViewMode) {
                    Text(String(localized: "Processed")).tag(HistoryDetailViewMode.processed)
                    Text(String(localized: "Diff")).tag(HistoryDetailViewMode.diff)
                    Text(String(localized: "Original")).tag(HistoryDetailViewMode.original)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 10)
                .padding(.top, 8)
            }

            // Content
            if viewModel.isEditing {
                TextEditor(text: $viewModel.editedText)
                    .font(.body)
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Group {
                        switch viewModel.detailViewMode {
                        case .diff where record.wasPostProcessed:
                            Text(diffAttributedString(segments: viewModel.diffSegments(for: record)))
                        case .original where record.wasPostProcessed:
                            Text(record.rawText)
                        default:
                            Text(record.finalText)
                        }
                    }
                    .textSelection(.enabled)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: record.id) {
            viewModel.cancelEditing()
            viewModel.audioPlaybackService.stop()
            viewModel.detailViewMode = .processed
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 4) {
            if viewModel.isEditing {
                Button(String(localized: "Cancel")) {
                    viewModel.cancelEditing()
                }
                .controlSize(.small)
                Button(String(localized: "Save")) {
                    viewModel.saveEditing()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                Button {
                    let text = viewModel.detailViewMode == .original && record.wasPostProcessed
                        ? record.rawText : record.finalText
                    viewModel.copyToClipboard(text)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help(String(localized: "Copy"))
                .accessibilityLabel(String(localized: "Copy"))

                Button {
                    viewModel.startEditing()
                } label: {
                    Image(systemName: "pencil")
                }
                .help(String(localized: "Edit"))
                .accessibilityLabel(String(localized: "Edit"))

                Button(role: .destructive) {
                    viewModel.deleteRecord(record)
                } label: {
                    Image(systemName: "trash")
                }
                .help(String(localized: "Delete"))
                .accessibilityLabel(String(localized: "Delete"))
            }
        }
        .buttonStyle(.borderless)
    }

    private func diffAttributedString(segments: [DiffSegment]) -> AttributedString {
        var result = AttributedString()
        for (index, segment) in segments.enumerated() {
            let word: String
            switch segment {
            case .unchanged(let text): word = text
            case .removed(let text): word = text
            case .added(let text): word = text
            }

            var attr = AttributedString(word)
            switch segment {
            case .unchanged:
                break
            case .removed:
                attr.foregroundColor = .red
                attr.strikethroughStyle = .single
                attr.backgroundColor = .red.opacity(0.15)
            case .added:
                attr.foregroundColor = .green
                attr.backgroundColor = .green.opacity(0.15)
            }
            result += attr

            if index < segments.count - 1 {
                result += AttributedString(" ")
            }
        }
        return result
    }

    private func metadataTag(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
    }

    private func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m \(s % 60)s"
    }
}

// MARK: - Audio Playback Bar

private struct AudioPlaybackBar: View {
    let audioURL: URL
    @ObservedObject var playbackService: AudioPlaybackService

    var body: some View {
        HStack(spacing: 8) {
            Button {
                playbackService.togglePlayPause(url: audioURL)
            } label: {
                Image(systemName: playbackService.isPlaying ? "pause.fill" : "play.fill")
                    .font(.callout)
                    .frame(width: 20)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(playbackService.isPlaying ? String(localized: "Pause") : String(localized: "Play"))

            if playbackService.duration > 0 {
                Slider(
                    value: Binding(
                        get: { playbackService.currentTime },
                        set: { playbackService.seek(to: $0) }
                    ),
                    in: 0...playbackService.duration
                )
                .controlSize(.small)
                .accessibilityLabel(String(localized: "Playback position"))

                Text(formatTime(playbackService.currentTime) + " / " + formatTime(playbackService.duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                Spacer()
                Text(String(localized: "Audio"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([audioURL])
            } label: {
                Image(systemName: "folder")
                    .font(.callout)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Show in Finder"))
            .accessibilityLabel(String(localized: "Show in Finder"))
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        let m = s / 60
        let r = s % 60
        return String(format: "%d:%02d", m, r)
    }
}

// MARK: - Flow Layout

private struct HistoryFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var height: CGFloat = 0
        for (index, row) in rows.enumerated() {
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            height += rowHeight
            if index < rows.count - 1 { height += spacing }
        }
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            var x = bounds.minX
            for subview in row {
                let size = subview.sizeThatFits(.unspecified)
                subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += rowHeight + spacing
        }
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [[LayoutSubviews.Element]] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[LayoutSubviews.Element]] = [[]]
        var currentWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentWidth + size.width > maxWidth && !rows[rows.count - 1].isEmpty {
                rows.append([])
                currentWidth = 0
            }
            rows[rows.count - 1].append(subview)
            currentWidth += size.width + spacing
        }
        return rows
    }
}
