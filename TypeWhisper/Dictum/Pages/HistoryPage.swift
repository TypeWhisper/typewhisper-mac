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
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?
    @State private var hovered: UUID?
    @FocusState private var listFocused: Bool

    private var visible: [TranscriptionRecord] {
        records.filter { filter.includes($0) && $0.id != pendingDeletion?.id }
    }
    private var current: TranscriptionRecord? { visible.first { $0.id == selected } }
    private var days: [Date] { Set(visible.map { Calendar.current.startOfDay(for: $0.timestamp) }).sorted(by: >) }

    var body: some View {
        DictumPageFrame(page: .history) {
            if history.totalRecords > 0 {
                DictumSegmentedControl(
                    items: [
                        .init(value: HistoryRecordFilter.all, title: "All"),
                        .init(value: HistoryRecordFilter.dictation, title: "Dictation"),
                        .init(value: HistoryRecordFilter.translation, title: "Translation")
                    ],
                    selection: $filter
                )
                NativeSearchField(text: $search, placeholder: String(localized: "Search", table: "DictumHistory"))
                    .frame(width: 200, height: 28)
                Menu {
                    Button { export() } label: { Text("Export as Markdown…", tableName: "DictumHistory") }
                    Button { if let url = sync.selectedFolderURL { NSWorkspace.shared.open(url) } } label: {
                        Text("Show Sync Folder in Finder", tableName: "DictumHistory")
                    }
                    Divider()
                    Button(role: .destructive) { clearAll = true } label: { Text("Delete All History…", tableName: "DictumHistory") }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14))
                        .foregroundStyle(DictumTheme.textSecondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(Text("More", tableName: "DictumHistory"))
            }
        } content: {
            VStack(spacing: 0) {
                Rectangle().fill(DictumTheme.separator).frame(height: 0.5)
                if history.totalRecords == 0 {
                    EmptyState(
                        title: "No dictations yet",
                        message: "Press fn and start talking. Your dictations show up here.",
                        symbol: "clock",
                        tableName: "DictumHistory"
                    ) {}
                } else if visible.isEmpty {
                    noResults
                } else {
                    split
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
                Button { undoDeletion() } label: {
                    Text("Undo deletion", tableName: "DictumHistory").font(.system(size: 12.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(DictumTheme.textPrimary)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(DictumTheme.raised, in: Capsule())
                .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
                .keyboardShortcut("z", modifiers: .command)
                .padding(.bottom, 20)
            } else if let toast {
                Text(toast).font(.system(size: 12.5)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(.black.opacity(0.92), in: Capsule())
                    .padding(.bottom, 20)
                    .transition(.opacity)
            }
        }
        .onChange(of: retry.message) { _, value in if let value { showToast(value); retry.message = nil } }
        .alert(String(localized: "Send this recording for reprocessing?", table: "DictumHistory"), isPresented: Binding(get: { retry.confirmation != nil }, set: { if !$0 { retry.cancelConfirmation() } })) {
            Button(role: .cancel) { retry.cancelConfirmation() } label: { Text("Cancel", tableName: "DictumHistory") }
            Button { retry.start() } label: { Text("Retry", tableName: "DictumHistory") }
        } message: { Text(retry.confirmation ?? "") }
        .alert(String(localized: "Delete this record and its recording?", table: "DictumHistory"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(role: .cancel) {} label: { Text("Cancel", tableName: "DictumHistory") }
            Button(role: .destructive) { if let deleting { scheduleDeletion(deleting) }; deleting = nil } label: { Text("Delete", tableName: "DictumHistory") }
        } message: { Text(deleting?.finalText ?? "") }
        .alert(String(localized: "Delete All History…", table: "DictumHistory"), isPresented: $clearAll) {
            Button(role: .cancel) {} label: { Text("Cancel", tableName: "DictumHistory") }
            Button(role: .destructive) { _ = history.clearAll(); reload() } label: { Text("Delete", tableName: "DictumHistory") }
        }
        .onDisappear { player?.stop(); commitDeletion() }
    }

    private var noResults: some View {
        EmptyState(
            title: search.isEmpty ? "No results" : LocalizedStringKey(String(format: String(localized: "No results for “%@”", table: "DictumHistory"), search)),
            message: "Try a different word.",
            symbol: "magnifyingglass",
            tableName: "DictumHistory"
        ) {}
    }

    private var split: some View {
        HStack(spacing: 0) {
            listPane.frame(width: 316)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(DictumTheme.separator).frame(width: 0.5)
                }
            detailPane
        }
    }

    private var listPane: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(days, id: \.self) { day in
                            Section {
                                ForEach(visible.filter { Calendar.current.isDate($0.timestamp, inSameDayAs: day) }) { record in
                                    row(record)
                                        .id(record.id)
                                        .onAppear { if record.id == visible.last?.id && hasMore { loadMore() } }
                                }
                            } header: {
                                Text(dayTitle(day))
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(DictumTheme.textTertiary)
                                    .padding(.top, 12).padding(.bottom, 5).padding(.horizontal, 10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(DictumTheme.windowBackground)
                            }
                        }
                    }
                    .padding(.top, 4).padding(.horizontal, 8).padding(.bottom, 8)
                }
                .onChange(of: selected) { _, id in
                    guard let id else { return }
                    withAnimation(DictumTheme.Motion.base) { proxy.scrollTo(id) }
                }
            }
            if sync.mode != .off { syncFooter }
        }
    }

    private func row(_ record: TranscriptionRecord) -> some View {
        let failed = record.processingFailureMessage != nil
        return HStack(alignment: .top, spacing: 10) {
            DictumAppIcon(bundleIdentifier: record.appBundleIdentifier, name: record.appName ?? "dictum", size: 20)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(failed ? record.rawText : record.finalText)
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(DictumTheme.textPrimary)
                HStack(spacing: 6) {
                    Text(record.timestamp, format: .dateTime.hour().minute())
                        .font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(DictumTheme.textTertiary)
                    if failed {
                        Badge(text: "Not polished", tint: DictumTheme.warning, tableName: "DictumHistory")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(record.id == selected ? DictumTheme.accentSoft : (record.id == hovered ? Color.primary.opacity(0.05) : Color.clear))
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? record.id : (hovered == record.id ? nil : hovered) }
        .onTapGesture {
            selected = record.id
            original = false
            listFocused = true
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(record.id == selected ? [.isButton, .isSelected] : .isButton)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
        .onKeyPress(.downArrow) { moveSelection(1); return .handled }
        .focused($listFocused)
    }

    private var syncFooter: some View {
        Button { DictumNavigation.shared.open(.general) } label: {
            HStack(spacing: 7) {
                Image(systemName: sync.errorMessage == nil ? "icloud" : "exclamationmark.icloud")
                    .font(.system(size: 14))
                    .foregroundStyle(sync.errorMessage == nil ? DictumTheme.textTertiary : DictumTheme.danger)
                Text(HistorySyncPresentation.status(sync))
                    .font(.system(size: 11.5)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: 34)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .top) { Rectangle().fill(DictumTheme.separator).frame(height: 0.5) }
        }
        .buttonStyle(.plain)
        .foregroundStyle(sync.errorMessage == nil ? DictumTheme.textSecondary : DictumTheme.danger)
    }

    @ViewBuilder private var detailPane: some View {
        if let record = current {
            ScrollView {
                detail(record)
                    .padding(.top, 22).padding(.horizontal, 30).padding(.bottom, 30)
            }
        } else {
            Color.clear
        }
    }

    private func detail(_ record: TranscriptionRecord) -> some View {
        let failed = record.processingFailureMessage != nil
        let showsOriginalToggle = !failed && record.rawText != record.finalText
        let shownText = original ? record.rawText : record.finalText
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                DictumAppIcon(bundleIdentifier: record.appBundleIdentifier, name: record.appName ?? "dictum", size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.appName ?? "dictum").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DictumTheme.textPrimary)
                    Text(detailDate(record)).font(.system(size: 12)).foregroundStyle(DictumTheme.textSecondary)
                }
                Spacer(minLength: 12)
                if showsOriginalToggle {
                    DictumSegmentedControl(
                        items: [.init(value: false, title: "Polished"), .init(value: true, title: "Original")],
                        selection: $original
                    )
                }
            }
            if let failure = record.processingFailureMessage {
                failureBanner(failure)
                    .padding(.top, 18)
            }
            Text(highlight(shownText))
                .font(.system(size: 15))
                .lineSpacing(DictumTheme.Typography.readingLineSpacing)
                .foregroundStyle(failed || original ? DictumTheme.textSecondary : DictumTheme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 18).padding(.horizontal, 20)
                .background(DictumTheme.card, in: RoundedRectangle(cornerRadius: 12))
                .padding(.top, 18)
            HStack(spacing: 16) {
                metaValue("Duration", "\(Int(record.durationSeconds) / 60):\(String(format: "%02d", Int(record.durationSeconds) % 60))")
                metaValue("Words", record.wordsCount.formatted())
                Text([record.engineUsed, record.modelUsed].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(DictumTheme.textSecondary)
            }
            .padding(.top, 14)
            HStack(spacing: 8) {
                actionButton("Copy", symbol: "doc.on.doc") { copy(shownText) }
                actionButton("Retry", symbol: "arrow.clockwise") { retry.request(record) }
                    .disabled(history.audioFileURL(for: record) == nil || retry.isRunning)
                if let url = history.audioFileURL(for: record) {
                    actionButton("Play Recording", symbol: "play.fill") { play(url) }
                }
                Spacer(minLength: 0)
                Button { requestDelete(record) } label: {
                    Image(systemName: "trash").font(.system(size: 14))
                        .foregroundStyle(DictumTheme.textSecondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Delete", tableName: "DictumHistory"))
            }
            .padding(.top, 16)
        }
    }

    private func failureBanner(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 16))
                .foregroundStyle(DictumTheme.warning)
                .accessibilityHidden(true)
            Text(text).font(.system(size: 12.5)).foregroundStyle(DictumTheme.textPrimary)
            Spacer(minLength: 0)
            if let record = current {
                Button { retry.request(record) } label: { Text("Retry", tableName: "DictumHistory") }
                    .buttonStyle(DictumActionButtonStyle())
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 9).padding(.horizontal, 12)
        .background(DictumTheme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
    }

    private func metaValue(_ title: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(String(localized: String.LocalizationValue(title), table: "DictumHistory"))
                .foregroundStyle(DictumTheme.textSecondary)
            Text(value).foregroundStyle(DictumTheme.textPrimary).monospacedDigit()
        }
        .font(.system(size: 12))
    }

    private func actionButton(_ title: LocalizedStringKey, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 12))
                Text(title, tableName: "DictumHistory")
            }
        }
        .buttonStyle(DictumActionButtonStyle())
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast(String(localized: "Copied", table: "DictumHistory"))
    }

    private func showToast(_ text: String) {
        toastTask?.cancel()
        withAnimation(DictumTheme.Motion.base) { toast = text }
        toastTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(1600)) } catch { return }
            withAnimation(DictumTheme.Motion.exit) { toast = nil }
        }
    }

    private func play(_ url: URL) {
        do { player = try AVAudioPlayer(contentsOf: url); player?.play() }
        catch { showToast(error.localizedDescription) }
    }

    private func moveSelection(_ delta: Int) {
        guard !visible.isEmpty else { return }
        let index = visible.firstIndex { $0.id == selected } ?? 0
        let next = min(max(index + delta, 0), visible.count - 1)
        selected = visible[next].id
        original = false
    }

    private func detailDate(_ record: TranscriptionRecord) -> String {
        let day = dayTitle(Calendar.current.startOfDay(for: record.timestamp))
        return "\(day) \(record.timestamp.formatted(.dateTime.hour().minute()))"
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
        catch { showToast(error.localizedDescription) }
    }
}
