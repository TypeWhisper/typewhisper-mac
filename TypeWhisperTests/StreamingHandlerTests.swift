import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

@MainActor
final class StreamingHandlerTests: XCTestCase {
    private final class MockBatchPlugin: NSObject, TranscriptionEnginePlugin, @unchecked Sendable {
        static var pluginId: String { "com.typewhisper.mock.batch" }
        static var pluginName: String { "Mock Batch" }

        var providerId: String { "mock-batch" }
        var providerDisplayName: String { "Mock Batch" }
        var isConfigured: Bool { true }
        var transcriptionModels: [PluginModelInfo] { [] }
        var selectedModelId: String? { nil }
        var supportsTranslation: Bool { false }
        var supportsStreaming: Bool { false }
        var supportedLanguages: [String] { ["en"] }
        private(set) var transcribeCallCount = 0

        func activate(host: HostServices) {}
        func deactivate() {}
        func selectModel(_ modelId: String) {}

        func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
            transcribeCallCount += 1
            return PluginTranscriptionResult(text: "final", detectedLanguage: language)
        }
    }

    private final class MockLivePlugin: NSObject, LiveTranscriptionCapablePlugin, @unchecked Sendable {
        static var pluginId: String { "com.typewhisper.mock.live" }
        static var pluginName: String { "Mock Live" }

        var providerId: String { "mock-live" }
        var providerDisplayName: String { "Mock Live" }
        var isConfigured: Bool { true }
        var transcriptionModels: [PluginModelInfo] { [] }
        var selectedModelId: String? { nil }
        var supportsTranslation: Bool { false }
        var supportsStreaming: Bool { true }
        var supportedLanguages: [String] { ["en"] }
        let session = MockLiveSession()

        func activate(host: HostServices) {}
        func deactivate() {}
        func selectModel(_ modelId: String) {}

        func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
            XCTFail("Batch transcribe should not be used for the live-session path")
            return PluginTranscriptionResult(text: "", detectedLanguage: language)
        }

        func transcribe(
            audio: AudioData,
            language: String?,
            translate: Bool,
            prompt: String?,
            onProgress: @Sendable @escaping (String) -> Bool
        ) async throws -> PluginTranscriptionResult {
            XCTFail("Legacy streaming should not be used for the live-session path")
            return PluginTranscriptionResult(text: "", detectedLanguage: language)
        }

        func createLiveTranscriptionSession(
            language: String?,
            translate: Bool,
            prompt: String?,
            onProgress: @Sendable @escaping (String) -> Bool
        ) async throws -> any LiveTranscriptionSession {
            await session.setOnProgress(onProgress)
            return session
        }
    }

    private actor MockLiveSession: LiveTranscriptionSession {
        private var appendedChunkSizes: [Int] = []
        private var onProgress: (@Sendable (String) -> Bool)?

        func setOnProgress(_ onProgress: @escaping @Sendable (String) -> Bool) {
            self.onProgress = onProgress
        }

        func appendAudio(samples: [Float]) async throws {
            appendedChunkSizes.append(samples.count)
            _ = onProgress?("chunk-\(samples.count)")
        }

        func finish() async throws -> PluginTranscriptionResult {
            PluginTranscriptionResult(text: "finished", detectedLanguage: "en")
        }

        func cancel() async {}

        func recordedChunks() -> [Int] {
            appendedChunkSizes
        }
    }

    override func tearDown() {
        PluginManager.shared = nil
        super.tearDown()
    }

    func testMeteredBatchPluginSkipsIntermediateCalls() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let plugin = MockBatchPlugin()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.batch",
                    name: "Mock Batch",
                    version: "1.0.0",
                    principalClass: "MockBatchPlugin",
                    requiresAPIKey: true
                ),
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let modelManager = ModelManagerService()
        modelManager.selectProvider(plugin.providerId)

        let handler = StreamingHandler(
            modelManager: modelManager,
            streamPromptProvider: { "" },
            bufferProvider: { Array(repeating: 0.5, count: 16_000) },
            bufferDeltaProvider: { _ in ([], 0) },
            bufferedDurationProvider: { 1.0 }
        )

        handler.start(
            engineOverrideId: plugin.providerId,
            selectedProviderId: plugin.providerId,
            language: "en",
            task: .transcribe,
            cloudModelOverride: nil,
            allowLiveTranscription: true,
            stateCheck: { true }
        )

        try await Task.sleep(for: .milliseconds(700))
        handler.stop()

        XCTAssertEqual(plugin.transcribeCallCount, 0)
    }

    func testDisabledLiveTranscriptionPreventsAnyIntermediateWork() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let plugin = MockBatchPlugin()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.local",
                    name: "Mock Local",
                    version: "1.0.0",
                    principalClass: "MockBatchPlugin",
                    requiresAPIKey: false
                ),
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let modelManager = ModelManagerService()
        modelManager.selectProvider(plugin.providerId)

        let handler = StreamingHandler(
            modelManager: modelManager,
            streamPromptProvider: { "" },
            bufferProvider: { Array(repeating: 0.5, count: 16_000) },
            bufferDeltaProvider: { _ in ([], 0) },
            bufferedDurationProvider: { 1.0 }
        )

        handler.start(
            engineOverrideId: plugin.providerId,
            selectedProviderId: plugin.providerId,
            language: "en",
            task: .transcribe,
            cloudModelOverride: nil,
            allowLiveTranscription: false,
            stateCheck: { true }
        )

        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(plugin.transcribeCallCount, 0)
    }

    func testLiveSessionConsumesOnlyIncrementalAudioDeltas() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let plugin = MockLivePlugin()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.live",
                    name: "Mock Live",
                    version: "1.0.0",
                    principalClass: "MockLivePlugin",
                    requiresAPIKey: false
                ),
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let modelManager = ModelManagerService()
        modelManager.selectProvider(plugin.providerId)

        let chunks = [
            Array(repeating: Float(0.2), count: 4000),
            Array(repeating: Float(0.3), count: 2500),
            Array(repeating: Float(0.4), count: 1500),
        ]
        let indexLock = NSLock()
        var index = 0
        var nextOffset = 0

        let handler = StreamingHandler(
            modelManager: modelManager,
            streamPromptProvider: { "" },
            bufferProvider: { [] },
            bufferDeltaProvider: { _ in
                indexLock.lock()
                defer { indexLock.unlock() }
                guard index < chunks.count else {
                    return ([], nextOffset)
                }
                let chunk = chunks[index]
                index += 1
                nextOffset += chunk.count
                return (chunk, nextOffset)
            },
            bufferedDurationProvider: { 0.5 }
        )

        var activeChecks = 0
        handler.start(
            engineOverrideId: plugin.providerId,
            selectedProviderId: plugin.providerId,
            language: "en",
            task: .transcribe,
            cloudModelOverride: nil,
            allowLiveTranscription: true,
            stateCheck: {
                activeChecks += 1
                return activeChecks <= 4
            }
        )

        try await Task.sleep(for: .milliseconds(1200))
        let result = await handler.finish()

        XCTAssertEqual(result?.text, "finished")
        let recorded = await plugin.session.recordedChunks()
        XCTAssertEqual(recorded, chunks.map(\.count))
    }
}
