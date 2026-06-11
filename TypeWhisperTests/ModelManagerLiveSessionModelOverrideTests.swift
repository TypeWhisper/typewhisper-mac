import Foundation
import os
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

    func testBatchTranscriptionForwardsSourceProgressFromOptionalProtocol() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let plugin = SourceProgressModelManagerPlugin()
        let modelManager = installBatchPlugin(plugin, appSupportDirectory: appSupportDirectory)
        let recorder = ModelManagerSourceProgressRecorder()

        let result = try await modelManager.transcribe(
            audioSamples: [Float](repeating: 0, count: 16_000),
            languageSelection: .auto,
            task: .transcribe,
            onProgress: { text in
                XCTAssertEqual(text, "source partial")
                return true
            },
            onSourceProgress: { progress in
                recorder.record(progress)
                return true
            }
        )

        let progress = try XCTUnwrap(recorder.recordedProgress)
        XCTAssertEqual(result.text, "source done")
        XCTAssertTrue(plugin.usedSourceProgressTranscribe)
        XCTAssertFalse(plugin.usedLegacyTranscribe)
        XCTAssertEqual(progress.processedDuration, 1.5)
        XCTAssertEqual(progress.totalDuration, 4)
        XCTAssertEqual(progress.previewText, "source partial")
        XCTAssertEqual(progress.fractionCompleted, 0.375)
    }

    func testBatchTranscriptionKeepsLegacyProgressPathWithoutOptionalProtocol() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let plugin = LegacyModelManagerTranscriptionPlugin()
        let modelManager = installBatchPlugin(plugin, appSupportDirectory: appSupportDirectory)

        let result = try await modelManager.transcribe(
            audioSamples: [Float](repeating: 0, count: 16_000),
            languageSelection: .auto,
            task: .transcribe,
            onProgress: { text in
                XCTAssertEqual(text, "legacy partial")
                return true
            },
            onSourceProgress: { _ in
                XCTFail("Legacy plugins should not receive source-progress callbacks")
                return true
            }
        )

        XCTAssertEqual(result.text, "legacy done")
        XCTAssertTrue(plugin.usedStreamingTranscribe)
        XCTAssertFalse(plugin.usedBatchTranscribe)
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

    private func installBatchPlugin(
        _ plugin: TranscriptionEnginePlugin,
        appSupportDirectory: URL
    ) -> ModelManagerService {
        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: type(of: plugin).pluginId,
                    name: type(of: plugin).pluginName,
                    version: "1.0.0",
                    principalClass: String(describing: type(of: plugin))
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

private final class ModelManagerSourceProgressRecorder: @unchecked Sendable {
    private let progress = OSAllocatedUnfairLock<PluginTranscriptionSourceProgress?>(initialState: nil)

    func record(_ value: PluginTranscriptionSourceProgress) {
        progress.withLock { $0 = value }
    }

    var recordedProgress: PluginTranscriptionSourceProgress? {
        progress.withLock { $0 }
    }
}

private final class SourceProgressModelManagerPlugin: NSObject, SourceProgressTranscriptionEnginePlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.mock.source-progress-model-manager"
    static let pluginName = "Source Progress Model Manager Mock"

    private(set) var usedLegacyTranscribe = false
    private(set) var usedSourceProgressTranscribe = false

    var providerId: String { "mock-source-progress-model-manager" }
    var providerDisplayName: String { Self.pluginName }
    var isConfigured: Bool { true }
    var selectedModelId: String? { nil }
    var transcriptionModels: [PluginModelInfo] { [] }
    var supportsTranslation: Bool { false }
    var supportsStreaming: Bool { true }
    var supportedLanguages: [String] { ["en"] }

    func activate(host: HostServices) {}
    func deactivate() {}
    func selectModel(_ modelId: String) {}

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        usedLegacyTranscribe = true
        return PluginTranscriptionResult(text: "legacy source done", detectedLanguage: language)
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool,
        onSourceProgress: @Sendable @escaping (PluginTranscriptionSourceProgress) -> Bool
    ) async throws -> PluginTranscriptionResult {
        usedSourceProgressTranscribe = true
        _ = onProgress("source partial")
        _ = onSourceProgress(PluginTranscriptionSourceProgress(
            processedDuration: 1.5,
            totalDuration: 4,
            previewText: "source partial"
        ))
        return PluginTranscriptionResult(text: "source done", detectedLanguage: language)
    }
}

private final class LegacyModelManagerTranscriptionPlugin: NSObject, TranscriptionEnginePlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.mock.legacy-model-manager"
    static let pluginName = "Legacy Model Manager Mock"

    private(set) var usedBatchTranscribe = false
    private(set) var usedStreamingTranscribe = false

    var providerId: String { "mock-legacy-model-manager" }
    var providerDisplayName: String { Self.pluginName }
    var isConfigured: Bool { true }
    var selectedModelId: String? { nil }
    var transcriptionModels: [PluginModelInfo] { [] }
    var supportsTranslation: Bool { false }
    var supportsStreaming: Bool { true }
    var supportedLanguages: [String] { ["en"] }

    func activate(host: HostServices) {}
    func deactivate() {}
    func selectModel(_ modelId: String) {}

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        usedBatchTranscribe = true
        return PluginTranscriptionResult(text: "legacy batch done", detectedLanguage: language)
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool
    ) async throws -> PluginTranscriptionResult {
        usedStreamingTranscribe = true
        _ = onProgress("legacy partial")
        return PluginTranscriptionResult(text: "legacy done", detectedLanguage: language)
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
