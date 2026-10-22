import Foundation
import AppKit
import UniformTypeIdentifiers
import Combine
import TypeWhisperPluginSDK

// MARK: - Activated Term Pack State

struct ActivatedTermPackState: Codable {
    let packID: String
    let source: String
    let installedVersion: String?
    let installedTerms: [String]
    let installedCorrections: [TermPackCorrection]
    let requiresCommercialLicense: Bool?
}

/// Per-entry settings of a deactivated pack, restored when the pack is activated again.
struct TermPackEntryOverride: Codable, Equatable {
    let isEnabled: Bool
    let ctcMinSimilarity: Float?
}

/// A local pack import that would replace an imported pack with the same ID.
struct LocalTermPackReplacement: Identifiable, Equatable {
    let existingName: String
    let file: LocalTermPackFile

    var id: String { file.id }
}

/// Why a local pack cannot be turned on: a built-in or registry pack uses its ID.
enum LocalTermPackConflict: Equatable {
    case builtIn
    case community

    func error(forID id: String) -> LocalTermPackError {
        switch self {
        case .builtIn: .builtInID(id)
        case .community: .communityID(id)
        }
    }
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
    let isRegex: Bool
    let isEnabled: Bool
    let source: DictionaryEntrySource
    let termBoostingLabel: String
    let formattedCtcMinSimilarity: String

    var replacementDisplayText: String? {
        replacement.map(dictionaryReplacementDisplayText)
    }
}

enum DictionaryListRowID: Hashable {
    case entry(UUID)
    case correctionGroup(String)
}

struct DictionaryCorrectionGroupRow: Identifiable, Equatable {
    let replacement: String
    let aliases: [DictionaryEntryRow]

    var id: DictionaryListRowID {
        .correctionGroup(replacement)
    }

    var replacementDisplayText: String {
        dictionaryReplacementDisplayText(replacement)
    }
}

enum DictionaryListRow: Identifiable, Equatable {
    case entry(DictionaryEntryRow)
    case correctionGroup(DictionaryCorrectionGroupRow)

    var id: DictionaryListRowID {
        switch self {
        case .entry(let row):
            return .entry(row.id)
        case .correctionGroup(let group):
            return group.id
        }
    }

    var entryRows: [DictionaryEntryRow] {
        switch self {
        case .entry(let row):
            return [row]
        case .correctionGroup(let group):
            return group.aliases
        }
    }
}

enum DictionaryResetAction: String, Identifiable, Equatable {
    case clearAutoLearnedCorrections
    case resetCustomDictionary
    case deactivateAllTermPacks

    var id: String { rawValue }
}

struct DictionaryResetRequest: Identifiable, Equatable {
    let action: DictionaryResetAction
    let termCount: Int
    let manualCorrectionCount: Int
    let autoLearnedCorrectionCount: Int
    let activePackCount: Int

    var id: String { action.id }
    var correctionCount: Int { manualCorrectionCount + autoLearnedCorrectionCount }
    var entryCount: Int { termCount + correctionCount }

    var canPerform: Bool {
        switch action {
        case .clearAutoLearnedCorrections:
            return autoLearnedCorrectionCount > 0
        case .resetCustomDictionary:
            return entryCount > 0
        case .deactivateAllTermPacks:
            return activePackCount > 0
        }
    }
}

// MARK: - Dictionary Terms Setting Suggestion

enum DictionaryTermsSettingActivation: Equatable {
    case enabling
    case failed(String)
}

struct DictionaryTermsSettingSuggestion: Equatable {
    let providerId: String
    let engineName: String
    let summary: String
    let activation: DictionaryTermsSettingActivation?
}

/// Decides when the Dictionary page suggests the plugin setting an engine needs for Terms.
enum DictionaryTermsSettingSuggestionPolicy {
    /// Adding Terms raises the suggestion when the selected engine ignores them until a
    /// plugin setting is on, the plugin can turn it on, and the user has not declined.
    static func shouldSuggest(
        afterAdding addedType: DictionaryEntryType,
        support: DictionaryTermsSupport?,
        canEnable: Bool,
        isDismissed: Bool
    ) -> Bool {
        addedType == .term && support == .requiresPluginSetting && canEnable && !isDismissed
    }

