import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class AppVocabularyImportViewModel: ObservableObject {
    let destination: AppVocabularyImport.Destination
    @Published var csvHasHeader = false
    @Published var source = AppVocabularyImport.Source.wisprFlow
    @Published private(set) var batch: AppVocabularyImport.Batch?
    @Published private(set) var rows: [AppVocabularyImport.Review] = []
    @Published var selected = Set<Int>()
    @Published var focusedRowID: Int?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    @Published private(set) var importedCount: Int?
    private var loadedURL: URL?
    private var baseline: [AppVocabularyImport.Existing] = []
    private var loadTask: Task<Void, Never>?
    private var generation = UUID()
    private let dictionary: DictionaryService
    private let snippets: SnippetService

    init(
        destination: AppVocabularyImport.Destination,
        source: AppVocabularyImport.Source = .wisprFlow,
        dictionary: DictionaryService = ServiceContainer.shared.dictionaryService,
        snippets: SnippetService = ServiceContainer.shared.snippetService
    ) {
        self.destination = destination
        self.source = destination == .snippets && source == .handy ? .wisprFlow : source
        self.dictionary = dictionary
        self.snippets = snippets
    }

    var sources: [AppVocabularyImport.Source] {
        destination == .dictionary ? [.wisprFlow, .handy, .wisprCSV] : [.wisprFlow, .wisprCSV]
    }

    var additions: [AppVocabularyImport.Entry] {
        rows.filter { $0.outcome == .add && selected.contains($0.id) }.map(\.entry)
    }

    private var currentSnapshot: [AppVocabularyImport.Existing] {
        destination == .dictionary ? dictionary.appImportSnapshot : snippets.appImportSnapshot
    }

    func reset() {
        generation = UUID()
        loadTask?.cancel()
        loadTask = nil
        loadedURL = nil
        batch = nil
        rows = []
        selected = []
        focusedRowID = nil
        error = nil
        importedCount = nil
        isLoading = false
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        switch source {
        case .wisprFlow:
            // SQLite files may have no registered UTType. The reader validates the schema.
            panel.allowedContentTypes = [.data]
        case .handy: panel.allowedContentTypes = [.json]
        case .wisprCSV: panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        }
        panel.directoryURL = source.defaultURL?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    func loadDefault() {
        reset()
        guard let url = source.defaultURL else { chooseFile(); return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            error = String(localized: "No source file was found. Use Choose File to locate it.")
            return
        }
        load(url)
    }

    func reloadCSV() {
        guard source == .wisprCSV, let loadedURL else { return }
        load(loadedURL)
    }

    func load(_ url: URL) {
        reset()
        loadedURL = url
        isLoading = true
        let source = source, destination = destination, generation = generation, csvHasHeader = csvHasHeader
        loadTask = Task { [weak self] in
            // Only immutable values cross the actor boundary. Large files never block the UI.
            let worker = Task.detached(priority: .userInitiated) {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                return Result { try AppVocabularyImport.load(source: source, url: url, destination: destination, csvHasHeader: csvHasHeader) }
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let self, self.generation == generation, !Task.isCancelled else { return }
            self.isLoading = false
            switch result {
            case .success(let batch):
                self.batch = batch
                self.rebuildReview()
            case .failure(let error):
                self.error = error.localizedDescription
            }
        }
    }

    private func rebuildReview() {
        guard let batch else { return }
        baseline = currentSnapshot
        rows = AppVocabularyImport.review(batch, existing: baseline)
        focusedRowID = rows.first?.id
        selected = Set(rows.filter { $0.outcome == .add }.map(\.id))
    }

    func commit() {
        guard !isLoading, importedCount == nil, !additions.isEmpty else { return }
        let entries = additions
        do {
            let committed = try destination == .dictionary
                ? dictionary.importReviewedEntries(entries, baseline: baseline)
                : snippets.importReviewedEntries(entries, baseline: baseline)
            guard committed else {
                rebuildReview()
                error = String(localized: "Your list changed while you were reviewing. Nothing was imported. Please review the updated list.")
                return
            }
            error = nil
            importedCount = entries.count
        } catch {
            self.error = error.localizedDescription
        }
    }
}
