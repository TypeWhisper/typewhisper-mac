import Foundation
import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

@MainActor
final class ModelManagerLiveSessionModelOverrideTests: XCTestCase {
    override func tearDown() {
        PluginManager.shared = nil
        super.tearDown()
    }

    func testLiveSessionKeepsManualModelOverrideUntilFinish() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let plugin = LiveModelOverrideTranscriptionPlugin()
        let modelManager = installLivePlugin(plugin, appSupportDirectory: appSupportDirectory)

        let sessionHandle = try await modelManager.createLiveTranscriptionSession(
            languageSelection: .auto,
            task: .transcribe,
            cloudModelOverride: "beta",
            onProgress: { _ in true }
        )
        let handle = try XCTUnwrap(sessionHandle)

        XCTAssertEqual(plugin.selectedModelId, "beta")

        let result = try await modelManager.finishLiveTranscriptionSession(
            handle,
            bufferedDuration: 1.0
        )

        XCTAssertEqual(result.text, "live with beta")
        XCTAssertEqual(plugin.selectedModelId, "alpha")
    }

    func testLiveSessionKeepsManualModelOverrideUntilCancel() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let plugin = LiveModelOverrideTranscriptionPlugin()
        let modelManager = installLivePlugin(plugin, appSupportDirectory: appSupportDirectory)

        let sessionHandle = try await modelManager.createLiveTranscriptionSession(
            languageSelection: .auto,
            task: .transcribe,
            cloudModelOverride: "beta",
            onProgress: { _ in true }
        )
        let handle = try XCTUnwrap(sessionHandle)

        XCTAssertEqual(plugin.selectedModelId, "beta")

        await modelManager.cancelLiveTranscriptionSession(handle)

        XCTAssertEqual(plugin.selectedModelId, "alpha")
    }

    private func installLivePlugin(
        _ plugin: LiveModelOverrideTranscriptionPlugin,
        appSupportDirectory: URL
    ) -> ModelManagerService {
        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: LiveModelOverrideTranscriptionPlugin.pluginId,
                    name: LiveModelOverrideTranscriptionPlugin.pluginName,
                    version: "1.0.0",
                    principalClass: "LiveModelOverrideTranscriptionPlugin"
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

private final class LiveModelOverrideTranscriptionPlugin: NSObject, TranscriptionModelCatalogProviding, LiveTranscriptionCapablePlugin, @unchecked Sendable {
    static var pluginId: String { "com.typewhisper.mock.live-model-override" }
    static var pluginName: String { "Mock Live Model Override" }

    private let models = [
        PluginModelInfo(id: "alpha", displayName: "Alpha"),
        PluginModelInfo(id: "beta", displayName: "Beta")
    ]
    private var currentModelId: String? = "alpha"

    var providerId: String { "mock-live-model-override" }
    var providerDisplayName: String { Self.pluginName }
    var isConfigured: Bool { currentModelId != nil }
    var selectedModelId: String? { currentModelId }
    var availableModels: [PluginModelInfo] { models }
    var transcriptionModels: [PluginModelInfo] { models }
    var supportsTranslation: Bool { false }
    var supportsStreaming: Bool { true }
    var supportedLanguages: [String] { ["en"] }

    func activate(host: HostServices) {}
    func deactivate() {}

    func selectModel(_ modelId: String) {
        currentModelId = models.contains { $0.id == modelId } ? modelId : nil
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        XCTFail("Batch transcribe should not be used for the live-session path")
        return PluginTranscriptionResult(text: "", detectedLanguage: language)
    }

    func createLiveTranscriptionSession(
        language: String?,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> any LiveTranscriptionSession {
        LiveModelOverrideSession(modelId: currentModelId)
    }
}

private actor LiveModelOverrideSession: LiveTranscriptionSession {
    private let modelId: String?

    init(modelId: String?) {
        self.modelId = modelId
    }

    func appendAudio(samples: [Float]) async throws {}

    func finish() async throws -> PluginTranscriptionResult {
        PluginTranscriptionResult(
            text: "live with \(modelId ?? "none")",
            detectedLanguage: nil
        )
    }

    func cancel() async {}
}
