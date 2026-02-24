import SwiftUI

struct HistoryView: View {
    @ObservedObject private var viewModel = HistoryViewModel.shared

    var body: some View {
        HSplitView {
            // MARK: - Left Panel: Search + Filters + List
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
                    .listStyle(.sidebar)
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
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
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
            .frame(minWidth: 260, idealWidth: 300, maxWidth: 320)

            // MARK: - Right Panel: Detail
            if viewModel.selectedRecordIDs.count > 1 {
                ContentUnavailableView {
                    Label(String(localized: "\(viewModel.selectedRecordIDs.count) items selected"), systemImage: "checkmark.circle")
                } description: {
                    Text(String(localized: "Right-click to export or delete selected entries."))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let record = viewModel.selectedRecord {
                RecordDetailView(record: record, viewModel: viewModel)
            } else {
                ContentUnavailableView {
                    Label(String(localized: "No Selection"), systemImage: "text.document")
                } description: {
                    Text(String(localized: "Select a transcription to view details."))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 600, minHeight: 400)
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
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(record.timestamp, format: .dateTime)
                        .font(.headline)
                    Spacer()
                    // Actions
                    Button {
                        viewModel.copyToClipboard(record.finalText)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .help(String(localized: "Copy"))

                    if viewModel.isEditing {
                        Button(String(localized: "Cancel")) {
                            viewModel.cancelEditing()
                        }
                        Button(String(localized: "Save")) {
                            viewModel.saveEditing()
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button {
                            viewModel.startEditing()
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .help(String(localized: "Edit"))
                    }

                    Button(role: .destructive) {
                        viewModel.deleteRecord(record)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help(String(localized: "Delete"))
                }

                HStack(spacing: 12) {
                    Label(formatDuration(record.durationSeconds), systemImage: "waveform")
                    Label("\(record.wordsCount) \(String(localized: "words"))", systemImage: "text.word.spacing")
                    if let lang = record.language {
                        Label(lang.uppercased(), systemImage: "globe")
                    }
                    Label(record.modelUsed ?? record.engineUsed, systemImage: "cpu")
                    if let appName = record.appName {
                        Label(appName, systemImage: "app")
                    }
                    if let domain = record.appDomain {
                        Label(domain, systemImage: "globe.desk")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding()
            .background(.bar)

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
                .padding(.horizontal)
                .padding(.top, 8)
            }

            // Content
            if viewModel.isEditing {
                TextEditor(text: $viewModel.editedText)
                    .font(.body)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(record.finalText)
                        .textSelection(.enabled)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 320)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m \(s % 60)s"
    }
}
