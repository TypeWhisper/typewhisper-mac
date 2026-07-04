import Foundation
import XCTest
import WhisperKit
import TypeWhisperPluginSDK
@testable import TypeWhisper

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
        XCTAssertEqual(model?.sizeDescription, "~600 MB")
        XCTAssertEqual(model?.ramRequirement, "8 GB+")
    }

    func testExactChineseLanguageDisablesWhisperKitLanguageDetection() {
        let options = WhisperKitPlugin.decodingOptions(language: "zh", translate: false)

        XCTAssertEqual(options.language, "zh")
        XCTAssertFalse(options.detectLanguage)
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

    func testModelLoadTimeoutClearsPersistedLoadedModelAndReportsError() async throws {
        let host = try makeHost(defaults: [
            "selectedModel": "openai_whisper-large-v3_turbo",
            "loadedModel": "openai_whisper-large-v3_turbo",
        ])
        defer { TestSupport.remove(host.pluginDataDirectory) }

        let plugin = WhisperKitPlugin()
        plugin.activate(host: host)
        plugin.setModelLoadTimeoutForTesting(.milliseconds(10))
        plugin.startModelLoadTimeoutForTesting(modelName: "Large v3 Turbo")

        try await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(plugin.isConfigured)
        XCTAssertNil(host.userDefault(forKey: "loadedModel"))
        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, "openai_whisper-large-v3_turbo")
        XCTAssertEqual(plugin.currentSettingsActivity?.isError, true)
        XCTAssertEqual(host.capabilitiesChangedCount, 1)
        XCTAssertTrue(plugin.currentSettingsActivity?.message.contains("Large v3 Turbo") == true)
        XCTAssertNil(plugin.loadingModelIdForTesting)
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
