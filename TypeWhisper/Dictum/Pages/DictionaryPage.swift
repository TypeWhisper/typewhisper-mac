import SwiftUI
import UniformTypeIdentifiers

struct DictionaryPage: View {
    @ObservedObject private var service = ServiceContainer.shared.dictionaryService
    @State private var search = ""
    @State private var filter = 0
    @State private var selection: Set<UUID> = []
    @State private var adding = false
    @State private var importing = false
    @State private var confirmDelete = false
    @State private var error: String?

    private var visible: [DictionaryEntry] {
        service.entries.filter {
            (filter == 0 || (filter == 1 ? $0.source == .manual : $0.source == .autoLearned))
                && (search.isEmpty || $0.original.localizedCaseInsensitiveContains(search)
                    || ($0.replacement?.localizedCaseInsensitiveContains(search) ?? false))
        }
    }

    var body: some View {
        DictumPageFrame(page: .dictionary) {
            if !service.entries.isEmpty {
                NativeSearchField(text: $search, placeholder: String(localized: "Search words", table: "DictumHistory")).frame(width: 180, height: 28)
                Button { importing = true } label: { Text("Import", tableName: "DictumHistory") }
                Button { export() } label: { Text("Export CSV…", tableName: "DictumHistory") }
                Button { adding = true } label: { Text("Add Word", tableName: "DictumHistory") }
                    .buttonStyle(.borderedProminent)
            }
        } content: {
            VStack(spacing: 14) {
                if service.entries.isEmpty {
                    Spacer()
                    Image(systemName: "book").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text("Your dictionary is empty", tableName: "DictumHistory").font(.headline)
                    Text("Add names, product names, and jargon so dictum spells them right. Words you correct in other apps are added here automatically.", tableName: "DictumHistory")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                    HStack {
                        Button { importing = true } label: { Text("Import CSV", tableName: "DictumHistory") }
                        Button { adding = true } label: { Text("Add Word", tableName: "DictumHistory") }
                    }
                    Spacer()
                } else {
                    HStack {
                        Picker(selection: $filter) {
                            Text("All", tableName: "DictumHistory").tag(0)
                            Text("Added by you", tableName: "DictumHistory").tag(1)
                            Text("Learned", tableName: "DictumHistory").tag(2)
                        } label: { Text("Source", tableName: "DictumHistory") }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 280)
                        Spacer()
                        Text(String(format: String(localized: "%lld words", table: "DictumHistory"), Int64(visible.count))).foregroundStyle(.secondary)
                    }
                    if !service.learnedSinceLastSeen().isEmpty {
                        HStack {
                            Image(systemName: "sparkles").foregroundStyle(DictumTheme.accent)
                            Text("Just learned", tableName: "DictumHistory").foregroundStyle(DictumTheme.accent)
                            ForEach(Array(service.learnedSinceLastSeen().prefix(3))) { entry in
                                HStack(spacing: 4) {
                                    Text(entry.replacement.map { "\($0) ← \(entry.original)" } ?? entry.original).lineLimit(1)
                                    Button { service.deleteEntries([entry]) } label: { Image(systemName: "xmark") }
                                        .buttonStyle(.plain).accessibilityLabel(Text("Delete", tableName: "DictumHistory"))
                                }.padding(6).background(DictumTheme.raised, in: Capsule())
                            }
                            Spacer()
                            Button { service.markLearnedWordsSeen() } label: { Text("OK", tableName: "DictumHistory") }
                        }.padding(12).background(DictumTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                    }
                    if visible.isEmpty {
                        Spacer()
                        Text(String(format: String(localized: "No results for “%@”", table: "DictumHistory"), search))
                        Button { adding = true } label: { Text(String(format: String(localized: "Add “%@” to Dictionary", table: "DictumHistory"), search)) }
                        Spacer()
                    } else {
                        Table(visible, selection: $selection) {
                            TableColumn("") { entry in
                                Toggle(isOn: Binding(get: { selection.contains(entry.id) }, set: { selected in
                                    if selected { selection.insert(entry.id) } else { selection.remove(entry.id) }
                                })) { Text(entry.replacement ?? entry.original) }.labelsHidden().toggleStyle(.checkbox)
                            }.width(20)
                            TableColumn(String(localized: "Word", table: "DictumHistory")) { Text($0.replacement ?? $0.original).fontWeight(.medium).frame(minHeight: 30) }
                            TableColumn(String(localized: "Heard as", table: "DictumHistory")) { Text($0.type == .correction ? $0.original : "—").foregroundStyle(.secondary) }
                            TableColumn(String(localized: "Source", table: "DictumHistory")) {
                                Text($0.source == .autoLearned ? String(localized: "Learned", table: "DictumHistory") : String(localized: "Manual", table: "DictumHistory"))
                                    .font(.system(size: 11)).padding(.horizontal, 6).padding(.vertical, 2)
                                    .foregroundStyle($0.source == .autoLearned ? DictumTheme.accent : DictumTheme.textSecondary)
                                    .background($0.source == .autoLearned ? DictumTheme.accentSoft : DictumTheme.card, in: Capsule())
                            }.width(80)
                            TableColumn(String(localized: "Uses", table: "DictumHistory")) { Text($0.usageCount.formatted()).frame(maxWidth: .infinity, alignment: .trailing) }.width(50)
                            TableColumn(String(localized: "Added", table: "DictumHistory")) { Text($0.createdAt, format: .dateTime.month().day()).frame(maxWidth: .infinity, alignment: .trailing) }.width(75)
                        }
                    }
                }
                if !selection.isEmpty {
                    HStack {
                        Text(String(format: String(localized: "%lld selected", table: "DictumHistory"), Int64(selection.count)))
                        Button { selection.removeAll() } label: { Text("Deselect", tableName: "DictumHistory") }
                        Button(role: .destructive) { confirmDelete = true } label: { Text("Delete", tableName: "DictumHistory") }
                    }.padding(10).background(.regularMaterial, in: Capsule())
                }
            }.padding(.horizontal, 28).padding(.bottom, 28).padding(.top, 4)
        }
        .sheet(isPresented: $adding) { DictionaryAddSheet(service: service, word: search) }
        .sheet(isPresented: $importing) { DictionaryImportSheet(service: service) }
        .alert(String(localized: "Delete selected words? This can't be undone.", table: "DictumHistory"), isPresented: $confirmDelete) {
            Button(role: .cancel) {} label: { Text("Cancel", tableName: "DictumHistory") }
            Button(role: .destructive) { service.deleteEntries(service.entries.filter { selection.contains($0.id) }); selection.removeAll() } label: { Text("Delete", tableName: "DictumHistory") }
        }
        .alert(String(localized: "Export failed", table: "DictumHistory"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button { error = nil } label: { Text("OK", tableName: "DictumHistory") }
        } message: { Text(error ?? "") }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "dictum-dictionary.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try DictionaryCSV.export(service.csvItems).write(to: url, options: .atomic) }
        catch { self.error = error.localizedDescription }
    }
}
