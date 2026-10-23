import Foundation
import XCTest
import WhisperKit
import class WhisperKit.TranscriptionResult
import struct WhisperKit.TranscriptionSegment
import TypeWhisperPluginSDK
import os
@testable import TypeWhisper

/// Runs WhisperKit's real VAD chunker and batch scheduler, replacing only inference.
private final class FailingChunkWhisperKit: WhisperKit, @unchecked Sendable {
    enum FailureMode { case once, always, cancelled, none }
    var failureMode: FailureMode = .once
    private let state = OSAllocatedUnfairLock(initialState: (attempts: [Int: Int](), requests: [DecodingOptions]()))
    var attempts: [Int: Int] { state.withLock { $0.attempts } }
    var requests: [DecodingOptions] { state.withLock { $0.requests } }

    override func runTranscribeTask(
        audioArray: [Float],
        decodeOptions: DecodingOptions? = nil,
        callback: TranscriptionCallback = nil,
        segmentCallback: SegmentDiscoveryCallback? = nil
    ) async throws -> [TranscriptionResult] {
        let marker = Int(audioArray.first ?? 0)
        let attempt = state.withLock { state in
            state.attempts[marker, default: 0] += 1
            if let decodeOptions { state.requests.append(decodeOptions) }
            return state.attempts[marker, default: 0]
        }
        if marker == 2 {
            switch failureMode {
            case .once where attempt == 1, .always:
                throw WhisperError.transcriptionFailed("injected chunk failure")
            case .cancelled:
                throw CancellationError()
            default: break
            }
        }
        let text = "part \(marker)"
        let segment = TranscriptionSegment(
            start: 0, end: Float(audioArray.count) / Float(WhisperKit.sampleRate), text: text
        )
        _ = callback?(TranscriptionProgress(timings: TranscriptionTimings(), text: text, tokens: []))
        (segmentCallback ?? segmentDiscoveryCallback)?([segment])
        return [TranscriptionResult(text: text, segments: [segment], language: "nl", timings: TranscriptionTimings())]
    }
}

@MainActor
final class WhisperKitPluginLifecycleTests: XCTestCase {
    private final class MockEventBus: EventBusProtocol {
        @discardableResult
        func subscribe(handler: @escaping @Sendable (TypeWhisperEvent) async -> Void) -> UUID { UUID() }
        func unsubscribe(id: UUID) {}
    }

    private final class MockHostServices: HostServices, HostModelLifecyclePolicyProviding, @unchecked Sendable {
        private var defaults: [String: Any]
        private var secrets: [String: String] = [:]

        let pluginDataDirectory: URL
        let eventBus: EventBusProtocol = MockEventBus()
        var activeAppBundleId: String?
        var activeAppName: String?
        var availableRuleNames: [String] = []
        var shouldRestoreLoadedModelsPassively: Bool
        private(set) var capabilitiesChangedCount = 0

        init(
            pluginDataDirectory: URL,
            defaults: [String: Any] = [:],
            shouldRestoreLoadedModelsPassively: Bool = true
        ) {
            self.pluginDataDirectory = pluginDataDirectory
            self.defaults = defaults
            self.shouldRestoreLoadedModelsPassively = shouldRestoreLoadedModelsPassively
        }

        func storeSecret(key: String, value: String) throws { secrets[key] = value }
        func loadSecret(key: String) -> String? { secrets[key] }
        func userDefault(forKey key: String) -> Any? { defaults[key] }
        func setUserDefault(_ value: Any?, forKey key: String) { defaults[key] = value }
        func notifyCapabilitiesChanged() { capabilitiesChangedCount += 1 }
        func setStreamingDisplayActive(_ active: Bool) {}
    }

    private func makeHost(
        defaults: [String: Any] = [:],
        shouldRestoreLoadedModelsPassively: Bool = true
    ) throws -> MockHostServices {
        let pluginDataDirectory = try TestSupport.makeTemporaryDirectory(prefix: "WhisperKitLifecycleTests")
        return MockHostServices(
            pluginDataDirectory: pluginDataDirectory,
            defaults: defaults,
            shouldRestoreLoadedModelsPassively: shouldRestoreLoadedModelsPassively
        )
    }

