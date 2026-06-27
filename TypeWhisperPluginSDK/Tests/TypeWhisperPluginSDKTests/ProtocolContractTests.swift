import Foundation
import os
import XCTest
@testable import TypeWhisperPluginSDK

private final class SourceProgressRecorder: @unchecked Sendable {
    private let progress = OSAllocatedUnfairLock<PluginTranscriptionSourceProgress?>(initialState: nil)

    func record(_ value: PluginTranscriptionSourceProgress) {
        progress.withLock { $0 = value }
    }

    var recordedProgress: PluginTranscriptionSourceProgress? {
        progress.withLock { $0 }
    }
}

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
    let availableWorkflows: [PluginWorkflowInfo]

    init(
        eventBus: EventBusProtocol,
        availableRuleNames: [String],
        availableWorkflows: [PluginWorkflowInfo] = []
    ) {
        self.eventBus = eventBus
        self.availableRuleNames = availableRuleNames
        self.availableWorkflows = availableWorkflows
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

@objc(MockDownloadedModelPlugin)
private final class MockDownloadedModelPlugin: NSObject, TypeWhisperPlugin, PluginDownloadedModelManaging, @unchecked Sendable {
    static let pluginId = "com.typewhisper.mock.downloaded-models"
    static let pluginName = "Mock Downloaded Models"

    private(set) var deletedModelIds: [String] = []
    var downloadedModels: [PluginModelInfo] = [
        PluginModelInfo(
            id: "local-small",
            displayName: "Local Small",
            sizeDescription: "1 GB",
            downloaded: true,
            loaded: true
        )
    ]

    required override init() {}

    func activate(host: HostServices) {}
    func deactivate() {}

    func deleteDownloadedModel(_ modelId: String) async throws {
        deletedModelIds.append(modelId)
        downloadedModels.removeAll { $0.id == modelId }
    }
}

@objc(MockAuthRoleStatusPlugin)
private final class MockAuthRoleStatusPlugin: NSObject, TypeWhisperPlugin, PluginAuthRoleStatusProviding, @unchecked Sendable {
    static let pluginId = "com.typewhisper.mock.auth-roles"
    static let pluginName = "Mock Auth Roles"

    required override init() {}

    func activate(host: HostServices) {}
    func deactivate() {}

    func authStatus(for role: PluginAuthRole) -> PluginAuthRoleStatus {
        role == .transcription
            ? PluginAuthRoleStatus(
                isAvailable: false,
                unavailableReason: "Transcription needs a key.",
                requiredCredentialLabel: "API key"
            )
            : .available
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

@objc(MockDictionaryBudgetPlugin)
private final class MockDictionaryBudgetPlugin: NSObject, TranscriptionEnginePlugin, DictionaryTermsBudgetProviding, @unchecked Sendable {
    static let pluginId = "com.typewhisper.mock.dictionary-budget"
    static let pluginName = "Mock Dictionary Budget"

    required override init() {}

    func activate(host: HostServices) {}
    func deactivate() {}

    var providerId: String { "mock-dictionary-budget" }
    var providerDisplayName: String { "Mock Dictionary Budget" }
    var isConfigured: Bool { true }
    var transcriptionModels: [PluginModelInfo] { [] }
    var selectedModelId: String? { nil }
    func selectModel(_ modelId: String) {}
    var supportsTranslation: Bool { false }
    var dictionaryTermsBudget: DictionaryTermsBudget {
        DictionaryTermsBudget(maxTerms: 10, maxCharsPerTerm: 20, maxWordsPerTerm: 3, maxTotalChars: 120)
    }

    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        PluginTranscriptionResult(text: "ok", detectedLanguage: language)
    }
}

@objc(MockCatalogTranscriptionPlugin)
private final class MockCatalogTranscriptionPlugin: NSObject, TranscriptionEnginePlugin, TranscriptionModelCatalogProviding, @unchecked Sendable {
    static let pluginId = "com.typewhisper.mock.catalog"
    static let pluginName = "Mock Catalog"

    required override init() {}

    func activate(host: HostServices) {}
    func deactivate() {}

    var providerId: String { "mock-catalog" }
    var providerDisplayName: String { "Mock Catalog" }
    var isConfigured: Bool { true }
    var transcriptionModels: [PluginModelInfo] { [PluginModelInfo(id: "tiny", displayName: "Tiny")] }
    var availableModels: [PluginModelInfo] {
        [
            PluginModelInfo(id: "tiny", displayName: "Tiny"),
            PluginModelInfo(id: "large", displayName: "Large")
        ]
    }
    var selectedModelId: String? { "tiny" }
    func selectModel(_ modelId: String) {}
    var supportsTranslation: Bool { false }

    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        PluginTranscriptionResult(text: "ok", detectedLanguage: language)
    }
}

@objc(MockStructuredTranscriptionPlugin)
private final class MockStructuredTranscriptionPlugin: NSObject, StructuredTranscriptionEnginePlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.mock.structured"
    static let pluginName = "Mock Structured"

    required override init() {}

    func activate(host: HostServices) {}
    func deactivate() {}

    var providerId: String { "mock-structured" }
    var providerDisplayName: String { "Mock Structured" }
    var isConfigured: Bool { true }
    var transcriptionModels: [PluginModelInfo] { [] }
    var selectedModelId: String? { nil }
    func selectModel(_ modelId: String) {}
    var supportsTranslation: Bool { false }

    func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
        PluginTranscriptionResult(text: "legacy", detectedLanguage: language)
    }

    func transcribeStructured(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginStructuredTranscriptionResult {
        PluginStructuredTranscriptionResult(
            text: "Speaker A: Hello",
            detectedLanguage: language,
            segments: [
                PluginStructuredTranscriptionSegment(
                    text: "Hello",
                    start: 0.25,
                    end: 1.5,
                    speakerLabel: "Speaker A",
                    speakerConfidence: 0.91
                )
            ]
        )
    }
}

