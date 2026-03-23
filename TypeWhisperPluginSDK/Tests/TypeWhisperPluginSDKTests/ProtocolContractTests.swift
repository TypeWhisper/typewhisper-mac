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
    let availableProfileNames: [String]

    init(eventBus: EventBusProtocol, availableProfileNames: [String]) {
        self.eventBus = eventBus
        self.availableProfileNames = availableProfileNames
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

final class ProtocolContractTests: XCTestCase {
    func testHostServicesExposeProfilesSecretsAndDefaults() throws {
        let host = MockHostServices(eventBus: MockEventBus(), availableProfileNames: ["Work", "Docs"])

        try host.storeSecret(key: "apiKey", value: "secret")
        host.setUserDefault("value", forKey: "sample")

        XCTAssertEqual(host.loadSecret(key: "apiKey"), "secret")
        XCTAssertEqual(host.userDefault(forKey: "sample") as? String, "value")
        XCTAssertEqual(host.availableProfileNames, ["Work", "Docs"])
        XCTAssertEqual(host.activeAppName, "Notes")
    }

    func testTranscriptionPluginUsesDefaultStreamingFallback() async throws {
        let plugin = MockTranscriptionPlugin()
        let host = MockHostServices(eventBus: MockEventBus(), availableProfileNames: ["Work"])
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
        XCTAssertEqual(plugin.host?.availableProfileNames, ["Work"])
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
}