    #if DEBUG
    private func waitForRestoreLoadedModelInvocationCount(
        _ plugin: WhisperKitPlugin,
        toBecome expected: Int,
        timeout: Duration = .seconds(1),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if plugin.restoreLoadedModelInvocationCountForTesting == expected {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(plugin.restoreLoadedModelInvocationCountForTesting, expected, file: file, line: line)
    }
    #endif

    func testAvailableModelsIncludeDistilLargeV3Turbo() {
        let model = WhisperKitPlugin.availableModels.first {
            $0.id == "distil-whisper_distil-large-v3_turbo"
        }

        XCTAssertEqual(model?.displayName, "Distil Large v3 Turbo")
        XCTAssertEqual(model?.sizeDescription, "~1.5 GB")
        XCTAssertEqual(model?.ramRequirement, "8 GB+")
    }

    func testExactChineseLanguageDisablesWhisperKitLanguageDetection() {
        let options = WhisperKitPlugin.decodingOptions(language: "zh", translate: false)

        XCTAssertEqual(options.language, "zh")
        XCTAssertFalse(options.detectLanguage)
    }

    func testLongTranscriptionRetriesFailedChunkAndKeepsItsPosition() async throws {
        let engine = try await FailingChunkWhisperKit(WhisperKitConfig(load: false, download: false))
        let samples = (1...3).flatMap { Array(repeating: Float($0), count: 30 * WhisperKit.sampleRate) }
        var options = WhisperKitPlugin.decodingOptions(language: "nl", translate: false)
        options.promptTokens = [42]

        let results = try await WhisperKitPlugin.transcribeAudio(with: engine, samples: samples, options: options)

        XCTAssertEqual(results.text, "part 1 part 2 part 3")
        XCTAssertEqual(results.segments.map(\.start), [0, 30, 60])
        XCTAssertEqual(results.segments.map(\.end), [30, 60, 90])
        XCTAssertEqual(engine.attempts, [1: 1, 2: 2, 3: 1])
        XCTAssertTrue(engine.requests.allSatisfy { $0.language == "nl" && $0.promptTokens == [42] && $0.task == .transcribe })
    }

    func testLongTranscriptionDoesNotReturnPartialSuccessWhenChunkRetryFails() async throws {
        let engine = try await FailingChunkWhisperKit(WhisperKitConfig(load: false, download: false))
        engine.failureMode = .always
        let samples = (1...3).flatMap { Array(repeating: Float($0), count: 30 * WhisperKit.sampleRate) }

        do {
            _ = try await WhisperKitPlugin.transcribeAudio(
                with: engine, samples: samples,
                options: WhisperKitPlugin.decodingOptions(language: "nl", translate: false)
            )
            XCTFail("A missing middle chunk must not be returned as a successful transcript")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("2 of 3"), error.localizedDescription)
        }
        XCTAssertEqual(engine.attempts[2], 2)
    }

    func testLongTranscriptionReportsRecoveredChunkSourceProgressAtOriginalOffset() async throws {
        let engine = try await FailingChunkWhisperKit(WhisperKitConfig(load: false, download: false))
        let discoveredSegments = OSAllocatedUnfairLock(initialState: [TranscriptionSegment]())
        let capture: @Sendable ([TranscriptionSegment]) -> Void = { segments in
            discoveredSegments.withLock { $0.append(contentsOf: segments) }
        }
        engine.segmentDiscoveryCallback = capture
        let samples = (1...3).flatMap { Array(repeating: Float($0), count: 30 * WhisperKit.sampleRate) }

        let result = try await WhisperKitPlugin.transcribeAudio(
            with: engine, samples: samples,
            options: WhisperKitPlugin.decodingOptions(language: "nl", translate: false)
        )

        let recovered = try XCTUnwrap(discoveredSegments.withLock { $0.first { $0.text == "part 2" } })
        XCTAssertEqual(recovered.seek, 30 * WhisperKit.sampleRate)
        XCTAssertEqual(recovered.start, 30)
        XCTAssertEqual(recovered.end, 60)
        let progress = try XCTUnwrap(WhisperKitPlugin.sourceProgress(
            fromDiscoveredSegments: [recovered], totalDuration: 90
        ))
        XCTAssertEqual(progress.processedDuration, 60)
        XCTAssertEqual(try XCTUnwrap(progress.fractionCompleted), 2.0 / 3.0, accuracy: 0.000_001)
        // Callback adjustment must not offset the returned results a second time.
        XCTAssertEqual(result.segments.map(\.start), [0, 30, 60])
        XCTAssertEqual(result.segments.map(\.end), [30, 60, 90])
    }

    func testLongTranscriptionDoesNotRetryCancelledChunk() async throws {
        let engine = try await FailingChunkWhisperKit(WhisperKitConfig(load: false, download: false))
        engine.failureMode = .cancelled
        let samples = (1...3).flatMap { Array(repeating: Float($0), count: 30 * WhisperKit.sampleRate) }
        do {
            _ = try await WhisperKitPlugin.transcribeAudio(
                with: engine, samples: samples,
                options: WhisperKitPlugin.decodingOptions(language: nil, translate: false)
            )
            XCTFail("Cancellation must not become partial success")
        } catch is CancellationError {
            XCTAssertEqual(engine.attempts[2], 1)
        }
    }

