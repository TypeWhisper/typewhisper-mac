import SwiftUI
import UniformTypeIdentifiers

struct DictionaryEditSheet: View {
    @ObservedObject var service: DictionaryService
    let entry: DictionaryEntry
    @State private var word: String
    @State private var heard: String
    @State private var failed = false
    @Environment(\.dismiss) private var dismiss

    init(service: DictionaryService, entry: DictionaryEntry) {
        self.service = service
        self.entry = entry
        _word = State(initialValue: entry.replacement ?? entry.original)
        _heard = State(initialValue: entry.original)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Word", tableName: "DictumHistory").font(.headline)
            TextField(String(localized: "Word or phrase", table: "DictumHistory"), text: $word)
            if entry.type == .correction {
                TextField(String(localized: "Heard as", table: "DictumHistory"), text: $heard)
            }
            if failed { Text("Could not save. Check for a duplicate word.", tableName: "DictumHistory").foregroundStyle(.red) }
            HStack {
                Spacer()
                Button { dismiss() } label: { Text("Cancel", tableName: "DictumHistory") }.keyboardShortcut(.cancelAction)
                Button {
                    let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
                    let original = entry.type == .correction ? heard.trimmingCharacters(in: .whitespacesAndNewlines) : word
                    if service.updateEntry(entry, original: original, replacement: entry.type == .correction ? word : nil,
                                           caseSensitive: entry.caseSensitive, ctcMinSimilarity: entry.ctcMinSimilarity) { dismiss() }
                    else { failed = true }
                } label: { Text("Save", tableName: "DictumHistory") }
                .keyboardShortcut(.defaultAction)
                .disabled(word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || (entry.type == .correction && heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }.padding(24).frame(width: 420)
    }
}

struct DictionaryAddSheet: View {
    @ObservedObject var service: DictionaryService
    @State var word: String
    @State private var heard = ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    private var duplicate: Bool {
        service.csvItems.contains { $0.word.caseInsensitiveCompare(word.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Word", tableName: "DictumHistory").font(.headline)
            TextField(String(localized: "Word or phrase", table: "DictumHistory"), text: $word).focused($focused)
            TextField(String(localized: "Often heard as (optional, comma separated)", table: "DictumHistory"), text: $heard)
            if duplicate { Text("This word is already in your dictionary", tableName: "DictumHistory").foregroundStyle(.red) }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button { dismiss() } label: { Text("Cancel", tableName: "DictumHistory") }.keyboardShortcut(.cancelAction)
                Button { add() } label: { Text("Add", tableName: "DictumHistory") }
                    .keyboardShortcut(.defaultAction).disabled(duplicate || word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 420).onAppear { focused = true }
    }

    private func add() {
        let candidates = heard.split(separator: ",").map(String.init)
        guard service.entries.count + 1 + candidates.count <= DictionaryCSV.maximumWords else { error = DictionaryCSVError.count.localizedDescription; return }
        do {
            _ = try service.applyDictionaryTraining(canonicalWord: word, approvedCandidates: candidates)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct DictionaryImportSheet: View {
    @ObservedObject var service: DictionaryService
    @Environment(\.dismiss) private var dismiss
    @State private var format = DictionaryCSVFormat.wisprFlow
    @State private var data: Data?
    @State private var preview: DictionaryCSVResult?
    @State private var error: String?
    @State private var choosing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import CSV", tableName: "DictumHistory").font(.headline)
            Picker(selection: $format) {
                Text("Wispr Flow (heard as, word)", tableName: "DictumHistory").tag(DictionaryCSVFormat.wisprFlow)
                Text("Word, heard as", tableName: "DictumHistory").tag(DictionaryCSVFormat.wordFirst)
            } label: { Text("Format", tableName: "DictumHistory") }
            VStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down").font(.largeTitle).foregroundStyle(.secondary)
                Text("Drop a CSV file here, or choose a file", tableName: "DictumHistory")
                Button { choosing = true } label: { Text("Choose file…", tableName: "DictumHistory") }
            }.frame(maxWidth: .infinity).padding(28).background(DictumTheme.card, in: RoundedRectangle(cornerRadius: 12))
                .dropDestination(for: URL.self) { urls, _ in guard let url = urls.first else { return false }; load(url); return true }
            if let preview {
                Text(String(format: String(localized: "%lld new words, %lld duplicates skipped", table: "DictumHistory"), Int64(preview.items.count), Int64(preview.duplicates)))
                Text(preview.items.prefix(5).map(\.word).joined(separator: " · ")).foregroundStyle(.secondary)
                ForEach(Array(preview.rejected.prefix(5).enumerated()), id: \.offset) { _, row in Text(verbatim: "\(row.row): \(row.reason)").foregroundStyle(.red) }
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button { dismiss() } label: { Text("Cancel", tableName: "DictumHistory") }.keyboardShortcut(.cancelAction)
                Button {
                    guard let data else { return }
                    do { _ = try service.importCSV(data, format: format); dismiss() }
                    catch { self.error = error.localizedDescription }
                } label: { Text("Import", tableName: "DictumHistory") }
                .disabled(preview?.items.isEmpty != false || error != nil).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 480)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.commaSeparatedText]) { result in
            do { load(try result.get()) } catch { self.error = error.localizedDescription }
        }
        .onChange(of: format) { _, _ in parse() }
    }

    private func load(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= DictionaryCSV.maximumBytes else { throw DictionaryCSVError.size }
            data = try Data(contentsOf: url)
            parse()
        } catch { data = nil; preview = nil; self.error = error.localizedDescription }
    }

    private func parse() {
        error = nil
        preview = nil
        guard let data else { return }
        do {
            let result = try DictionaryCSV.parse(data, format: format, existing: Set(service.csvItems.map(\.identity)))
            guard service.entries.count + result.items.count <= DictionaryCSV.maximumWords else { throw DictionaryCSVError.count }
            preview = result
        } catch { self.error = error.localizedDescription }
    }
}
