import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

private final class BudgetedDictionaryEnginePlugin: NSObject, TranscriptionEnginePlugin, DictionaryTermsBudgetProviding, @unchecked Sendable {
    static let pluginId = "com.typewhisper.tests.budgeted-dictionary-engine"
    static let pluginName = "Budgeted Dictionary Engine"
    var providerIdValue = "budgeted"
    var budgetValue = DictionaryTermsBudget()

    required override init() {}

    func activate(host: HostServices) {}
    func deactivate() {}

    var providerId: String { providerIdValue }
    var providerDisplayName: String { "Budgeted Mock" }
    var isConfigured: Bool { true }
    var transcriptionModels: [PluginModelInfo] { [] }
    var selectedModelId: String? { nil }
    func selectModel(_ modelId: String) {}
    var supportsTranslation: Bool { false }
    var dictionaryTermsBudget: DictionaryTermsBudget { budgetValue }

    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        PluginTranscriptionResult(text: "ok", detectedLanguage: language)
    }
}

private final class LegacyDictionaryEnginePlugin: NSObject, TranscriptionEnginePlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.tests.legacy-dictionary-engine"
    static let pluginName = "Legacy Dictionary Engine"
    var providerIdValue = "legacy"

    required override init() {}

    func activate(host: HostServices) {}
    func deactivate() {}

    var providerId: String { providerIdValue }
    var providerDisplayName: String { "Legacy Mock" }
    var isConfigured: Bool { true }
    var transcriptionModels: [PluginModelInfo] { [] }
    var selectedModelId: String? { nil }
    func selectModel(_ modelId: String) {}
    var supportsTranslation: Bool { false }

    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        PluginTranscriptionResult(text: "ok", detectedLanguage: language)
    }
}

