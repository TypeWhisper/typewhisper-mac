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
        VStack(alignment: .leading, spacing: 0) {
            Text("Edit Word", tableName: "DictumHistory")
                .font(.system(size: 15, weight: .semibold))
            field("Word or phrase", text: $word)
            if entry.type == .correction {
                field("Heard as", text: $heard)
            }
            if failed {
                Text("Could not save. Check for a duplicate word.", tableName: "DictumHistory")
                    .font(.system(size: 12)).foregroundStyle(DictumTheme.danger).padding(.top, 12)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button { dismiss() } label: { Text("Cancel", tableName: "DictumHistory") }
                    .buttonStyle(DictumActionButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button {
                    let word = word.trimmingCharacters(in: .whitespacesAndNewlines)
                    let original = entry.type == .correction ? heard.trimmingCharacters(in: .whitespacesAndNewlines) : word
                    if service.updateEntry(entry, original: original, replacement: entry.type == .correction ? word : nil,
                                           caseSensitive: entry.caseSensitive, ctcMinSimilarity: entry.ctcMinSimilarity) { dismiss() }
                    else { failed = true }
                } label: { Text("Save", tableName: "DictumHistory") }
                .buttonStyle(DictumActionButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || (entry.type == .correction && heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }.padding(.top, 20)
        }
        .padding(20)
        .frame(width: 420)
        .background(DictumTheme.raised)
    }

    private func field(_ title: LocalizedStringKey, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title, tableName: "DictumHistory").font(.system(size: 12)).foregroundStyle(DictumTheme.textSecondary)
            TextField("", text: text).textFieldStyle(.plain).font(.system(size: 13))
                .padding(.horizontal, 8).frame(height: 28)
                .background(DictumTheme.control, in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(DictumTheme.controlBorder, lineWidth: 0.5) }
        }
        .padding(.top, 14)
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
        VStack(alignment: .leading, spacing: 0) {
            Text("Add Word", tableName: "DictumHistory")
                .font(.system(size: 15, weight: .semibold))
            field("Word or phrase") {
                TextField("", text: $word).focused($focused)
            }
            field("Often heard as (optional, comma separated)") {
                TextField(String(localized: "For example: 迪克腾, dick tom", table: "DictumHistory"), text: $heard)
            }
            if duplicate {
                Text("This word is already in your dictionary", tableName: "DictumHistory")
                    .font(.system(size: 12)).foregroundStyle(DictumTheme.danger).padding(.top, 12)
            }
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(DictumTheme.danger).padding(.top, 12)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button { dismiss() } label: { Text("Cancel", tableName: "DictumHistory") }
                    .buttonStyle(DictumActionButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button { add() } label: { Text("Add", tableName: "DictumHistory") }
                    .buttonStyle(DictumActionButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(duplicate || word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(.top, 20)
        }
        .padding(20)
        .frame(width: 420)
        .background(DictumTheme.raised)
        .onAppear { focused = true }
    }

    private func field<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title, tableName: "DictumHistory").font(.system(size: 12)).foregroundStyle(DictumTheme.textSecondary)
            content()
                .textFieldStyle(.plain).font(.system(size: 13))
                .padding(.horizontal, 8).frame(height: 28)
                .background(DictumTheme.control, in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(DictumTheme.controlBorder, lineWidth: 0.5) }
        }
        .padding(.top, 14)
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
    var onExport: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var format = DictionaryCSVFormat.wisprFlow
    @State private var data: Data?
    @State private var preview: DictionaryCSVResult?
    @State private var error: String?
    @State private var choosing = false
    @State private var fileName: String?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Import CSV", tableName: "DictumHistory")
                .font(.system(size: 15, weight: .semibold))
            dropZone.padding(.top, 14)
            if let preview {
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(format: String(localized: "%lld new words, %lld duplicates skipped", table: "DictumHistory"), Int64(preview.items.count), Int64(preview.duplicates)))
                            .font(.system(size: 13)).foregroundStyle(DictumTheme.textPrimary)
                        Text(verbatim: previewCaption(preview))
                            .font(.system(size: 11)).foregroundStyle(DictumTheme.textTertiary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(DictumTheme.card, in: RoundedRectangle(cornerRadius: 10))
                .padding(.top, 14)
            }
            ForEach(Array((preview?.rejected ?? []).prefix(5).enumerated()), id: \.offset) { _, row in
                Text(verbatim: "\(row.row): \(row.reason)")
                    .font(.system(size: 11)).foregroundStyle(DictumTheme.danger).lineLimit(1)
            }
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(DictumTheme.danger).padding(.top, 12)
            }
            HStack(spacing: 8) {
                DictumPopup(title: "Format", selection: $format, tableName: "DictumHistory", value: Text(formatName(format))) {
                    Text("Wispr Flow (heard as, word)", tableName: "DictumHistory").tag(DictionaryCSVFormat.wisprFlow)
                    Text("Word, heard as", tableName: "DictumHistory").tag(DictionaryCSVFormat.wordFirst)
                }
                Button { dismiss(); onExport() } label: {
                    Text("Export CSV…", tableName: "DictumHistory").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(DictumTheme.textSecondary)
                .padding(.horizontal, 8).frame(height: 24)
                Spacer(minLength: 12)
                Button { dismiss() } label: { Text("Cancel", tableName: "DictumHistory") }
                    .buttonStyle(DictumActionButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button { importNow() } label: {
                    Text(preview.map { String(format: String(localized: "Import %lld words", table: "DictumHistory"), Int64($0.items.count)) } ?? String(localized: "Import", table: "DictumHistory"))
                }
                .buttonStyle(DictumActionButtonStyle(prominent: true))
                .disabled(preview?.items.isEmpty != false || error != nil)
                .keyboardShortcut(.defaultAction)
            }.padding(.top, 20)
        }
        .padding(20)
        .frame(width: 420)
        .background(DictumTheme.raised)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.commaSeparatedText]) { result in
            do { load(try result.get()) } catch { self.error = error.localizedDescription }
        }
        .onChange(of: format) { _, _ in parse() }
    }

    private var dropZone: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.down.to.line").font(.system(size: 24)).foregroundStyle(DictumTheme.textTertiary)
            HStack(spacing: 4) {
                Text("Drop a CSV file here, or", tableName: "DictumHistory")
                Button { choosing = true } label: { Text("Choose file…", tableName: "DictumHistory") }
                    .buttonStyle(.plain).foregroundStyle(DictumTheme.accent)
            }.font(.system(size: 13)).foregroundStyle(DictumTheme.textSecondary)
            Text("The first column is the word; an optional second column lists how it is often heard.", tableName: "DictumHistory")
                .font(.system(size: 11)).foregroundStyle(DictumTheme.textTertiary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).frame(height: 120)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    hovering ? DictumTheme.accent.opacity(0.6) : DictumTheme.separatorStrong,
                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                )
        }
        .contentShape(Rectangle())
        .onTapGesture { choosing = true }
        .onHover { hovering = $0 }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            load(url)
            return true
        }
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

    private func previewCaption(_ preview: DictionaryCSVResult) -> String {
        let words = preview.items.prefix(4).map(\.word).joined(separator: "、")
        return [fileName, words.isEmpty ? nil : words + "…"].compactMap { $0 }.joined(separator: " · ")
    }

    private func formatName(_ format: DictionaryCSVFormat) -> String {
        switch format {
        case .wisprFlow: String(localized: "Wispr Flow (heard as, word)", table: "DictumHistory")
        case .wordFirst: String(localized: "Word, heard as", table: "DictumHistory")
        }
    }

    private func load(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= DictionaryCSV.maximumBytes else { throw DictionaryCSVError.size }
            data = try Data(contentsOf: url)
            fileName = url.lastPathComponent
            parse()
        } catch { data = nil; preview = nil; self.error = error.localizedDescription }
    }

    private func importNow() {
        guard let data else { return }
        do { _ = try service.importCSV(data, format: format); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
