import Foundation
import XCTest
@testable import TypeWhisperPluginSDK

private final class MockEventBus: EventBusProtocol, @unchecked Sendable {
    private(set) var handlers: [UUID: @Sendable (TypeWhisperEvent) async -> Void] = [:]

    func subscribe(handler: @escaping @Sendable (TypeWhisperEvent) async -> Void) -> UUID {
        let id = UUID()
        handlers[id] = handler
        return id
    }

    func unsubscribe(id: UUID) {
        handlers.removeValue(forKey: id)
    }
}

private struct MockHostServices: HostServices {
    private final class Storage: @unchecked Sendable {
        var secrets: [String: String] = [:]
        var defaults: [String: AnySendable] = [:]
    }

    private struct AnySendable: @unchecked Sendable {
        let value: Any
    }

    private let storage = Storage()

    let pluginDataDirectory: URL
    let activeAppBundleId: String? = "com.apple.Notes"
    let activeAppName: String? = "Notes"
    let eventBus: EventBusProtocol
    let availableRuleNames: [String]

    init(eventBus: EventBusProtocol, availableRuleNames: [String]) {
        self.eventBus = eventBus
        self.availableRuleNames = availableRuleNames
        self.pluginDataDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    func storeSecret(key: String, value: String) throws {
        storage.secrets[key] = value
    }

    func loadSecret(key: String) -> String? {
        storage.secrets[key]
    }

    func userDefault(forKey key: String) -> Any? {
        storage.defaults[key]?.value
    }

    func setUserDefault(_ value: Any?, forKey key: String) {
        storage.defaults[key] = value.map(AnySendable.init(value:))
    }

    func notifyCapabilitiesChanged() {}
    func setStreamingDisplayActive(_ active: Bool) {}
}

@objc(MockTranscriptionPlugin)
private final class MockTranscriptionPlugin: NSObject, TranscriptionEnginePlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.mock.transcription"
    static let pluginName = "Mock Transcription"

    private(set) var host: HostServices?

    required override init() {}

    func activate(host: HostServices) {
        self.host = host
    }

    func deactivate() {
        host = nil
    }

    var providerId: String { "mock" }
    var providerDisplayName: String { "Mock" }
    var isConfigured: Bool { true }
    var transcriptionModels: [PluginModelInfo] { [PluginModelInfo(id: "tiny", displayName: "Tiny")] }
    var selectedModelId: String? { "tiny" }
    func selectModel(_ modelId: String) {}
    var supportsTranslation: Bool { true }

    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        PluginTranscriptionResult(text: translate ? "translated" : "transcribed", detectedLanguage: language)
    }
}

@objc(MockDictionaryTermsPlugin)
private final class MockDictionaryTermsPlugin: NSObject, TranscriptionEnginePlugin, DictionaryTermsCapabilityProviding, @unchecked Sendable {
    static let pluginId = "com.typewhisper.mock.dictionary-terms"
    static let pluginName = "Mock Dictionary Terms"

    required override init() {}

    func activate(host: HostServices) {}
    func deactivate() {}

    var providerId: String { "mock-dictionary-terms" }
    var providerDisplayName: String { "Mock Dictionary Terms" }
    var isConfigured: Bool { true }
    var transcriptionModels: [PluginModelInfo] { [] }
    var selectedModelId: String? { nil }
    func selectModel(_ modelId: String) {}
    var supportsTranslation: Bool { false }
    var dictionaryTermsSupport: DictionaryTermsSupport { .requiresPluginSetting }

    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        PluginTranscriptionResult(text: "ok", detectedLanguage: language)
    }
}

final class ProtocolContractTests: XCTestCase {
    func testHostServicesExposeRulesSecretsAndDefaults() throws {
        let host = MockHostServices(eventBus: MockEventBus(), availableRuleNames: ["Work", "Docs"])

        try host.storeSecret(key: "apiKey", value: "secret")
        host.setUserDefault("value", forKey: "sample")

        XCTAssertEqual(host.loadSecret(key: "apiKey"), "secret")
        XCTAssertEqual(host.userDefault(forKey: "sample") as? String, "value")
        XCTAssertEqual(host.availableRuleNames, ["Work", "Docs"])
        XCTAssertEqual(host.availableProfileNames, ["Work", "Docs"])
        XCTAssertEqual(host.activeAppName, "Notes")
    }

    func testTranscriptionPluginUsesDefaultStreamingFallback() async throws {
        let plugin = MockTranscriptionPlugin()
        let host = MockHostServices(eventBus: MockEventBus(), availableRuleNames: ["Work"])
        plugin.activate(host: host)

        let result = try await plugin.transcribe(
            audio: AudioData(samples: [0.1, -0.1], wavData: Data([0x00, 0x01]), duration: 1),
            language: "en",
            translate: false,
            prompt: nil,
            onProgress: { progress in
                XCTAssertEqual(progress, "transcribed")
                return true
            }
        )

        XCTAssertEqual(result.text, "transcribed")
        XCTAssertEqual(plugin.host?.availableRuleNames, ["Work"])
        XCTAssertNil(plugin.settingsView)

        plugin.deactivate()
        XCTAssertNil(plugin.host)
    }

    func testMemoryEncodingRoundTripsAndWavEncoderProducesHeader() throws {
        let entry = MemoryEntry(content: "Prefers German", type: .preference)
        let data = try JSONEncoder.memoryEncoder.encode(entry)
        let decoded = try JSONDecoder.memoryDecoder.decode(MemoryEntry.self, from: data)
        let wav = PluginWavEncoder.encode([0, 0.5, -0.5])

        XCTAssertEqual(decoded.content, entry.content)
        XCTAssertEqual(decoded.type, entry.type)
        XCTAssertEqual(String(data: wav.prefix(4), encoding: .utf8), "RIFF")
    }

    func testDictionaryTermsCapabilityProtocolIsOptional() {
        let legacyPlugin = MockTranscriptionPlugin()
        let capabilityPlugin = MockDictionaryTermsPlugin()

        XCTAssertFalse(legacyPlugin is any DictionaryTermsCapabilityProviding)
        XCTAssertEqual(capabilityPlugin.dictionaryTermsSupport, .requiresPluginSetting)
    }

    func testPluginDictionaryTermsNormalizesPromptAndContextTokens() {
        XCTAssertEqual(
            PluginDictionaryTerms.normalizedTerms(from: [" Kubernetes ", "kubernetes", "", "MLX"]),
            ["Kubernetes", "MLX"]
        )
        XCTAssertEqual(
            PluginDictionaryTerms.terms(fromPrompt: " Kubernetes, MLX, Kubernetes "),
            ["Kubernetes", "MLX"]
        )
        XCTAssertEqual(
            PluginDictionaryTerms.contextBiasTokens(fromPrompt: "TypeWhisper, Apple Silicon MLX"),
            ["TypeWhisper", "Apple", "Silicon", "MLX"]
        )
        XCTAssertEqual(
            PluginDictionaryTerms.prompt(from: ["TypeWhisper", "MLX"], maxLength: 100),
            "TypeWhisper, MLX"
        )
    }
}
