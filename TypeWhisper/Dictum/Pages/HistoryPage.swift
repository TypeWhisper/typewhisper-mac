import SwiftUI
import AVFoundation

struct DictumHistoryPage: View {
    @ObservedObject private var history = ServiceContainer.shared.historyService
    @ObservedObject private var sync = ServiceContainer.shared.cloudFolderSyncController
    @StateObject private var retry = HistoryRetryController()
    @State private var records: [TranscriptionRecord] = []
    @State private var selected: UUID?
    @State private var search = ""
    @State private var filter = HistoryRecordFilter.all
    @State private var original = false
    @State private var hasMore = false
    @State private var deleting: TranscriptionRecord?
    @State private var clearAll = false
    @State private var pendingDeletion: TranscriptionRecord?
    @State private var deletionTask: Task<Void, Never>?
    @State private var player: AVAudioPlayer?
    @State private var message: String?

    private var visible: [TranscriptionRecord] {
        records.filter { filter.includes($0) && $0.id != pendingDeletion?.id }
    }
    private var current: TranscriptionRecord? { visible.first { $0.id == selected } }
    private var days: [Date] { Set(visible.map { Calendar.current.startOfDay(for: $0.timestamp) }).sorted(by: >) }

    var body: some View {
        DictumPageFrame(page: .history) {
            if history.totalRecords > 0 {
                Picker(selection: $filter) {
                    Text("All", tableName: "DictumHistory").tag(HistoryRecordFilter.all)
                    Text("Dictation", tableName: "DictumHistory").tag(HistoryRecordFilter.dictation)
                    Text("Translation", tableName: "DictumHistory").tag(HistoryRecordFilter.translation)
                } label: { Text("History", tableName: "DictumHistory") }
                .pickerStyle(.segmented).labelsHidden().fixedSize().frame(minWidth: 190)
                NativeSearchField(text: $search, placeholder: String(localized: "Search", table: "DictumHistory")).frame(width: 200, height: 28)
                Menu {
                    Button { export() } label: { Text("Export as Markdown…", tableName: "DictumHistory") }
                    Button { if let url = sync.selectedFolderURL { NSWorkspace.shared.open(url) } } label: { Text("Show Sync Folder in Finder", tableName: "DictumHistory") }
                    Divider()
                    Button(role: .destructive) { clearAll = true } label: { Text("Delete All History…", tableName: "DictumHistory") }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 28)
            }
        } content: {
            if history.totalRecords == 0 {
                VStack(spacing: 12) {
                    Image(systemName: "clock").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text("No dictations yet", tableName: "DictumHistory").font(.headline)
                    Text("Press fn and start talking. Your dictations show up here.", tableName: "DictumHistory").foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        List(selection: $selected) {
                            ForEach(days, id: \.self) { day in
                                Section(dayTitle(day)) {
                                    ForEach(visible.filter { Calendar.current.isDate($0.timestamp, inSameDayAs: day) }) { record in
                                        HStack(alignment: .top, spacing: 10) {
                                            appIcon(record, size: 20)
                                            VStack(alignment: .leading, spacing: 6) {
                                                Text(record.finalText).lineLimit(2)
                                                HStack {
                                                    Text(record.timestamp, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary)
                                                    if record.processingFailureMessage != nil { Text("Not polished", tableName: "DictumHistory").font(.caption).foregroundStyle(.orange) }
                                                }
                                            }
                                            }.padding(.vertical, 8).tag(record.id)
                                            .listRowBackground(record.id == selected ? DictumTheme.accentSoft : Color.clear)
                                            .onAppear { if record.id == visible.last?.id && hasMore { loadMore() } }
                                    }
                                }
                            }
                        }.listStyle(.plain)
                        if sync.mode != .off {
                            Button { DictumNavigation.shared.open(.general) } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: sync.errorMessage == nil ? "icloud" : "exclamationmark.icloud")
                                    Text(HistorySyncPresentation.status(sync))
                                        .lineLimit(1).font(.caption)
                                }.frame(maxWidth: .infinity).frame(height: 34)
                            }.buttonStyle(.plain).foregroundStyle(sync.errorMessage == nil ? Color.secondary : Color.red)
                        }
                    }.frame(width: 316)
                    Divider()
                    if let record = current { detail(record) }
                    else {
                        VStack(spacing: 8) {
                            if search.isEmpty { Text("No results", tableName: "DictumHistory") }
                            else {
                                Text(String(format: String(localized: "No results for “%@”", table: "DictumHistory"), search))
                                Text("Try a different word.", tableName: "DictumHistory").foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .onAppear { reload() }
        .onChange(of: search) { _, _ in reload() }
        .onChange(of: filter) { _, _ in selected = visible.first?.id }
        .onReceive(history.$recentRecords) { _ in reload() }
        .onDeleteCommand { if let current { requestDelete(current) } }
        .onCopyCommand { current.map { [NSItemProvider(object: (original ? $0.rawText : $0.finalText) as NSString)] } ?? [] }
        .overlay(alignment: .bottom) {
            if pendingDeletion != nil {
                Button { undoDeletion() } label: { Text("Undo deletion", tableName: "DictumHistory") }
                    .keyboardShortcut("z", modifiers: .command).padding(12).background(.regularMaterial, in: Capsule()).padding(20)
            } else if let message = retry.message ?? message { Text(message).padding(12).background(.regularMaterial, in: Capsule()).padding(20) }
        }
        .alert(String(localized: "Send this recording for reprocessing?", table: "DictumHistory"), isPresented: Binding(get: { retry.confirmation != nil }, set: { if !$0 { retry.cancelConfirmation() } })) {
            Button(role: .cancel) { retry.cancelConfirmation() } label: { Text("Cancel", tableName: "DictumHistory") }
            Button { retry.start() } label: { Text("Retry", tableName: "DictumHistory") }
        } message: { Text(retry.confirmation ?? "") }
        .alert(String(localized: "Delete this record and its recording?", table: "DictumHistory"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(role: .cancel) {} label: { Text("Cancel", tableName: "DictumHistory") }
            Button(role: .destructive) { if let deleting { scheduleDeletion(deleting) }; deleting = nil } label: { Text("Delete", tableName: "DictumHistory") }
        }
        .alert(String(localized: "Delete All History…", table: "DictumHistory"), isPresented: $clearAll) {
            Button(role: .cancel) {} label: { Text("Cancel", tableName: "DictumHistory") }
            Button(role: .destructive) { _ = history.clearAll(); reload() } label: { Text("Delete", tableName: "DictumHistory") }
        }
        .onDisappear { player?.stop(); commitDeletion() }
    }

    private func detail(_ record: TranscriptionRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    appIcon(record, size: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.appName ?? "dictum").fontWeight(.semibold)
                        Text(record.timestamp, format: .dateTime).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker(selection: $original) {
                        Text("Polished", tableName: "DictumHistory").tag(false)
                        Text("Original", tableName: "DictumHistory").tag(true)
                    } label: { Text("Text", tableName: "DictumHistory") }.pickerStyle(.segmented).labelsHidden().fixedSize().frame(minWidth: 145)
                }
                if let failure = record.processingFailureMessage { Text(failure).foregroundStyle(.orange) }
                Text(highlight(original ? record.rawText : record.finalText))
                    .font(.system(size: 15)).lineSpacing(10).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    .background(DictumTheme.card, in: RoundedRectangle(cornerRadius: 12))
                HStack(spacing: 12) {
                    Text(String(localized: "Duration", table: "DictumHistory") + " " + String(format: "%d:%02d", Int(record.durationSeconds) / 60, Int(record.durationSeconds) % 60))
                    Text(String(localized: "Words", table: "DictumHistory") + " " + record.wordsCount.formatted())
                    Text([record.engineUsed, record.modelUsed].compactMap { $0 }.joined(separator: " · "))
                }.font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(original ? record.rawText : record.finalText, forType: .string) } label: { Text("Copy", tableName: "DictumHistory") }
                    Button { retry.request(record) } label: { Text("Retry", tableName: "DictumHistory") }
                        .disabled(history.audioFileURL(for: record) == nil || retry.isRunning)
                    if let url = history.audioFileURL(for: record) {
                        Button {
                            do { player = try AVAudioPlayer(contentsOf: url); player?.play() }
                            catch { message = error.localizedDescription }
                        } label: { Text("Play Recording", tableName: "DictumHistory") }
                    }
                    Spacer()
                    Button(role: .destructive) { requestDelete(record) } label: { Image(systemName: "trash") }
                        .accessibilityLabel(Text("Delete", tableName: "DictumHistory"))
                }.buttonStyle(DictumControlStyle(kind: .smallButton))
            }.padding(24)
        }
    }

    private func appIcon(_ record: TranscriptionRecord, size: CGFloat) -> some View {
        let url = record.appBundleIdentifier.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        return Image(nsImage: url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)!)
            .resizable().frame(width: size, height: size)
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return String(localized: "Today", table: "DictumHistory") }
        if Calendar.current.isDateInYesterday(day) { return String(localized: "Yesterday", table: "DictumHistory") }
        return day.formatted(.dateTime.month().day())
    }

    private func highlight(_ text: String) -> AttributedString {
        var value = AttributedString(text)
        guard !search.isEmpty else { return value }
        var remaining = text.startIndex..<text.endIndex
        while let range = text.range(of: search, options: .caseInsensitive, range: remaining) {
            if let lower = AttributedString.Index(range.lowerBound, within: value), let upper = AttributedString.Index(range.upperBound, within: value) {
                value[lower..<upper].backgroundColor = .yellow.opacity(0.3)
            }
            remaining = range.upperBound..<text.endIndex
        }
        return value
    }

    private func reload() {
        let page = history.fetchPage(query: HistoryQuery(searchText: search), offset: 0, limit: max(200, records.count))
        records = page.records
        hasMore = page.hasMore
        if !visible.contains(where: { $0.id == selected }) { selected = visible.first?.id }
    }

    private func loadMore() {
        let page = history.fetchPage(query: HistoryQuery(searchText: search), offset: records.count, limit: 200)
        records += page.records
        hasMore = page.hasMore
    }

    private func requestDelete(_ record: TranscriptionRecord) {
        if history.audioFileURL(for: record) != nil { deleting = record } else { scheduleDeletion(record) }
    }

    private func scheduleDeletion(_ record: TranscriptionRecord) {
        commitDeletion()
        pendingDeletion = record
        selected = visible.first?.id
        deletionTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            commitDeletion()
        }
    }

    private func undoDeletion() {
        deletionTask?.cancel()
        selected = pendingDeletion?.id
        pendingDeletion = nil
    }

    private func commitDeletion() {
        deletionTask?.cancel()
        if let record = pendingDeletion { pendingDeletion = nil; history.deleteRecord(record) }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "dictum-history.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = history.allRecords(query: HistoryQuery(searchText: search)).filter { filter.includes($0) }.map {
            "## \($0.timestamp.formatted(.iso8601))\n\n\($0.finalText)\n"
        }.joined(separator: "\n")
        do { try text.write(to: url, atomically: true, encoding: .utf8) }
        catch { message = error.localizedDescription }
    }
}
