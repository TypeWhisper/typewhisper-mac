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
    let requiresCommercialLicense: Bool?
}

private func dictionaryReplacementDisplayText(_ replacement: String) -> String {
    replacement.isEmpty ? "\"\"" : replacement
}

struct DictionaryEntryRow: Identifiable, Equatable {
    let id: UUID
    let type: DictionaryEntryType
    let original: String
    let replacement: String?
    let caseSensitive: Bool
    let isEnabled: Bool
    let termBoostingLabel: String
    let formattedCtcMinSimilarity: String

    var replacementDisplayText: String? {
        replacement.map(dictionaryReplacementDisplayText)
    }
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

    enum TermBoostingMode: String, CaseIterable, Identifiable {
        case automatic
        case strong
        case balanced
        case precise
        case advanced

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .automatic: return String(localized: "Auto")
            case .strong: return String(localized: "Strong")
            case .balanced: return String(localized: "Balanced")
            case .precise: return String(localized: "Precise")
            case .advanced: return String(localized: "Advanced")
            }
        }
    }

    @Published var filterTab: FilterTab = .all

    // Editor state
    @Published var isEditing = false
    @Published var isCreatingNew = false
    @Published var editType: DictionaryEntryType = .term
    @Published var editOriginal = ""
    @Published var editReplacement = ""
    @Published var editCaseSensitive = false
    @Published var editTermBoostingMode: TermBoostingMode = .automatic
    @Published var editAdvancedCtcMinSimilarity: Double = 0.65

    // Term Packs
    @Published var activatedPackStates: [String: ActivatedTermPackState] = [:]

    static let strongCtcMinSimilarity: Double = 0.50
    static let balancedCtcMinSimilarity: Double = 0.65
    static let preciseCtcMinSimilarity: Double = 0.80
    static let minimumAdvancedCtcMinSimilarity: Double = 0.40
    static let maximumAdvancedCtcMinSimilarity: Double = 0.95

    private let dictionaryService: DictionaryService
    private let licenseService: LicenseService?
    private let termPackRegistryService: TermPackRegistryService?
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

    var filteredEntryRows: [DictionaryEntryRow] {
        filteredEntries.map(row)
    }

    var termsCount: Int { dictionaryService.termsCount }
    var correctionsCount: Int { dictionaryService.correctionsCount }
    var enabledTermsCount: Int { dictionaryService.enabledTermsCount }
    var enabledCorrectionsCount: Int { dictionaryService.enabledCorrectionsCount }
    var editCtcMinSimilarity: Float? {
        switch editTermBoostingMode {
        case .automatic:
            return nil
        case .strong:
            return Float(Self.strongCtcMinSimilarity)
        case .balanced:
            return Float(Self.balancedCtcMinSimilarity)
        case .precise:
            return Float(Self.preciseCtcMinSimilarity)
        case .advanced:
            let value = min(
                max(editAdvancedCtcMinSimilarity, Self.minimumAdvancedCtcMinSimilarity),
                Self.maximumAdvancedCtcMinSimilarity
            )
            return Float(value)
        }
    }
    var hasCommercialLicense: Bool { licenseService?.hasCommercialLicense ?? false }
    var visibleBuiltInPacks: [TermPack] {
        TermPack.allPacks.filter { !$0.requiresCommercialLicense || hasCommercialLicense }
    }
    var visibleCommunityPacks: [TermPack] {
        (termPackRegistryService ?? TermPackRegistryService.shared)?
            .communityPacks
            .filter(canUsePack) ?? []
    }

    init(
        dictionaryService: DictionaryService,
        licenseService: LicenseService? = nil,
        termPackRegistryService: TermPackRegistryService? = nil
    ) {
        self.dictionaryService = dictionaryService
        self.licenseService = licenseService
        self.termPackRegistryService = termPackRegistryService
        self.entries = dictionaryService.entries
        migrateLegacyActivatedPacks()
        loadActivatedPackStates()
        reconcileCommercialPackAccess()
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

        licenseService?.$licenseStatus
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reconcileCommercialPackAccess()
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        if let registryService = termPackRegistryService ?? TermPackRegistryService.shared {
            registryService.$communityPacks
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    if self.hasCommercialLicense {
                        self.applyIndustryPreset(IndustryPreset.selected())
                    } else {
                        self.reconcileCommercialPackAccess()
                    }
                    self.objectWillChange.send()
                }
                .store(in: &cancellables)
        }
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
        resetTermBoostingEditor()
    }

    func startEditing(_ entry: DictionaryEntry) {
        selectedEntry = entry
        isCreatingNew = false
        isEditing = true
        editType = entry.type
        editOriginal = entry.original
        editReplacement = entry.replacement ?? ""
        editCaseSensitive = entry.caseSensitive
        setTermBoostingEditor(to: entry.type == .term ? entry.ctcMinSimilarity : nil)
    }

    func startEditingEntry(id: UUID) {
        guard let entry = entry(withID: id) else { return }
        startEditing(entry)
    }

    func cancelEditing() {
        isEditing = false
        isCreatingNew = false
        selectedEntry = nil
        editType = .term
        editOriginal = ""
        editReplacement = ""
        editCaseSensitive = false
        resetTermBoostingEditor()
    }

    func saveEditing() {
        guard !editOriginal.isEmpty else {
            error = String(localized: "Original text cannot be empty")
            return
        }

        let replacement = editType == .correction ? editReplacement : nil
        let ctcMinSimilarity = editType == .term ? editCtcMinSimilarity : nil

        if isCreatingNew {
            dictionaryService.addEntry(
                type: editType,
                original: editOriginal,
                replacement: replacement,
                caseSensitive: editCaseSensitive,
                ctcMinSimilarity: ctcMinSimilarity
            )
        } else if let entry = selectedEntry {
            dictionaryService.updateEntry(
                entry,
                original: editOriginal,
                replacement: replacement,
                caseSensitive: editCaseSensitive,
                ctcMinSimilarity: ctcMinSimilarity
            )
        }

        cancelEditing()
    }

    func deleteEntry(_ entry: DictionaryEntry) {
        dictionaryService.deleteEntry(entry)
    }

    func deleteEntry(id: UUID) {
        guard let entry = entry(withID: id) else { return }
        dictionaryService.deleteEntry(entry)
    }

    func toggleEntry(_ entry: DictionaryEntry) {
        dictionaryService.toggleEntry(entry)
    }

    func toggleEntry(id: UUID) {
        guard let entry = entry(withID: id) else { return }
        dictionaryService.toggleEntry(entry)
    }

    func clearError() {
        error = nil
    }

    func clearImportMessage() {
        importMessage = nil
    }

    func termBoostingLabel(for threshold: Float?) -> String {
        termBoostingMode(for: threshold).displayName
    }

    func formattedCtcMinSimilarity(_ threshold: Float?) -> String {
        guard let threshold else { return "" }
        return String(format: "%.2f", Double(threshold))
    }

    private func row(for entry: DictionaryEntry) -> DictionaryEntryRow {
        DictionaryEntryRow(
            id: entry.id,
            type: entry.type,
            original: entry.original,
            replacement: entry.replacement,
            caseSensitive: entry.caseSensitive,
            isEnabled: entry.isEnabled,
            termBoostingLabel: termBoostingLabel(for: entry.ctcMinSimilarity),
            formattedCtcMinSimilarity: formattedCtcMinSimilarity(entry.ctcMinSimilarity)
        )
    }

    private func entry(withID id: UUID) -> DictionaryEntry? {
        entries.first { $0.id == id }
    }

    private func resetTermBoostingEditor() {
        editTermBoostingMode = .automatic
        editAdvancedCtcMinSimilarity = Self.balancedCtcMinSimilarity
    }

    private func setTermBoostingEditor(to threshold: Float?) {
        editTermBoostingMode = termBoostingMode(for: threshold)
        if let threshold {
            editAdvancedCtcMinSimilarity = min(
                max(Double(threshold), Self.minimumAdvancedCtcMinSimilarity),
                Self.maximumAdvancedCtcMinSimilarity
            )
        } else {
            editAdvancedCtcMinSimilarity = Self.balancedCtcMinSimilarity
        }
    }

    private func termBoostingMode(for threshold: Float?) -> TermBoostingMode {
        guard let threshold else { return .automatic }
        let value = Double(threshold)
        if abs(value - Self.strongCtcMinSimilarity) < 0.001 { return .strong }
        if abs(value - Self.balancedCtcMinSimilarity) < 0.001 { return .balanced }
        if abs(value - Self.preciseCtcMinSimilarity) < 0.001 { return .precise }
        return .advanced
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
        guard canUsePack(pack) else {
            error = String(localized: "This industry term pack requires an active commercial license.")
            return
        }

        if isPackActivated(pack) {
            deactivatePack(pack)
        } else {
            activatePack(pack)
        }
    }

    func activatePack(_ pack: TermPack) {
        guard canUsePack(pack) else {
            error = String(localized: "This industry term pack requires an active commercial license.")
            return
        }

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

    func applyIndustryPreset(_ preset: IndustryPreset) {
        UserDefaults.standard.set(preset.rawValue, forKey: UserDefaultsKeys.selectedIndustryPreset)

        guard let packID = preset.termPackID,
              hasCommercialLicense,
              let pack = resolvePack(id: packID),
              !isPackActivated(pack) else {
            return
        }

        activatePack(pack)
    }

    func canUsePack(_ pack: TermPack) -> Bool {
        !pack.requiresCommercialLicense || hasCommercialLicense
    }

    private func reconcileCommercialPackAccess() {
        if hasCommercialLicense {
            applyIndustryPreset(IndustryPreset.selected())
            return
        }

        let industryPackIDs = Set(IndustryPreset.allCases.compactMap(\.termPackID))
        let allowedStates = activatedPackStates.filter { packID, state in
            state.requiresCommercialLicense != true && !industryPackIDs.contains(packID)
        }

        guard allowedStates.count != activatedPackStates.count else { return }
        reconcileActivatedPacks(from: activatedPackStates, to: allowedStates)
    }

    /// Resolves a pack by ID from built-in + community packs
    func resolvePack(id: String) -> TermPack? {
        if let builtIn = TermPack.allPacks.first(where: { $0.id == id }) {
            return builtIn
        }
        return (termPackRegistryService ?? TermPackRegistryService.shared)?
            .communityPacks
            .first(where: { $0.id == id })
    }

    // MARK: - Reconciliation

    /// Removes all pack-generated entries, then re-applies all active packs in deterministic order.
    private func makeActivatedState(for pack: TermPack) -> ActivatedTermPackState {
        ActivatedTermPackState(
            packID: pack.id,
            source: pack.source.rawValue,
            installedVersion: pack.version,
            installedTerms: pack.terms,
            installedCorrections: pack.corrections,
            requiresCommercialLicense: pack.requiresCommercialLicense
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
                installedCorrections: actuallyAddedCorrections,
                requiresCommercialLicense: state.requiresCommercialLicense
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
