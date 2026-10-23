import SwiftUI
import UniformTypeIdentifiers

struct DictionaryPage: View {
    @ObservedObject private var service = ServiceContainer.shared.dictionaryService
    @State private var search = ""
    @State private var filter = DictionaryFilter.all
    @State private var selection: Set<UUID> = []
    @State private var adding = false
    @State private var importing = false
    @State private var pendingDelete: [DictionaryEntry] = []
    @State private var error: String?
    @State private var hovered: UUID?
    @State private var editing: DictionaryEntry?
    @State private var dismissedLearned: Set<UUID> = []
    @State private var hoveredHeader = false

    init() {
        _dismissedLearned = State(initialValue: DictionaryPage.loadDismissed())
    }

    private var visible: [DictionaryEntry] {
        service.entries.filter {
            filter.includes($0)
                && (search.isEmpty || $0.original.localizedCaseInsensitiveContains(search)
                    || ($0.replacement?.localizedCaseInsensitiveContains(search) ?? false))
        }
    }

    private var learned: [DictionaryEntry] {
        guard search.isEmpty, filter == .all else { return [] }
        return service.learnedSinceLastSeen().filter { !dismissedLearned.contains($0.id) }
    }

    var body: some View {
        DictumPageFrame(page: .dictionary) {
            if !service.entries.isEmpty {
                NativeSearchField(text: $search, placeholder: String(localized: "Search words", table: "DictumHistory"))
                    .frame(width: 200, height: 28)
                Button { importing = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.to.line").font(.system(size: 12))
                        Text("Import", tableName: "DictumHistory")
                    }
                }
                .buttonStyle(DictumActionButtonStyle())
                Button { adding = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                        Text("Add Word", tableName: "DictumHistory")
                    }
                }
                .buttonStyle(DictumActionButtonStyle(prominent: true))
            }
        } content: {
            content
        }
        .sheet(isPresented: $adding) { DictionaryAddSheet(service: service, word: search) }
        .sheet(item: $editing) { DictionaryEditSheet(service: service, entry: $0) }
        .sheet(isPresented: $importing) { DictionaryImportSheet(service: service, onExport: export) }
        .alert(deleteTitle, isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })) {
            Button(role: .cancel) {} label: { Text("Cancel", tableName: "DictumHistory") }
            Button(role: .destructive) { deletePending() } label: { Text("Delete", tableName: "DictumHistory") }
        }
        .onChange(of: search) { _, _ in pruneSelection() }
        .onChange(of: filter) { _, _ in pruneSelection() }
        .alert(String(localized: "Export failed", table: "DictumHistory"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button { error = nil } label: { Text("OK", tableName: "DictumHistory") }
        } message: { Text(error ?? "") }
    }

    @ViewBuilder private var content: some View {
        if service.entries.isEmpty {
            EmptyState(
                title: "Your dictionary is empty",
                message: "Add names, product names, and jargon so dictum spells them right. Words you correct in other apps are added here automatically.",
                symbol: "book",
                tableName: "DictumHistory"
            ) {
                HStack(spacing: 8) {
                    Button { importing = true } label: { Text("Import CSV", tableName: "DictumHistory") }
                        .buttonStyle(DictumActionButtonStyle())
                    Button { adding = true } label: { Text("Add Word", tableName: "DictumHistory") }
                        .buttonStyle(DictumActionButtonStyle(prominent: true))
                }
            }
        } else {
            VStack(spacing: 0) {
                filterBar
                if !learned.isEmpty { learnedStrip }
                if visible.isEmpty { noResults } else { table }
            }
            .overlay(alignment: .bottom) {
                if !selection.isEmpty { selectionBar.padding(.bottom, 20) }
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            DictumSegmentedControl(
                items: [
                    .init(value: DictionaryFilter.all, title: "All"),
                    .init(value: DictionaryFilter.manual, title: "Added by you"),
                    .init(value: DictionaryFilter.learned, title: "Learned")
                ],
                selection: $filter
            )
            Spacer(minLength: 0)
            Text(verbatim: visible.count.formatted() + " " + String(localized: "words", table: "DictumHistory"))                .font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(DictumTheme.textTertiary)
        }
        .padding(.horizontal, 28).padding(.bottom, 12)
    }

    private var learnedStrip: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles").font(.system(size: 16)).foregroundStyle(DictumTheme.accent)
                .accessibilityHidden(true)
            Text("Just learned", tableName: "DictumHistory")
                .font(.system(size: 13)).foregroundStyle(DictumTheme.textPrimary).fixedSize()
            HStack(spacing: 6) {
                ForEach(learned.prefix(3)) { entry in
                    learnedChip(entry)
                }
            }
            Spacer(minLength: 0)
            Button {
                service.markLearnedWordsSeen()
                dismissedLearned.formUnion(learned.map(\.id))
                DictionaryPage.storeDismissed(learned.map(\.id))
            } label: {
                Text("OK", tableName: "DictumHistory").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(DictumTheme.textSecondary)
            .padding(.horizontal, 8).frame(height: 24)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(DictumTheme.accentSoft, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 20).padding(.bottom, 14)
    }

    private func learnedChip(_ entry: DictionaryEntry) -> some View {
        HStack(spacing: 6) {
            Text(entry.replacement ?? entry.original).font(.system(size: 12.5)).lineLimit(1)
            if entry.type == .correction {
                Text(verbatim: "← " + entry.original).font(.system(size: 11.5)).foregroundStyle(DictumTheme.textTertiary)
            }
            Button { dismissLearned(entry.id) } label: {
                Image(systemName: "xmark").font(.system(size: 10))
                    .foregroundStyle(DictumTheme.textTertiary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Remove", tableName: "DictumHistory"))
        }
        .padding(.leading, 9).padding(.trailing, 4).frame(height: 24)
        .background(DictumTheme.raised, in: RoundedRectangle(cornerRadius: 6))
        .shadow(color: DictumTheme.controlShadow, radius: 1.5, y: 1)
    }

    private var table: some View {
        VStack(spacing: 0) {
            headerRow
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, entry in
                        row(entry, index: index)
                    }
                }
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 20)
    }

    private var headerRow: some View {
        DictumColumnsLayout(columns: Self.columns) {
            checkbox(
                isOn: !visible.isEmpty && visible.allSatisfy { selection.contains($0.id) },
                visible: hoveredHeader || !selection.isEmpty,
                label: String(localized: "Select all words", table: "DictumHistory")
            ) {
                toggleAll()
            }
            headerText("Word", alignment: .leading)
            headerText("Heard as", alignment: .leading)
            headerText("Source", alignment: .leading)
            headerText("Uses", alignment: .trailing)
            headerText("Added", alignment: .trailing)
        }
        .frame(height: 28)
        .overlay(alignment: .bottom) { Rectangle().fill(DictumTheme.separator).frame(height: 0.5) }
        .onHover { hoveredHeader = $0 }
    }

    private func headerText(_ key: LocalizedStringKey, alignment: Alignment) -> some View {
        Text(key, tableName: "DictumHistory")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(DictumTheme.textTertiary)
            .frame(maxWidth: .infinity, alignment: alignment)
    }

    private func row(_ entry: DictionaryEntry, index: Int) -> some View {
        let isSelected = selection.contains(entry.id)
        let isHovered = hovered == entry.id
        return DictumColumnsLayout(columns: Self.columns) {
            checkbox(
                isOn: isSelected,
                visible: isHovered || !selection.isEmpty,
                label: String(
                    format: String(localized: "Select %@", table: "DictumHistory"),
                    entry.replacement ?? entry.original
                )
            ) { toggle(entry) }
            Text(entry.replacement ?? entry.original)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DictumTheme.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.type == .correction ? entry.original : "—")
                .font(.system(size: 13))
                .foregroundStyle(DictumTheme.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            sourceBadge(entry)
            Text(entry.usageCount.formatted()).font(.system(size: 13)).monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
            addedColumn(entry, hovered: isHovered)
        }
        .frame(height: 38)
        .background {
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? DictumTheme.accentSoft : (isHovered ? Color.primary.opacity(0.05) : (index % 2 == 1 ? DictumTheme.card : Color.clear)))
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle(entry) }
        .onHover { hovered = $0 ? entry.id : (hovered == entry.id ? nil : hovered) }
    }

    private func sourceBadge(_ entry: DictionaryEntry) -> some View {
        let learned = entry.source == .autoLearned
        return Text(learned ? "Learned" : "Manual", tableName: "DictumHistory")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(learned ? DictumTheme.accent : DictumTheme.textSecondary)
            .padding(.horizontal, 6).frame(height: 18)
            .background(learned ? DictumTheme.accentSoft : DictumTheme.selected, in: RoundedRectangle(cornerRadius: 5))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func addedColumn(_ entry: DictionaryEntry, hovered: Bool) -> some View {
        ZStack(alignment: .trailing) {
            Text(entry.createdAt, format: .dateTime.month().day())
                .font(.system(size: 12)).foregroundStyle(DictumTheme.textTertiary)
                .opacity(hovered ? 0 : 1)
            HStack(spacing: 2) {
                iconButton("pencil", label: "Edit Word %@", word: entry.replacement ?? entry.original) { editing = entry }
                iconButton("trash", label: "Delete %@", word: entry.replacement ?? entry.original) {
                    pendingDelete = [entry]
                }
            }
            .opacity(hovered ? 1 : 0)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func iconButton(
        _ symbol: String,
        label: String.LocalizationValue,
        word: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12))
                .foregroundStyle(DictumTheme.textSecondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(format: String(localized: label, table: "DictumHistory"), word)))
    }

    private func checkbox(isOn: Bool, visible: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 4)
                .fill(isOn ? DictumTheme.accent : DictumTheme.control)
                .overlay {
                    if isOn {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                    } else {
                        RoundedRectangle(cornerRadius: 4).strokeBorder(DictumTheme.separatorStrong, lineWidth: 1)
                    }
                }
                .frame(width: 14, height: 14)
                .opacity(visible ? 1 : 0)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }

    private var deleteTitle: String {
        if pendingDelete.count == 1, let entry = pendingDelete.first {
            let word = entry.replacement ?? entry.original
            return String(
                format: String(localized: "Remove %@ from the dictionary? This can't be undone.", table: "DictumHistory"),
                word
            )
        }
        return String(
            format: String(localized: "Delete %lld words? This can't be undone.", table: "DictumHistory"),
            Int64(pendingDelete.count)
        )
    }

    private func deletePending() {
        let entries = pendingDelete
        pendingDelete = []
        service.deleteEntries(entries)
        selection.subtract(entries.map(\.id))
    }

    private func pruneSelection() {
        selection.formIntersection(Set(visible.map(\.id)))
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text(String(format: String(localized: "%lld selected", table: "DictumHistory"), Int64(selection.count)))
                .font(.system(size: 13)).foregroundStyle(DictumTheme.textPrimary)
            Button { selection.removeAll() } label: {
                Text("Deselect", tableName: "DictumHistory").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(DictumTheme.textSecondary)
            .padding(.horizontal, 8).frame(height: 24)
            Button { pendingDelete = visible.filter { selection.contains($0.id) } } label: {
                HStack(spacing: 5) {
                    Image(systemName: "trash").font(.system(size: 12))
                    Text("Delete", tableName: "DictumHistory")
                }
                .font(.system(size: 12)).foregroundStyle(.white)
                .padding(.horizontal, 10).frame(height: 24)
                .background(DictumTheme.danger, in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 6)
        .background(DictumTheme.raised, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
    }

    private static let dismissedLearnedKey = "dictum.dictionary.dismissedLearned"

    private static func storeDismissed(_ ids: [UUID]) {
        let data = try? JSONEncoder().encode(ids)
        UserDefaults.standard.set(data, forKey: dismissedLearnedKey)
    }

    private static func loadDismissed() -> Set<UUID> {
        guard let data = UserDefaults.standard.data(forKey: dismissedLearnedKey),
              let ids = try? JSONDecoder().decode([UUID].self, from: data) else {
            return []
        }
        return Set(ids)
    }

    private func dismissLearned(_ id: UUID) {
        dismissedLearned.insert(id)
        DictionaryPage.storeDismissed(Array(dismissedLearned))
    }

    private var noResults: some View {
        EmptyState(
            title: LocalizedStringKey(String(format: String(localized: "No results for “%@”", table: "DictumHistory"), search)),
            message: "Try a different word.",
            symbol: "magnifyingglass",
            tableName: "DictumHistory"
        ) {
            if !search.isEmpty {
                Button {
                    adding = true
                } label: {
                    Text(String(format: String(localized: "Add “%@” to Dictionary", table: "DictumHistory"), search))
                }
                .buttonStyle(DictumActionButtonStyle())
            }
        }
    }

    private func toggle(_ entry: DictionaryEntry) {
        if selection.contains(entry.id) { selection.remove(entry.id) } else { selection.insert(entry.id) }
    }

    private func toggleAll() {
        if visible.allSatisfy({ selection.contains($0.id) }) {
            selection.subtract(visible.map(\.id))
        } else {
            selection.formUnion(visible.map(\.id))
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "dictum-dictionary.csv"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try DictionaryCSV.export(service.csvItems).write(to: url, options: .atomic) }
            catch { self.error = error.localizedDescription }
        }
    }

    private static let columns: [DictumColumnsLayout.Column] = [
        .fixed(28), .flexible(1.2), .flexible(1), .fixed(92), .fixed(64), .fixed(84)
    ]
}

enum DictionaryFilter: Int, CaseIterable {
    case all, manual, learned

    func includes(_ entry: DictionaryEntry) -> Bool {
        switch self {
        case .all: true
        case .manual: entry.source == .manual
        case .learned: entry.source == .autoLearned
        }
    }
}