final class DictionaryServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.activatedTermPacks)
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.activatedTermPackStates)
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.selectedIndustryPreset)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.activatedTermPacks)
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.activatedTermPackStates)
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.selectedIndustryPreset)
        PluginManager.shared = nil
        super.tearDown()
    }

    @MainActor
    func testDictionaryTermsCorrectionsAndLearning() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)

        service.addEntry(type: .term, original: "TypeWhisper")
        service.addEntry(type: .term, original: "typewhisper")
        service.addEntry(type: .correction, original: "teh", replacement: "the")

        XCTAssertEqual(service.termsCount, 1)
        XCTAssertEqual(service.correctionsCount, 1)
        XCTAssertEqual(service.getTermsForPrompt(providerId: nil), "TypeWhisper")

        let corrected = service.applyCorrections(to: "teh TypeWhisper")
        XCTAssertEqual(corrected, "the TypeWhisper")
        XCTAssertEqual(service.corrections.first?.usageCount, 1)

        service.learnCorrection(original: "langauge", replacement: "language")
        XCTAssertEqual(service.correctionsCount, 2)
    }

    @MainActor
    func testEmptyCorrectionReplacementPersistsAndRemovesText() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        service.addEntry(type: .correction, original: "¿", replacement: "")

        XCTAssertEqual(service.correctionsCount, 1)
        XCTAssertEqual(service.corrections.first?.replacement, "")
        XCTAssertEqual(service.applyCorrections(to: "¿Como estas?"), "Como estas?")
        XCTAssertEqual(service.corrections.first?.usageCount, 1)

        let reloadedService = DictionaryService(appSupportDirectory: appSupportDirectory)
        XCTAssertEqual(reloadedService.correctionsCount, 1)
        XCTAssertEqual(reloadedService.corrections.first?.replacement, "")
        XCTAssertEqual(reloadedService.applyCorrections(to: "¿Como estas?"), "Como estas?")
        reloadedService.loadEntries()
        XCTAssertEqual(reloadedService.corrections.first?.usageCount, 2)
    }

    @MainActor
    func testAPITermHelpersDeleteSingleTermWithoutClearingOthers() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        try service.setAPITerms([" TypeWhisper ", "WhisperKit", "typewhisper"], replaceExisting: true)

        XCTAssertTrue(try service.deleteAPITerm("typewhisper"))
        XCTAssertEqual(service.enabledTerms(), ["WhisperKit"])
        XCTAssertFalse(try service.deleteAPITerm("Missing"))
    }

    @MainActor
    func testAPICorrectionHelpersUpsertCaseInsensitiveAndPreserveUsageCount() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        try service.upsertAPICorrection(original: "teh", replacement: "the", caseSensitive: false)
        XCTAssertEqual(service.applyCorrections(to: "teh"), "the")
        XCTAssertEqual(service.corrections.first?.usageCount, 1)

        try service.upsertAPICorrection(original: "TEH", replacement: "The", caseSensitive: true)

        XCTAssertEqual(service.correctionsCount, 1)
        XCTAssertEqual(service.corrections.first?.original, "TEH")
        XCTAssertEqual(service.corrections.first?.replacement, "The")
        XCTAssertEqual(service.corrections.first?.caseSensitive, true)
        XCTAssertEqual(service.corrections.first?.usageCount, 1)
        XCTAssertTrue(try service.deleteAPICorrection(original: "teh"))
        XCTAssertEqual(service.correctionsCount, 0)
        XCTAssertFalse(try service.deleteAPICorrection(original: "missing"))
    }

    @MainActor
    func testEnabledTermsAreNormalizedAndPromptRendererStaysBackwardCompatible() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        service.addEntry(type: .term, original: " Kubernetes ", ctcMinSimilarity: 0.65)
        service.addEntry(type: .term, original: "MLX")
        service.addEntry(type: .term, original: "mlx")
        service.addEntry(type: .term, original: "TypeWhisper")

        XCTAssertEqual(service.enabledTerms(), ["Kubernetes", "MLX", "TypeWhisper"])
        XCTAssertEqual(service.enabledTermHints(), [
            PluginDictionaryTermHint(text: "Kubernetes", ctcMinSimilarity: 0.65),
            PluginDictionaryTermHint(text: "MLX", ctcMinSimilarity: nil),
            PluginDictionaryTermHint(text: "TypeWhisper", ctcMinSimilarity: nil),
        ])
        XCTAssertEqual(
            service.getTermsForPrompt(providerId: nil),
            PluginDictionaryTerms.prompt(from: ["Kubernetes", "MLX", "TypeWhisper"])
        )
    }

    @MainActor
    func testAPITermEntriesPersistThresholdsAndPlainTermsPreserveExistingValues() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        try service.setAPITermEntries(
            [
                (term: " TypeWhisper ", ctcMinSimilarity: 0.65),
                (term: "Reson8", ctcMinSimilarity: nil),
            ],
            replaceExisting: true
        )

        XCTAssertEqual(service.enabledTermHints(), [
            PluginDictionaryTermHint(text: "Reson8", ctcMinSimilarity: nil),
            PluginDictionaryTermHint(text: "TypeWhisper", ctcMinSimilarity: 0.65),
        ])

        try service.setAPITerms(["typewhisper", "Caivex"], replaceExisting: false)

        XCTAssertEqual(service.enabledTermHints(), [
            PluginDictionaryTermHint(text: "Caivex", ctcMinSimilarity: nil),
            PluginDictionaryTermHint(text: "Reson8", ctcMinSimilarity: nil),
            PluginDictionaryTermHint(text: "typewhisper", ctcMinSimilarity: 0.65),
        ])

        try service.setAPITermEntries(
            [(term: "TypeWhisper", ctcMinSimilarity: nil)],
            replaceExisting: true
        )

        XCTAssertEqual(service.enabledTermHints(), [
            PluginDictionaryTermHint(text: "TypeWhisper", ctcMinSimilarity: nil),
        ])
    }

    @MainActor
    func testGetTermsForPromptUsesLoadedEngineBudget() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        service.setTerms(["Alpha", "BetaBeta", "Gamma", "alpha"], replaceExisting: true)

        let plugin = BudgetedDictionaryEnginePlugin()
        plugin.providerIdValue = "budgeted"
        plugin.budgetValue = DictionaryTermsBudget(maxTerms: 2, maxCharsPerTerm: 5)
        installPlugins([plugin], appSupportDirectory: appSupportDirectory)

        XCTAssertEqual(service.getTermsForPrompt(providerId: plugin.providerId), "Alpha, Gamma")
        XCTAssertEqual(service.getTermHints(providerId: plugin.providerId), [
            PluginDictionaryTermHint(text: "Alpha", ctcMinSimilarity: nil),
            PluginDictionaryTermHint(text: "Gamma", ctcMinSimilarity: nil),
        ])
    }

    @MainActor
    func testGetTermsForPromptFallsBackToLegacyBudgetForUnknownOrUnbudgetedEngines() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        service.setTerms(makeLongTerms(count: 40, length: 24), replaceExisting: true)

        let plugin = LegacyDictionaryEnginePlugin()
        plugin.providerIdValue = "legacy"
        installPlugins([plugin], appSupportDirectory: appSupportDirectory)

        let expectedFallback = PluginDictionaryTerms.prompt(from: service.enabledTerms())
        XCTAssertEqual(service.getTermsForPrompt(providerId: nil), expectedFallback)
        XCTAssertEqual(service.getTermsForPrompt(providerId: plugin.providerId), expectedFallback)
        XCTAssertEqual(service.getTermsForPrompt(providerId: "missing"), expectedFallback)
        XCTAssertLessThanOrEqual(expectedFallback?.count ?? 0, 600)
    }

    @MainActor
    func testGetTermsForPromptAllowsBudgetsAboveLegacy600Characters() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        service.setTerms(makeLongTerms(count: 40, length: 24), replaceExisting: true)

        let plugin = BudgetedDictionaryEnginePlugin()
        plugin.providerIdValue = "budgeted"
        plugin.budgetValue = DictionaryTermsBudget(maxTotalChars: 2_000)
        installPlugins([plugin], appSupportDirectory: appSupportDirectory)

        let prompt = try XCTUnwrap(service.getTermsForPrompt(providerId: plugin.providerId))
        XCTAssertGreaterThan(prompt.count, 600)
    }

    @MainActor
    func testGetTermsForPromptAppliesWordAndCharacterFilters() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        service.setTerms(
            ["Alpha", "one two three", "123456789012345678901", "Beta Beta", "Gamma"],
            replaceExisting: true
        )

        let plugin = BudgetedDictionaryEnginePlugin()
        plugin.providerIdValue = "budgeted"
        plugin.budgetValue = DictionaryTermsBudget(maxCharsPerTerm: 20, maxWordsPerTerm: 2)
        installPlugins([plugin], appSupportDirectory: appSupportDirectory)

        XCTAssertEqual(service.getTermsForPrompt(providerId: plugin.providerId), "Alpha, Beta Beta, Gamma")
    }

    @MainActor
    func testTermPackActivationPreservesManualEntriesAndDeactivationRemovesOnlyPackEntries() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        service.addEntry(type: .term, original: "Rust")

        let viewModel = DictionaryViewModel(dictionaryService: service)
        let pack = TermPack(
            id: "community-rust",
            name: "Rust Terms",
            description: "Rust ecosystem terms",
            icon: "shippingbox",
            terms: ["Rust", "Tokio"],
            corrections: [],
            version: "1.0.0",
            author: "Tests",
            localizedNames: nil,
            localizedDescriptions: nil
        )

        viewModel.activatePack(pack)

        XCTAssertEqual(service.entries.filter { $0.type == .term }.map(\.original).sorted(), ["Rust", "Tokio"])
        XCTAssertEqual(service.entries.first(where: { $0.original == "Rust" })?.caseSensitive, false)
        XCTAssertEqual(viewModel.activatedPackStates[pack.id]?.installedTerms, ["Tokio"])

        viewModel.deactivatePack(pack)

        XCTAssertEqual(service.entries.filter { $0.type == .term }.map(\.original), ["Rust"])
        XCTAssertFalse(viewModel.isPackActivated(pack))
    }

    @MainActor
    func testTermPackUpdateReplacesPreviousSnapshotEntries() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        let viewModel = DictionaryViewModel(dictionaryService: service)

        let v1 = TermPack(
            id: "community-rust",
            name: "Rust Terms",
            description: "Rust ecosystem terms",
            icon: "shippingbox",
            terms: ["Tokio"],
            corrections: [],
            version: "1.0.0",
            author: "Tests",
            localizedNames: nil,
            localizedDescriptions: nil
        )
        let v2 = TermPack(
            id: "community-rust",
            name: "Rust Terms",
            description: "Rust ecosystem terms",
            icon: "shippingbox",
            terms: ["Cargo"],
            corrections: [],
            version: "1.1.0",
            author: "Tests",
            localizedNames: nil,
            localizedDescriptions: nil
        )

        viewModel.activatePack(v1)
        viewModel.updatePack(v2)

        XCTAssertEqual(service.entries.filter { $0.type == .term }.map(\.original), ["Cargo"])
        XCTAssertEqual(viewModel.activatedPackStates[v2.id]?.installedTerms, ["Cargo"])
        XCTAssertEqual(viewModel.activatedPackStates[v2.id]?.installedVersion, "1.1.0")
    }

    @MainActor
    func testCommercialIndustryPacksAreHiddenWithoutCommercialLicense() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        let license = LicenseService(defaults: UserDefaults(suiteName: #function)!)
        let registry = TermPackRegistryService()
        registry.communityPacks = [
            makeCommercialIndustryPack(id: "real-estate", terms: ["Exposé"]),
            makeCommercialIndustryPack(id: "architecture", terms: ["HOAI"]),
            makeCommercialIndustryPack(id: "legal", terms: ["Mandat"])
        ]
        let viewModel = DictionaryViewModel(
            dictionaryService: service,
            licenseService: license,
            termPackRegistryService: registry
        )

        XCTAssertFalse(viewModel.visibleBuiltInPacks.contains { $0.id == "real-estate" })
        XCTAssertFalse(viewModel.visibleBuiltInPacks.contains { $0.id == "architecture" })
        XCTAssertFalse(viewModel.visibleBuiltInPacks.contains { $0.id == "legal" })
        XCTAssertFalse(viewModel.visibleCommunityPacks.contains { $0.id == "real-estate" })
        XCTAssertFalse(viewModel.visibleCommunityPacks.contains { $0.id == "architecture" })
        XCTAssertFalse(viewModel.visibleCommunityPacks.contains { $0.id == "legal" })
    }

    @MainActor
    func testCommercialIndustryPresetActivatesMatchingPackWhenLicensed() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        let defaults = UserDefaults(suiteName: #function)!
        let license = LicenseService(defaults: defaults)
        license.licenseStatus = .active
        license.licenseTier = .team
        let registry = TermPackRegistryService()
        let realEstatePack = makeCommercialIndustryPack(id: "real-estate", terms: ["Exposé", "Grundbuch"])
        registry.communityPacks = [realEstatePack]
        let viewModel = DictionaryViewModel(
            dictionaryService: service,
            licenseService: license,
            termPackRegistryService: registry
        )

        viewModel.applyIndustryPreset(.realEstate)

        XCTAssertEqual(UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedIndustryPreset), IndustryPreset.realEstate.rawValue)
        XCTAssertTrue(viewModel.isPackActivated(realEstatePack))
        XCTAssertTrue(service.entries.contains { $0.original == "Exposé" })
    }

    @MainActor
    func testIndustryPresetStoresSelectionWithoutActivatingPackWhenUnlicensed() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        let license = LicenseService(defaults: UserDefaults(suiteName: #function)!)
        let registry = TermPackRegistryService()
        registry.communityPacks = [makeCommercialIndustryPack(id: "architecture", terms: ["HOAI"])]
        let viewModel = DictionaryViewModel(
            dictionaryService: service,
            licenseService: license,
            termPackRegistryService: registry
        )

        viewModel.applyIndustryPreset(.architecture)

        XCTAssertEqual(UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedIndustryPreset), IndustryPreset.architecture.rawValue)
        XCTAssertFalse(viewModel.activatedPackStates.keys.contains("architecture"))
        XCTAssertFalse(service.entries.contains { $0.original == "HOAI" })
    }

    private func makeCommercialIndustryPack(id: String, terms: [String]) -> TermPack {
        TermPack(
            id: id,
            name: id,
            description: "Industry test pack",
            icon: "shippingbox",
            terms: terms,
            corrections: [],
            version: "1.0.0",
            author: "Tests",
            localizedNames: nil,
            localizedDescriptions: nil,
            requiresCommercialLicense: true
        )
    }

    @MainActor
    private func installPlugins(_ plugins: [any TranscriptionEnginePlugin], appSupportDirectory: URL) {
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)
        PluginManager.shared.loadedPlugins = plugins.enumerated().map { index, plugin in
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.tests.\(plugin.providerId).\(index)",
                    name: plugin.providerDisplayName,
                    version: "1.0.0",
                    principalClass: "DictionaryServiceTestsPlugin\(index)"
                ),
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        }
    }

    private func makeLongTerms(count: Int, length: Int) -> [String] {
        (1...count).map { index in
            let prefix = "Term\(index)-"
            let paddingLength = max(0, length - prefix.count)
            return prefix + String(repeating: "x", count: paddingLength)
        }
    }
}

