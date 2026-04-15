import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

final class DictionaryServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.activatedTermPacks)
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.activatedTermPackStates)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.activatedTermPacks)
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.activatedTermPackStates)
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
        XCTAssertEqual(service.getTermsForPrompt(), "TypeWhisper")

        let corrected = service.applyCorrections(to: "teh TypeWhisper")
        XCTAssertEqual(corrected, "the TypeWhisper")
        XCTAssertEqual(service.corrections.first?.usageCount, 1)

        service.learnCorrection(original: "langauge", replacement: "language")
        XCTAssertEqual(service.correctionsCount, 2)
    }

    @MainActor
    func testEnabledTermsAreNormalizedAndPromptRendererStaysBackwardCompatible() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        service.addEntry(type: .term, original: " Kubernetes ")
        service.addEntry(type: .term, original: "MLX")
        service.addEntry(type: .term, original: "mlx")
        service.addEntry(type: .term, original: "TypeWhisper")

        XCTAssertEqual(service.enabledTerms(), ["Kubernetes", "MLX", "TypeWhisper"])
        XCTAssertEqual(
            service.getTermsForPrompt(),
            PluginDictionaryTerms.prompt(from: ["Kubernetes", "MLX", "TypeWhisper"])
        )
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
    }
}
