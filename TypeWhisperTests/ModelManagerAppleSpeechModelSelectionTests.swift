import Foundation
import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

@MainActor
final class ModelManagerAppleSpeechModelSelectionTests: XCTestCase {
    override func tearDown() {
        PluginManager.shared = nil
        super.tearDown()
    }

    func testAutoFirstUsePreparesDefaultAppleSpeechModelAndTranscribes() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let plugin = MockAppleSpeechTranscriptionPlugin(
            availableModels: [
                PluginModelInfo(id: "speechanalyzer-en_US", displayName: "English")
            ]
        )
        let modelManager = installAppleSpeechPlugin(plugin, appSupportDirectory: appSupportDirectory)

        let result = try await modelManager.transcribe(
            audioSamples: [Float](repeating: 0, count: 16_000),
            languageSelection: .auto,
            task: .transcribe
        )

        XCTAssertEqual(result.text, "transcribed with speechanalyzer-en_US")
        XCTAssertEqual(plugin.requestedLanguagePreparations, [nil])
        XCTAssertEqual(plugin.selectedModelId, "speechanalyzer-en_US")
    }

    func testExactLanguagePreparesMatchingAppleSpeechModel() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let plugin = MockAppleSpeechTranscriptionPlugin()
        let modelManager = installAppleSpeechPlugin(plugin, appSupportDirectory: appSupportDirectory)

        let result = try await modelManager.transcribe(
            audioSamples: [Float](repeating: 0, count: 16_000),
            languageSelection: .exact("de"),
            task: .transcribe
        )

        XCTAssertEqual(result.text, "transcribed with speechanalyzer-de_DE")
        XCTAssertEqual(plugin.requestedLanguagePreparations, ["de"])
        XCTAssertEqual(plugin.selectedModelId, "speechanalyzer-de_DE")
    }

    func testExactLanguageSwitchesConfiguredAppleSpeechModel() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let plugin = MockAppleSpeechTranscriptionPlugin()
        plugin.selectModel("speechanalyzer-en_US")
        let modelManager = installAppleSpeechPlugin(plugin, appSupportDirectory: appSupportDirectory)

        let result = try await modelManager.transcribe(
            audioSamples: [Float](repeating: 0, count: 16_000),
            languageSelection: .exact("de"),
            task: .transcribe
        )

        XCTAssertEqual(result.text, "transcribed with speechanalyzer-de_DE")
        XCTAssertEqual(plugin.requestedLanguagePreparations, ["de"])
        XCTAssertEqual(plugin.selectedModelId, "speechanalyzer-de_DE")
    }

    func testExactUnsupportedLanguageDoesNotUseConfiguredAppleSpeechModel() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let plugin = MockAppleSpeechTranscriptionPlugin()
        plugin.selectModel("speechanalyzer-en_US")
        let modelManager = installAppleSpeechPlugin(plugin, appSupportDirectory: appSupportDirectory)

        do {
            _ = try await modelManager.transcribe(
                audioSamples: [Float](repeating: 0, count: 16_000),
                languageSelection: .exact("it"),
                task: .transcribe
            )
            XCTFail("Expected unsupported explicit Apple Speech language to fail")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                TranscriptionEngineError.appleSpeechModelNotLoaded.localizedDescription
            )
        }

        XCTAssertEqual(plugin.requestedLanguagePreparations, [])
        XCTAssertEqual(plugin.selectedModelId, "speechanalyzer-en_US")
        XCTAssertEqual(plugin.transcribedModelIds, [])
    }

    func testManualModelOverrideTakesPrecedenceAndRestoresPreviousSelection() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let plugin = MockAppleSpeechTranscriptionPlugin()
        plugin.selectModel("speechanalyzer-en_US")
        let modelManager = installAppleSpeechPlugin(plugin, appSupportDirectory: appSupportDirectory)

        let result = try await modelManager.transcribe(
            audioSamples: [Float](repeating: 0, count: 16_000),
            languageSelection: .exact("de"),
            task: .transcribe,
            cloudModelOverride: "speechanalyzer-fr_FR"
        )

        XCTAssertEqual(result.text, "transcribed with speechanalyzer-fr_FR")
        XCTAssertEqual(plugin.requestedLanguagePreparations, [])
        XCTAssertEqual(plugin.selectedModelId, "speechanalyzer-en_US")
    }

    func testManualModelOverrideLoadsPersistedAppleSpeechModelWhenRuntimeModelIsUnloaded() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let plugin = MockAppleSpeechTranscriptionPlugin(
            persistedSelectedModelId: "speechanalyzer-en_US"
        )
        let modelManager = installAppleSpeechPlugin(plugin, appSupportDirectory: appSupportDirectory)

        let result = try await modelManager.transcribe(
            audioSamples: [Float](repeating: 0, count: 16_000),
            languageSelection: .auto,
            task: .transcribe,
            cloudModelOverride: "speechanalyzer-en_US"
        )

        XCTAssertEqual(result.text, "transcribed with speechanalyzer-en_US")
        XCTAssertEqual(plugin.requestedLanguagePreparations, [])
        XCTAssertEqual(plugin.transcribedModelIds, ["speechanalyzer-en_US"])
        XCTAssertEqual(plugin.selectedModelId, "speechanalyzer-en_US")
    }

    func testAppleSpeechUsesActionableErrorWhenNoModelCanBePrepared() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let plugin = MockAppleSpeechTranscriptionPlugin(availableModels: [])
        let modelManager = installAppleSpeechPlugin(plugin, appSupportDirectory: appSupportDirectory)

        do {
            _ = try await modelManager.transcribe(
                audioSamples: [Float](repeating: 0, count: 16_000),
                languageSelection: .auto,
                task: .transcribe
            )
            XCTFail("Expected Apple Speech model preparation to fail")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                TranscriptionEngineError.appleSpeechModelNotLoaded.localizedDescription
            )
        }
    }

    private func installAppleSpeechPlugin(
        _ plugin: MockAppleSpeechTranscriptionPlugin,
        appSupportDirectory: URL
    ) -> ModelManagerService {
        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: AppleSpeechModelSelection.manifestId,
                    name: "Apple Speech",
                    version: "1.0.0",
                    principalClass: "MockAppleSpeechTranscriptionPlugin"
                ),
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let modelManager = ModelManagerService()
        modelManager.selectProvider(plugin.providerId)
        return modelManager
    }
}