final class TermPackRegistryServiceTests: XCTestCase {
    @MainActor
    func testBackgroundCheckDoesNotRecordTimestampWhenFetchFails() async {
        let suiteName = "TermPackRegistryServiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = TermPackRegistryService(
            userDefaults: defaults,
            fetchData: { _ in throw URLError(.notConnectedToInternet) }
        )

        service.checkForUpdatesInBackground()

        for _ in 0..<20 {
            if case .error = service.fetchState {
                break
            }
            await Task.yield()
        }

        XCTAssertEqual(defaults.double(forKey: UserDefaultsKeys.termPackRegistryLastUpdateCheck), 0)
    }

    @MainActor
    func testBackgroundCheckRecordsTimestampWhenFetchSucceeds() async throws {
        let suiteName = "TermPackRegistryServiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let payload = """
        {
          "schemaVersion": 1,
          "packs": [
            {
              "id": "community-rust",
              "name": "Rust Terms",
              "description": "Rust ecosystem terms",
              "icon": "shippingbox",
              "version": "1.0.0",
              "author": "Tests",
              "requiresCommercialLicense": true,
              "terms": ["Tokio"]
            }
          ]
        }
        """.data(using: .utf8)!

        let service = TermPackRegistryService(
            userDefaults: defaults,
            fetchData: { _ in
                let response = HTTPURLResponse(
                    url: URL(string: "https://example.com/termpacks.json")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (payload, response)
            }
        )

        service.checkForUpdatesInBackground()

        for _ in 0..<20 {
            if service.fetchState == .loaded {
                break
            }
            await Task.yield()
        }

        XCTAssertGreaterThan(defaults.double(forKey: UserDefaultsKeys.termPackRegistryLastUpdateCheck), 0)
        XCTAssertEqual(service.communityPacks.map(\.id), ["community-rust"])
        XCTAssertEqual(service.communityPacks.first?.requiresCommercialLicense, true)
    }
}