    /// A raised suggestion stays while the setting is off or while enabling runs or failed,
    /// so download progress and errors remain visible after the plugin reports support.
    static func isVisible(
        support: DictionaryTermsSupport?,
        canEnable: Bool,
        isDismissed: Bool,
        activation: DictionaryTermsSettingActivation?
    ) -> Bool {
        guard canEnable, !isDismissed else { return false }
        return activation != nil || support == .requiresPluginSetting
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
    @Published private(set) var pendingResetRequest: DictionaryResetRequest?

    // Filter
    enum FilterTab: Int, CaseIterable {
        case all, terms, corrections, autoLearned, termPacks
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
    @Published var searchQuery = ""

    // Editor state
    @Published var isEditing = false
    @Published var isCreatingNew = false
    @Published var editType: DictionaryEntryType = .term
    @Published var editOriginal = ""
    @Published var editReplacement = ""
    @Published var editCaseSensitive = false
    @Published var editIsRegex = false
    @Published var editTermBoostingMode: TermBoostingMode = .automatic
    @Published var editAdvancedCtcMinSimilarity: Double = 0.65
    @Published private(set) var lockedCorrectionReplacement: String?

    // Term Packs
    @Published var activatedPackStates: [String: ActivatedTermPackState] = [:]
    /// Pack ID → entry key → settings the user changed before deactivating that pack.
    private var inactivePackEntryOverrides: [String: [String: TermPackEntryOverride]] = [:]

    // Local Term Packs
    @Published private(set) var localTermPackImportError: String?
    @Published private(set) var pendingLocalTermPackReplacement: LocalTermPackReplacement?
    @Published private(set) var pendingLocalTermPackRemoval: TermPack?

    // Engine setting suggestion for Terms
    @Published private(set) var termsSettingSuggestionProviderId: String?
    @Published private(set) var termsSettingActivations: [String: DictionaryTermsSettingActivation] = [:]
    @Published private var dismissedTermsSettingProviderIds: Set<String> = []

    static let strongCtcMinSimilarity: Double = 0.50
    static let balancedCtcMinSimilarity: Double = 0.65
    static let preciseCtcMinSimilarity: Double = 0.80
    static let minimumAdvancedCtcMinSimilarity: Double = 0.40
    static let maximumAdvancedCtcMinSimilarity: Double = 0.95

    private let dictionaryService: DictionaryService
    private let licenseService: LicenseService?
    private let termPackRegistryService: TermPackRegistryService?
    private let localTermPackStore: LocalTermPackStore?
    private let defaults: UserDefaults
    private let selectedTranscriptionEngine: @MainActor () -> (any TranscriptionEnginePlugin)?
    private let transcriptionEngineLookup: @MainActor (String) -> (any TranscriptionEnginePlugin)?
    private var cancellables = Set<AnyCancellable>()
    private var selectedEntry: DictionaryEntry?

    private var entriesForSelectedFilter: [DictionaryEntry] {
        switch filterTab {
        case .all:
            return entries
        case .terms:
            return entries.filter { $0.type == .term }
        case .corrections:
            return entries.filter { $0.type == .correction }
        case .autoLearned:
            return entries.filter {
                $0.type == .correction && $0.source == .autoLearned
            }
        case .termPacks:
            return []
        }
    }

    var filteredListRows: [DictionaryListRow] {
        let listRows = groupedListRows(from: entriesForSelectedFilter.map(row))

        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return listRows }

        return listRows.filter { listRow in
            switch listRow {
            case .entry(let row):
                return rowMatchesSearch(row, query: query)
            case .correctionGroup(let group):
                return group.replacement.localizedCaseInsensitiveContains(query) ||
                    group.aliases.contains { rowMatchesSearch($0, query: query) }
            }
        }
    }

    var filteredEntryRows: [DictionaryEntryRow] {
        filteredListRows.flatMap(\.entryRows)
    }

    var filteredEntries: [DictionaryEntry] {
        let visibleIDs = Set(filteredEntryRows.map(\.id))
        return entriesForSelectedFilter.filter { visibleIDs.contains($0.id) }
    }

    var hasActiveSearch: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        registryCommunityPacks.filter(canUsePack)
    }
    /// Imported local packs; empty when this view model has no local pack store.
    var visibleLocalPacks: [TermPack] {
        localTermPackStore?.packs ?? []
    }
    var supportsLocalTermPacks: Bool { localTermPackStore != nil }

    /// Every loaded registry pack, including commercial packs this license cannot use.
    private var registryCommunityPacks: [TermPack] {
        (termPackRegistryService ?? TermPackRegistryService.shared)?.communityPacks ?? []
    }