@objc(MockAppleSpeechTranscriptionPlugin)
private final class MockAppleSpeechTranscriptionPlugin: NSObject, TranscriptionModelCatalogProviding, @unchecked Sendable {
    static let pluginId = AppleSpeechModelSelection.manifestId
    static let pluginName = "Apple Speech"
    private static let defaultAvailableModels = [
        PluginModelInfo(id: "speechanalyzer-en_US", displayName: "English"),
        PluginModelInfo(id: "speechanalyzer-de_DE", displayName: "German"),
        PluginModelInfo(id: "speechanalyzer-fr_FR", displayName: "French")
    ]

    let availableModels: [PluginModelInfo]
    private(set) var requestedLanguagePreparations: [String?] = []
    private(set) var transcribedModelIds: [String] = []
    private let persistedSelectedModelId: String?
    private var currentModelId: String?

    init(
        availableModels: [PluginModelInfo] = defaultAvailableModels,
        persistedSelectedModelId: String? = nil
    ) {
        self.availableModels = availableModels
        self.persistedSelectedModelId = persistedSelectedModelId
        super.init()
    }

    required override init() {
        self.availableModels = Self.defaultAvailableModels
        self.persistedSelectedModelId = nil
        super.init()
    }

    var providerId: String { AppleSpeechModelSelection.providerId }
    var providerDisplayName: String { "Apple Speech" }
    var isConfigured: Bool { currentModelId != nil }
    var selectedModelId: String? { currentModelId ?? persistedSelectedModelId }
    var supportsTranslation: Bool { false }
    var supportsStreaming: Bool { false }
    var supportedLanguages: [String] {
        Array(Set(availableModels.compactMap { AppleSpeechModelSelection.modelLanguageCode(for: $0.id) }))
    }
    var transcriptionModels: [PluginModelInfo] {
        guard let currentModelId else { return [] }
        return availableModels.filter { $0.id == currentModelId }
    }

    func activate(host: HostServices) {}
    func deactivate() {}

    func selectModel(_ modelId: String) {
        currentModelId = availableModels.contains { $0.id == modelId } ? modelId : nil
    }

    @objc func triggerRestoreModel() {
        triggerRestoreModel(forLanguage: nil)
    }

    @objc(triggerRestoreModelForLanguage:)
    func triggerRestoreModel(forLanguage languageCode: NSString?) {
        let language = languageCode as String?
        requestedLanguagePreparations.append(language)

        let modelId: String?
        if let language {
            modelId = AppleSpeechModelSelection.preferredModelId(
                from: availableModels,
                localeIdentifier: language,
                languageCode: language,
                fallbackToFirst: false
            )
        } else if let currentModelId {
            modelId = currentModelId
        } else {
            modelId = AppleSpeechModelSelection.preferredModelId(from: availableModels)
        }

        if let modelId {
            selectModel(modelId)
        }
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        guard let currentModelId else {
            throw PluginTranscriptionError.notConfigured
        }
        transcribedModelIds.append(currentModelId)
        return PluginTranscriptionResult(
            text: "transcribed with \(currentModelId)",
            detectedLanguage: language
        )
    }
}