    func testCallbackCancellationDoesNotReturnPartialTranscriptOrRetry() async throws {
        for seconds in [10, 90] {
            let engine = try await FailingChunkWhisperKit(WhisperKitConfig(load: false, download: false))
            engine.failureMode = .none
            do {
                _ = try await WhisperKitPlugin.transcribeAudio(
                    with: engine,
                    samples: Array(repeating: 2, count: seconds * WhisperKit.sampleRate),
                    options: WhisperKitPlugin.decodingOptions(language: nil, translate: false),
                    callback: { _ in false }
                )
                XCTFail("A cancelled transcription must not report success")
            } catch is CancellationError {
                XCTAssertEqual(engine.attempts[2], seconds == 10 ? 1 : 3)
            }
        }
    }

    func testLongTranscriptionKeepsFinalBatchOffsetsWithShortLastChunk() async throws {
        let engine = try await FailingChunkWhisperKit(WhisperKitConfig(load: false, download: false))
        engine.failureMode = .none
        let samples = (1...5).flatMap { Array(repeating: Float($0), count: 30 * WhisperKit.sampleRate) }
            + Array(repeating: Float(6), count: 5 * WhisperKit.sampleRate)
        var options = WhisperKitPlugin.decodingOptions(language: "nl", translate: true)
        options.concurrentWorkerCount = 4

        let result = try await WhisperKitPlugin.transcribeAudio(with: engine, samples: samples, options: options)

        XCTAssertEqual(result.text, "part 1 part 2 part 3 part 4 part 5 part 6")
        XCTAssertEqual(result.segments.map(\.start), [0, 30, 60, 90, 120, 150])
        XCTAssertEqual(result.segments.last?.end, 155)
        XCTAssertEqual(engine.attempts, [1: 1, 2: 1, 3: 1, 4: 1, 5: 1, 6: 1])
        XCTAssertTrue(engine.requests.allSatisfy { $0.task == .translate && $0.language == "nl" })
    }

    func testActivationPromotesPersistedLoadedModelToSelectedModelWhenSelectionMissing() async throws {
        let host = try makeHost(defaults: ["loadedModel": "openai_whisper-tiny"])
        defer { TestSupport.remove(host.pluginDataDirectory) }

        let plugin = WhisperKitPlugin()
        plugin.activate(host: host)

        XCTAssertEqual(plugin.selectedModelId, "openai_whisper-tiny")
        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, "openai_whisper-tiny")