    init(
        dictionaryService: DictionaryService,
        licenseService: LicenseService? = nil,
        termPackRegistryService: TermPackRegistryService? = nil,
        localTermPackStore: LocalTermPackStore? = nil,
        defaults: UserDefaults = .standard,
        selectedTranscriptionEngine: @escaping @MainActor () -> (any TranscriptionEnginePlugin)? = { nil },
        transcriptionEngineLookup: @escaping @MainActor (String) -> (any TranscriptionEnginePlugin)? = {
            PluginManager.shared?.transcriptionEngine(for: $0)
        }
    ) {
        self.dictionaryService = dictionaryService
        self.licenseService = licenseService
        self.termPackRegistryService = termPackRegistryService
        self.localTermPackStore = localTermPackStore
        self.defaults = defaults
        self.selectedTranscriptionEngine = selectedTranscriptionEngine
        self.transcriptionEngineLookup = transcriptionEngineLookup
        self.entries = dictionaryService.entries
        self.dismissedTermsSettingProviderIds = Set(
            defaults.stringArray(forKey: UserDefaultsKeys.dismissedDictionaryTermsSettingSuggestions) ?? []
        )
        migrateLegacyActivatedPacks()
        loadActivatedPackStates()
        loadInactivePackEntryOverrides()
        migratePackTermsToPreciseBoosting()
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

        localTermPackStore?.$packs
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    // MARK: - Editor Actions

    var editRegexError: String? {
        guard editType == .correction, editIsRegex, !editOriginal.isEmpty else { return nil }
        guard (try? NSRegularExpression(pattern: editOriginal)) == nil else { return nil }
        return String(localized: "Invalid regular expression.")
    }

    var canSaveEditing: Bool {
        !editOriginal.isEmpty && editValidationError == nil
    }

    var editValidationError: String? {
        if let editRegexError { return editRegexError }
        if dictionaryService.duplicateEntry(
            type: editType, original: editOriginal, isRegex: editIsRegex,
            excluding: isCreatingNew ? nil : selectedEntry?.id
        ) != nil {
            return String(localized: "An entry with this original and matching mode already exists.")
        }
        return nil
    }

    func startCreating(type: DictionaryEntryType = .term) {
        selectedEntry = nil
        isCreatingNew = true
        isEditing = true
        lockedCorrectionReplacement = nil
        editType = type
        editOriginal = ""
        editReplacement = ""
        editCaseSensitive = false
        editIsRegex = false
        resetTermBoostingEditor()
    }

    func startCreatingCorrectionAlias(replacement: String) {
        guard !replacement.isEmpty else { return }
        startCreating(type: .correction)
        lockedCorrectionReplacement = replacement
        editReplacement = replacement
    }

    func startEditing(_ entry: DictionaryEntry) {
        selectedEntry = entry
        isCreatingNew = false
        isEditing = true
        lockedCorrectionReplacement = nil
        editType = entry.type
        editOriginal = entry.original
        editReplacement = entry.replacement ?? ""
        editCaseSensitive = entry.caseSensitive
        editIsRegex = entry.isRegex
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
        editIsRegex = false
        lockedCorrectionReplacement = nil
        resetTermBoostingEditor()
    }

    func saveEditing() {
        guard !editOriginal.isEmpty else {
            error = String(localized: "Original text cannot be empty")
            return
        }
        if let editValidationError {
            error = editValidationError
            return
        }

        let replacement = editType == .correction
            ? (lockedCorrectionReplacement ?? editReplacement)
            : nil
        let ctcMinSimilarity = editType == .term ? editCtcMinSimilarity : nil

        if isCreatingNew {
            guard dictionaryService.addEntry(
                type: editType,
                original: editOriginal,
                replacement: replacement,
                caseSensitive: editCaseSensitive,
                isRegex: editType == .correction && editIsRegex,
                ctcMinSimilarity: ctcMinSimilarity
            ) else {
                error = String(localized: "Could not save the dictionary entry.")
                return
            }
            suggestTermsSettingIfNeeded(afterAdding: editType)
        } else if let entry = selectedEntry {
            guard dictionaryService.updateEntry(
                entry,
                original: editOriginal,
                replacement: replacement,
                caseSensitive: editCaseSensitive,
                isRegex: editType == .correction && editIsRegex,
                ctcMinSimilarity: ctcMinSimilarity
            ) else {
                error = String(localized: "Could not save the dictionary entry.")
                return
            }
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

    func setEntryEnabled(id: UUID, enabled: Bool) {
        guard let entry = entry(withID: id) else { return }
        dictionaryService.setEntryEnabled(entry, enabled: enabled)
    }

    func clearError() {
        error = nil
    }

    func clearImportMessage() {
        importMessage = nil
    }

    // MARK: - Reset Actions

    func resetRequest(for action: DictionaryResetAction) -> DictionaryResetRequest {
        switch action {
        case .clearAutoLearnedCorrections:
            let autoLearnedCorrections = dictionaryService.entries.filter {
                $0.type == .correction && $0.source == .autoLearned
            }
            return DictionaryResetRequest(
                action: action,
                termCount: 0,
                manualCorrectionCount: 0,
                autoLearnedCorrectionCount: autoLearnedCorrections.count,
                activePackCount: 0
            )

        case .resetCustomDictionary:
            let packEntryIDs = managedPackEntryIDs()
            let customEntries = dictionaryService.entries.filter { !packEntryIDs.contains($0.id) }
            return DictionaryResetRequest(
                action: action,
                termCount: customEntries.filter { $0.type == .term }.count,
                manualCorrectionCount: customEntries.filter {
                    $0.type == .correction && $0.source == .manual
                }.count,
                autoLearnedCorrectionCount: customEntries.filter {
                    $0.type == .correction && $0.source == .autoLearned
                }.count,
                activePackCount: activatedPackStates.count
            )

        case .deactivateAllTermPacks:
            let packEntryIDs = managedPackEntryIDs()
            let packEntries = dictionaryService.entries.filter { packEntryIDs.contains($0.id) }
            return DictionaryResetRequest(
                action: action,
                termCount: packEntries.filter { $0.type == .term }.count,
                manualCorrectionCount: packEntries.filter { $0.type == .correction }.count,
                autoLearnedCorrectionCount: 0,
                activePackCount: activatedPackStates.count
            )
        }
    }

    func requestReset(_ action: DictionaryResetAction) {
        let request = resetRequest(for: action)
        guard request.canPerform else { return }
        pendingResetRequest = request
    }

    func cancelReset() {
        pendingResetRequest = nil
    }

    func confirmReset() {
        guard let action = pendingResetRequest?.action else { return }
        pendingResetRequest = nil

        do {
            switch action {
            case .clearAutoLearnedCorrections:
                let ids = Set(dictionaryService.entries.filter {
                    $0.type == .correction && $0.source == .autoLearned
                }.map(\.id))
                try dictionaryService.deleteEntries(ids: ids)

            case .resetCustomDictionary:
                let packEntryIDs = managedPackEntryIDs()
                let ids = Set(dictionaryService.entries.filter {
                    !packEntryIDs.contains($0.id)
                }.map(\.id))
                try dictionaryService.deleteEntries(ids: ids)

            case .deactivateAllTermPacks:
                let ids = managedPackEntryIDs()
                try dictionaryService.deleteEntries(ids: ids)
                activatedPackStates = [:]
                saveActivatedPackStates()
                inactivePackEntryOverrides = [:]
                saveInactivePackEntryOverrides()
            }
        } catch {
            self.error = error.localizedDescription
        }
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
            isRegex: entry.isRegex,
            isEnabled: entry.isEnabled,
            source: entry.source,
            termBoostingLabel: termBoostingLabel(for: entry.ctcMinSimilarity),
            formattedCtcMinSimilarity: formattedCtcMinSimilarity(entry.ctcMinSimilarity)
        )
    }

    private func groupedListRows(from rows: [DictionaryEntryRow]) -> [DictionaryListRow] {
        var listRows: [DictionaryListRow] = []
        var groupIndexes: [String: Int] = [:]

        for row in rows {
            guard row.type == .correction,
                  let replacement = row.replacement,
                  !replacement.isEmpty else {
                listRows.append(.entry(row))
                continue
            }

            if let groupIndex = groupIndexes[replacement],
               case .correctionGroup(let existingGroup) = listRows[groupIndex] {
                listRows[groupIndex] = .correctionGroup(DictionaryCorrectionGroupRow(
                    replacement: replacement,
                    aliases: existingGroup.aliases + [row]
                ))
            } else {
                groupIndexes[replacement] = listRows.count
                listRows.append(.correctionGroup(DictionaryCorrectionGroupRow(
                    replacement: replacement,
                    aliases: [row]
                )))
            }
        }

        return listRows
    }

    private func rowMatchesSearch(_ row: DictionaryEntryRow, query: String) -> Bool {
        row.original.localizedCaseInsensitiveContains(query) ||
            (row.replacement?.localizedCaseInsensitiveContains(query) ?? false)
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

    // MARK: - Engine Setting Suggestion

    /// The suggestion shown above the dictionary, if the last added Terms raised one.
    var visibleTermsSettingSuggestion: DictionaryTermsSettingSuggestion? {
        guard let providerId = termsSettingSuggestionProviderId,
              let engine = transcriptionEngineLookup(providerId),
              let enabler = engine as? any DictionaryTermsSettingEnabling else {
            return nil
        }
        let activation = termsSettingActivations[providerId]
        guard DictionaryTermsSettingSuggestionPolicy.isVisible(
            support: enabler.dictionaryTermsSupport,
            canEnable: true,
            isDismissed: dismissedTermsSettingProviderIds.contains(providerId),
            activation: activation
        ) else {
            return nil
        }
        return DictionaryTermsSettingSuggestion(
            providerId: providerId,
            engineName: engine.providerDisplayName,
            summary: enabler.dictionaryTermsSettingSummary,
            activation: activation
        )
    }

    func suggestTermsSettingIfNeeded(afterAdding addedType: DictionaryEntryType) {
        guard addedType == .term, let engine = selectedTranscriptionEngine() else { return }
        let providerId = engine.providerId
        guard DictionaryTermsSettingSuggestionPolicy.shouldSuggest(
            afterAdding: addedType,
            support: (engine as? any DictionaryTermsCapabilityProviding)?.dictionaryTermsSupport,
            canEnable: engine is any DictionaryTermsSettingEnabling,
            isDismissed: dismissedTermsSettingProviderIds.contains(providerId)
        ) else {
            return
        }
        termsSettingSuggestionProviderId = providerId
    }

    func termsSettingActivation(for providerId: String) -> DictionaryTermsSettingActivation? {
        termsSettingActivations[providerId]
    }

    func enableTermsSetting(for engine: any TranscriptionEnginePlugin) {
        guard let enabler = engine as? any DictionaryTermsSettingEnabling else { return }
        let providerId = engine.providerId
        guard termsSettingActivations[providerId] != .enabling else { return }

        termsSettingActivations[providerId] = .enabling
        Task { [weak self] in
            do {
                try await enabler.enableDictionaryTermsSetting()
                self?.finishTermsSettingActivation(providerId: providerId, failure: nil)
            } catch {
                self?.finishTermsSettingActivation(providerId: providerId, failure: error.localizedDescription)
            }
        }
    }

    func enableSuggestedTermsSetting() {
        guard let providerId = termsSettingSuggestionProviderId,
              let engine = transcriptionEngineLookup(providerId) else { return }
        enableTermsSetting(for: engine)
    }

    /// "Not now" is remembered per engine, so adding more Terms does not ask again.
    /// The engine overview keeps offering the setting.
    func dismissTermsSettingSuggestion() {
        guard let providerId = termsSettingSuggestionProviderId else { return }
        termsSettingSuggestionProviderId = nil
        if case .failed = termsSettingActivations[providerId] {
            termsSettingActivations[providerId] = nil
        }
        dismissedTermsSettingProviderIds.insert(providerId)
        defaults.set(
            dismissedTermsSettingProviderIds.sorted(),
            forKey: UserDefaultsKeys.dismissedDictionaryTermsSettingSuggestions
        )
    }

    /// The suggestion belongs to the moment Terms were added; leaving the page ends it.
    func clearTermsSettingSuggestion() {
        guard let providerId = termsSettingSuggestionProviderId,
              termsSettingActivations[providerId] == nil else { return }
        termsSettingSuggestionProviderId = nil
    }

    private func finishTermsSettingActivation(providerId: String, failure: String?) {
        if let failure {
            termsSettingActivations[providerId] = .failed(failure)
        } else {
            termsSettingActivations[providerId] = nil
            if termsSettingSuggestionProviderId == providerId {
                termsSettingSuggestionProviderId = nil
            }
        }
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
            importDictionary(data: try Data(contentsOf: url))
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Adds the entries of a dictionary export. A term pack file picked here is imported as a
    /// local pack instead, and the Term Packs tab opens to show it.
    func importDictionary(data: Data) {
        do {
            let parsed = try DictionaryExporter.parseJSON(data)
            guard !parsed.isEmpty else {
                error = String(localized: "The file contains no dictionary entries.")
                return
            }
            let termsCountBeforeImport = dictionaryService.termsCount
            let result = DictionaryExporter.importEntries(parsed, into: dictionaryService)
            if dictionaryService.termsCount > termsCountBeforeImport {
                suggestTermsSettingIfNeeded(afterAdding: .term)
            }

            if result.skipped > 0 {
                importMessage = String(localized: "\(result.imported) entries imported, \(result.skipped) duplicates skipped.")
            } else {
                importMessage = String(localized: "\(result.imported) entries imported.")
            }
        } catch DictionaryImportError.invalidFormat where isLocalTermPackFile(data) {
            filterTab = .termPacks
            importLocalTermPack(data: data)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func isLocalTermPackFile(_ data: Data) -> Bool {
        supportsLocalTermPacks && (try? LocalTermPackFile.decode(data)) != nil
    }

    // MARK: - Term Packs

    func isPackActivated(_ pack: TermPack) -> Bool {
        activatedState(for: pack) != nil
    }

    /// The activation state of this pack. A local pack and a registry pack may end up with the
    /// same ID (a community pack published after the import); their states never stand in for
    /// each other. Built-in and community packs keep matching by ID alone.
    private func activatedState(for pack: TermPack) -> ActivatedTermPackState? {
        guard let state = activatedPackStates[pack.id] else { return nil }
        let stateIsLocal = state.source == TermPack.Source.local.rawValue
        return stateIsLocal == (pack.source == .local) ? state : nil
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
            if isPackActivated(pack), !pack.terms.isEmpty {
                suggestTermsSettingIfNeeded(afterAdding: .term)
            }
        }
    }

    func activatePack(_ pack: TermPack) {
        guard canUsePack(pack) else {
            error = String(localized: "This industry term pack requires an active commercial license.")
            return
        }
        // Built-in and registry packs keep their IDs; a local pack never takes one over.
        if let conflict = localPackConflict(for: pack) {
            error = conflict.error(forID: pack.id).localizedDescription
            return
        }

        var nextStates = activatedPackStates
        nextStates[pack.id] = makeActivatedState(for: pack)
        reconcileActivatedPacks(from: activatedPackStates, to: nextStates)
    }

    func deactivatePack(_ pack: TermPack) {
        guard isPackActivated(pack) else { return }
        var nextStates = activatedPackStates
        nextStates.removeValue(forKey: pack.id)
        reconcileActivatedPacks(from: activatedPackStates, to: nextStates)
    }

    /// Turns a pack off like `deactivatePack`, but throws when its entries could not be deleted;
    /// the pack then stays on. A pack that is already off succeeds.
    private func deactivatePackRemovingEntries(_ pack: TermPack) throws {
        guard isPackActivated(pack) else { return }
        var nextStates = activatedPackStates
        nextStates.removeValue(forKey: pack.id)
        try applyActivatedPacks(from: activatedPackStates, to: nextStates, throwsWhenDeletionFails: true)
    }

    func updatePack(_ pack: TermPack) {
        guard isPackActivated(pack) else { return }
        var nextStates = activatedPackStates
        nextStates[pack.id] = makeActivatedState(for: pack)
        reconcileActivatedPacks(from: activatedPackStates, to: nextStates)
    }

    func hasUpdate(for pack: TermPack) -> Bool {
        guard let state = activatedState(for: pack),
              let installedVersion = state.installedVersion,
              let packVersion = pack.version else { return false }
        return TermPackRegistryService.compareVersions(packVersion, installedVersion) == .orderedDescending
    }

    func applyIndustryPreset(_ preset: IndustryPreset) {
        defaults.set(preset.rawValue, forKey: UserDefaultsKeys.selectedIndustryPreset)

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

        let allowedStates = activatedPackStates.filter { packID, state in
            state.requiresCommercialLicense != true && !Self.industryPackIDs.contains(packID)
        }

        guard allowedStates.count != activatedPackStates.count else { return }
        reconcileActivatedPacks(from: activatedPackStates, to: allowedStates)
    }

    /// Registry IDs of the commercial industry packs, known even before the registry loads.
    private static let industryPackIDs = Set(IndustryPreset.allCases.compactMap(\.termPackID))

    /// Resolves a pack by ID from built-in + community packs
    func resolvePack(id: String) -> TermPack? {
        if let builtIn = TermPack.allPacks.first(where: { $0.id == id }) {
            return builtIn
        }
        return (termPackRegistryService ?? TermPackRegistryService.shared)?
            .communityPacks
            .first(where: { $0.id == id })
    }

    // MARK: - Local Term Packs

    /// The built-in or registry pack that owns this local pack's ID, if any.
    func localPackConflict(for pack: TermPack) -> LocalTermPackConflict? {
        guard pack.source == .local else { return nil }
        return reservedPackConflict(forID: pack.id)
    }

    func importLocalTermPackFromFile() {
        guard supportsLocalTermPacks else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = String(localized: "Select a term pack JSON file to import.")

        guard panel.runModal() == .OK, let url = panel.url else { return }
        importLocalTermPack(from: url)
    }

    func importLocalTermPack(from url: URL) {
        do {
            importLocalTermPack(data: try Self.readLocalTermPackFile(at: url))
        } catch {
            localTermPackImportError = Self.localTermPackImportMessage(for: error)
        }
    }

    /// Validates the file and adds it as a local pack. A pack with the same ID is only replaced
    /// after `confirmLocalTermPackReplacement()`. The import leaves a new pack off.
    func importLocalTermPack(data: Data) {
        guard let localTermPackStore else { return }
        do {
            let file = try LocalTermPackFile.decode(data)
            try checkLocalTermPackID(file.id)
            if let existing = localTermPackStore.pack(withID: file.id) {
                pendingLocalTermPackReplacement = LocalTermPackReplacement(existingName: existing.name, file: file)
                return
            }
            try saveImportedLocalTermPack(file)
        } catch {
            localTermPackImportError = Self.localTermPackImportMessage(for: error)
        }
    }

    func confirmLocalTermPackReplacement() {
        guard let replacement = pendingLocalTermPackReplacement else { return }
        pendingLocalTermPackReplacement = nil
        do {
            // The registry may have loaded a pack with this ID while the question was open.
            try checkLocalTermPackID(replacement.file.id)
            try saveImportedLocalTermPack(replacement.file)
        } catch {
            localTermPackImportError = Self.localTermPackImportMessage(for: error)
        }
    }

    func cancelLocalTermPackReplacement() {
        pendingLocalTermPackReplacement = nil
    }

    func clearLocalTermPackImportError() {
        localTermPackImportError = nil
    }

    func exportLocalTermPackToFile(_ pack: TermPack) {
        guard let data = exportedLocalTermPackData(id: pack.id) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(pack.id).json"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            self.error = String(localized: "The term pack could not be exported. \(error.localizedDescription)")
        }
    }

    /// The pack file as stored, in the registry format, ready to import on another Mac.
    func exportedLocalTermPackData(id: String) -> Data? {
        try? localTermPackStore?.file(withID: id)?.encodedData()
    }

    func requestLocalTermPackRemoval(_ pack: TermPack) {
        guard pack.source == .local, localTermPackStore?.pack(withID: pack.id) != nil else { return }
        pendingLocalTermPackRemoval = pack
    }

    func cancelLocalTermPackRemoval() {
        pendingLocalTermPackRemoval = nil
    }

    /// Removes the entries the pack added to the dictionary, then deletes the pack file.
    func confirmLocalTermPackRemoval() {
        guard let pack = pendingLocalTermPackRemoval, let localTermPackStore else { return }
        pendingLocalTermPackRemoval = nil

        do {
            // Entries first: if they cannot be removed, the file stays, so the removal can be tried again.
            try deactivatePackRemovingEntries(pack)
            try localTermPackStore.remove(id: pack.id)
        } catch {
            self.error = String(localized: "The term pack could not be removed. \(error.localizedDescription)")
            return
        }
        // Forget per-entry settings, unless a registry pack with the same ID may own them.
        if reservedPackConflict(forID: pack.id) == nil,
           inactivePackEntryOverrides.removeValue(forKey: pack.id) != nil {
            saveInactivePackEntryOverrides()
        }
    }

    private func saveImportedLocalTermPack(_ file: LocalTermPackFile) throws {
        guard let localTermPackStore else { return }
        try localTermPackStore.save(file)

        // The file defines the pack: when it is on, its entries follow the imported file.
        let pack = file.termPack
        if isPackActivated(pack) {
            updatePack(pack)
            importMessage = String(localized: "“\(pack.name)” was imported, and its dictionary entries were updated.")
        } else {
            importMessage = String(localized: "“\(pack.name)” was added to Local Packs. Turn it on to add its entries to the dictionary.")
        }
    }

    private func checkLocalTermPackID(_ id: String) throws {
        if let conflict = reservedPackConflict(forID: id) {
            throw conflict.error(forID: id)
        }
    }

    /// Built-in and registry packs own their IDs. Registry IDs are known from the loaded
    /// registry, the industry presets and packs that are on while the registry is offline.
    private func reservedPackConflict(forID id: String) -> LocalTermPackConflict? {
        if TermPack.builtInIDs.contains(id) { return .builtIn }
        if Self.industryPackIDs.contains(id) || registryCommunityPacks.contains(where: { $0.id == id }) {
            return .community
        }
        if let state = activatedPackStates[id], state.source != TermPack.Source.local.rawValue {
            return state.source == TermPack.Source.builtIn.rawValue ? .builtIn : .community
        }
        return nil
    }

    private static func readLocalTermPackFile(at url: URL) throws -> Data {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > LocalTermPackFile.maximumFileSize {
            throw LocalTermPackError.fileTooLarge
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw LocalTermPackError.unreadableFile
        }
    }

    private static func localTermPackImportMessage(for error: any Error) -> String {
        if let packError = error as? LocalTermPackError {
            return packError.localizedDescription
        }
        return String(localized: "The term pack could not be saved. \(error.localizedDescription)")
    }

    // MARK: - Reconciliation

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

    /// Re-applies all active packs in deterministic order. Entries a pack installed earlier
    /// stay in place, so per-entry boosting and enabled overrides survive toggling other packs
    /// and pack updates. Overrides of a deactivated pack are kept until it is activated again.
    /// Entries that no active pack contains any more are removed.
    private func reconcileActivatedPacks(
        from previousStates: [String: ActivatedTermPackState],
        to nextStates: [String: ActivatedTermPackState]
    ) {
        // A failed deletion is logged by DictionaryService, and the states follow the request.
        try? applyActivatedPacks(from: previousStates, to: nextStates, throwsWhenDeletionFails: false)
    }

    /// With `throwsWhenDeletionFails`, a failed deletion of stale pack entries throws before
    /// the dictionary, the pack states or the entry overrides change.
    private func applyActivatedPacks(
        from previousStates: [String: ActivatedTermPackState],
        to nextStates: [String: ActivatedTermPackState],
        throwsWhenDeletionFails: Bool
    ) throws {
        let previouslyManagedIDs = managedPackEntryIDs(from: previousStates)
        var reusableEntries: [String: DictionaryEntry] = [:]
        var claimedKeys = Set<String>()

        for entry in dictionaryService.entries {
            guard let key = Self.packEntryKey(for: entry) else { continue }
            if previouslyManagedIDs.contains(entry.id) {
                reusableEntries[key] = reusableEntries[key] ?? entry
            } else {
                claimedKeys.insert(key)
            }
        }

        var previousOwners: [String: String] = [:]
        for state in previousStates.values {
            for key in Self.packEntryKeys(of: state) {
                previousOwners[key] = previousOwners[key] ?? state.packID
            }
        }

        // Built-in packs first, then community and local packs, each by ID
        let sortedStates = nextStates.values.sorted { a, b in
            let aRank = Self.reconcileRank(ofSource: a.source)
            let bRank = Self.reconcileRank(ofSource: b.source)
            if aRank != bRank {
                return aRank < bRank
            }
            return a.packID < b.packID
        }

        var newStates: [String: ActivatedTermPackState] = [:]
        var entriesToAdd: [(type: DictionaryEntryType, original: String, replacement: String?, caseSensitive: Bool, isEnabled: Bool, ctcMinSimilarity: Float?, source: DictionaryEntrySource)] = []
        // Reused entries whose pack definition changed spelling or case sensitivity
        var refreshedEntries: [(entry: DictionaryEntry, original: String, replacement: String?, caseSensitive: Bool)] = []

        for state in sortedStates {
            let restoredOverrides = inactivePackEntryOverrides[state.packID] ?? [:]

            var installedTerms: [String] = []
            for term in state.installedTerms {
                let key = Self.termKey(term)
                guard claimedKeys.insert(key).inserted else { continue }
                installedTerms.append(term)
                if let entry = reusableEntries.removeValue(forKey: key) {
                    if entry.original != term {
                        refreshedEntries.append((entry, term, nil, entry.caseSensitive))
                    }
                } else {
                    let override = restoredOverrides[key]
                    let ctcMinSimilarity: Float? = if let override {
                        override.ctcMinSimilarity
                    } else {
                        Self.packTermCtcMinSimilarity
                    }
                    entriesToAdd.append((
                        type: .term,
                        original: term,
                        replacement: nil,
                        caseSensitive: true,
                        isEnabled: override?.isEnabled ?? true,
                        ctcMinSimilarity: ctcMinSimilarity,
                        source: .manual
                    ))
                }
            }

            var installedCorrections: [TermPackCorrection] = []
            for correction in state.installedCorrections {
                let key = Self.correctionKey(original: correction.original, replacement: correction.replacement)
                guard claimedKeys.insert(key).inserted else { continue }
                installedCorrections.append(correction)
                if let entry = reusableEntries.removeValue(forKey: key) {
                    if entry.original != correction.original
                        || entry.replacement != correction.replacement
                        || entry.caseSensitive != correction.caseSensitive {
                        refreshedEntries.append((entry, correction.original, correction.replacement, correction.caseSensitive))
                    }
                } else {
                    entriesToAdd.append((
                        type: .correction,
                        original: correction.original,
                        replacement: correction.replacement,
                        caseSensitive: correction.caseSensitive,
                        isEnabled: restoredOverrides[key]?.isEnabled ?? true,
                        ctcMinSimilarity: nil,
                        source: .manual
                    ))
                }
            }

            newStates[state.packID] = ActivatedTermPackState(
                packID: state.packID,
                source: state.source,
                installedVersion: state.installedVersion,
                installedTerms: installedTerms,
                installedCorrections: installedCorrections,
                requiresCommercialLicense: state.requiresCommercialLicense
            )
        }

        // Active packs hold their overrides in their entries. Remember changed entries of
        // deactivated packs; entries an active pack dropped in an update are forgotten.
        var nextOverrides = inactivePackEntryOverrides.filter { nextStates[$0.key] == nil }
        for (key, entry) in reusableEntries {
            guard let owner = previousOwners[key], nextStates[owner] == nil,
                  let override = Self.packEntryOverride(for: entry) else { continue }
            nextOverrides[owner, default: [:]][key] = override
        }

        // Remove stale entries before adding, so a changed correction replacement can take the original's place.
        if throwsWhenDeletionFails {
            try dictionaryService.deleteEntries(ids: Set(reusableEntries.values.map(\.id)))
        } else if !reusableEntries.isEmpty {
            dictionaryService.deleteEntries(Array(reusableEntries.values))
        }
        for (entry, original, replacement, caseSensitive) in refreshedEntries {
            dictionaryService.updateEntry(
                entry,
                original: original,
                replacement: replacement,
                caseSensitive: caseSensitive,
                ctcMinSimilarity: entry.ctcMinSimilarity
            )
        }
        dictionaryService.importEntries(entriesToAdd)

        activatedPackStates = newStates
        saveActivatedPackStates()
        inactivePackEntryOverrides = nextOverrides
        saveInactivePackEntryOverrides()
    }

    /// Pack terms start at Precise boosting: packs carry many terms that sit close to everyday words,
    /// so the size-dependent Auto threshold lets them replace ordinary speech.
    private static let packTermCtcMinSimilarity = Float(preciseCtcMinSimilarity)

    /// The pack that comes first claims an entry several active packs share.
    private static func reconcileRank(ofSource source: String) -> Int {
        switch TermPack.Source(rawValue: source) {
        case .builtIn: 0
        case .community: 1
        case .local: 2
        case nil: 3
        }
    }

    private static func termKey(_ term: String) -> String {
        "term:\(term.lowercased())"
    }

    private static func packEntryKey(for entry: DictionaryEntry) -> String? {
        switch entry.type {
        case .term:
            return termKey(entry.original)
        case .correction:
            guard !entry.isRegex, let replacement = entry.replacement else { return nil }
            return correctionKey(original: entry.original, replacement: replacement)
        }
    }

    private static func packEntryKeys(of state: ActivatedTermPackState) -> [String] {
        state.installedTerms.map(termKey) + state.installedCorrections.map {
            correctionKey(original: $0.original, replacement: $0.replacement)
        }
    }

    /// Returns nil when the entry still has the pack defaults.
    private static func packEntryOverride(for entry: DictionaryEntry) -> TermPackEntryOverride? {
        let ctcMinSimilarity = entry.type == .term ? entry.ctcMinSimilarity : nil
        let defaultCtcMinSimilarity = entry.type == .term ? packTermCtcMinSimilarity : nil
        guard !entry.isEnabled || ctcMinSimilarity != defaultCtcMinSimilarity else { return nil }
        return TermPackEntryOverride(isEnabled: entry.isEnabled, ctcMinSimilarity: ctcMinSimilarity)
    }

    private static func correctionKey(original: String, replacement: String) -> String {
        "correction:\(original.lowercased())|\(replacement.lowercased())"
    }

    private func managedPackEntryIDs(
        from states: [String: ActivatedTermPackState]? = nil
    ) -> Set<UUID> {
        let keys = Set((states ?? activatedPackStates).values.flatMap(Self.packEntryKeys))
        return Set(dictionaryService.entries.compactMap { entry -> UUID? in
            guard let key = Self.packEntryKey(for: entry), keys.contains(key) else { return nil }
            return entry.id
        })
    }

    /// Moves pack terms installed with the former Auto default to Precise once.
    /// Earlier pack toggles and updates reset every pack term to Auto, so Auto is not a deliberate choice here.
    private func migratePackTermsToPreciseBoosting() {
        guard !defaults.bool(forKey: UserDefaultsKeys.termPackPreciseBoostingMigrated) else { return }
        // Retry on a later launch if the dictionary store could not be opened.
        guard activatedPackStates.isEmpty || !dictionaryService.entries.isEmpty else { return }
        let managedIDs = managedPackEntryIDs()
        let autoTermIDs = Set(dictionaryService.entries.filter {
            managedIDs.contains($0.id) && $0.type == .term && $0.ctcMinSimilarity == nil
        }.map(\.id))
        guard dictionaryService.setCtcMinSimilarity(Self.packTermCtcMinSimilarity, forTermEntryIDs: autoTermIDs) else {
            return
        }
        defaults.set(true, forKey: UserDefaultsKeys.termPackPreciseBoostingMigrated)
    }

    // MARK: - Persistence

    private func loadActivatedPackStates() {
        guard let data = defaults.data(forKey: UserDefaultsKeys.activatedTermPackStates) else { return }
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
            defaults.set(data, forKey: UserDefaultsKeys.activatedTermPackStates)
        }
    }

    private func loadInactivePackEntryOverrides() {
        guard let data = defaults.data(forKey: UserDefaultsKeys.termPackEntryOverrides) else { return }
        inactivePackEntryOverrides = (try? JSONDecoder().decode(
            [String: [String: TermPackEntryOverride]].self,
            from: data
        )) ?? [:]
    }

    private func saveInactivePackEntryOverrides() {
        if inactivePackEntryOverrides.isEmpty {
            defaults.removeObject(forKey: UserDefaultsKeys.termPackEntryOverrides)
        } else if let data = try? JSONEncoder().encode(inactivePackEntryOverrides) {
            defaults.set(data, forKey: UserDefaultsKeys.termPackEntryOverrides)
        }
    }

    /// Migrate from legacy activatedTermPacks (Set<String>) to new snapshot-based system.
    /// Does NOT auto-reactivate packs - just cleans up the old key. Entries remain in dictionary.
    private func migrateLegacyActivatedPacks() {
        let legacyKey = UserDefaultsKeys.activatedTermPacks
        guard defaults.stringArray(forKey: legacyKey) != nil else { return }
        // Clear legacy key - packs will need to be re-activated
        defaults.removeObject(forKey: legacyKey)
    }
}
