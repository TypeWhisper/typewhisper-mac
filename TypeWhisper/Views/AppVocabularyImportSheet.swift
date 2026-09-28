import SwiftUI

struct AppVocabularyImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: AppVocabularyImportViewModel
    private let readFromAppOnAppear: Bool
    @State private var didReadInitialSource = false

    init(
        destination: AppVocabularyImport.Destination,
        source: AppVocabularyImport.Source = .wisprFlow,
        readFromAppOnAppear: Bool = false
    ) {
        _model = StateObject(wrappedValue: AppVocabularyImportViewModel(destination: destination, source: source))
        self.readFromAppOnAppear = readFromAppOnAppear
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.destination == .dictionary
                 ? String(localized: "Import Words from Another App")
                 : String(localized: "Import Snippets from Another App"))
                .font(.title2.bold())

            if let count = model.importedCount {
                Label(String(localized: "Import Complete"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(String(localized: "\(count) entries imported."))
            } else {
                Text(String(localized: "Review the entries before importing. Existing entries will not be overwritten."))
                    .foregroundStyle(.secondary)
                HStack {
                    Picker(String(localized: "Source"), selection: $model.source) {
                        ForEach(model.sources) { source in Text(source.name).tag(source) }
                    }
                    .onChange(of: model.source) { _, _ in model.reset() }
                    .disabled(model.isLoading)
                    if model.source.defaultURL != nil {
                        Button(String(localized: "Read from App")) { model.loadDefault() }
                            .disabled(model.isLoading)
                    }
                    Button(String(localized: "Choose File...")) { model.chooseFile() }
                        .disabled(model.isLoading)
                }

                if model.source == .wisprCSV {
                    Toggle(String(localized: "First row is a header"), isOn: $model.csvHasHeader)
                        .onChange(of: model.csvHasHeader) { _, _ in model.reloadCSV() }
                        .disabled(model.isLoading)
                }

                if model.isLoading {
                    ProgressView(String(localized: "Reading source..."))
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else if let batch = model.batch {
                    reviewSummary(batch)
                    if !model.rows.isEmpty {
                        Table(model.rows, selection: $model.focusedRowID) {
                            TableColumn(String(localized: "Import")) { row in
                                Toggle(String(localized: "Import"), isOn: Binding(
                                    get: { model.selected.contains(row.id) },
                                    set: { if $0 { model.selected.insert(row.id) } else { model.selected.remove(row.id) } }
                                ))
                                .labelsHidden()
                                .disabled(row.outcome != .add)
                                .accessibilityLabel(row.entry.original)
                            }.width(50)
                            TableColumn(String(localized: "Type")) { row in
                                Text(kindName(row.entry.kind))
                            }.width(80)
                            TableColumn(String(localized: "Term / Trigger")) { row in
                                Text(row.entry.original).textSelection(.enabled)
                            }
                            TableColumn(String(localized: "Replacement")) { row in
                                Text(row.entry.replacement ?? "—")
                                    .lineLimit(3)
                                    .help(row.entry.replacement ?? row.entry.original)
                                    .textSelection(.enabled)
                            }
                            TableColumn(String(localized: "Status")) { row in
                                Text(status(row.outcome))
                                    .foregroundStyle(row.outcome == .add ? .primary : .secondary)
                            }.width(110)
                        }
                        .frame(minHeight: 130)
                        if let row = model.rows.first(where: { $0.id == model.focusedRowID }) {
                            ScrollView {
                                Text(row.entry.replacement.map { row.entry.original + "\n→\n" + $0 } ?? row.entry.original)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                    .padding(8)
                            }
                            .frame(height: 74)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                            .accessibilityLabel(String(localized: "Selected entry content"))
                        }
                    }
                }
            }

            if let error = model.error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(model.importedCount == nil ? String(localized: "Cancel") : String(localized: "Done")) {
                    model.reset()
                    dismiss()
                }.keyboardShortcut(.cancelAction)
                if model.importedCount == nil {
                    Button(String(localized: "Import Selected")) { model.commit() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isLoading || model.additions.isEmpty)
                }
            }
        }
        .padding(24)
        .frame(width: 760, height: 560)
        .task {
            guard readFromAppOnAppear, !didReadInitialSource else { return }
            didReadInitialSource = true
            model.loadDefault()
        }
        .onDisappear { model.reset() }
    }

    private func reviewSummary(_ batch: AppVocabularyImport.Batch) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "\(model.additions.count) selected, \(model.rows.filter { $0.outcome == .duplicate }.count) duplicates, \(model.rows.filter { $0.outcome == .conflict }.count) conflicts."))
            if batch.excluded > 0 {
                Text(String(localized: "\(batch.excluded) entries excluded (deleted, another entry type, empty or incompatible)."))
                    .foregroundStyle(.secondary)
            }
            if batch.entries.isEmpty {
                Text(String(localized: "No compatible entries found. Nothing was changed."))
            }
            if model.destination == .snippets {
                Text(String(localized: "Snippets containing TypeWhisper dynamic placeholders are excluded to preserve literal text."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func status(_ outcome: AppVocabularyImport.Review.Outcome) -> String {
        switch outcome {
        case .add: String(localized: "New")
        case .duplicate: String(localized: "Duplicate")
        case .conflict: String(localized: "Conflict")
        }
    }

    private func kindName(_ kind: AppVocabularyImport.Entry.Kind) -> String {
        switch kind {
        case .term: String(localized: "Term")
        case .correction: String(localized: "Correction")
        case .snippet: String(localized: "Snippet")
        }
    }
}

/// Optional welcome-screen entry point. Presence only preselects a source in the dialog.
struct SetupWizardImportLink: View {
    @State private var isPresented = false

    var body: some View {
        Button(String(localized: "Import from Wispr Flow or Handy...")) {
            isPresented = true
        }
        .buttonStyle(.plain)
        .font(.callout)
        .foregroundStyle(.secondary)
        .underline()
        .sheet(isPresented: $isPresented) {
            SetupWizardImportDialog()
        }
    }
}

private struct SetupWizardImportDialog: View {
    @Environment(\.dismiss) private var dismiss
    @State private var detectedSources: [AppVocabularyImport.Source] = []
    @State private var selectedSource = AppVocabularyImport.Source.wisprFlow
    @State private var destination: AppVocabularyImport.Destination?

    var body: some View {
        Group {
            if let destination {
                AppVocabularyImportSheet(
                    destination: destination,
                    source: selectedSource,
                    readFromAppOnAppear: detectedSources.contains(selectedSource)
                )
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Text(String(localized: "Import from Another App..."))
                        .font(.title2.bold())
                    if !detectedSources.isEmpty {
                        Text(String(localized: "Source files found on this Mac: \(detectedSources.map(\.name).joined(separator: ", "))."))
                            .foregroundStyle(.secondary)
                    }
                    Picker(String(localized: "Source"), selection: $selectedSource) {
                        Text("Wispr Flow").tag(AppVocabularyImport.Source.wisprFlow)
                        Text("Handy").tag(AppVocabularyImport.Source.handy)
                    }
                    HStack {
                        Button(String(localized: "Cancel")) { dismiss() }
                            .keyboardShortcut(.cancelAction)
                        Spacer()
                        if selectedSource == .wisprFlow {
                            Button(String(localized: "Review Snippets...")) { destination = .snippets }
                        }
                        Button(String(localized: "Review Words...")) { destination = .dictionary }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(24)
                .frame(width: 480)
            }
        }
        .task {
            detectedSources = AppVocabularyImport.detectedSources()
            if let source = detectedSources.first {
                selectedSource = source
            }
        }
    }
}
