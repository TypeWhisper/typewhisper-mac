import Foundation
import AppKit
import UniformTypeIdentifiers
import Combine

@MainActor
class DictionaryViewModel: ObservableObject {
    nonisolated(unsafe) static var _shared: DictionaryViewModel?
    static var shared: DictionaryViewModel {
        guard let instance = _shared else {
            fatalError("DictionaryViewModel not initialized")
        }
        return instance
    }

    @Published var entries: [DictionaryEntry] = []
    @Published var error: String?
    @Published var importMessage: String?

    // Filter
    enum FilterTab: Int, CaseIterable {
        case all, terms, corrections, termPacks
    }
    @Published var filterTab: FilterTab = .all

    // Editor state
    @Published var isEditing = false
    @Published var isCreatingNew = false
    @Published var editType: DictionaryEntryType = .term
    @Published var editOriginal = ""
    @Published var editReplacement = ""
    @Published var editCaseSensitive = false

    // Term Packs
    @Published var activatedPacks: Set<String> = []

    private let dictionaryService: DictionaryService
    private var cancellables = Set<AnyCancellable>()
    private var selectedEntry: DictionaryEntry?

    private static let activatedPacksKey = UserDefaultsKeys.activatedTermPacks

    var filteredEntries: [DictionaryEntry] {
        switch filterTab {
        case .all:
            return entries
        case .terms:
            return entries.filter { $0.type == .term }
        case .corrections:
            return entries.filter { $0.type == .correction }
        case .termPacks:
            return []
        }
    }

    var termsCount: Int { dictionaryService.termsCount }
    var correctionsCount: Int { dictionaryService.correctionsCount }
    var enabledTermsCount: Int { dictionaryService.enabledTermsCount }
    var enabledCorrectionsCount: Int { dictionaryService.enabledCorrectionsCount }

    init(dictionaryService: DictionaryService) {
        self.dictionaryService = dictionaryService
        self.entries = dictionaryService.entries
        loadActivatedPacks()
        setupBindings()
    }

    private func setupBindings() {
        dictionaryService.$entries
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] entries in
                self?.entries = entries
            }
            .store(in: &cancellables)
    }

    // MARK: - Editor Actions

    func startCreating(type: DictionaryEntryType = .term) {
        selectedEntry = nil
        isCreatingNew = true
        isEditing = true
        editType = type
        editOriginal = ""
        editReplacement = ""
        editCaseSensitive = false
    }

    func startEditing(_ entry: DictionaryEntry) {
        selectedEntry = entry
        isCreatingNew = false
        isEditing = true
        editType = entry.type
        editOriginal = entry.original
        editReplacement = entry.replacement ?? ""
        editCaseSensitive = entry.caseSensitive
    }

    func cancelEditing() {
        isEditing = false
        isCreatingNew = false
        selectedEntry = nil
        editType = .term
        editOriginal = ""
        editReplacement = ""
        editCaseSensitive = false
    }

    func saveEditing() {
        guard !editOriginal.isEmpty else {
            error = String(localized: "Original text cannot be empty")
            return
        }

        if editType == .correction && editReplacement.isEmpty {
            error = String(localized: "Replacement text cannot be empty for corrections")
            return
        }

        let replacement = editType == .correction ? editReplacement : nil

        if isCreatingNew {
            dictionaryService.addEntry(
                type: editType,
                original: editOriginal,
                replacement: replacement,
                caseSensitive: editCaseSensitive
            )
        } else if let entry = selectedEntry {
            dictionaryService.updateEntry(
                entry,
                original: editOriginal,
                replacement: replacement,
                caseSensitive: editCaseSensitive
            )
        }

        cancelEditing()
    }

    func deleteEntry(_ entry: DictionaryEntry) {
        dictionaryService.deleteEntry(entry)
    }

    func toggleEntry(_ entry: DictionaryEntry) {
        dictionaryService.toggleEntry(entry)
    }

    func clearError() {
        error = nil
    }

    func clearImportMessage() {
        importMessage = nil
    }

    // MARK: - Export / Import

    func exportDictionary() {
        DictionaryExporter.saveToFile(entries)
    }

    func importDictionary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = String(localized: "Select a dictionary JSON file to import.")

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let parsed = try DictionaryExporter.parseJSON(data)
            guard !parsed.isEmpty else {
                error = String(localized: "The file contains no dictionary entries.")
                return
            }
            let result = DictionaryExporter.importEntries(parsed, into: dictionaryService)

            if result.skipped > 0 {
                importMessage = String(localized: "\(result.imported) entries imported, \(result.skipped) duplicates skipped.")
            } else {
                importMessage = String(localized: "\(result.imported) entries imported.")
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Term Packs

    func isPackActivated(_ pack: TermPack) -> Bool {
        activatedPacks.contains(pack.id)
    }

    func togglePack(_ pack: TermPack) {
        if activatedPacks.contains(pack.id) {
            deactivatePack(pack)
        } else {
            activatePack(pack)
        }
    }

    private func activatePack(_ pack: TermPack) {
        let existingOriginals = Set(entries.filter { $0.type == .term }.map { $0.original.lowercased() })
        let newTerms = pack.terms
            .filter { !existingOriginals.contains($0.lowercased()) }
            .map { (type: DictionaryEntryType.term, original: $0, replacement: nil as String?, caseSensitive: true) }

        if !newTerms.isEmpty {
            dictionaryService.addEntries(newTerms)
        }
        activatedPacks.insert(pack.id)
        saveActivatedPacks()
    }

    private func deactivatePack(_ pack: TermPack) {
        let packTermsLowered = Set(pack.terms.map { $0.lowercased() })
        let entriesToRemove = entries.filter { entry in
            entry.type == .term && packTermsLowered.contains(entry.original.lowercased())
        }
        if !entriesToRemove.isEmpty {
            dictionaryService.deleteEntries(entriesToRemove)
        }
        activatedPacks.remove(pack.id)
        saveActivatedPacks()
    }

    private func loadActivatedPacks() {
        if let saved = UserDefaults.standard.stringArray(forKey: Self.activatedPacksKey) {
            activatedPacks = Set(saved)
        }
    }

    private func saveActivatedPacks() {
        UserDefaults.standard.set(Array(activatedPacks), forKey: Self.activatedPacksKey)
    }
}