        try await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(plugin.isConfigured)
        XCTAssertEqual(host.userDefault(forKey: "loadedModel") as? String, "openai_whisper-tiny")
        XCTAssertEqual(host.capabilitiesChangedCount, 0)
    }

    func testActivationSkipsPassiveRestoreWhenHostDisallowsIt() async throws {
        let host = try makeHost(
            defaults: ["loadedModel": "openai_whisper-tiny"],
            shouldRestoreLoadedModelsPassively: false
        )
        defer { TestSupport.remove(host.pluginDataDirectory) }

        let plugin = WhisperKitPlugin()
        plugin.activate(host: host)

        XCTAssertFalse(plugin.shouldRestoreLoadedModelsPassively)
        XCTAssertEqual(plugin.selectedModelId, "openai_whisper-tiny")
        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, "openai_whisper-tiny")

        #if DEBUG
        await waitForRestoreLoadedModelInvocationCount(plugin, toBecome: 0)
        #endif

        XCTAssertFalse(plugin.isConfigured)
        XCTAssertEqual(host.userDefault(forKey: "loadedModel") as? String, "openai_whisper-tiny")
        XCTAssertEqual(host.capabilitiesChangedCount, 0)
    }

    func testActivationSchedulesPassiveRestoreWhenHostAllowsIt() async throws {
        let host = try makeHost(defaults: ["loadedModel": "openai_whisper-tiny"])
        defer { TestSupport.remove(host.pluginDataDirectory) }

        let plugin = WhisperKitPlugin()
        plugin.activate(host: host)

        XCTAssertTrue(plugin.shouldRestoreLoadedModelsPassively)
        #if DEBUG
        await waitForRestoreLoadedModelInvocationCount(plugin, toBecome: 1)
        #endif
    }

    func testReconciliationRetriesActivationTimeDenialWithoutDownloadingMissingModel() async throws {
        let host = try makeHost(defaults: ["loadedModel": "openai_whisper-tiny"],
                                shouldRestoreLoadedModelsPassively: false)
        defer { TestSupport.remove(host.pluginDataDirectory) }
        let plugin = WhisperKitPlugin()
        plugin.activate(host: host)
        host.shouldRestoreLoadedModelsPassively = true
        plugin.requestPassiveModelRestore()
        #if DEBUG
        await waitForRestoreLoadedModelInvocationCount(plugin, toBecome: 1)
        #endif
        XCTAssertFalse(plugin.isConfigured)
        XCTAssertNil(plugin.loadingModelIdForTesting)
        XCTAssertEqual(host.capabilitiesChangedCount, 0)
        XCTAssertEqual(host.userDefault(forKey: "loadedModel") as? String, "openai_whisper-tiny")
        plugin.deactivate()
    }

    func testQueuedPassiveRestoreRechecksSelectionBeforeStarting() async throws {
        let host = try makeHost(defaults: ["loadedModel": "openai_whisper-tiny"],
                                shouldRestoreLoadedModelsPassively: false)
        defer { TestSupport.remove(host.pluginDataDirectory) }
        let plugin = WhisperKitPlugin()
        plugin.activate(host: host)
        host.shouldRestoreLoadedModelsPassively = true
        plugin.requestPassiveModelRestore()
        host.shouldRestoreLoadedModelsPassively = false
        // The controller starts on MainActor after this synchronous selection change.
        try await Task.sleep(for: .milliseconds(50))
        #if DEBUG
        XCTAssertEqual(plugin.restoreLoadedModelInvocationCountForTesting, 0)
        #endif
        XCTAssertNil(plugin.loadingModelIdForTesting)
        plugin.deactivate()
    }

    func testDeactivationCancelsQueuedPassiveRestore() async throws {
        let host = try makeHost(defaults: ["loadedModel": "openai_whisper-tiny"])
        defer { TestSupport.remove(host.pluginDataDirectory) }
        let plugin = WhisperKitPlugin()
        plugin.activate(host: host)
        plugin.requestPassiveModelRestore()
        plugin.deactivate()
        try await Task.sleep(for: .milliseconds(50))
        #if DEBUG
        XCTAssertEqual(plugin.restoreLoadedModelInvocationCountForTesting, 0)
        #endif
        XCTAssertFalse(plugin.isConfigured)
        XCTAssertEqual(host.capabilitiesChangedCount, 0)
    }

    func testRestoreWhileSameModelLoadingDoesNotStartAnotherLoad() async throws {
        let modelId = "openai_whisper-large-v3_turbo"
        let host = try makeHost(
            defaults: [
                "selectedModel": modelId,
                "loadedModel": modelId,
            ],
            shouldRestoreLoadedModelsPassively: false
        )
        defer { TestSupport.remove(host.pluginDataDirectory) }

        let plugin = WhisperKitPlugin()
        plugin.activate(host: host)
        plugin.setLoadingModelForTesting(modelId)

        let generation = plugin.modelLoadGenerationForTesting

        await plugin.restoreLoadedModel(allowDownloads: true)

        XCTAssertEqual(plugin.modelLoadGenerationForTesting, generation)
        XCTAssertEqual(plugin.loadingModelIdForTesting, modelId)
        XCTAssertEqual(plugin.currentSettingsActivity?.message, "Optimizing model")
        #if DEBUG
        XCTAssertEqual(plugin.restoreLoadedModelInvocationCountForTesting, 1)
        #endif
    }

    func testRestoreFallsBackToSelectedDownloadedModelWhenLoadedMarkerMissing() throws {
        let modelId = "openai_whisper-tiny"
        let host = try makeHost(
            defaults: ["selectedModel": modelId],
            shouldRestoreLoadedModelsPassively: false
        )
        defer { TestSupport.remove(host.pluginDataDirectory) }
        _ = try makeUsableWhisperModelDirectory(host: host, modelId: modelId)

        let plugin = WhisperKitPlugin()
        plugin.activate(host: host)

        XCTAssertNil(host.userDefault(forKey: "loadedModel"))
        XCTAssertEqual(plugin.selectedModelId, modelId)
        XCTAssertEqual(plugin.restoreTargetModelIdForTesting(allowDownloads: false), modelId)
    }

    func testExplicitRestoreFallsBackToSelectedModelWhenLoadedMarkerMissing() throws {
        let modelId = "openai_whisper-large-v3_turbo"
        let host = try makeHost(
            defaults: ["selectedModel": modelId],
            shouldRestoreLoadedModelsPassively: false
        )
        defer { TestSupport.remove(host.pluginDataDirectory) }

        let plugin = WhisperKitPlugin()
        plugin.activate(host: host)

        XCTAssertNil(host.userDefault(forKey: "loadedModel"))
        XCTAssertEqual(plugin.selectedModelId, modelId)
        XCTAssertNil(plugin.restoreTargetModelIdForTesting(allowDownloads: false))
        XCTAssertEqual(plugin.restoreTargetModelIdForTesting(allowDownloads: true), modelId)
    }

    func testPreferredRestoreWinsOverPersistedLoadedModel() throws {
        let persistedModelId = "openai_whisper-tiny"
        let preferredModelId = "openai_whisper-large-v3_turbo"
        let host = try makeHost(
            defaults: [
                "selectedModel": persistedModelId,
                "loadedModel": persistedModelId,
            ],
            shouldRestoreLoadedModelsPassively: false
        )
        defer { TestSupport.remove(host.pluginDataDirectory) }
        _ = try makeUsableWhisperModelDirectory(host: host, modelId: persistedModelId)
        _ = try makeUsableWhisperModelDirectory(host: host, modelId: preferredModelId)

        let plugin = WhisperKitPlugin()
        plugin.activate(host: host)

        XCTAssertEqual(
            plugin.restoreTargetModelIdForTesting(
                allowDownloads: false,
                preferredModelId: preferredModelId
            ),
            preferredModelId
        )
    }

    func testPreferredRestoreDoesNotFallBackWhenRequestedModelIsNotDownloaded() throws {
        let persistedModelId = "openai_whisper-tiny"
        let preferredModelId = "openai_whisper-large-v3_turbo"
        let host = try makeHost(
            defaults: [
                "selectedModel": persistedModelId,
                "loadedModel": persistedModelId,
            ],
            shouldRestoreLoadedModelsPassively: false
        )
        defer { TestSupport.remove(host.pluginDataDirectory) }
        _ = try makeUsableWhisperModelDirectory(host: host, modelId: persistedModelId)

        let plugin = WhisperKitPlugin()
        plugin.activate(host: host)

        XCTAssertNil(
            plugin.restoreTargetModelIdForTesting(
                allowDownloads: false,
                preferredModelId: preferredModelId
            )
        )
    }

    func testSelectingDownloadedAutoUnloadedModelSchedulesRestore() async throws {
        let modelId = "openai_whisper-tiny"
        let host = try makeHost(shouldRestoreLoadedModelsPassively: false)
        defer { TestSupport.remove(host.pluginDataDirectory) }
        _ = try makeUsableWhisperModelDirectory(host: host, modelId: modelId)

        let plugin = WhisperKitPlugin()
        plugin.activate(host: host)
        plugin.selectModel(modelId)

        #if DEBUG
        await waitForRestoreLoadedModelInvocationCount(plugin, toBecome: 1)
        #endif
        XCTAssertEqual(plugin.selectedModelId, modelId)
        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, modelId)
        plugin.deactivate()
    }

    func testSelectingUndownloadedModelDoesNotScheduleRestore() async throws {
        let modelId = "openai_whisper-large-v3_turbo"
        let host = try makeHost(shouldRestoreLoadedModelsPassively: false)
        defer { TestSupport.remove(host.pluginDataDirectory) }

        let plugin = WhisperKitPlugin()
        plugin.activate(host: host)
        plugin.selectModel(modelId)

        #if DEBUG
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(plugin.restoreLoadedModelInvocationCountForTesting, 0)
        #endif
        XCTAssertEqual(plugin.selectedModelId, modelId)
        XCTAssertFalse(plugin.isConfigured)
        plugin.deactivate()
    }

    func testWhisperKitExposesPreferredModelRestoreSelector() {
        let plugin = WhisperKitPlugin()

        XCTAssertTrue(plugin.responds(to: NSSelectorFromString("triggerRestoreModelForModel:")))
    }

    func testUnloadWithoutClearingPersistenceKeepsLoadedModelMarker() throws {
        let host = try makeHost(defaults: [
            "selectedModel": "openai_whisper-tiny",
            "loadedModel": "openai_whisper-tiny",
        ])
        defer { TestSupport.remove(host.pluginDataDirectory) }

        let plugin = WhisperKitPlugin()
        plugin.activate(host: host)

        plugin.unloadModel(clearPersistence: false)

        XCTAssertFalse(plugin.isConfigured)
        XCTAssertEqual(plugin.selectedModelId, "openai_whisper-tiny")
        XCTAssertEqual(host.userDefault(forKey: "loadedModel") as? String, "openai_whisper-tiny")
    }

    func testUnloadClearingPersistenceRemovesLoadedModelMarker() throws {
        let host = try makeHost(defaults: [
            "selectedModel": "openai_whisper-tiny",
            "loadedModel": "openai_whisper-tiny",
        ])
        defer { TestSupport.remove(host.pluginDataDirectory) }

        let plugin = WhisperKitPlugin()
        plugin.activate(host: host)

        plugin.unloadModel(clearPersistence: true)

        XCTAssertFalse(plugin.isConfigured)
        XCTAssertEqual(plugin.selectedModelId, "openai_whisper-tiny")
        XCTAssertNil(host.userDefault(forKey: "loadedModel"))
    }

    func testAutoUnloadWaitsForAllActiveModelUsesAndKeepsLoadedModelMarker() throws {
        let modelId = "openai_whisper-tiny"
        let host = try makeHost(
            defaults: [
                "selectedModel": modelId,
                "loadedModel": modelId,
            ],
            shouldRestoreLoadedModelsPassively: false
        )
        defer { TestSupport.remove(host.pluginDataDirectory) }

        let plugin = WhisperKitPlugin()
        plugin.activate(host: host)
        plugin.beginModelUseForTesting()
        plugin.beginModelUseForTesting()

        plugin.triggerAutoUnload()
        XCTAssertEqual(plugin.activeModelUseCountForTesting, 2)
        XCTAssertEqual(host.capabilitiesChangedCount, 0)

        plugin.endModelUseForTesting()
        plugin.triggerAutoUnload()
        XCTAssertEqual(plugin.activeModelUseCountForTesting, 1)
        XCTAssertEqual(host.capabilitiesChangedCount, 0)

        plugin.endModelUseForTesting()
        plugin.triggerAutoUnload()

        XCTAssertEqual(plugin.activeModelUseCountForTesting, 0)
        XCTAssertEqual(host.userDefault(forKey: "loadedModel") as? String, modelId)
        XCTAssertEqual(host.capabilitiesChangedCount, 1)
    }

    func testEndingModelUseCannotUnderflowActiveUseCount() {
        let plugin = WhisperKitPlugin()

        plugin.endModelUseForTesting()
        plugin.beginModelUseForTesting()
        plugin.endModelUseForTesting()
        plugin.endModelUseForTesting()

        XCTAssertEqual(plugin.activeModelUseCountForTesting, 0)
    }

    func testWhisperKitDeclaresHostModelLifecyclePolicyAwareness() {
        let plugin: any TypeWhisperPlugin = WhisperKitPlugin()

        XCTAssertNotNil(plugin as? any HostModelLifecyclePolicyAwarePlugin)
    }

    func testReadyModelStateClearsLoadingSettingsActivity() throws {
        let host = try makeHost(defaults: [
            "selectedModel": "openai_whisper-large-v3_turbo",
            "loadedModel": "openai_whisper-large-v3_turbo",
        ])
        defer { TestSupport.remove(host.pluginDataDirectory) }

        let plugin = WhisperKitPlugin()
        plugin.activate(host: host)

        plugin.setModelStateForTesting(.loading(phase: "loading"))
        XCTAssertEqual(plugin.currentSettingsActivity?.message, "Loading model")

        plugin.setModelStateForTesting(
            .ready("openai_whisper-large-v3_turbo"),
            loadedModelId: "openai_whisper-large-v3_turbo"
        )
        XCTAssertNil(plugin.currentSettingsActivity)
    }

    func testSourceProgressDoesNotRegressDuringEarlierChunkRecovery() {
        let reported = OSAllocatedUnfairLock(initialState: [PluginTranscriptionSourceProgress]())
        let callback = WhisperKitPlugin.makeSourceProgressCallback(totalDuration: 90) { progress in
            reported.withLock { $0.append(progress) }
            return true
        }

        // Later chunks can finish before the serial retry discovers earlier segments.
        for end: Float in [30, 90, 31, 45, 60] {
            callback([TranscriptionSegment(start: 0, end: end, text: "")])
        }

        let values = reported.withLock { $0 }
        XCTAssertEqual(values.first?.processedDuration, 30)
        XCTAssertEqual(values.last?.processedDuration, 90)
        XCTAssertEqual(values.last?.fractionCompleted, 1)
        XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy {
            $0.processedDuration <= $1.processedDuration
        })
    }

    func testSourceProgressIsOrderedAcrossConcurrentChunkCallbacks() async {
        let reported = OSAllocatedUnfairLock(initialState: [Double]())
        let callback = WhisperKitPlugin.makeSourceProgressCallback(totalDuration: 100) { progress in
            reported.withLock { $0.append(progress.processedDuration) }
            return true
        }

        await withTaskGroup(of: Void.self) { group in
            for end in (1...100).reversed() {
                group.addTask {
                    callback([TranscriptionSegment(start: 0, end: Float(end), text: "")])
                }
            }
        }

        let values = reported.withLock { $0 }
        XCTAssertEqual(values.last, 100)
        XCTAssertTrue(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
    }

    func testSourceProgressStartsFreshForEachTranscription() {
        let reported = OSAllocatedUnfairLock(initialState: [Double]())
        let capture: @Sendable (PluginTranscriptionSourceProgress) -> Bool = { progress in
            reported.withLock { $0.append(progress.processedDuration) }
            return true
        }
        let first = WhisperKitPlugin.makeSourceProgressCallback(totalDuration: 90, onSourceProgress: capture)
        let second = WhisperKitPlugin.makeSourceProgressCallback(totalDuration: 90, onSourceProgress: capture)

        first([TranscriptionSegment(start: 0, end: 90, text: "")])
        second([TranscriptionSegment(start: 0, end: 10, text: "")])
        first([TranscriptionSegment(start: 0, end: 60, text: "")])
        second([TranscriptionSegment(start: 0, end: 20, text: "")])

        XCTAssertEqual(reported.withLock { $0 }, [90, 10, 20])
    }

    func testSourceProgressUsesLatestDiscoveredSegmentEnd() {
        let progress = WhisperKitPlugin.sourceProgress(
            fromSegmentEnds: [10, 75],
            totalDuration: 120
        )

        XCTAssertEqual(progress?.processedDuration, 75)
        XCTAssertEqual(progress?.totalDuration, 120)
        XCTAssertEqual(progress?.fractionCompleted, 0.625)
    }

    func testSourceProgressClampsLatestDiscoveredSegmentEndToTotalDuration() {
        let progress = WhisperKitPlugin.sourceProgress(
            fromSegmentEnds: [300],
            totalDuration: 120
        )

        XCTAssertEqual(progress?.processedDuration, 120)
        XCTAssertEqual(progress?.totalDuration, 120)
        XCTAssertNil(WhisperKitPlugin.sourceProgress(fromSegmentEnds: [], totalDuration: 120))
        XCTAssertNil(WhisperKitPlugin.sourceProgress(
            fromSegmentEnds: [10],
            totalDuration: 0
        ))
    }

    func testLoadedModelSuppressesLoadingSettingsActivity() throws {
        let host = try makeHost(defaults: [
            "selectedModel": "openai_whisper-large-v3_turbo",
            "loadedModel": "openai_whisper-large-v3_turbo",
        ])
        defer { TestSupport.remove(host.pluginDataDirectory) }

        let plugin = WhisperKitPlugin()
        plugin.activate(host: host)

        plugin.setModelStateForTesting(
            .loading(phase: "loading"),
            loadedModelId: "openai_whisper-large-v3_turbo"
        )
        XCTAssertNil(plugin.currentSettingsActivity)
    }

    func testLoadedModelKeepsSettingsStateReadyWhenWhisperKitReportsPrewarming() throws {
        let host = try makeHost(defaults: [
            "selectedModel": "openai_whisper-large-v3_turbo",
            "loadedModel": "openai_whisper-large-v3_turbo",
        ])
        defer { TestSupport.remove(host.pluginDataDirectory) }

        let plugin = WhisperKitPlugin()
        plugin.activate(host: host)

        plugin.setModelStateForTesting(
            .loading(phase: "prewarming"),
            loadedModelId: "openai_whisper-large-v3_turbo"
        )

        XCTAssertEqual(plugin.settingsModelState, .ready("openai_whisper-large-v3_turbo"))
    }

    func testSlowModelLoadWarningKeepsLoadActiveAndPreventsRetry() async throws {
        let host = try makeHost(defaults: [
            "selectedModel": "openai_whisper-large-v3_turbo",
            "loadedModel": "openai_whisper-large-v3_turbo",
        ], shouldRestoreLoadedModelsPassively: false)
        defer { TestSupport.remove(host.pluginDataDirectory) }

        let plugin = WhisperKitPlugin()
        plugin.activate(host: host)
        plugin.setSlowModelLoadWarningDurationForTesting(.milliseconds(10))
        plugin.startSlowModelLoadWarningForTesting()
        let generation = plugin.modelLoadGenerationForTesting

        try await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(plugin.isConfigured)
        XCTAssertEqual(host.userDefault(forKey: "loadedModel") as? String, "openai_whisper-large-v3_turbo")
        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, "openai_whisper-large-v3_turbo")
        XCTAssertEqual(plugin.currentSettingsActivity?.isError, false)
        XCTAssertEqual(plugin.currentSettingsActivity?.message, "Model optimization is taking longer than expected")
        XCTAssertEqual(host.capabilitiesChangedCount, 1)
        XCTAssertEqual(plugin.loadingModelIdForTesting, "openai_whisper-large-v3_turbo")
        XCTAssertEqual(plugin.modelLoadGenerationForTesting, generation)

        await plugin.restoreLoadedModel(allowDownloads: true)

        XCTAssertEqual(plugin.loadingModelIdForTesting, "openai_whisper-large-v3_turbo")
        XCTAssertEqual(plugin.modelLoadGenerationForTesting, generation)
    }

    func testActivationDoesNotMarkPluginConfiguredBeforeRestoreSucceeds() async throws {
        let host = try makeHost(defaults: [
            "selectedModel": "openai_whisper-tiny",
            "loadedModel": "openai_whisper-tiny",
        ])
        defer { TestSupport.remove(host.pluginDataDirectory) }

        let plugin = WhisperKitPlugin()
        plugin.activate(host: host)

        XCTAssertFalse(plugin.isConfigured)

        try await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(plugin.isConfigured)
        XCTAssertEqual(plugin.selectedModelId, "openai_whisper-tiny")
        XCTAssertEqual(host.userDefault(forKey: "loadedModel") as? String, "openai_whisper-tiny")
    }

    func testDeleteDownloadedModelRemovesFilesAndClearsPersistedSelection() async throws {
        let modelId = "openai_whisper-tiny"
        let host = try makeHost(defaults: ["selectedModel": modelId])
        defer { TestSupport.remove(host.pluginDataDirectory) }

        let plugin = WhisperKitPlugin()
        plugin.activate(host: host)
        host.setUserDefault(modelId, forKey: "loadedModel")

        let modelDirectory = try makeUsableWhisperModelDirectory(host: host, modelId: modelId)

        XCTAssertEqual(plugin.downloadedModels.map(\.id), [modelId])

        try await plugin.deleteDownloadedModel(modelId)

        XCTAssertFalse(FileManager.default.fileExists(atPath: modelDirectory.path))
        XCTAssertNil(plugin.selectedModelId)
        XCTAssertNil(host.userDefault(forKey: "selectedModel"))
        XCTAssertNil(host.userDefault(forKey: "loadedModel"))
        XCTAssertGreaterThanOrEqual(host.capabilitiesChangedCount, 1)
    }

    func testFailedPassiveRestorePreservesPersistedModelWithoutReportingAnError() async throws {
        let modelId = "openai_whisper-tiny"
        let host = try makeHost(defaults: ["loadedModel": modelId],
                                shouldRestoreLoadedModelsPassively: false)
        defer { TestSupport.remove(host.pluginDataDirectory) }
        let directory = try makeUsableWhisperModelDirectory(host: host, modelId: modelId)
        // The files pass the presence check but contain invalid Core ML data.
        let plugin = WhisperKitPlugin()
        plugin.activate(host: host)
        defer { plugin.deactivate() }
        host.shouldRestoreLoadedModelsPassively = true

        await plugin.restoreLoadedModel(allowDownloads: false, passively: true)

        XCTAssertEqual(host.userDefault(forKey: "loadedModel") as? String, modelId)
        XCTAssertEqual(plugin.settingsModelState, .notLoaded)
        XCTAssertNil(plugin.loadingModelIdForTesting)
        XCTAssertEqual(host.capabilitiesChangedCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    func testDownloadedModelWithLocalTokenizerReachesNativeLoading() async throws {
        let modelId = "openai_whisper-large-v3_turbo"
        let host = try makeHost(defaults: ["loadedModel": modelId],
                                shouldRestoreLoadedModelsPassively: false)
        defer { TestSupport.remove(host.pluginDataDirectory) }
        _ = try makeUsableWhisperModelDirectory(host: host, modelId: modelId)
        // Where WhisperKit caches the tokenizer of every large-v3 variant on the first load.
        let tokenizerDirectory = host.pluginDataDirectory
            .appendingPathComponent("models/models/openai/whisper-large-v3", isDirectory: true)
        try FileManager.default.createDirectory(at: tokenizerDirectory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: tokenizerDirectory.appendingPathComponent("tokenizer.json"))
        let plugin = WhisperKitPlugin()
        plugin.activate(host: host)
        defer { plugin.deactivate() }

        await plugin.restoreLoadedModel(allowDownloads: true)

        // 本机文件直接进入 Core ML 的模型校验。
        guard case .error(let message) = plugin.settingsModelState else {
            return XCTFail("Expected Core ML to reject the placeholder model: \(plugin.settingsModelState)")
        }
        XCTAssertFalse(message.isEmpty)
    }

    private func makeUsableWhisperModelDirectory(
        host: MockHostServices,
        modelId: String
    ) throws -> URL {
        let modelDirectory = host.pluginDataDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(modelId, isDirectory: true)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        try Data("{}".utf8).write(to: modelDirectory.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: modelDirectory.appendingPathComponent("generation_config.json"))

        for component in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            let componentDirectory = modelDirectory.appendingPathComponent("\(component).mlmodelc", isDirectory: true)
            try FileManager.default.createDirectory(
                at: componentDirectory.appendingPathComponent("analytics", isDirectory: true),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: componentDirectory.appendingPathComponent("weights", isDirectory: true),
                withIntermediateDirectories: true
            )

            for file in ["metadata.json", "model.mil", "coremldata.bin"] {
                try Data("x".utf8).write(to: componentDirectory.appendingPathComponent(file))
            }
            try Data("x".utf8).write(to: componentDirectory.appendingPathComponent("analytics/coremldata.bin"))
            try Data("x".utf8).write(to: componentDirectory.appendingPathComponent("weights/weight.bin"))

            if component == "AudioEncoder" || component == "TextDecoder" {
                try Data("x".utf8).write(to: componentDirectory.appendingPathComponent("model.mlmodel"))
            }
        }

        return modelDirectory
    }
}
