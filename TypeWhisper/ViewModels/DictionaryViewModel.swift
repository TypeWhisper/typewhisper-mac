import Foundation
import AppKit
import UniformTypeIdentifiers
import Combine

// MARK: - Activated Term Pack State

struct ActivatedTermPackState: Codable {
    let packID: String
    let source: String
    let installedVersion: String?
    let installedTerms: [String]
    let installedCorrections: [TermPackCorrection]
}

// MARK: - Dictionary ViewModel

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
    @Published var activatedPackStates: [String: ActivatedTermPackState] = [:]

    private let dictionaryService: DictionaryService
    private var cancellables = Set<AnyCancellable>()
    private var selectedEntry: DictionaryEntry?

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
        migrateLegacyActivatedPacks()
        loadActivatedPackStates()
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
        activatedPackStates[pack.id] != nil
    }

    func togglePack(_ pack: TermPack) {
        if isPackActivated(pack) {
            deactivatePack(pack)
        } else {
            activatePack(pack)
        }
    }

    func activatePack(_ pack: TermPack) {
        var nextStates = activatedPackStates
        nextStates[pack.id] = makeActivatedState(for: pack)
        reconcileActivatedPacks(from: activatedPackStates, to: nextStates)
    }

    func deactivatePack(_ pack: TermPack) {
        var nextStates = activatedPackStates
        nextStates.removeValue(forKey: pack.id)
        reconcileActivatedPacks(from: activatedPackStates, to: nextStates)
    }

    func updatePack(_ pack: TermPack) {
        guard isPackActivated(pack) else { return }
        var nextStates = activatedPackStates
        nextStates[pack.id] = makeActivatedState(for: pack)
        reconcileActivatedPacks(from: activatedPackStates, to: nextStates)
    }

    func hasUpdate(for pack: TermPack) -> Bool {
        guard let state = activatedPackStates[pack.id],
              let installedVersion = state.installedVersion,
              let packVersion = pack.version else { return false }
        return TermPackRegistryService.compareVersions(packVersion, installedVersion) == .orderedDescending
    }

    /// Resolves a pack by ID from built-in + community packs
    func resolvePack(id: String) -> TermPack? {
        if let builtIn = TermPack.allPacks.first(where: { $0.id == id }) {
            return builtIn
        }
        return TermPackRegistryService.shared?.communityPacks.first(where: { $0.id == id })
    }

    // MARK: - Reconciliation

    /// Removes all pack-generated entries, then re-applies all active packs in deterministic order.
    private func makeActivatedState(for pack: TermPack) -> ActivatedTermPackState {
        ActivatedTermPackState(
            packID: pack.id,
            source: pack.source.rawValue,
            installedVersion: pack.version,
            installedTerms: pack.terms,
            installedCorrections: pack.corrections
        )
    }

    private func reconcileActivatedPacks(
        from previousStates: [String: ActivatedTermPackState],
        to nextStates: [String: ActivatedTermPackState]
    ) {
        // Step 1: Remove only entries that were previously installed by packs.
        removeSnapshotEntries(from: previousStates)

        // Step 2: Re-apply all active packs in deterministic order (built-in first, then community by ID)
        let sortedStates = nextStates.values.sorted { a, b in
            if a.source != b.source {
                return a.source == "builtIn"
            }
            return a.packID < b.packID
        }

        var newStates: [String: ActivatedTermPackState] = [:]
        for state in sortedStates {
            let actuallyAddedTerms = addTermEntries(state.installedTerms)
            let actuallyAddedCorrections = addCorrectionEntries(state.installedCorrections)

            newStates[state.packID] = ActivatedTermPackState(
                packID: state.packID,
                source: state.source,
                installedVersion: state.installedVersion,
                installedTerms: actuallyAddedTerms,
                installedCorrections: actuallyAddedCorrections
            )
        }

        // Step 3: Save updated snapshots
        activatedPackStates = newStates
        saveActivatedPackStates()
    }

    private func removeSnapshotEntries(from states: [String: ActivatedTermPackState]) {
        var termsToRemove = Set<String>()
        var correctionsToRemove = Set<String>() // "original|replacement" keys

        for state in states.values {
            for term in state.installedTerms {
                termsToRemove.insert(term.lowercased())
            }
            for correction in state.installedCorrections {
                correctionsToRemove.insert("\(correction.original.lowercased())|\(correction.replacement.lowercased())")
            }
        }

        let entriesToDelete = dictionaryService.entries.filter { entry in
            if entry.type == .term {
                return termsToRemove.contains(entry.original.lowercased())
            } else if entry.type == .correction, let replacement = entry.replacement {
                return correctionsToRemove.contains("\(entry.original.lowercased())|\(replacement.lowercased())")
            }
            return false
        }

        if !entriesToDelete.isEmpty {
            dictionaryService.deleteEntries(entriesToDelete)
        }
    }

    /// Adds term entries, skipping any that already exist. Returns the terms that were actually added.
    private func addTermEntries(_ terms: [String]) -> [String] {
        let existingOriginals = Set(dictionaryService.entries.filter { $0.type == .term }.map { $0.original.lowercased() })
        let newTerms = terms.filter { !existingOriginals.contains($0.lowercased()) }

        if !newTerms.isEmpty {
            let items = newTerms.map {
                (type: DictionaryEntryType.term, original: $0, replacement: nil as String?, caseSensitive: true)
            }
            dictionaryService.addEntries(items)
        }
        return newTerms
    }

    /// Adds correction entries, skipping any that already exist. Returns the corrections that were actually added.
    private func addCorrectionEntries(_ corrections: [TermPackCorrection]) -> [TermPackCorrection] {
        let existingKeys = Set(
            dictionaryService.entries
                .filter { $0.type == .correction }
                .compactMap { entry -> String? in
                    guard let replacement = entry.replacement else { return nil }
                    return "\(entry.original.lowercased())|\(replacement.lowercased())"
                }
        )

        let newCorrections = corrections.filter { correction in
            !existingKeys.contains("\(correction.original.lowercased())|\(correction.replacement.lowercased())")
        }

        if !newCorrections.isEmpty {
            let items = newCorrections.map {
                (type: DictionaryEntryType.correction, original: $0.original, replacement: $0.replacement as String?, caseSensitive: $0.caseSensitive)
            }
            dictionaryService.addEntries(items)
        }
        return newCorrections
    }

    // MARK: - Persistence

    private func loadActivatedPackStates() {
        guard let data = UserDefaults.standard.data(forKey: UserDefaultsKeys.activatedTermPackStates) else { return }
        do {
            let states = try JSONDecoder().decode([ActivatedTermPackState].self, from: data)
            activatedPackStates = Dictionary(uniqueKeysWithValues: states.map { ($0.packID, $0) })
        } catch {
            // Corrupted data - start fresh
            activatedPackStates = [:]
        }
    }

    private func saveActivatedPackStates() {
        let states = Array(activatedPackStates.values)
        if let data = try? JSONEncoder().encode(states) {
            UserDefaults.standard.set(data, forKey: UserDefaultsKeys.activatedTermPackStates)
        }
    }

    /// Migrate from legacy activatedTermPacks (Set<String>) to new snapshot-based system.
    /// Does NOT auto-reactivate packs - just cleans up the old key. Entries remain in dictionary.
    private func migrateLegacyActivatedPacks() {
        let legacyKey = UserDefaultsKeys.activatedTermPacks
        guard UserDefaults.standard.stringArray(forKey: legacyKey) != nil else { return }
        // Clear legacy key - packs will need to be re-activated
        UserDefaults.standard.removeObject(forKey: legacyKey)
    }
}