@objc(MockSourceProgressTranscriptionPlugin)
private final class MockSourceProgressTranscriptionPlugin: NSObject, SourceProgressTranscriptionEnginePlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.mock.source-progress"
    static let pluginName = "Mock Source Progress"

    required override init() {}

    func activate(host: HostServices) {}
    func deactivate() {}

    var providerId: String { "mock-source-progress" }
    var providerDisplayName: String { "Mock Source Progress" }
    var isConfigured: Bool { true }
    var transcriptionModels: [PluginModelInfo] { [] }
    var selectedModelId: String? { nil }
    func selectModel(_ modelId: String) {}
    var supportsTranslation: Bool { false }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        PluginTranscriptionResult(text: "legacy", detectedLanguage: language)
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?,
        onProgress: @Sendable @escaping (String) -> Bool,
        onSourceProgress: @Sendable @escaping (PluginTranscriptionSourceProgress) -> Bool
    ) async throws -> PluginTranscriptionResult {
        _ = onSourceProgress(PluginTranscriptionSourceProgress(
            processedDuration: 1.5,
            totalDuration: audio.duration,
            previewText: "partial"
        ))
        _ = onProgress("partial")
        return PluginTranscriptionResult(text: "done", detectedLanguage: language)
    }
}

private final class MockTTSPlaybackSession: TTSPlaybackSession, @unchecked Sendable {
    var isActive = true
    var onFinish: (@Sendable () -> Void)?

    func stop() {
        isActive = false
        onFinish?()
    }
}

private actor GateConcurrencyState {
    private var currentCount = 0
    private(set) var maxConcurrent = 0

    func enter() {
        currentCount += 1
        maxConcurrent = max(maxConcurrent, currentCount)
    }

    func leave() {
        currentCount -= 1
    }
}

private actor GateLockRelease {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor GateOperationState {
    private(set) var didRun = false

    func markRan() {
        didRun = true
    }

    func value() -> Bool {
        didRun
    }
}

@objc(MockTTSPlugin)
private final class MockTTSPlugin: NSObject, TTSProviderPlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.mock.tts"
    static let pluginName = "Mock TTS"

    private(set) var host: HostServices?

    required override init() {}

    func activate(host: HostServices) {
        self.host = host
    }

    func deactivate() {
        host = nil
    }

    var providerId: String { "mock-tts" }
    var providerDisplayName: String { "Mock TTS" }
    var isConfigured: Bool { true }
    var availableVoices: [PluginVoiceInfo] { [PluginVoiceInfo(id: "default", displayName: "Default")] }
    var selectedVoiceId: String? { host?.userDefault(forKey: "voice") as? String }
    var settingsSummary: String? { "Default voice" }

    func selectVoice(_ voiceId: String?) {
        host?.setUserDefault(voiceId, forKey: "voice")
    }

    func speak(_ request: TTSSpeakRequest) async throws -> any TTSPlaybackSession {
        let session = MockTTSPlaybackSession()
        host?.setUserDefault(request.text, forKey: "lastSpokenText")
        return session
    }
}

