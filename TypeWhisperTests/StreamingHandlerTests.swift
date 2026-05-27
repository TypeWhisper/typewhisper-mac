import XCTest
import os
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
        var languages = ["en"]
        var supportedLanguages: [String] { languages }
        private(set) var transcribeCallCount = 0
        private(set) var lastPrompt: String?

        func activate(host: HostServices) {}
        func deactivate() {}
        func selectModel(_ modelId: String) {}

        func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
            transcribeCallCount += 1
            lastPrompt = prompt
            return PluginTranscriptionResult(text: "final", detectedLanguage: language)
        }
    }

    private final class MockStreamingFallbackPlugin: NSObject, TranscriptionEnginePlugin, @unchecked Sendable {
        static var pluginId: String { "com.typewhisper.mock.streaming-fallback" }
        static var pluginName: String { "Mock Streaming Fallback" }

        var providerId: String { "mock-streaming-fallback" }
        var providerDisplayName: String { "Mock Streaming Fallback" }
        var isConfigured: Bool { true }
        var transcriptionModels: [PluginModelInfo] { [] }
        var selectedModelId: String? { nil }
        var supportsTranslation: Bool { false }
        var supportsStreaming: Bool { true }
        var supportedLanguages: [String] { ["en"] }
        private(set) var transcribeCallCount = 0
        private(set) var recordedSampleCounts: [Int] = []
        private(set) var lastPrompt: String?

        func activate(host: HostServices) {}
        func deactivate() {}
        func selectModel(_ modelId: String) {}

        func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
            transcribeCallCount += 1
            recordedSampleCounts.append(audio.samples.count)
            lastPrompt = prompt
            return PluginTranscriptionResult(text: "fallback-\(audio.samples.count)", detectedLanguage: language)
        }

        func transcribe(
            audio: AudioData,
            language: String?,
            translate: Bool,
            prompt: String?,
            onProgress: @Sendable @escaping (String) -> Bool
        ) async throws -> PluginTranscriptionResult {
            transcribeCallCount += 1
            recordedSampleCounts.append(audio.samples.count)
            lastPrompt = prompt
            _ = onProgress("preview-\(audio.samples.count)")
            return PluginTranscriptionResult(text: "fallback-\(audio.samples.count)", detectedLanguage: language)
        }
    }

    private actor SlowPreviewFallbackRecorder {
        private var activeTranscriptions = 0
        private var maxConcurrentTranscriptions = 0
        private var prompts: [String?] = []

        func begin(prompt: String?) {
            activeTranscriptions += 1
            maxConcurrentTranscriptions = max(maxConcurrentTranscriptions, activeTranscriptions)
            prompts.append(prompt)
        }

        func end() {
            activeTranscriptions -= 1
        }

        func snapshot() -> (callCount: Int, maxConcurrentTranscriptions: Int, prompts: [String?]) {
            (prompts.count, maxConcurrentTranscriptions, prompts)
        }
    }

    private final class MockPreviewFallbackOptOutPlugin: NSObject, TranscriptionEnginePlugin, TranscriptPreviewFallbackPolicyProviding, @unchecked Sendable {
        static var pluginId: String { "com.typewhisper.mock.preview-opt-out" }
        static var pluginName: String { "Mock Preview Opt Out" }

        var providerId: String { "mock-preview-opt-out" }
        var providerDisplayName: String { "Mock Preview Opt Out" }
        var isConfigured: Bool { true }
        var transcriptionModels: [PluginModelInfo] { [] }
        var selectedModelId: String? { nil }
        var supportsTranslation: Bool { false }
        var supportsStreaming: Bool { false }
        var supportedLanguages: [String] { ["en"] }
        var allowsTranscriptPreviewFallback: Bool { false }

        private let recorder = SlowPreviewFallbackRecorder()

        func activate(host: HostServices) {}
        func deactivate() {}
        func selectModel(_ modelId: String) {}

        func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
            await recorder.begin(prompt: prompt)
            try await Task.sleep(for: .milliseconds(500))
            await recorder.end()
            return PluginTranscriptionResult(text: "final-\(prompt ?? "none")", detectedLanguage: language)
        }

        func snapshot() async -> (callCount: Int, maxConcurrentTranscriptions: Int, prompts: [String?]) {
            await recorder.snapshot()
        }
    }

    private final class MockHintPlugin: NSObject, LanguageHintTranscriptionEnginePlugin, @unchecked Sendable {
        static var pluginId: String { "com.typewhisper.mock.hints" }
        static var pluginName: String { "Mock Hints" }

        var providerId: String { "mock-hints" }
        var providerDisplayName: String { "Mock Hints" }
        var isConfigured: Bool { true }
        var transcriptionModels: [PluginModelInfo] { [] }
        var selectedModelId: String? { nil }
        var supportsTranslation: Bool { false }
        var supportsStreaming: Bool { false }
        var supportedLanguages: [String] { ["de", "en", "nl"] }
        private(set) var lastSelection = PluginLanguageSelection()

        func activate(host: HostServices) {}
        func deactivate() {}
        func selectModel(_ modelId: String) {}

        func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
            XCTFail("Legacy language API should not be used when hints are available")
            return PluginTranscriptionResult(text: "", detectedLanguage: language)
        }

        func transcribe(
            audio: AudioData,
            languageSelection: PluginLanguageSelection,
            translate: Bool,
            prompt: String?
        ) async throws -> PluginTranscriptionResult {
            lastSelection = languageSelection
            return PluginTranscriptionResult(text: "hinted", detectedLanguage: languageSelection.languageHints.first)
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
        private(set) var lastPrompt: String?

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
            lastPrompt = prompt
            await session.setOnProgress(onProgress)
            return session
        }
    }

    private final class MockHintLivePlugin: NSObject, LiveLanguageHintTranscriptionCapablePlugin, @unchecked Sendable {
        static var pluginId: String { "com.typewhisper.mock.live-hints" }
        static var pluginName: String { "Mock Live Hints" }

        var providerId: String { "mock-live-hints" }
        var providerDisplayName: String { "Mock Live Hints" }
        var isConfigured: Bool { true }
        var transcriptionModels: [PluginModelInfo] { [] }
        var selectedModelId: String? { nil }
        var supportsTranslation: Bool { false }
        var supportsStreaming: Bool { true }
        var supportedLanguages: [String] { ["de", "en"] }
        let session = MockLiveSession()
        private(set) var lastSelection = PluginLanguageSelection()
        private(set) var lastPrompt: String?

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
            XCTFail("Legacy streaming should not be used for the hint-aware live-session path")
            return PluginTranscriptionResult(text: "", detectedLanguage: language)
        }

        func createLiveTranscriptionSession(
            language: String?,
            translate: Bool,
            prompt: String?,
            onProgress: @Sendable @escaping (String) -> Bool
        ) async throws -> any LiveTranscriptionSession {
            XCTFail("Legacy live-session API should not be used when hint-aware API exists")
            return session
        }

        func createLiveTranscriptionSession(
            languageSelection: PluginLanguageSelection,
            translate: Bool,
            prompt: String?,
            onProgress: @Sendable @escaping (String) -> Bool
        ) async throws -> any LiveTranscriptionSession {
            lastSelection = languageSelection
            lastPrompt = prompt
            await session.setOnProgress(onProgress)
            return session
        }
    }

    private actor MockLiveSession: LiveTranscriptionSession {
        private var appendedChunkSizes: [Int] = []
        private var onProgress: (@Sendable (String) -> Bool)?
        private var progressUpdates: [String] = []

        func setOnProgress(_ onProgress: @escaping @Sendable (String) -> Bool) {
            self.onProgress = onProgress
        }

        func setProgressUpdates(_ progressUpdates: [String]) {
            self.progressUpdates = progressUpdates
        }

        func appendAudio(samples: [Float]) async throws {
            appendedChunkSizes.append(samples.count)
            let progressText: String
            if progressUpdates.isEmpty {
                progressText = "chunk-\(samples.count)"
            } else {
                progressText = progressUpdates.removeFirst()
            }
            _ = onProgress?(progressText)
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

    func testMeteredBatchPluginStillUsesIntermediatePreviewCalls() async throws {
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
            bufferProvider: { Array(repeating: 0.5, count: 16_000) },
            recentBufferProvider: { _ in Array(repeating: 0.5, count: 16_000) },
            bufferDeltaProvider: { _ in ([], 0) },
            bufferedDurationProvider: { 1.0 }
        )

        handler.start(
            streamPrompt: "Batch Terms",
            engineOverrideId: plugin.providerId,
            selectedProviderId: plugin.providerId,
            languageSelection: .exact("en"),
            task: .transcribe,
            cloudModelOverride: nil,
            allowLiveTranscription: true,
            stateCheck: { true }
        )

        try await Task.sleep(for: .milliseconds(3400))
        handler.stop()

        XCTAssertEqual(plugin.transcribeCallCount, 1)
        XCTAssertEqual(plugin.lastPrompt, "Batch Terms")
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
            bufferProvider: { Array(repeating: 0.5, count: 16_000) },
            recentBufferProvider: { _ in Array(repeating: 0.5, count: 16_000) },
            bufferDeltaProvider: { _ in ([], 0) },
            bufferedDurationProvider: { 1.0 }
        )

        handler.start(
            streamPrompt: "Unused Terms",
            engineOverrideId: plugin.providerId,
            selectedProviderId: plugin.providerId,
            languageSelection: .exact("en"),
            task: .transcribe,
            cloudModelOverride: nil,
            allowLiveTranscription: false,
            stateCheck: { true }
        )

        try await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(plugin.transcribeCallCount, 0)
    }

    func testStreamingFallbackDoesNotPreviewBeforeThreeSeconds() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let plugin = MockStreamingFallbackPlugin()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.streaming-fallback",
                    name: "Mock Streaming Fallback",
                    version: "1.0.0",
                    principalClass: "MockStreamingFallbackPlugin"
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
            bufferProvider: {
                XCTFail("full buffer provider should not be used for fallback previews")
                return Array(repeating: 0.5, count: 160_000)
            },
            recentBufferProvider: { _ in Array(repeating: 0.5, count: 16_000) },
            bufferDeltaProvider: { _ in ([], 0) },
            bufferedDurationProvider: { 10.0 }
        )

        handler.start(
            streamPrompt: "Fallback Terms",
            engineOverrideId: plugin.providerId,
            selectedProviderId: plugin.providerId,
            languageSelection: .exact("en"),
            task: .transcribe,
            cloudModelOverride: nil,
            allowLiveTranscription: true,
            stateCheck: { true }
        )

        try await Task.sleep(for: .milliseconds(2500))
        handler.stop()

        XCTAssertEqual(plugin.transcribeCallCount, 0)
    }

    func testStreamingFallbackCallsPreviewAfterThreeSecondsEvenWithoutLiveSession() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let plugin = MockStreamingFallbackPlugin()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.streaming-fallback",
                    name: "Mock Streaming Fallback",
                    version: "1.0.0",
                    principalClass: "MockStreamingFallbackPlugin"
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
            bufferProvider: {
                XCTFail("full buffer provider should not be used for fallback previews")
                return Array(repeating: 0.5, count: 160_000)
            },
            recentBufferProvider: { _ in Array(repeating: 0.5, count: 16_000) },
            bufferDeltaProvider: { _ in ([], 0) },
            bufferedDurationProvider: { 10.0 }
        )

        handler.start(
            streamPrompt: "Fallback Terms",
            engineOverrideId: plugin.providerId,
            selectedProviderId: plugin.providerId,
            languageSelection: .exact("en"),
            task: .transcribe,
            cloudModelOverride: nil,
            allowLiveTranscription: true,
            stateCheck: { true }
        )

        try await Task.sleep(for: .milliseconds(3400))
        handler.stop()

        XCTAssertEqual(plugin.transcribeCallCount, 1)
        XCTAssertEqual(plugin.lastPrompt, "Fallback Terms")
    }

    func testStreamingFallbackUsesRecentWindowProviderInsteadOfFullBuffer() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let plugin = MockStreamingFallbackPlugin()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.streaming-fallback",
                    name: "Mock Streaming Fallback",
                    version: "1.0.0",
                    principalClass: "MockStreamingFallbackPlugin"
                ),
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let modelManager = ModelManagerService()
        modelManager.selectProvider(plugin.providerId)

        let requestedWindowLock = OSAllocatedUnfairLock(initialState: Optional<TimeInterval>.none)

        let handler = StreamingHandler(
            modelManager: modelManager,
            bufferProvider: {
                XCTFail("full buffer provider should not be used for fallback previews")
                return Array(repeating: 0.5, count: 160_000)
            },
            recentBufferProvider: { window in
                requestedWindowLock.withLock { requestedWindow in
                    requestedWindow = window
                }
                return Array(repeating: 0.5, count: 16_000)
            },
            bufferDeltaProvider: { _ in ([], 0) },
            bufferedDurationProvider: { 10.0 }
        )

        handler.start(
            streamPrompt: "Fallback Terms",
            engineOverrideId: plugin.providerId,
            selectedProviderId: plugin.providerId,
            languageSelection: .exact("en"),
            task: .transcribe,
            cloudModelOverride: nil,
            allowLiveTranscription: true,
            stateCheck: { true }
        )

        try await Task.sleep(for: .milliseconds(3400))
        handler.stop()

        let finalRequestedWindow = requestedWindowLock.withLock { $0 }

        XCTAssertEqual(finalRequestedWindow, 10)
        XCTAssertEqual(plugin.recordedSampleCounts, [16_000])
    }

    func testStreamingFallbackSkipsPreviewWhenRecentWindowEndsInSustainedSilence() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let plugin = MockStreamingFallbackPlugin()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.streaming-fallback",
                    name: "Mock Streaming Fallback",
                    version: "1.0.0",
                    principalClass: "MockStreamingFallbackPlugin"
                ),
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let modelManager = ModelManagerService()
        modelManager.selectProvider(plugin.providerId)

        let updatesLock = OSAllocatedUnfairLock(initialState: [String]())
        let handler = StreamingHandler(
            modelManager: modelManager,
            bufferProvider: {
                XCTFail("full buffer provider should not be used for fallback previews")
                return []
            },
            recentBufferProvider: { _ in
                Array(repeating: Float(0.2), count: 16_000)
                    + Array(repeating: Float(0.0001), count: 40_000)
            },
            bufferDeltaProvider: { _ in ([], 0) },
            bufferedDurationProvider: { 3.5 }
        )
        handler.onPartialTextUpdate = { text in
            updatesLock.withLock { $0.append(text) }
        }

        handler.start(
            streamPrompt: "Fallback Terms",
            engineOverrideId: plugin.providerId,
            selectedProviderId: plugin.providerId,
            languageSelection: .exact("de"),
            task: .transcribe,
            cloudModelOverride: nil,
            allowLiveTranscription: true,
            stateCheck: { true }
        )

        try await Task.sleep(for: .milliseconds(3400))
        handler.stop()

        XCTAssertEqual(plugin.transcribeCallCount, 0)
        XCTAssertTrue(updatesLock.withLock { $0 }.isEmpty)
    }

    func testStabilizeTextAppendsDisjointPreviewWindows() {
        let stable = StreamingHandler.stabilizeText(
            confirmed: "First sentence.",
            new: "Second sentence."
        )

        XCTAssertEqual(stable, "First sentence. Second sentence.")
    }

    func testStabilizeTextMergesOverlappingPreviewWindows() {
        let stable = StreamingHandler.stabilizeText(
            confirmed: "First sentence. Second sentence.",
            new: "Second sentence. Third sentence."
        )

        XCTAssertEqual(stable, "First sentence. Second sentence. Third sentence.")
    }

    func testStabilizeTextMergesFuzzyOverlappingPreviewWindows() {
        let stable = StreamingHandler.stabilizeText(
            confirmed: "Jetzt funktioniert es perfekt.",
            new: "funktioniert perfekt. Faellt dir noch was ein, was wir vorm testen sollten?"
        )

        XCTAssertEqual(
            stable,
            "Jetzt funktioniert es perfekt. Faellt dir noch was ein, was wir vorm testen sollten?"
        )
    }

    func testStabilizeTextReplacesRestatedPreviewWindowInsteadOfAppending() {
        let stable = StreamingHandler.stabilizeText(
            confirmed: "Ich rede jetzt und rede jetzt ein bisschen laenger.",
            new: "Ich rede jetzt. Ich drehe jetzt ein bisschen laenger."
        )

        XCTAssertEqual(
            stable,
            "Ich rede jetzt. Ich drehe jetzt ein bisschen laenger."
        )
    }

    func testStabilizeTextMergesApproximateOverlappingPreviewWindow() {
        let stable = StreamingHandler.stabilizeText(
            confirmed: "Ich rede jetzt. Ich drehe jetzt ein bisschen laenger.",
            new: "Dreh dir jetzt ein bisschen laenger. Dreh dir immer noch."
        )

        XCTAssertEqual(
            stable,
            "Ich rede jetzt. Ich drehe jetzt ein bisschen laenger. Dreh dir immer noch."
        )
    }

    func testStabilizeTextDropsRepeatedEarlierPreviewPrefixAfterPause() {
        let stable = StreamingHandler.stabilizeText(
            confirmed: """
            Super. Koennen wir jetzt noch einmal... einbauen, also ein bisschen zumindest dieses Abstand vom Ding, wenn man lange... man lange Pause macht. Man muss ja nicht dann letztendlich.
            """,
            new: """
            dieses Abstand vom Ding, wenn man lange Pause macht. Das muss ja nicht ein letztlich haben muss., ist das. Aber wie das ist erstmal so. Ist das? Aber wir lassen es erstmal so.
            """
        )

        XCTAssertEqual(
            stable,
            """
            Super. Koennen wir jetzt noch einmal... einbauen, also ein bisschen zumindest dieses Abstand vom Ding, wenn man lange... man lange Pause macht. Man muss ja nicht dann letztendlich. Das muss ja nicht ein letztlich haben muss., ist das. Aber wie das ist erstmal so. Ist das? Aber wir lassen es erstmal so.
            """
        )
    }

    func testStabilizeTextReplacesProviderCorrectionInsteadOfAppendingSuffix() {
        let stable = StreamingHandler.stabilizeText(
            confirmed: "Ich bin an Koin.",
            new: "Ich bin an Koeln."
        )

        XCTAssertEqual(stable, "Ich bin an Koeln.")
    }

    func testPreviewFallbackOptOutSkipsIntermediateWorkAndAllowsFinalTranscription() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let plugin = MockPreviewFallbackOptOutPlugin()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.preview-opt-out",
                    name: "Mock Preview Opt Out",
                    version: "1.0.0",
                    principalClass: "MockPreviewFallbackOptOutPlugin"
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
            bufferProvider: {
                XCTFail("full buffer provider should not be used for fallback previews")
                return Array(repeating: 0.5, count: 160_000)
            },
            recentBufferProvider: { _ in Array(repeating: 0.5, count: 16_000) },
            bufferDeltaProvider: { _ in ([], 0) },
            bufferedDurationProvider: { 10.0 }
        )

        handler.start(
            streamPrompt: "Preview Terms",
            engineOverrideId: plugin.providerId,
            selectedProviderId: plugin.providerId,
            languageSelection: .exact("en"),
            task: .transcribe,
            cloudModelOverride: nil,
            allowLiveTranscription: true,
            stateCheck: { true }
        )

        try await Task.sleep(for: .milliseconds(3400))
        let liveResult = await handler.finish()
        let finalResult = try await modelManager.transcribe(
            audioSamples: Array(repeating: 0.5, count: 16_000),
            languageSelection: .exact("en"),
            task: .transcribe,
            engineOverrideId: plugin.providerId,
            cloudModelOverride: nil,
            prompt: "Final Terms"
        )
        let snapshot = await plugin.snapshot()

        XCTAssertNil(liveResult)
        XCTAssertEqual(finalResult.text, "final-Final Terms")
        XCTAssertEqual(snapshot.callCount, 1)
        XCTAssertEqual(snapshot.maxConcurrentTranscriptions, 1)
        XCTAssertEqual(snapshot.prompts, ["Final Terms"])
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
            bufferProvider: { [] },
            recentBufferProvider: { _ in [] },
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
            streamPrompt: "Live Terms",
            engineOverrideId: plugin.providerId,
            selectedProviderId: plugin.providerId,
            languageSelection: .exact("en"),
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
        XCTAssertEqual(plugin.lastPrompt, "Live Terms")
    }

    func testLiveSessionProgressAllowsProviderCorrections() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let plugin = MockLivePlugin()
        await plugin.session.setProgressUpdates([
            "Ich bin an Koin.",
            "Ich bin an Koeln.",
        ])
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
            Array(repeating: Float(0.3), count: 4000),
        ]
        let indexLock = NSLock()
        var index = 0
        var nextOffset = 0

        let handler = StreamingHandler(
            modelManager: modelManager,
            bufferProvider: { [] },
            recentBufferProvider: { _ in [] },
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

        let updatesLock = OSAllocatedUnfairLock(initialState: [String]())
        handler.onPartialTextUpdate = { text in
            updatesLock.withLock { $0.append(text) }
        }

        var activeChecks = 0
        handler.start(
            streamPrompt: "Live Terms",
            engineOverrideId: plugin.providerId,
            selectedProviderId: plugin.providerId,
            languageSelection: .exact("de"),
            task: .transcribe,
            cloudModelOverride: nil,
            allowLiveTranscription: true,
            stateCheck: {
                activeChecks += 1
                return activeChecks <= 3
            }
        )

        try await Task.sleep(for: .milliseconds(900))
        handler.stop()

        let updates = updatesLock.withLock { $0 }
        XCTAssertEqual(updates.last, "Ich bin an Koeln.")
        XCTAssertFalse(updates.contains("Ich bin an Koin.eln."))
    }

    func testLiveSessionSuppressesAdditiveProgressDuringSustainedSilence() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let plugin = MockLivePlugin()
        await plugin.session.setProgressUpdates([
            "Gesprochener Satz.",
            "Gesprochener Satz. Halluzinierter Nachsatz.",
        ])
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
            Array(repeating: Float(0.2), count: 16_000),
            Array(repeating: Float(0.0001), count: 40_000),
        ]
        let indexLock = NSLock()
        var index = 0
        var nextOffset = 0

        let handler = StreamingHandler(
            modelManager: modelManager,
            bufferProvider: { [] },
            recentBufferProvider: { _ in [] },
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
            bufferedDurationProvider: { 3.5 }
        )

        let updatesLock = OSAllocatedUnfairLock(initialState: [String]())
        handler.onPartialTextUpdate = { text in
            updatesLock.withLock { $0.append(text) }
        }

        var activeChecks = 0
        handler.start(
            streamPrompt: "Live Terms",
            engineOverrideId: plugin.providerId,
            selectedProviderId: plugin.providerId,
            languageSelection: .exact("de"),
            task: .transcribe,
            cloudModelOverride: nil,
            allowLiveTranscription: true,
            stateCheck: {
                activeChecks += 1
                return activeChecks <= 3
            }
        )

        try await Task.sleep(for: .milliseconds(900))
        handler.stop()

        XCTAssertEqual(updatesLock.withLock { $0 }, ["Gesprochener Satz."])
    }

    func testModelManagerUsesHintAwarePluginWhenMultipleHintsAreSelected() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let plugin = MockHintPlugin()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.hints",
                    name: "Mock Hints",
                    version: "1.0.0",
                    principalClass: "MockHintPlugin"
                ),
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let modelManager = ModelManagerService()
        modelManager.selectProvider(plugin.providerId)

        _ = try await modelManager.transcribe(
            audioSamples: Array(repeating: 0.25, count: 16_000),
            languageSelection: .hints(["de", "en"]),
            task: .transcribe
        )

        XCTAssertEqual(plugin.lastSelection.languageHints, ["de", "en"])
        XCTAssertNil(plugin.lastSelection.requestedLanguage)
    }

    func testModelManagerUsesFirstSelectedHintForLegacyPluginsWithMultipleHints() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let plugin = MockBatchPlugin()
        plugin.languages = ["de", "en"]
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.batch",
                    name: "Mock Batch",
                    version: "1.0.0",
                    principalClass: "MockBatchPlugin"
                ),
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let modelManager = ModelManagerService()
        modelManager.selectProvider(plugin.providerId)

        let result = try await modelManager.transcribe(
            audioSamples: Array(repeating: 0.25, count: 16_000),
            languageSelection: .hints(["de", "en"]),
            task: .transcribe
        )

        XCTAssertEqual(result.detectedLanguage, "de")
    }

    func testModelManagerFiltersUnsupportedHintsBeforeLegacyFallback() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let plugin = MockBatchPlugin()
        plugin.languages = ["en"]
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.batch",
                    name: "Mock Batch",
                    version: "1.0.0",
                    principalClass: "MockBatchPlugin"
                ),
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let modelManager = ModelManagerService()
        modelManager.selectProvider(plugin.providerId)

        let result = try await modelManager.transcribe(
            audioSamples: Array(repeating: 0.25, count: 16_000),
            languageSelection: .hints(["de", "en"]),
            task: .transcribe
        )

        XCTAssertEqual(result.detectedLanguage, "en")
    }

    func testStreamingHandlerUsesHintAwareLiveSessionWhenAvailable() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let plugin = MockHintLivePlugin()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.live-hints",
                    name: "Mock Live Hints",
                    version: "1.0.0",
                    principalClass: "MockHintLivePlugin"
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
            bufferProvider: { [] },
            recentBufferProvider: { _ in [] },
            bufferDeltaProvider: { _ in (Array(repeating: 0.1, count: 4000), 4000) },
            bufferedDurationProvider: { 0.25 }
        )

        handler.start(
            streamPrompt: "Hint Terms",
            engineOverrideId: plugin.providerId,
            selectedProviderId: plugin.providerId,
            languageSelection: .hints(["de", "en"]),
            task: .transcribe,
            cloudModelOverride: nil,
            allowLiveTranscription: true,
            stateCheck: { false }
        )

        try await Task.sleep(for: .milliseconds(150))
        _ = await handler.finish()

        XCTAssertEqual(plugin.lastSelection.languageHints, ["de", "en"])
        XCTAssertNil(plugin.lastSelection.requestedLanguage)
        XCTAssertEqual(plugin.lastPrompt, "Hint Terms")
    }
}