final class ProtocolContractTests: XCTestCase {
    func testLocalInferenceGateSerializesConcurrentOperations() async throws {
        let gate = PluginLocalInferenceGate()
        let state = GateConcurrencyState()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await gate.withLock {
                        await state.enter()
                        try await Task.sleep(for: .milliseconds(20))
                        await state.leave()
                    }
                }
            }

            try await group.waitForAll()
        }

        let maxConcurrent = await state.maxConcurrent
        XCTAssertEqual(maxConcurrent, 1)
    }

    func testLocalInferenceGateDoesNotRunCancelledWaiter() async throws {
        let gate = PluginLocalInferenceGate()
        let release = GateLockRelease()
        let cancelledOperation = GateOperationState()
        let holderStarted = expectation(description: "holder acquired inference gate")

        let holder = Task {
            try await gate.withLock {
                holderStarted.fulfill()
                await release.wait()
            }
        }
        await fulfillment(of: [holderStarted], timeout: 1.0)

        let waiter = Task {
            try await gate.withLock {
                await cancelledOperation.markRan()
            }
        }
        waiter.cancel()

        try await Task.sleep(for: .milliseconds(20))
        await release.release()
        try await holder.value

        do {
            try await waiter.value
            XCTFail("Cancelled waiter should throw before running gated operation")
        } catch is CancellationError {
            // Expected.
        }

        let cancelledOperationRan = await cancelledOperation.value()
        XCTAssertFalse(cancelledOperationRan)

        let followerRan = try await gate.withLock { true }
        XCTAssertTrue(followerRan)
    }

    func testPluginAuthRolesExposeStableRawValues() {
        XCTAssertEqual(PluginAuthRole.transcription.rawValue, "transcription")
        XCTAssertEqual(PluginAuthRole.llm.rawValue, "llm")
        XCTAssertEqual(PluginAuthRole.tts.rawValue, "tts")
    }

    func testPluginAuthRoleStatusResolverUsesProviderOverrideAndLegacyFallback() {
        let roleAwarePlugin = MockAuthRoleStatusPlugin()
        let roleStatus = PluginAuthRoleStatusResolver.status(
            for: roleAwarePlugin,
            role: .transcription,
            legacyIsConfigured: true
        )

        XCTAssertFalse(roleStatus.isAvailable)
        XCTAssertEqual(roleStatus.unavailableReason, "Transcription needs a key.")
        XCTAssertEqual(roleStatus.requiredCredentialLabel, "API key")

        let legacyPlugin = MockTranscriptionPlugin()
        XCTAssertEqual(
            PluginAuthRoleStatusResolver.status(for: legacyPlugin, role: .transcription, legacyIsConfigured: true),
            .available
        )
        XCTAssertFalse(
            PluginAuthRoleStatusResolver.status(for: legacyPlugin, role: .transcription, legacyIsConfigured: false).isAvailable
        )
    }

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

    func testHostServicesExposeWorkflowSnapshots() throws {
        let workflowId = try XCTUnwrap(UUID(uuidString: "4C35C70D-4AD2-48C7-9D05-6A1C5A4A6D2C"))
        let workflow = PluginWorkflowInfo(
            id: workflowId,
            name: "Dynamic Cleanup",
            isEnabled: true,
            sortOrder: 2,
            template: .custom,
            trigger: PluginWorkflowTrigger(
                kind: .website,
                appBundleIdentifiers: [],
                websitePatterns: ["example.com"],
                hotkeys: [
                    PluginWorkflowHotkey(
                        keyCode: 15,
                        modifierFlags: 1_048_576,
                        isFn: false,
                        isDoubleTap: true,
                        modifierKeyCodes: [55],
                        mouseButton: nil
                    )
                ],
                hotkeyBehavior: .processSelectedText
            ),
            behavior: PluginWorkflowBehavior(
                settings: ["triggerWord": "cleanup"],
                fineTuning: "Keep speaker intent.",
                providerId: "openai",
                cloudModel: "gpt-5.4",
                transcriptionEngineId: "whisperkit",
                transcriptionModelId: "large-v3",
                temperatureMode: .custom,
                temperatureValue: 0.2
            ),
            output: PluginWorkflowOutput(
                format: "markdown",
                autoEnter: true,
                targetActionPluginId: "com.example.action"
            ),
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let host = MockHostServices(
            eventBus: MockEventBus(),
            availableRuleNames: ["Dynamic Cleanup"],
            availableWorkflows: [workflow]
        )

        XCTAssertEqual(host.availableWorkflows, [workflow])
        XCTAssertEqual(host.availableWorkflows.first?.trigger.websitePatterns, ["example.com"])
        XCTAssertEqual(host.availableWorkflows.first?.behavior.settings["triggerWord"], "cleanup")
        XCTAssertEqual(host.availableWorkflows.first?.behavior.transcriptionEngineId, "whisperkit")
        XCTAssertEqual(host.availableWorkflows.first?.behavior.transcriptionModelId, "large-v3")
        XCTAssertEqual(host.availableWorkflows.first?.output.targetActionPluginId, "com.example.action")
    }

    func testWorkflowBehaviorDecodesLegacyPayloadWithoutTranscriptionOverrides() throws {
        let payload: [String: Any] = [
            "settings": ["triggerWord": "cleanup"],
            "fineTuning": "Keep speaker intent.",
            "providerId": "openai",
            "cloudModel": "gpt-5.4",
            "temperatureMode": "custom",
            "temperatureValue": 0.2
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)

        let behavior = try JSONDecoder().decode(PluginWorkflowBehavior.self, from: data)

        XCTAssertEqual(behavior.providerId, "openai")
        XCTAssertEqual(behavior.cloudModel, "gpt-5.4")
        XCTAssertNil(behavior.transcriptionEngineId)
        XCTAssertNil(behavior.transcriptionModelId)
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
        let hasSettingsView = await MainActor.run { plugin.settingsView != nil }
        XCTAssertFalse(hasSettingsView)

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

    func testDictionaryTermsBudgetProtocolIsOptional() {
        let legacyPlugin = MockTranscriptionPlugin()
        let budgetPlugin = MockDictionaryBudgetPlugin()

        XCTAssertFalse(legacyPlugin is any DictionaryTermsBudgetProviding)
        XCTAssertEqual(
            budgetPlugin.dictionaryTermsBudget,
            DictionaryTermsBudget(maxTerms: 10, maxCharsPerTerm: 20, maxWordsPerTerm: 3, maxTotalChars: 120)
        )
    }

    func testTranscriptionModelCatalogProtocolIsOptional() {
        let legacyPlugin = MockTranscriptionPlugin()
        let catalogPlugin = MockCatalogTranscriptionPlugin()

        XCTAssertFalse(legacyPlugin is any TranscriptionModelCatalogProviding)
        XCTAssertEqual(legacyPlugin.modelCatalog.map(\.id), ["tiny"])
        XCTAssertEqual(catalogPlugin.modelCatalog.map(\.id), ["tiny", "large"])
    }

    func testDownloadedModelManagingProtocolIsOptionalAndUsesModelInfo() async throws {
        let legacyPlugin = MockTranscriptionPlugin()
        let downloadedModelPlugin = MockDownloadedModelPlugin()

        XCTAssertFalse(legacyPlugin is any PluginDownloadedModelManaging)
        XCTAssertEqual(downloadedModelPlugin.downloadedModels.map(\.id), ["local-small"])
        XCTAssertEqual(downloadedModelPlugin.downloadedModels.first?.downloaded, true)
        XCTAssertEqual(downloadedModelPlugin.downloadedModels.first?.loaded, true)

        try await downloadedModelPlugin.deleteDownloadedModel("local-small")

        XCTAssertEqual(downloadedModelPlugin.deletedModelIds, ["local-small"])
        XCTAssertTrue(downloadedModelPlugin.downloadedModels.isEmpty)
    }

    func testStructuredTranscriptionProtocolIsOptionalAndCarriesSpeakerMetadata() async throws {
        let legacyPlugin = MockTranscriptionPlugin()
        let structuredPlugin = MockStructuredTranscriptionPlugin()
        let erasedStructuredPlugin: Any = structuredPlugin

        XCTAssertFalse(legacyPlugin is any StructuredTranscriptionEnginePlugin)
        XCTAssertTrue(erasedStructuredPlugin is any StructuredTranscriptionEnginePlugin)

        let result = try await structuredPlugin.transcribeStructured(
            audio: AudioData(samples: [0.1], wavData: Data([0x00]), duration: 1),
            language: "en",
            translate: false,
            prompt: nil
        )

        XCTAssertEqual(result.text, "Speaker A: Hello")
        XCTAssertEqual(result.detectedLanguage, "en")
        XCTAssertEqual(result.segments.first?.text, "Hello")
        XCTAssertEqual(result.segments.first?.speakerLabel, "Speaker A")
        XCTAssertEqual(result.segments.first?.speakerConfidence, 0.91)
    }

    func testSourceProgressProtocolIsOptionalAndCarriesDurations() async throws {
        let legacyPlugin = MockTranscriptionPlugin()
        let sourceProgressPlugin = MockSourceProgressTranscriptionPlugin()
        let erasedSourceProgressPlugin: Any = sourceProgressPlugin
        let recorder = SourceProgressRecorder()

        XCTAssertFalse(legacyPlugin is any SourceProgressTranscriptionEnginePlugin)
        XCTAssertTrue(erasedSourceProgressPlugin is any SourceProgressTranscriptionEnginePlugin)

        let result = try await sourceProgressPlugin.transcribe(
            audio: AudioData(samples: [0.1], wavData: Data([0x00]), duration: 3),
            language: "en",
            translate: false,
            prompt: nil,
            onProgress: { text in
                XCTAssertEqual(text, "partial")
                return true
            },
            onSourceProgress: { progress in
                recorder.record(progress)
                return true
            }
        )

        let reportedProgress = recorder.recordedProgress
        XCTAssertEqual(result.text, "done")
        XCTAssertEqual(reportedProgress?.processedDuration, 1.5)
        XCTAssertEqual(reportedProgress?.totalDuration, 3)
        XCTAssertEqual(reportedProgress?.previewText, "partial")
        XCTAssertEqual(reportedProgress?.fractionCompleted, 0.5)
    }

    func testFileJobAutomationContextCarriesWatchFolderExportMetadata() throws {
        let segment = FileJobTranscriptSegment(
            text: "Hello",
            start: 0.25,
            end: 1.5,
            speakerLabel: "Speaker A",
            speakerConfidence: 0.91
        )
        let context = FileJobContext(
            jobKind: .watchFolder,
            sourceFilePath: "/tmp/in/meeting.wav",
            outputDirectoryPath: "/tmp/out",
            outputFilePath: "/tmp/out/meeting.srt",
            outputFormat: "srt",
            engineId: "whisperkit",
            engineName: "WhisperKit",
            modelId: "large-v3",
            transcriptText: "Speaker A: Hello",
            detectedLanguage: "en",
            segments: [segment]
        )
        let artifact = FileJobArtifact(fileExtension: "srt", content: "1\n00:00:00,250 --> 00:00:01,500\nHello")
        let result = FileJobAutomationResult(
            artifact: artifact,
            appliedSteps: ["File Job Script"],
            outputPathWasWritten: true
        )

        XCTAssertEqual(FileJobKind.watchFolder.rawValue, "watch-folder")
        XCTAssertEqual(context.sourceFileName, "meeting.wav")
        XCTAssertEqual(context.outputFormat, "srt")
        XCTAssertEqual(context.segments, [segment])
        XCTAssertEqual(result.artifact, artifact)
        XCTAssertEqual(result.appliedSteps, ["File Job Script"])
        XCTAssertTrue(result.outputPathWasWritten)

        let encoded = try JSONEncoder().encode(context)
        let decoded = try JSONDecoder().decode(FileJobContext.self, from: encoded)
        XCTAssertEqual(decoded, context)
    }

    func testTTSPluginCanPersistVoiceAndReceiveSpeakRequest() async throws {
        let plugin = MockTTSPlugin()
        let host = MockHostServices(eventBus: MockEventBus(), availableRuleNames: ["Work"])
        plugin.activate(host: host)

        plugin.selectVoice("default")
        let session = try await plugin.speak(
            TTSSpeakRequest(text: "Hello", language: "en", purpose: .manualReadback)
        )

        XCTAssertEqual(plugin.selectedVoiceId, "default")
        XCTAssertEqual(plugin.settingsSummary, "Default voice")
        XCTAssertEqual(host.userDefault(forKey: "lastSpokenText") as? String, "Hello")
        XCTAssertTrue(session.isActive)

        session.stop()
        XCTAssertFalse(session.isActive)
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

    func testPluginDictionaryTermHintsNormalizeAndPreserveThresholds() {
        let hints = PluginDictionaryTerms.normalizedTermHints(from: [
            PluginDictionaryTermHint(text: " Kubernetes ", ctcMinSimilarity: 0.65),
            PluginDictionaryTermHint(text: "kubernetes", ctcMinSimilarity: 0.8),
            PluginDictionaryTermHint(text: "MLX", ctcMinSimilarity: nil),
            PluginDictionaryTermHint(text: "Clipped Low", ctcMinSimilarity: -0.25),
            PluginDictionaryTermHint(text: "Clipped High", ctcMinSimilarity: 1.25),
            PluginDictionaryTermHint(text: "Invalid", ctcMinSimilarity: .nan),
        ])

        XCTAssertEqual(hints, [
            PluginDictionaryTermHint(text: "Kubernetes", ctcMinSimilarity: 0.65),
            PluginDictionaryTermHint(text: "MLX", ctcMinSimilarity: nil),
            PluginDictionaryTermHint(text: "Clipped Low", ctcMinSimilarity: 0),
            PluginDictionaryTermHint(text: "Clipped High", ctcMinSimilarity: 1),
            PluginDictionaryTermHint(text: "Invalid", ctcMinSimilarity: nil),
        ])
        XCTAssertEqual(
            PluginDictionaryTerms.clippedTermHints(from: hints, budget: DictionaryTermsBudget(maxTotalChars: 12)),
            [PluginDictionaryTermHint(text: "Kubernetes", ctcMinSimilarity: 0.65)]
        )
    }

    func testPluginDictionaryTermsClippedTermsApplyPerTermFiltersBeforeMaxTerms() {
        XCTAssertEqual(
            PluginDictionaryTerms.clippedTerms(
                from: ["toolongchars", "beta", "gamma"],
                budget: DictionaryTermsBudget(maxTerms: 1, maxCharsPerTerm: 5)
            ),
            ["beta"]
        )
        XCTAssertEqual(
            PluginDictionaryTerms.clippedTerms(
                from: ["one two three", "alpha beta", "gamma"],
                budget: DictionaryTermsBudget(maxTerms: 1, maxWordsPerTerm: 2)
            ),
            ["alpha beta"]
        )
    }

    func testPluginDictionaryTermsClippedTermsApplyTotalCharacterBudgetToJoinedPrompt() {
        XCTAssertEqual(
            PluginDictionaryTerms.clippedTerms(
                from: ["AA", "BB", "CC"],
                budget: DictionaryTermsBudget(maxTotalChars: 6)
            ),
            ["AA", "BB"]
        )
    }

    func testPluginDictionaryTermsClippedTermsTreatNegativeMaxTermsAsZero() {
        let budget = DictionaryTermsBudget(maxTerms: -1)

        XCTAssertEqual(
            PluginDictionaryTerms.clippedTerms(from: ["Alpha", "Beta", "Gamma"], budget: budget),
            []
        )
        XCTAssertNil(PluginDictionaryTerms.prompt(from: ["Alpha", "Beta", "Gamma"], budget: budget))
    }

    func testPluginDictionaryTermsPromptWithBudgetReturnsNilWhenNothingSurvives() {
        XCTAssertNil(
            PluginDictionaryTerms.prompt(
                from: ["toolong"],
                budget: DictionaryTermsBudget(maxCharsPerTerm: 2)
            )
        )
    }
}
