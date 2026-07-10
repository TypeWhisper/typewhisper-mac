import AppKit
import Carbon.HIToolbox
import CoreAudio
import Foundation
import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

private func rtfAttributedStringContainsFontTrait(
    _ trait: NSFontTraitMask,
    in attributed: NSAttributedString,
    matching text: String
) -> Bool {
    let range = (attributed.string as NSString).range(of: text)
    guard range.location != NSNotFound else { return false }

    var effectiveRange = NSRange(location: 0, length: 0)
    let font = attributed.attribute(.font, at: range.location, effectiveRange: &effectiveRange) as? NSFont
    guard let font else { return false }
    return NSFontManager.shared.traits(of: font).contains(trait)
}

final class SecureInputDiagnosticsProviderTests: XCTestCase {
    func testSnapshotPrefersOnConsoleIORegistryOwner() {
        let consoleUsers: NSArray = [
            [
                "kCGSSessionSecureInputPID": NSNumber(value: 111),
                "kCGSSessionOnConsoleKey": NSNumber(value: false),
            ],
            [
                "kCGSSessionSecureInputPID": NSNumber(value: 222),
                "kCGSessionOnConsoleKey": NSNumber(value: true),
            ],
        ]

        let snapshot = SecureInputDiagnosticsProvider.snapshot(
            consoleUsers: consoleUsers,
            currentSessionPID: 333,
            carbonSecureInputEnabled: true,
            processResolver: { pid in
                SecureInputProcessInfo(
                    pid: pid,
                    appName: "App \(pid)",
                    bundleIdentifier: "test.\(pid)",
                    executablePath: "/Applications/App\(pid).app"
                )
            }
        )

        XCTAssertTrue(snapshot.isActive)
        XCTAssertEqual(snapshot.primarySource, "ioRegistry")
        XCTAssertEqual(snapshot.primaryPID, 222)
        XCTAssertEqual(snapshot.primaryAppName, "App 222")
        XCTAssertEqual(snapshot.ioRegistryPID, 222)
        XCTAssertEqual(snapshot.currentSessionPID, 333)
    }

    func testSnapshotDoesNotBlameCurrentSessionWhenIORegistryOwnerCannotBeResolved() {
        let consoleUsers: NSArray = [
            [
                "kCGSSessionSecureInputPID": NSNumber(value: 111),
                "kCGSessionOnConsoleKey": NSNumber(value: true),
            ],
        ]

        let snapshot = SecureInputDiagnosticsProvider.snapshot(
            consoleUsers: consoleUsers,
            currentSessionPID: 333,
            carbonSecureInputEnabled: true,
            processResolver: { pid in
                guard pid == 333 else { return nil }
                return SecureInputProcessInfo(
                    pid: pid,
                    appName: "Current App",
                    bundleIdentifier: "test.current",
                    executablePath: "/Applications/Current.app"
                )
            }
        )

        XCTAssertTrue(snapshot.isActive)
        XCTAssertEqual(snapshot.primarySource, "unknown")
        XCTAssertEqual(snapshot.primaryPID, 111)
        XCTAssertNil(snapshot.primaryAppName)
        XCTAssertEqual(snapshot.ioRegistryPID, 111)
        XCTAssertEqual(snapshot.currentSessionPID, 333)
    }

    func testSnapshotPreservesActiveStateWhenOwnerIsUnknown() {
        let snapshot = SecureInputDiagnosticsProvider.snapshot(
            consoleUsers: nil,
            currentSessionPID: nil,
            carbonSecureInputEnabled: true,
            processResolver: { _ in nil }
        )

        XCTAssertTrue(snapshot.isActive)
        XCTAssertEqual(snapshot.primarySource, "unknown")
        XCTAssertNil(snapshot.primaryPID)
        XCTAssertEqual(snapshot.userFacingOwner, "another app")
    }

    func testSnapshotDoesNotTreatResolvedStaleOwnerAsActive() {
        let consoleUsers: NSArray = [
            [
                "kCGSSessionSecureInputPID": NSNumber(value: 111),
                "kCGSessionOnConsoleKey": NSNumber(value: true),
            ],
        ]

        let snapshot = SecureInputDiagnosticsProvider.snapshot(
            consoleUsers: consoleUsers,
            currentSessionPID: nil,
            carbonSecureInputEnabled: false,
            processResolver: { pid in
                SecureInputProcessInfo(
                    pid: pid,
                    appName: "Stale App",
                    bundleIdentifier: "test.stale",
                    executablePath: "/Applications/Stale.app"
                )
            }
        )

        XCTAssertFalse(snapshot.isActive)
        XCTAssertEqual(snapshot.primarySource, "ioRegistry")
        XCTAssertEqual(snapshot.primaryPID, 111)
        XCTAssertEqual(snapshot.primaryAppName, "Stale App")
        XCTAssertEqual(snapshot.ioRegistryPID, 111)
    }
}

final class APIRouterAndHandlersTests: XCTestCase {
    private actor RecorderStartGate {
        private var entries = 0
        private var firstEntryContinuation: CheckedContinuation<Void, Never>?
        private var releaseContinuation: CheckedContinuation<Void, Never>?
        private var released = false

        func enter() -> Int {
            entries += 1
            if entries == 1 {
                firstEntryContinuation?.resume()
                firstEntryContinuation = nil
            }
            return entries
        }

        func waitForFirstEntry() async {
            if entries > 0 { return }
            await withCheckedContinuation { continuation in
                firstEntryContinuation = continuation
            }
        }

        func waitForRelease() async {
            if released { return }
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }

        func release() {
            released = true
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }

    @objc(APIRouterMockLLMProviderPlugin)
    private final class MockLLMProviderPlugin: NSObject, LLMProviderPlugin, LLMProviderIdentityProviding, LLMProviderSetupStatusProviding, LLMTemperatureControllableProvider, PluginSettingsActivityReporting, @unchecked Sendable {
        static var pluginId: String { "com.typewhisper.mock.llm" }
        static var pluginName: String { "Mock LLM" }

        enum ProcessOutcome: Sendable {
            case response(String)
            case delayedResponse(String, milliseconds: Int)
            case rateLimit
            case networkFailure
            case apiFailure(String)
            case waitForCancellation
        }

        private let requestLock = NSLock()
        var models: [PluginModelInfo] = []
        var responseText = "processed"
        var available = true
        var configuredProviderName = "Gemini"
        var configuredProviderId: String?
        var configuredProviderDisplayName: String?
        var configuredProviderLegacyAliases: [String] = []
        var requiresExternalCredentials = true
        var unavailableReason: String?
        var restoreMakesAvailable = false
        nonisolated(unsafe) private var _lastSystemPrompt: String?
        nonisolated(unsafe) private var _lastUserText: String?
        nonisolated(unsafe) private var _lastRequestedModel: String?
        nonisolated(unsafe) private var _lastTemperatureDirective: PluginLLMTemperatureDirective?
        nonisolated(unsafe) private var _autoUnloadCount = 0
        nonisolated(unsafe) private var _restoreCount = 0
        nonisolated(unsafe) private var _processCallCount = 0
        nonisolated(unsafe) private var _queuedProcessOutcomes: [ProcessOutcome] = []

        var lastSystemPrompt: String? {
            requestLock.withLock { _lastSystemPrompt }
        }

        var lastUserText: String? {
            requestLock.withLock { _lastUserText }
        }

        var lastRequestedModel: String? {
            requestLock.withLock { _lastRequestedModel }
        }

        var lastTemperatureDirective: PluginLLMTemperatureDirective? {
            requestLock.withLock { _lastTemperatureDirective }
        }

        var autoUnloadCount: Int {
            requestLock.withLock { _autoUnloadCount }
        }

        var restoreCount: Int {
            requestLock.withLock { _restoreCount }
        }

        var processCallCount: Int {
            requestLock.withLock { _processCallCount }
        }

        var queuedProcessOutcomes: [ProcessOutcome] {
            get { requestLock.withLock { _queuedProcessOutcomes } }
            set { requestLock.withLock { _queuedProcessOutcomes = newValue } }
        }

        required override init() {}

        func activate(host: HostServices) {}
        func deactivate() {}

        var providerName: String { configuredProviderName }
        var providerId: String { configuredProviderId ?? configuredProviderName }
        var providerDisplayName: String { configuredProviderDisplayName ?? configuredProviderName }
        var providerLegacyAliases: [String] { configuredProviderLegacyAliases }
        var isAvailable: Bool { available }
        var supportedModels: [PluginModelInfo] { models }
        var currentSettingsActivity: PluginSettingsActivity? { nil }

        func process(systemPrompt: String, userText: String, model: String?) async throws -> String {
            try await resolveProcessOutcome(
                recordProcessRequest(systemPrompt: systemPrompt, userText: userText, model: model)
            )
        }

        func process(
            systemPrompt: String,
            userText: String,
            model: String?,
            temperatureDirective: PluginLLMTemperatureDirective
        ) async throws -> String {
            try await resolveProcessOutcome(
                recordProcessRequest(
                    systemPrompt: systemPrompt,
                    userText: userText,
                    model: model,
                    temperatureDirective: temperatureDirective
                )
            )
        }

        private func recordProcessRequest(
            systemPrompt: String,
            userText: String,
            model: String?,
            temperatureDirective: PluginLLMTemperatureDirective? = nil
        ) -> ProcessOutcome {
            requestLock.withLock {
                _lastSystemPrompt = systemPrompt
                _lastUserText = userText
                _lastRequestedModel = model
                if let temperatureDirective {
                    _lastTemperatureDirective = temperatureDirective
                }
                _processCallCount += 1
                return _queuedProcessOutcomes.isEmpty
                    ? .response(responseText)
                    : _queuedProcessOutcomes.removeFirst()
            }
        }

        private func resolveProcessOutcome(_ outcome: ProcessOutcome) async throws -> String {
            switch outcome {
            case .response(let response):
                return response
            case .delayedResponse(let response, let milliseconds):
                try await Task.sleep(for: .milliseconds(milliseconds))
                return response
            case .rateLimit:
                throw LLMError.providerError("HTTP 429 Too Many Requests")
            case .networkFailure:
                throw URLError(.notConnectedToInternet)
            case .apiFailure(let message):
                throw LLMError.providerError(message)
            case .waitForCancellation:
                try await Task.sleep(for: .seconds(60))
                return requestLock.withLock { responseText }
            }
        }

        @objc func triggerAutoUnload() {
            requestLock.withLock {
                _autoUnloadCount += 1
            }
        }

        @objc func triggerRestoreModel() {
            requestLock.withLock {
                _restoreCount += 1
            }
            if restoreMakesAvailable {
                available = true
            }
        }
    }

    @MainActor
    private func waitForAutoUnloadCount(
        _ plugin: MockLLMProviderPlugin,
        toBecome expected: Int,
        timeout: Duration = .seconds(2),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if plugin.autoUnloadCount == expected {
                return
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(plugin.autoUnloadCount, expected, file: file, line: line)
    }

    @MainActor
    private func assertAutoUnloadCount(
        _ plugin: MockLLMProviderPlugin,
        remains expected: Int,
        duration: Duration = .milliseconds(500),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now.advanced(by: duration)
        while ContinuousClock.now < deadline {
            let actual = plugin.autoUnloadCount
            if actual != expected {
                XCTFail("Expected autoUnloadCount to remain \(expected), got \(actual)", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(plugin.autoUnloadCount, expected, file: file, line: line)
    }

    @MainActor
    private final class MemoryRetrieverSpy: MemoryRetrieving {
        private(set) var requestedTexts: [String] = []
        var context = """
        <memory_context>
        The user prefers concise wording.
        </memory_context>
        """

        func retrieveRelevantMemories(for text: String) async -> String {
            requestedTexts.append(text)
            return context
        }
    }

    @MainActor
    private final class ProcessActivityManagerSpy: ProcessActivityManaging {
        private(set) var reasons: [String] = []

        func withActivity<T>(
            options: ProcessInfo.ActivityOptions,
            reason: String,
            operation: () async throws -> T
        ) async rethrows -> T {
            reasons.append(reason)
            return try await operation()
        }
    }

    @objc(APIRouterMockLegacyLLMProviderPlugin)
    private final class MockLegacyLLMProviderPlugin: NSObject, LLMProviderPlugin, @unchecked Sendable {
        static var pluginId: String { "com.typewhisper.mock.legacy-llm" }
        static var pluginName: String { "Mock Legacy LLM" }

        required override init() {}

        func activate(host: HostServices) {}
        func deactivate() {}

        var providerName: String { "Legacy LLM" }
        var isAvailable: Bool { true }
        var supportedModels: [PluginModelInfo] { [] }

        func process(systemPrompt: String, userText: String, model: String?) async throws -> String {
            "processed"
        }
    }

    @objc(APIRouterExpandedRolePlugin)
    private final class ExpandedRolePlugin: NSObject, TypeWhisperPlugin, AdditionalLLMProvidersProviding, AdditionalTranscriptionEnginesProviding, @unchecked Sendable {
        static var pluginId: String { "com.typewhisper.mock.expanded-role" }
        static var pluginName: String { "Expanded Role Mock" }

        var additionalLLMProviders: [any LLMProviderPlugin]
        var additionalTranscriptionEngines: [any TranscriptionEnginePlugin]

        required override init() {
            self.additionalLLMProviders = []
            self.additionalTranscriptionEngines = []
            super.init()
        }

        init(
            additionalLLMProviders: [any LLMProviderPlugin],
            additionalTranscriptionEngines: [any TranscriptionEnginePlugin]
        ) {
            self.additionalLLMProviders = additionalLLMProviders
            self.additionalTranscriptionEngines = additionalTranscriptionEngines
            super.init()
        }

        func activate(host: HostServices) {}
        func deactivate() {}
    }

    @objc(APIRouterNamedTranscriptionPlugin)
    private final class NamedTranscriptionPlugin: NSObject, TranscriptionEnginePlugin, @unchecked Sendable {
        static var pluginId: String { "com.typewhisper.mock.named-transcription" }
        static var pluginName: String { "Named Mock Transcription" }

        var providerIdValue = "expanded-engine"
        var providerDisplayNameValue = "Expanded Engine"
        var modelId = "expanded-model"

        required override init() {}

        init(providerId: String, providerDisplayName: String, modelId: String) {
            self.providerIdValue = providerId
            self.providerDisplayNameValue = providerDisplayName
            self.modelId = modelId
            super.init()
        }

        func activate(host: HostServices) {}
        func deactivate() {}

        var providerId: String { providerIdValue }
        var providerDisplayName: String { providerDisplayNameValue }
        var isConfigured: Bool { true }
        var transcriptionModels: [PluginModelInfo] {
            [PluginModelInfo(id: modelId, displayName: modelId)]
        }
        var selectedModelId: String? { modelId }
        func selectModel(_ modelId: String) {
            self.modelId = modelId
        }
        var supportsTranslation: Bool { false }

        func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
            PluginTranscriptionResult(text: "expanded transcription", detectedLanguage: language)
        }
    }

    @objc(APIRouterMockTranscriptionPlugin)
    private final class MockTranscriptionPlugin: NSObject, TranscriptionEnginePlugin, LanguageHintTranscriptionEnginePlugin, @unchecked Sendable {
        static var pluginId: String { "com.typewhisper.mock.transcription" }
        static var pluginName: String { "Mock Transcription" }
        private static let promptLock = NSLock()
        nonisolated(unsafe) private static var _lastPrompt: String?
        nonisolated(unsafe) private static var _lastLanguageSelection = PluginLanguageSelection()
        nonisolated(unsafe) private static var _responseText = "transcribed"
        nonisolated(unsafe) private static var _transcribeCallCount = 0

        static var lastPrompt: String? {
            promptLock.withLock { _lastPrompt }
        }

        static var lastLanguageSelection: PluginLanguageSelection {
            promptLock.withLock { _lastLanguageSelection }
        }

        static var transcribeCallCount: Int {
            promptLock.withLock { _transcribeCallCount }
        }

        static func reset() {
            promptLock.withLock {
                _lastPrompt = nil
                _lastLanguageSelection = PluginLanguageSelection()
                _responseText = "transcribed"
                _transcribeCallCount = 0
            }
        }

        static func setResponseText(_ text: String) {
            promptLock.withLock {
                _responseText = text
            }
        }

        var languages: [String] = []

        required override init() {}

        func activate(host: HostServices) {}
        func deactivate() {}

        var providerId: String { "mock" }
        var providerDisplayName: String { "Mock" }
        var isConfigured: Bool { true }
        var transcriptionModels: [PluginModelInfo] { [PluginModelInfo(id: "tiny", displayName: "Tiny")] }
        var selectedModelId: String? { "tiny" }
        func selectModel(_ modelId: String) {}
        var supportsTranslation: Bool { false }
        var supportedLanguages: [String] { languages }

        func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
            Self.promptLock.withLock {
                Self._lastPrompt = prompt
                Self._lastLanguageSelection = PluginLanguageSelection(requestedLanguage: language)
                Self._transcribeCallCount += 1
            }
            return PluginTranscriptionResult(text: Self.promptLock.withLock { Self._responseText }, detectedLanguage: language)
        }

        func transcribe(
            audio: AudioData,
            languageSelection: PluginLanguageSelection,
            translate: Bool,
            prompt: String?
        ) async throws -> PluginTranscriptionResult {
            Self.promptLock.withLock {
                Self._lastPrompt = prompt
                Self._lastLanguageSelection = languageSelection
                Self._transcribeCallCount += 1
            }
            return PluginTranscriptionResult(
                text: Self.promptLock.withLock { Self._responseText },
                detectedLanguage: languageSelection.requestedLanguage ?? languageSelection.languageHints.first
            )
        }
    }

    @objc(APIRouterMockLiveTranscriptionPlugin)
    private final class MockLiveTranscriptionPlugin: NSObject, LiveTranscriptionCapablePlugin, @unchecked Sendable {
        static var pluginId: String { "com.typewhisper.mock.live-transcription" }
        static var pluginName: String { "Mock Live Transcription" }

        var providerId: String { "mock-live" }
        var providerDisplayName: String { "Mock Live" }
        var isConfigured: Bool { true }
        var transcriptionModels: [PluginModelInfo] { [PluginModelInfo(id: "live", displayName: "Live")] }
        var selectedModelId: String? { "live" }
        var supportsTranslation: Bool { false }

        required override init() {}

        func activate(host: HostServices) {}
        func deactivate() {}
        func selectModel(_ modelId: String) {}

        func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
            XCTFail("Batch transcribe should not be used when stable live preview is available")
            return PluginTranscriptionResult(text: "batch", detectedLanguage: language)
        }

        func createLiveTranscriptionSession(
            language: String?,
            translate: Bool,
            prompt: String?,
            onProgress: @Sendable @escaping (String) -> Bool
        ) async throws -> any LiveTranscriptionSession {
            MockLiveSession()
        }

        private actor MockLiveSession: LiveTranscriptionSession {
            func appendAudio(samples: [Float]) async throws {}

            func finish() async throws -> PluginTranscriptionResult {
                PluginTranscriptionResult(text: "", detectedLanguage: "en")
            }

            func cancel() async {}
        }
    }

    @objc(APIRouterStructuredTranscriptionPlugin)
    private final class StructuredTranscriptionPlugin: NSObject, StructuredTranscriptionEnginePlugin, @unchecked Sendable {
        static var pluginId: String { "com.typewhisper.mock.structured-transcription" }
        static var pluginName: String { "Structured Mock Transcription" }

        required override init() {}

        func activate(host: HostServices) {}
        func deactivate() {}

        var providerId: String { "structured-mock" }
        var providerDisplayName: String { "Structured Mock" }
        var isConfigured: Bool { true }
        var transcriptionModels: [PluginModelInfo] { [PluginModelInfo(id: "structured", displayName: "Structured")] }
        var selectedModelId: String? { "structured" }
        func selectModel(_ modelId: String) {}
        var supportsTranslation: Bool { false }

        func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
            PluginTranscriptionResult(
                text: "legacy text",
                detectedLanguage: language,
                segments: [
                    PluginTranscriptionSegment(text: "legacy text", start: 0, end: 1)
                ]
            )
        }

        func transcribeStructured(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginStructuredTranscriptionResult {
            PluginStructuredTranscriptionResult(
                text: "Speaker A: Hello\nSpeaker B: Hi",
                detectedLanguage: language,
                segments: [
                    PluginStructuredTranscriptionSegment(
                        text: "Hello",
                        start: 0.0,
                        end: 1.0,
                        speakerLabel: "Speaker A",
                        speakerConfidence: 0.9
                    ),
                    PluginStructuredTranscriptionSegment(
                        text: "Hi",
                        start: 1.0,
                        end: 2.0,
                        speakerLabel: "Speaker B",
                        speakerConfidence: 0.82
                    )
                ]
            )
        }
    }

    @objc(APIRouterLegacySegmentTranscriptionPlugin)
    private final class LegacySegmentTranscriptionPlugin: NSObject, TranscriptionEnginePlugin, @unchecked Sendable {
        static var pluginId: String { "com.typewhisper.mock.legacy-segment-transcription" }
        static var pluginName: String { "Legacy Segment Mock Transcription" }

        required override init() {}

        func activate(host: HostServices) {}
        func deactivate() {}

        var providerId: String { "legacy-segment-mock" }
        var providerDisplayName: String { "Legacy Segment Mock" }
        var isConfigured: Bool { true }
        var transcriptionModels: [PluginModelInfo] { [PluginModelInfo(id: "legacy", displayName: "Legacy")] }
        var selectedModelId: String? { "legacy" }
        func selectModel(_ modelId: String) {}
        var supportsTranslation: Bool { false }

        func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
            PluginTranscriptionResult(
                text: "legacy segment",
                detectedLanguage: language,
                segments: [
                    PluginTranscriptionSegment(text: "legacy segment", start: 0.0, end: 1.0)
                ]
            )
        }
    }

    @objc(APIRouterBudgetedTranscriptionPlugin)
    private final class BudgetedTranscriptionPlugin: NSObject, TranscriptionEnginePlugin, DictionaryTermsBudgetProviding, @unchecked Sendable {
        static var pluginId: String { "com.typewhisper.mock.budgeted-transcription" }
        static var pluginName: String { "Budgeted Mock Transcription" }
        private static let promptLock = NSLock()
        nonisolated(unsafe) private static var _lastPrompt: String?

        static var lastPrompt: String? {
            promptLock.withLock { _lastPrompt }
        }

        static func reset() {
            promptLock.withLock {
                _lastPrompt = nil
            }
        }

        required override init() {}

        func activate(host: HostServices) {}
        func deactivate() {}

        var providerId: String { "budgeted-mock" }
        var providerDisplayName: String { "Budgeted Mock" }
        var isConfigured: Bool { true }
        var transcriptionModels: [PluginModelInfo] { [PluginModelInfo(id: "large", displayName: "Large")] }
        var selectedModelId: String? { "large" }
        func selectModel(_ modelId: String) {}
        var supportsTranslation: Bool { false }
        var dictionaryTermsBudget: DictionaryTermsBudget { DictionaryTermsBudget(maxTotalChars: 2_000) }

        func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
            Self.promptLock.withLock {
                Self._lastPrompt = prompt
            }
            return PluginTranscriptionResult(text: "transcribed", detectedLanguage: language)
        }
    }

    @objc(APIRouterConfigurableTranscriptionPlugin)
    private final class ConfigurableTranscriptionPlugin: NSObject, TranscriptionEnginePlugin, @unchecked Sendable {
        static var pluginId: String { "com.typewhisper.mock.configurable-transcription" }
        static var pluginName: String { "Configurable Mock Transcription" }

        var configured = false
        var currentModelId: String?

        required override init() {}

        func activate(host: HostServices) {}
        func deactivate() {}

        var providerId: String { "configurable-mock" }
        var providerDisplayName: String { "Configurable Mock" }
        var isConfigured: Bool { configured }
        var transcriptionModels: [PluginModelInfo] { [PluginModelInfo(id: "tiny", displayName: "Tiny")] }
        var selectedModelId: String? { currentModelId }
        func selectModel(_ modelId: String) {
            currentModelId = modelId
            configured = true
        }
        var supportsTranslation: Bool { false }

        func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
            PluginTranscriptionResult(text: "transcribed", detectedLanguage: language)
        }
    }

    @objc(APIRouterRestoringTranscriptionPlugin)
    private final class RestoringTranscriptionPlugin: NSObject, TranscriptionEnginePlugin, PluginSettingsActivityReporting, @unchecked Sendable {
        static var pluginId: String { "com.typewhisper.mock.restoring-transcription" }
        static var pluginName: String { "Restoring Mock Transcription" }

        private let stateLock = NSLock()
        private var _configured = false
        private var _currentModelId: String?
        private var _currentSettingsActivity: PluginSettingsActivity?
        private var _restoreCount = 0

        var restoreDelay: Duration = .milliseconds(0)
        var restoreShouldConfigure = true

        var configured: Bool {
            get { stateLock.withLock { _configured } }
            set { stateLock.withLock { _configured = newValue } }
        }

        var currentModelId: String? {
            get { stateLock.withLock { _currentModelId } }
            set { stateLock.withLock { _currentModelId = newValue } }
        }

        var activity: PluginSettingsActivity? {
            get { stateLock.withLock { _currentSettingsActivity } }
            set { stateLock.withLock { _currentSettingsActivity = newValue } }
        }

        var restoreCount: Int {
            stateLock.withLock { _restoreCount }
        }

        required override init() {}

        func activate(host: HostServices) {}
        func deactivate() {}

        var providerId: String { "restoring-mock" }
        var providerDisplayName: String { "Restoring Mock" }
        var isConfigured: Bool { configured }
        var transcriptionModels: [PluginModelInfo] { [PluginModelInfo(id: "tiny", displayName: "Tiny")] }
        var selectedModelId: String? { currentModelId }
        var currentSettingsActivity: PluginSettingsActivity? { activity }
        func selectModel(_ modelId: String) {
            currentModelId = modelId
        }
        var supportsTranslation: Bool { false }

        @objc func triggerRestoreModel() {
            let delay = restoreDelay
            let shouldConfigure = restoreShouldConfigure
            stateLock.withLock {
                _restoreCount += 1
            }

            Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard let self, shouldConfigure else { return }
                self.stateLock.withLock {
                    self._configured = true
                    self._currentSettingsActivity = nil
                }
            }
        }

        func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
            PluginTranscriptionResult(text: "transcribed", detectedLanguage: language)
        }
    }

    @objc(APIRouterCatalogTranscriptionPlugin)
    private final class CatalogTranscriptionPlugin: NSObject, TranscriptionEnginePlugin, TranscriptionModelCatalogProviding, @unchecked Sendable {
        static var pluginId: String { "com.typewhisper.mock.catalog-transcription" }
        static var pluginName: String { "Catalog Mock Transcription" }

        required override init() {}

        func activate(host: HostServices) {}
        func deactivate() {}

        var providerId: String { "catalog-mock" }
        var providerDisplayName: String { "Catalog Mock" }
        var isConfigured: Bool { true }
        var transcriptionModels: [PluginModelInfo] {
            [PluginModelInfo(id: "tiny", displayName: "Tiny")]
        }
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
            PluginTranscriptionResult(text: "transcribed", detectedLanguage: language)
        }
    }

    @objc(APIRouterMockTTSPlugin)
    private final class MockTTSProviderPlugin: NSObject, TTSProviderPlugin, @unchecked Sendable {
        static var pluginId: String { "com.typewhisper.mock.tts" }
        static var pluginName: String { "Mock TTS" }

        private let requestsLock = NSLock()
        private var requests: [TTSSpeakRequest] = []
        var onSpeak: ((TTSSpeakRequest) -> Void)?

        required override init() {}

        func activate(host: HostServices) {}
        func deactivate() {}

        var providerId: String { "mock-tts" }
        var providerDisplayName: String { "Mock TTS" }
        var isConfigured: Bool { true }
        var availableVoices: [PluginVoiceInfo] { [] }
        var selectedVoiceId: String? { nil }
        var settingsSummary: String? { "Mock Summary" }
        var recordedRequests: [TTSSpeakRequest] {
            requestsLock.withLock { requests }
        }

        func selectVoice(_ voiceId: String?) {}

        func speak(_ request: TTSSpeakRequest) async throws -> any TTSPlaybackSession {
            requestsLock.withLock {
                requests.append(request)
            }
            onSpeak?(request)
            return MockTTSPlaybackSession()
        }
    }

    private final class MockTTSPlaybackSession: TTSPlaybackSession, @unchecked Sendable {
        var isActive: Bool = true
        var onFinish: (@Sendable () -> Void)?

        func stop() {
            guard isActive else { return }
            isActive = false
            onFinish?()
        }
    }

    private final class MockEventBus: EventBusProtocol, @unchecked Sendable {
        @discardableResult
        func subscribe(handler: @escaping @Sendable (TypeWhisperEvent) async -> Void) -> UUID {
            UUID()
        }

        func unsubscribe(id: UUID) {}
    }

    private final class MockHostServices: HostServices, @unchecked Sendable {
        private var secrets: [String: String]
        private var defaults: [String: Any]

        let pluginDataDirectory: URL
        let eventBus: EventBusProtocol = MockEventBus()
        var activeAppBundleId: String?
        var activeAppName: String?
        var availableRuleNames: [String]
        private(set) var capabilitiesChangedCount = 0
        private(set) var streamingDisplayActiveValues: [Bool] = []

        init(
            pluginDataDirectory: URL,
            secrets: [String: String] = [:],
            defaults: [String: Any] = [:],
            availableRuleNames: [String] = []
        ) {
            self.pluginDataDirectory = pluginDataDirectory
            self.secrets = secrets
            self.defaults = defaults
            self.availableRuleNames = availableRuleNames
        }

        func storeSecret(key: String, value: String) throws {
            secrets[key] = value
        }

        func loadSecret(key: String) -> String? {
            secrets[key]
        }

        func userDefault(forKey key: String) -> Any? {
            defaults[key]
        }

        func setUserDefault(_ value: Any?, forKey key: String) {
            defaults[key] = value
        }

        func notifyCapabilitiesChanged() {
            capabilitiesChangedCount += 1
        }

        func setStreamingDisplayActive(_ active: Bool) {
            streamingDisplayActiveValues.append(active)
        }
    }

    private final class APIContext: @unchecked Sendable {
        let router: APIRouter
        let modelManager: ModelManagerService
        let historyService: HistoryService
        let profileService: ProfileService
        let workflowService: WorkflowService
        let dictionaryService: DictionaryService
        let dictationViewModel: DictationViewModel
        let audioRecordingService: AudioRecordingService
        let audioRecorderViewModel: AudioRecorderViewModel
        let audioRecorderService: AudioRecorderService
        let textInsertionService: TextInsertionService
        let ttsProvider: MockTTSProviderPlugin
        private let retainedObjects: [AnyObject]

        init(
            router: APIRouter,
            modelManager: ModelManagerService,
            historyService: HistoryService,
            profileService: ProfileService,
            workflowService: WorkflowService,
            dictionaryService: DictionaryService,
            dictationViewModel: DictationViewModel,
            audioRecordingService: AudioRecordingService,
            audioRecorderViewModel: AudioRecorderViewModel,
            audioRecorderService: AudioRecorderService,
            textInsertionService: TextInsertionService,
            ttsProvider: MockTTSProviderPlugin,
            retainedObjects: [AnyObject]
        ) {
            self.router = router
            self.modelManager = modelManager
            self.historyService = historyService
            self.profileService = profileService
            self.workflowService = workflowService
            self.dictionaryService = dictionaryService
            self.dictationViewModel = dictationViewModel
            self.audioRecordingService = audioRecordingService
            self.audioRecorderViewModel = audioRecorderViewModel
            self.audioRecorderService = audioRecorderService
            self.textInsertionService = textInsertionService
            self.ttsProvider = ttsProvider
            self.retainedObjects = retainedObjects
        }
    }

    @MainActor
    private final class MockMediaPlaybackService: MediaPlaybackService {
        let onPause: () -> Void
        let onResume: () -> Void

        init(
            onPause: @escaping () -> Void = {},
            onResume: @escaping () -> Void = {}
        ) {
            self.onPause = onPause
            self.onResume = onResume
            super.init(startListening: false)
        }

        override func pauseIfPlaying() {
            onPause()
        }

        override func resumeIfWePaused() {
            onResume()
        }
    }

    @MainActor
    private final class MockAudioDuckingService: AudioDuckingService {
        let onRestore: () -> Void
        let onDuck: (Float) -> Void

        init(
            onRestore: @escaping () -> Void = {},
            onDuck: @escaping (Float) -> Void = { _ in }
        ) {
            self.onRestore = onRestore
            self.onDuck = onDuck
        }

        override func duckAudio(to factor: Float) {
            onDuck(factor)
        }

        override func restoreAudio() {
            onRestore()
        }
    }

    @MainActor
    private final class MockSoundService: SoundService {
        let onPlay: (SoundEvent, Bool) -> Void
        let playbackDurationForEvent: (SoundEvent, Bool) -> TimeInterval?

        init(
            onPlay: @escaping (SoundEvent, Bool) -> Void = { _, _ in },
            playbackDurationForEvent: @escaping (SoundEvent, Bool) -> TimeInterval? = { _, _ in nil }
        ) {
            self.onPlay = onPlay
            self.playbackDurationForEvent = playbackDurationForEvent
            super.init()
        }

        override func play(_ event: SoundEvent, enabled: Bool) -> Bool {
            onPlay(event, enabled)
            return enabled
        }

        override func playbackDuration(for event: SoundEvent, enabled: Bool) -> TimeInterval? {
            playbackDurationForEvent(event, enabled)
        }
    }

    private final class FakeAudioDeviceTransportResolver: AudioDeviceTransportResolving {
        private let transports: [AudioDeviceID: UInt32]
        private let onResolve: ((AudioDeviceID) -> Void)?

        init(
            transports: [AudioDeviceID: UInt32],
            onResolve: ((AudioDeviceID) -> Void)? = nil
        ) {
            self.transports = transports
            self.onResolve = onResolve
        }

        func transportType(for deviceID: AudioDeviceID) -> UInt32? {
            onResolve?(deviceID)
            return transports[deviceID]
        }
    }

    private final class FakeBluetoothInputRouteStabilizer: BluetoothInputRouteStabilizing {
        private let handler: (AudioDeviceID?, String) -> Bool

        init(handler: @escaping (AudioDeviceID?, String) -> Bool) {
            self.handler = handler
        }

        func waitForActivatedDefaultInput(deviceID: AudioDeviceID?, reason: String) -> Bool {
            handler(deviceID, reason)
        }
    }

    private final class FakeAudioInputSelectionEngineValidator: AudioInputSelectionEngineValidating {
        private let handler: (AudioDeviceID?) throws -> Void

        init(handler: @escaping (AudioDeviceID?) throws -> Void) {
            self.handler = handler
        }

        func validate(preferredDeviceID: AudioDeviceID?) throws {
            try handler(preferredDeviceID)
        }
    }

    #if !APPSTORE
    private final class FakeMediaPlaybackController: MediaPlaybackControlling {
        var returnedSnapshot: MediaPlaybackSnapshot? = FakeMediaPlaybackController.snapshot(
            isPlaying: false,
            playbackRate: nil,
            bundleIdentifier: nil
        )
        var snapshotQueue: [MediaPlaybackSnapshot?] = []
        var onGetPlaybackSnapshot: ((@escaping (_ snapshot: MediaPlaybackSnapshot?) -> Void) -> Void)?
        private(set) var pauseCalls = 0
        private(set) var playCalls = 0
        private(set) var togglePlayPauseCalls = 0

        func getPlaybackSnapshot(_ onReceive: @escaping (_ snapshot: MediaPlaybackSnapshot?) -> Void) {
            if let onGetPlaybackSnapshot {
                onGetPlaybackSnapshot(onReceive)
                return
            }

            if !snapshotQueue.isEmpty {
                onReceive(snapshotQueue.removeFirst())
                return
            }

            onReceive(returnedSnapshot)
        }

        func play() {
            playCalls += 1
        }

        func pause() {
            pauseCalls += 1
        }

        func togglePlayPause() {
            togglePlayPauseCalls += 1
        }

        static func snapshot(
            isPlaying: Bool?,
            playbackRate: Double?,
            bundleIdentifier: String? = "com.apple.Music",
            trackIdentifier: String? = nil
        ) -> MediaPlaybackSnapshot {
            let resolvedTrackIdentifier = bundleIdentifier == nil ? nil : (trackIdentifier ?? "Song||Artist||Album")
            return MediaPlaybackSnapshot(
                isApplicationPlaying: isPlaying,
                playbackRate: playbackRate,
                bundleIdentifier: bundleIdentifier,
                trackIdentifier: resolvedTrackIdentifier
            )
        }
    }

    @MainActor
    private final class TestMediaPlaybackResumeScheduler {
        private(set) var scheduledDelays: [TimeInterval] = []
        private var actions: [@MainActor () -> Void] = []

        func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) {
            scheduledDelays.append(delay)
            actions.append(action)
        }

        func runNextAction() {
            guard !actions.isEmpty else { return }
            let action = actions.removeFirst()
            action()
        }

        func runPendingActions() {
            while !actions.isEmpty {
                runNextAction()
            }
        }
    }
    #endif

    func testRouterHandlesOptionsAndNotFound() async {
        let router = APIRouter()

        let optionsResponse = await router.route(
            HTTPRequest(method: "OPTIONS", path: "/v1/status", queryParams: [:], headers: [:], body: Data())
        )
        let notFoundResponse = await router.route(
            HTTPRequest(method: "GET", path: "/missing", queryParams: [:], headers: [:], body: Data())
        )

        XCTAssertEqual(optionsResponse.status, 204)
        XCTAssertEqual(notFoundResponse.status, 404)
    }

    func testRouterRequiresAPITokenForRegisteredRoutes() async throws {
        let router = APIRouter(apiTokenProvider: { "test-token" })
        router.register("GET", "/v1/status") { _ in
            .json(["status": "ready"])
        }
        router.register("GET", "/v1/models") { _ in
            .json(["ok": true])
        }

        let publicStatus = await router.route(
            HTTPRequest(method: "GET", path: "/v1/status", queryParams: [:], headers: [:], body: Data())
        )
        let missingToken = await router.route(
            HTTPRequest(method: "GET", path: "/v1/models", queryParams: [:], headers: [:], body: Data())
        )
        let badToken = await router.route(
            HTTPRequest(
                method: "GET",
                path: "/v1/models",
                queryParams: [:],
                headers: ["authorization": "Bearer wrong-token"],
                body: Data()
            )
        )
        let goodBearerToken = await router.route(
            HTTPRequest(
                method: "GET",
                path: "/v1/models",
                queryParams: [:],
                headers: ["authorization": "Bearer test-token"],
                body: Data()
            )
        )
        let goodHeaderToken = await router.route(
            HTTPRequest(
                method: "GET",
                path: "/v1/models",
                queryParams: [:],
                headers: ["x-typewhisper-api-token": "test-token"],
                body: Data()
            )
        )

        XCTAssertEqual(publicStatus.status, 200)
        XCTAssertEqual(missingToken.status, 401)
        XCTAssertEqual(badToken.status, 401)
        XCTAssertEqual(goodBearerToken.status, 200)
        XCTAssertEqual(goodHeaderToken.status, 200)
    }

    func testLocalAPIAuthenticatorEnforcesTokenOnlyWhenEnabled() {
        let authenticator = LocalAPIAuthenticator(initialToken: "test-token", requiresAuthentication: false)

        XCTAssertNil(authenticator.tokenForEnforcedRequests())

        authenticator.setRequiresAuthentication(true)
        XCTAssertEqual(authenticator.tokenForEnforcedRequests(), "test-token")

        authenticator.setRequiresAuthentication(false)
        XCTAssertNil(authenticator.tokenForEnforcedRequests())
    }

    func testSerializedResponseOmitsWildcardCORSHeaders() {
        let responseText = String(decoding: HTTPResponse.json(["ok": true]).serialized(), as: UTF8.self)

        XCTAssertFalse(responseText.contains("Access-Control-Allow-Origin: *"))
        XCTAssertFalse(responseText.contains("Access-Control-Allow-Headers: Content-Type"))
    }

    func testAPIHandlersExposeStatusHistoryAndRules() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
        }

        context = await MainActor.run { () -> APIContext in
            let context = Self.makeAPIContext(appSupportDirectory: appSupportDirectory)
            context.historyService.addRecord(
                rawText: "Sprint planning",
                finalText: "Sprint planning",
                appName: "Notes",
                appBundleIdentifier: "com.apple.Notes",
                durationSeconds: 5,
                language: "en",
                engineUsed: "parakeet"
            )
            context.profileService.addProfile(
                name: "Legacy Docs",
                urlPatterns: ["docs.github.com"],
                inputLanguage: #"["de","en"]"#,
                priority: 1
            )
            _ = context.workflowService.addWorkflow(
                name: "Docs",
                template: .summary,
                trigger: .website("docs.github.com"),
                behavior: WorkflowBehavior(settings: [
                    WorkflowBehavior.inputLanguageSettingKey: #"["de","en"]"#
                ]),
                sortOrder: 0
            )
            return context
        }

        let router = try XCTUnwrap(context?.router)

        let status = try Self.jsonObject(
            await router.route(HTTPRequest(method: "GET", path: "/v1/status", queryParams: [:], headers: [:], body: Data()))
        )
        let history = try Self.jsonObject(
            await router.route(HTTPRequest(method: "GET", path: "/v1/history", queryParams: [:], headers: [:], body: Data()))
        )
        let rules = try Self.jsonObject(
            await router.route(HTTPRequest(method: "GET", path: "/v1/rules", queryParams: [:], headers: [:], body: Data()))
        )
        let legacyProfiles = try Self.jsonObject(
            await router.route(HTTPRequest(method: "GET", path: "/v1/profiles", queryParams: [:], headers: [:], body: Data()))
        )

        XCTAssertEqual(status["status"] as? String, "no_model")
        XCTAssertEqual((history["entries"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((rules["rules"] as? [[String: Any]])?.first?["name"] as? String, "Docs")
        XCTAssertEqual((rules["rules"] as? [[String: Any]])?.first?["language_mode"] as? String, "multiple")
        XCTAssertEqual((rules["rules"] as? [[String: Any]])?.first?["language_hints"] as? [String], ["de", "en"])
        XCTAssertNil((rules["rules"] as? [[String: Any]])?.first?["input_language"] as? String)
        XCTAssertEqual((legacyProfiles["profiles"] as? [[String: Any]])?.first?["name"] as? String, "Docs")

        let workflowId = try XCTUnwrap((rules["rules"] as? [[String: Any]])?.first?["id"] as? String)
        let toggle = try Self.jsonObject(
            await router.route(HTTPRequest(method: "PUT", path: "/v1/rules/toggle", queryParams: ["id": workflowId], headers: [:], body: Data()))
        )
        XCTAssertEqual(toggle["name"] as? String, "Docs")
        XCTAssertEqual(toggle["is_enabled"] as? Bool, false)

        let toggledRules = try Self.jsonObject(
            await router.route(HTTPRequest(method: "GET", path: "/v1/rules", queryParams: [:], headers: [:], body: Data()))
        )
        XCTAssertEqual((toggledRules["rules"] as? [[String: Any]])?.first?["is_enabled"] as? Bool, false)
    }

    func testDictionaryTermsEndpointsReplaceMergeAndDeleteSingleTerm() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
        }

        context = await MainActor.run { Self.makeAPIContext(appSupportDirectory: appSupportDirectory) }
        let apiContext = try XCTUnwrap(context)
        let router = apiContext.router

        let putBody = try JSONSerialization.data(withJSONObject: [
            "terms": [" TypeWhisper ", "WhisperKit", "typewhisper", "", "Qwen3 "],
            "replace": true
        ])
        let putResponse = try Self.jsonObject(await router.route(
            HTTPRequest(
                method: "PUT",
                path: "/v1/dictionary/terms",
                queryParams: [:],
                headers: ["content-type": "application/json"],
                body: putBody
            )
        ))
        let expectedTerms = ["Qwen3", "TypeWhisper", "WhisperKit"]
        XCTAssertEqual(putResponse["count"] as? Int, 3)
        XCTAssertEqual(putResponse["terms"] as? [String], expectedTerms)
        XCTAssertEqual(
            (putResponse["term_entries"] as? [[String: Any]])?.compactMap { $0["term"] as? String },
            expectedTerms
        )

        let mergeBody = try JSONSerialization.data(withJSONObject: [
            "terms": ["Raycast", "qwen3"],
        ])
        let mergeResponse = try Self.jsonObject(await router.route(
            HTTPRequest(
                method: "PUT",
                path: "/v1/dictionary/terms",
                queryParams: [:],
                headers: ["content-type": "application/json"],
                body: mergeBody
            )
        ))
        let expectedMergedTerms = ["qwen3", "Raycast", "TypeWhisper", "WhisperKit"]
        XCTAssertEqual(mergeResponse["count"] as? Int, 4)
        XCTAssertEqual(mergeResponse["terms"] as? [String], expectedMergedTerms)

        let getResponse = try Self.jsonObject(await router.route(
            HTTPRequest(method: "GET", path: "/v1/dictionary/terms", queryParams: [:], headers: [:], body: Data())
        ))
        XCTAssertEqual(getResponse["terms"] as? [String], expectedMergedTerms)
        let enabledTerms = await MainActor.run { apiContext.dictionaryService.enabledTerms() }
        XCTAssertEqual(enabledTerms, expectedMergedTerms)

        let deleteBody = try JSONSerialization.data(withJSONObject: ["term": "typewhisper"])
        let deleteResponse = try Self.jsonObject(await router.route(
            HTTPRequest(
                method: "DELETE",
                path: "/v1/dictionary/terms",
                queryParams: [:],
                headers: ["content-type": "application/json"],
                body: deleteBody
            )
        ))
        XCTAssertEqual(deleteResponse["deleted"] as? Bool, true)
        XCTAssertEqual(deleteResponse["count"] as? Int, 3)

        let finalGet = try Self.jsonObject(await router.route(
            HTTPRequest(method: "GET", path: "/v1/dictionary/terms", queryParams: [:], headers: [:], body: Data())
        ))
        XCTAssertEqual(finalGet["terms"] as? [String], ["qwen3", "Raycast", "WhisperKit"])

        let missingDeleteResponse = try Self.jsonObject(await router.route(
            HTTPRequest(
                method: "DELETE",
                path: "/v1/dictionary/terms",
                queryParams: [:],
                headers: ["content-type": "application/json"],
                body: try JSONSerialization.data(withJSONObject: ["term": "Missing"])
            )
        ))
        XCTAssertEqual(missingDeleteResponse["deleted"] as? Bool, false)
        XCTAssertEqual(missingDeleteResponse["count"] as? Int, 3)

        let missingTermDelete = await router.route(
            HTTPRequest(
                method: "DELETE",
                path: "/v1/dictionary/terms",
                queryParams: [:],
                headers: ["content-type": "application/json"],
                body: try JSONSerialization.data(withJSONObject: [:])
            )
        )
        XCTAssertEqual(missingTermDelete.status, 400)

        let emptyDelete = await router.route(
            HTTPRequest(method: "DELETE", path: "/v1/dictionary/terms", queryParams: [:], headers: [:], body: Data())
        )
        XCTAssertEqual(emptyDelete.status, 400)
    }

    func testDictionaryTermsEndpointAcceptsStructuredTermEntries() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
        }

        context = await MainActor.run { Self.makeAPIContext(appSupportDirectory: appSupportDirectory) }
        let apiContext = try XCTUnwrap(context)
        let router = apiContext.router

        let putBody = try JSONSerialization.data(withJSONObject: [
            "term_entries": [
                ["term": " Caivex ", "ctc_min_similarity": 0.65],
                ["term": "Reson8"],
            ],
            "replace": true,
        ])
        let putResponse = try Self.jsonObject(await router.route(
            HTTPRequest(
                method: "PUT",
                path: "/v1/dictionary/terms",
                queryParams: [:],
                headers: ["content-type": "application/json"],
                body: putBody
            )
        ))

        XCTAssertEqual(putResponse["terms"] as? [String], ["Caivex", "Reson8"])
        let structuredEntries = try XCTUnwrap(putResponse["term_entries"] as? [[String: Any]])
        XCTAssertEqual(structuredEntries[0]["term"] as? String, "Caivex")
        XCTAssertEqual(try XCTUnwrap(structuredEntries[0]["ctc_min_similarity"] as? Double), 0.65, accuracy: 0.0001)
        XCTAssertEqual(structuredEntries[1]["term"] as? String, "Reson8")
        XCTAssertNil(structuredEntries[1]["ctc_min_similarity"])

        let mergeBody = try JSONSerialization.data(withJSONObject: [
            "terms": ["caivex"],
        ])
        _ = await router.route(HTTPRequest(
            method: "PUT",
            path: "/v1/dictionary/terms",
            queryParams: [:],
            headers: ["content-type": "application/json"],
            body: mergeBody
        ))

        let hints = await MainActor.run { apiContext.dictionaryService.enabledTermHints() }
        XCTAssertEqual(hints, [
            PluginDictionaryTermHint(text: "caivex", ctcMinSimilarity: 0.65),
            PluginDictionaryTermHint(text: "Reson8", ctcMinSimilarity: nil),
        ])
    }

    func testDictionaryTermsEndpointRejectsAmbiguousPayloadFormats() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
        }

        context = await MainActor.run { Self.makeAPIContext(appSupportDirectory: appSupportDirectory) }
        let router = try XCTUnwrap(context?.router)
        let body = try JSONSerialization.data(withJSONObject: [
            "terms": ["Caivex"],
            "term_entries": [
                ["term": "Reson8", "ctc_min_similarity": 0.65],
            ],
        ])

        let response = await router.route(HTTPRequest(
            method: "PUT",
            path: "/v1/dictionary/terms",
            queryParams: [:],
            headers: ["content-type": "application/json"],
            body: body
        ))

        XCTAssertEqual(response.status, 400)
        let error = try Self.jsonObject(response)
        XCTAssertEqual((error["error"] as? [String: Any])?["message"] as? String, "Use either 'terms' or 'term_entries', not both")
    }

    func testDictionaryCorrectionsEndpointsListUpsertDeleteAndValidateInput() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
        }

        context = await MainActor.run { Self.makeAPIContext(appSupportDirectory: appSupportDirectory) }
        let apiContext = try XCTUnwrap(context)
        let router = apiContext.router

        let initialGet = try Self.jsonObject(await router.route(
            HTTPRequest(method: "GET", path: "/v1/dictionary/corrections", queryParams: [:], headers: [:], body: Data())
        ))
        XCTAssertEqual(initialGet["count"] as? Int, 0)
        XCTAssertEqual((initialGet["corrections"] as? [[String: Any]])?.count, 0)

        let putBody = try JSONSerialization.data(withJSONObject: [
            "original": "teh",
            "replacement": "the",
            "caseSensitive": false,
        ])
        let putResponse = try Self.jsonObject(await router.route(
            HTTPRequest(
                method: "PUT",
                path: "/v1/dictionary/corrections",
                queryParams: [:],
                headers: ["content-type": "application/json"],
                body: putBody
            )
        ))
        var corrections = try XCTUnwrap(putResponse["corrections"] as? [[String: Any]])
        XCTAssertEqual(putResponse["count"] as? Int, 1)
        XCTAssertEqual(corrections.first?["original"] as? String, "teh")
        XCTAssertEqual(corrections.first?["replacement"] as? String, "the")
        XCTAssertEqual(corrections.first?["caseSensitive"] as? Bool, false)

        let upsertBody = try JSONSerialization.data(withJSONObject: [
            "original": "TEH",
            "replacement": "The",
            "caseSensitive": true,
        ])
        let upsertResponse = try Self.jsonObject(await router.route(
            HTTPRequest(
                method: "PUT",
                path: "/v1/dictionary/corrections",
                queryParams: [:],
                headers: ["content-type": "application/json"],
                body: upsertBody
            )
        ))
        corrections = try XCTUnwrap(upsertResponse["corrections"] as? [[String: Any]])
        XCTAssertEqual(upsertResponse["count"] as? Int, 1)
        XCTAssertEqual(corrections.first?["original"] as? String, "TEH")
        XCTAssertEqual(corrections.first?["replacement"] as? String, "The")
        XCTAssertEqual(corrections.first?["caseSensitive"] as? Bool, true)
        let serviceCorrectionsCount = await MainActor.run { apiContext.dictionaryService.correctionsCount }
        XCTAssertEqual(serviceCorrectionsCount, 1)

        let emptyReplacementBody = try JSONSerialization.data(withJSONObject: [
            "original": "¿",
            "replacement": "",
            "caseSensitive": false,
        ])
        let emptyReplacementResponse = try Self.jsonObject(await router.route(
            HTTPRequest(
                method: "PUT",
                path: "/v1/dictionary/corrections",
                queryParams: [:],
                headers: ["content-type": "application/json"],
                body: emptyReplacementBody
            )
        ))
        XCTAssertEqual(emptyReplacementResponse["count"] as? Int, 2)

        let deleteBody = try JSONSerialization.data(withJSONObject: ["original": "teh"])
        let deleteResponse = try Self.jsonObject(await router.route(
            HTTPRequest(
                method: "DELETE",
                path: "/v1/dictionary/corrections",
                queryParams: [:],
                headers: ["content-type": "application/json"],
                body: deleteBody
            )
        ))
        XCTAssertEqual(deleteResponse["deleted"] as? Bool, true)
        XCTAssertEqual(deleteResponse["count"] as? Int, 1)

        let missingDeleteBody = try JSONSerialization.data(withJSONObject: ["original": "missing"])
        let missingDeleteResponse = try Self.jsonObject(await router.route(
            HTTPRequest(
                method: "DELETE",
                path: "/v1/dictionary/corrections",
                queryParams: [:],
                headers: ["content-type": "application/json"],
                body: missingDeleteBody
            )
        ))
        XCTAssertEqual(missingDeleteResponse["deleted"] as? Bool, false)
        XCTAssertEqual(missingDeleteResponse["count"] as? Int, 1)

        let missingOriginalPut = await router.route(
            HTTPRequest(
                method: "PUT",
                path: "/v1/dictionary/corrections",
                queryParams: [:],
                headers: ["content-type": "application/json"],
                body: try JSONSerialization.data(withJSONObject: ["replacement": "value"])
            )
        )
        XCTAssertEqual(missingOriginalPut.status, 400)

        let missingReplacementPut = await router.route(
            HTTPRequest(
                method: "PUT",
                path: "/v1/dictionary/corrections",
                queryParams: [:],
                headers: ["content-type": "application/json"],
                body: try JSONSerialization.data(withJSONObject: ["original": "value"])
            )
        )
        XCTAssertEqual(missingReplacementPut.status, 400)

        let missingOriginalDelete = await router.route(
            HTTPRequest(
                method: "DELETE",
                path: "/v1/dictionary/corrections",
                queryParams: [:],
                headers: ["content-type": "application/json"],
                body: try JSONSerialization.data(withJSONObject: [:])
            )
        )
        XCTAssertEqual(missingOriginalDelete.status, 400)
    }

    func testTranscribeEndpointPassesDictionaryTermsAsPrompt() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
        }

        MockTranscriptionPlugin.reset()
        context = await MainActor.run {
            let context = Self.makeAPIContext(appSupportDirectory: appSupportDirectory, withMockTranscriptionPlugin: true)
            context.dictionaryService.setTerms([" TypeWhisper ", "WhisperKit", "typewhisper"], replaceExisting: true)
            return context
        }

        let router = try XCTUnwrap(context?.router)
        let wavData = WavEncoder.encode(Array(repeating: Float(0), count: 1600))
        let boundary = "TestBoundary-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"test.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"language\"\r\n\r\n".data(using: .utf8)!)
        body.append("en\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let response = try Self.jsonObject(await router.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/transcribe",
                queryParams: [:],
                headers: ["content-type": "multipart/form-data; boundary=\(boundary)"],
                body: body
            )
        ))

        XCTAssertEqual(response["text"] as? String, "transcribed")
        XCTAssertEqual(MockTranscriptionPlugin.lastPrompt, "TypeWhisper, WhisperKit")
    }

    func testTranscribeEndpointNormalizesNumbersByDefault() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
        }

        MockTranscriptionPlugin.reset()
        defer { MockTranscriptionPlugin.reset() }
        MockTranscriptionPlugin.setResponseText("two")
        context = await MainActor.run {
            Self.makeAPIContext(appSupportDirectory: appSupportDirectory, withMockTranscriptionPlugin: true)
        }

        let router = try XCTUnwrap(context?.router)
        let wavData = WavEncoder.encode(Array(repeating: Float(0), count: 1600))

        let response = try Self.jsonObject(await router.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/transcribe",
                queryParams: [:],
                headers: ["content-type": "audio/wav", "x-language": "en"],
                body: wavData
            )
        ))

        XCTAssertEqual(response["text"] as? String, "2")
    }

    func testTranscribeEndpointNormalizeNumbersFalsePreservesRawText() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
        }

        MockTranscriptionPlugin.reset()
        defer { MockTranscriptionPlugin.reset() }
        MockTranscriptionPlugin.setResponseText("two")
        context = await MainActor.run {
            Self.makeAPIContext(appSupportDirectory: appSupportDirectory, withMockTranscriptionPlugin: true)
        }

        let router = try XCTUnwrap(context?.router)
        let wavData = WavEncoder.encode(Array(repeating: Float(0), count: 1600))

        let response = try Self.jsonObject(await router.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/transcribe",
                queryParams: [:],
                headers: [
                    "content-type": "audio/wav",
                    "x-language": "en",
                    "x-normalize-numbers": "false",
                ],
                body: wavData
            )
        ))

        XCTAssertEqual(response["text"] as? String, "two")
    }

    func testTranscribeEndpointAppliesDictionaryCorrectionsByDefault() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
        }

        MockTranscriptionPlugin.reset()
        defer { MockTranscriptionPlugin.reset() }
        MockTranscriptionPlugin.setResponseText("teh TypeWhisper")
        context = await MainActor.run {
            Self.makeAPIContext(appSupportDirectory: appSupportDirectory, withMockTranscriptionPlugin: true)
        }
        let apiContext = try XCTUnwrap(context)
        try await MainActor.run {
            try apiContext.dictionaryService.upsertAPICorrection(
                original: "teh",
                replacement: "the",
                caseSensitive: false
            )
        }

        let response = try Self.jsonObject(await apiContext.router.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/transcribe",
                queryParams: [:],
                headers: ["content-type": "audio/wav", "x-language": "en"],
                body: WavEncoder.encode(Array(repeating: Float(0), count: 1600))
            )
        ))

        XCTAssertEqual(response["text"] as? String, "the TypeWhisper")
        let usageCount = await MainActor.run {
            apiContext.dictionaryService.corrections.first?.usageCount
        }
        XCTAssertEqual(usageCount, 1)
    }

    func testTranscribeEndpointApplyCorrectionsFalsePreservesRawText() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
        }

        MockTranscriptionPlugin.reset()
        defer { MockTranscriptionPlugin.reset() }
        MockTranscriptionPlugin.setResponseText("teh TypeWhisper")
        context = await MainActor.run {
            Self.makeAPIContext(appSupportDirectory: appSupportDirectory, withMockTranscriptionPlugin: true)
        }
        let apiContext = try XCTUnwrap(context)
        try await MainActor.run {
            try apiContext.dictionaryService.upsertAPICorrection(
                original: "teh",
                replacement: "the",
                caseSensitive: false
            )
        }

        let wavData = WavEncoder.encode(Array(repeating: Float(0), count: 1600))
        let rawResponse = try Self.jsonObject(await apiContext.router.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/transcribe",
                queryParams: [:],
                headers: [
                    "content-type": "audio/wav",
                    "x-language": "en",
                    "x-apply-corrections": "false",
                ],
                body: wavData
            )
        ))

        XCTAssertEqual(rawResponse["text"] as? String, "teh TypeWhisper")

        let boundary = "Boundary-\(UUID().uuidString)"
        let multipartResponse = try Self.jsonObject(await apiContext.router.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/transcribe",
                queryParams: [:],
                headers: ["content-type": "multipart/form-data; boundary=\(boundary)"],
                body: Self.multipartTranscribeBody(
                    wavData: wavData,
                    boundary: boundary,
                    fields: [("apply_corrections", "false")]
                )
            )
        ))

        XCTAssertEqual(multipartResponse["text"] as? String, "teh TypeWhisper")
        let usageCount = await MainActor.run {
            apiContext.dictionaryService.corrections.first?.usageCount
        }
        XCTAssertEqual(usageCount, 0)
    }

    func testTranscribeEndpointRejectsInvalidApplyCorrectionsValues() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
        }

        context = await MainActor.run {
            Self.makeAPIContext(appSupportDirectory: appSupportDirectory, withMockTranscriptionPlugin: true)
        }
        let router = try XCTUnwrap(context?.router)
        let wavData = WavEncoder.encode(Array(repeating: Float(0), count: 1600))

        let rawResponse = await router.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/transcribe",
                queryParams: [:],
                headers: [
                    "content-type": "audio/wav",
                    "x-apply-corrections": "maybe",
                ],
                body: wavData
            )
        )
        let rawJSON = try Self.jsonObject(rawResponse)

        XCTAssertEqual(rawResponse.status, 400)
        XCTAssertEqual((rawJSON["error"] as? [String: Any])?["message"] as? String, "Invalid 'x-apply-corrections' value")

        let boundary = "Boundary-\(UUID().uuidString)"
        let multipartResponse = await router.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/transcribe",
                queryParams: [:],
                headers: ["content-type": "multipart/form-data; boundary=\(boundary)"],
                body: Self.multipartTranscribeBody(
                    wavData: wavData,
                    boundary: boundary,
                    fields: [("apply_corrections", "maybe")]
                )
            )
        )
        let multipartJSON = try Self.jsonObject(multipartResponse)

        XCTAssertEqual(multipartResponse.status, 400)
        XCTAssertEqual((multipartJSON["error"] as? [String: Any])?["message"] as? String, "Invalid 'apply_corrections' value")
    }

    func testTranscribeEndpointRejectsInvalidNormalizeNumbersHeader() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
        }

        context = await MainActor.run {
            Self.makeAPIContext(appSupportDirectory: appSupportDirectory, withMockTranscriptionPlugin: true)
        }

        let router = try XCTUnwrap(context?.router)
        let response = await router.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/transcribe",
                queryParams: [:],
                headers: [
                    "content-type": "audio/wav",
                    "x-normalize-numbers": "maybe",
                ],
                body: WavEncoder.encode(Array(repeating: Float(0), count: 1600))
            )
        )
        let json = try Self.jsonObject(response)

        XCTAssertEqual(response.status, 400)
        XCTAssertEqual((json["error"] as? [String: Any])?["message"] as? String, "Invalid 'x-normalize-numbers' value")
    }

    func testTranscribeEndpointRejectsInvalidMultipartNormalizeNumbers() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
        }

        context = await MainActor.run {
            Self.makeAPIContext(appSupportDirectory: appSupportDirectory, withMockTranscriptionPlugin: true)
        }

        let router = try XCTUnwrap(context?.router)
        let boundary = "Boundary-\(UUID().uuidString)"
        let wavData = WavEncoder.encode(Array(repeating: Float(0), count: 1600))
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"test.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"normalize_numbers\"\r\n\r\n".data(using: .utf8)!)
        body.append("maybe\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let response = await router.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/transcribe",
                queryParams: [:],
                headers: ["content-type": "multipart/form-data; boundary=\(boundary)"],
                body: body
            )
        )
        let json = try Self.jsonObject(response)

        XCTAssertEqual(response.status, 400)
        XCTAssertEqual((json["error"] as? [String: Any])?["message"] as? String, "Invalid 'normalize_numbers' value")
    }

    func testTranscribeEndpointUsesOverrideEngineBudgetForDictionaryPrompt() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
        }

        MockTranscriptionPlugin.reset()
        BudgetedTranscriptionPlugin.reset()
        context = await MainActor.run {
            let context = Self.makeAPIContext(appSupportDirectory: appSupportDirectory, withMockTranscriptionPlugin: true)
            PluginManager.shared.loadedPlugins.append(
                LoadedPlugin(
                    manifest: PluginManifest(
                        id: "com.typewhisper.mock.budgeted-transcription",
                        name: "Budgeted Mock Transcription",
                        version: "1.0.0",
                        principalClass: "APIRouterBudgetedTranscriptionPlugin"
                    ),
                    instance: BudgetedTranscriptionPlugin(),
                    bundle: Bundle.main,
                    sourceURL: appSupportDirectory,
                    isEnabled: true
                )
            )
            context.dictionaryService.setTerms(Self.makeLongTerms(count: 40, length: 24), replaceExisting: true)
            return context
        }

        let router = try XCTUnwrap(context?.router)
        let wavData = WavEncoder.encode(Array(repeating: Float(0), count: 1600))

        let response = try Self.jsonObject(await router.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/transcribe",
                queryParams: [:],
                headers: [
                    "content-type": "audio/wav",
                    "x-engine": "budgeted-mock",
                ],
                body: wavData
            )
        ))

        XCTAssertEqual(response["text"] as? String, "transcribed")
        XCTAssertNil(MockTranscriptionPlugin.lastPrompt)
        XCTAssertGreaterThan(try XCTUnwrap(BudgetedTranscriptionPlugin.lastPrompt).count, 600)
    }

    func testTranscribeEndpointUsesSelectedEngineBudgetWhenNoOverrideIsProvided() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
        }

        MockTranscriptionPlugin.reset()
        BudgetedTranscriptionPlugin.reset()
        context = await MainActor.run {
            let context = Self.makeAPIContext(appSupportDirectory: appSupportDirectory, withMockTranscriptionPlugin: true)
            let budgetedPlugin = BudgetedTranscriptionPlugin()
            PluginManager.shared.loadedPlugins.append(
                LoadedPlugin(
                    manifest: PluginManifest(
                        id: "com.typewhisper.mock.budgeted-transcription",
                        name: "Budgeted Mock Transcription",
                        version: "1.0.0",
                        principalClass: "APIRouterBudgetedTranscriptionPlugin"
                    ),
                    instance: budgetedPlugin,
                    bundle: Bundle.main,
                    sourceURL: appSupportDirectory,
                    isEnabled: true
                )
            )
            context.modelManager.selectProvider(budgetedPlugin.providerId)
            context.dictionaryService.setTerms(Self.makeLongTerms(count: 40, length: 24), replaceExisting: true)
            return context
        }

        let router = try XCTUnwrap(context?.router)
        let wavData = WavEncoder.encode(Array(repeating: Float(0), count: 1600))

        let response = try Self.jsonObject(await router.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/transcribe",
                queryParams: [:],
                headers: ["content-type": "audio/wav"],
                body: wavData
            )
        ))

        XCTAssertEqual(response["text"] as? String, "transcribed")
        XCTAssertNil(MockTranscriptionPlugin.lastPrompt)
        XCTAssertGreaterThan(try XCTUnwrap(BudgetedTranscriptionPlugin.lastPrompt).count, 600)
    }

    func testTranscribeEndpointAcceptsRepeatedLanguageHints() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
        }

        MockTranscriptionPlugin.reset()
        context = await MainActor.run {
            Self.makeAPIContext(appSupportDirectory: appSupportDirectory, withMockTranscriptionPlugin: true)
        }

        let router = try XCTUnwrap(context?.router)
        let wavData = WavEncoder.encode(Array(repeating: Float(0), count: 1600))
        let boundary = "TestBoundary-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"test.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n".data(using: .utf8)!)
        for hint in ["de", "en"] {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"language_hint\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(hint)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let response = try Self.jsonObject(await router.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/transcribe",
                queryParams: [:],
                headers: ["content-type": "multipart/form-data; boundary=\(boundary)"],
                body: body
            )
        ))

        XCTAssertEqual(response["text"] as? String, "transcribed")
        XCTAssertEqual(MockTranscriptionPlugin.lastLanguageSelection.languageHints, ["de", "en"])
        XCTAssertNil(MockTranscriptionPlugin.lastLanguageSelection.requestedLanguage)
    }

    @MainActor
    func testTranscribeEndpointVerboseJSONIncludesSpeakerWhenStructuredSegmentsAreReturned() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
        }

        context = Self.makeAPIContext(appSupportDirectory: appSupportDirectory)
        let plugin = StructuredTranscriptionPlugin()
        PluginManager.shared.loadedPlugins.append(
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.structured-transcription",
                    name: "Structured Mock Transcription",
                    version: "1.0.0",
                    principalClass: "APIRouterStructuredTranscriptionPlugin"
                ),
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        )
        context?.modelManager.selectProvider(plugin.providerId)

        let router = try XCTUnwrap(context?.router)
        let wavData = WavEncoder.encode(Array(repeating: Float(0), count: 1600))
        let response = try Self.jsonObject(await router.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/transcribe",
                queryParams: [:],
                headers: [
                    "content-type": "audio/wav",
                    "x-response-format": "verbose_json",
                ],
                body: wavData
            )
        ))

        let segments = try XCTUnwrap(response["segments"] as? [[String: Any]])
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0]["text"] as? String, "Hello")
        XCTAssertEqual(segments[0]["speaker"] as? String, "Speaker A")
        XCTAssertEqual(segments[1]["speaker"] as? String, "Speaker B")
    }

    func testTranscribeLocalFileEndpointTranscribesTemporaryWavFile() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        let audioDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
            TestSupport.remove(audioDirectory)
        }

        MockTranscriptionPlugin.reset()
        context = await MainActor.run {
            Self.makeAPIContext(appSupportDirectory: appSupportDirectory, withMockTranscriptionPlugin: true)
        }

        let fileURL = audioDirectory.appendingPathComponent("large-file.wav")
        try WavEncoder.encode(Array(repeating: Float(0), count: 1600)).write(to: fileURL)

        let response = try Self.jsonObject(await XCTUnwrap(context?.router).route(
            HTTPRequest(
                method: "POST",
                path: "/v1/transcribe/local-file",
                queryParams: [:],
                headers: ["content-type": "application/json"],
                body: try JSONSerialization.data(withJSONObject: ["path": fileURL.path])
            )
        ))

        XCTAssertEqual(response["text"] as? String, "transcribed")
        XCTAssertEqual(MockTranscriptionPlugin.lastLanguageSelection.languageHints, [])
        XCTAssertNil(MockTranscriptionPlugin.lastLanguageSelection.requestedLanguage)
    }

    func testTranscribeLocalFileEndpointAppliesDictionaryCorrectionsByDefault() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        let audioDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
            TestSupport.remove(audioDirectory)
        }

        MockTranscriptionPlugin.reset()
        defer { MockTranscriptionPlugin.reset() }
        MockTranscriptionPlugin.setResponseText("teh TypeWhisper")
        context = await MainActor.run {
            Self.makeAPIContext(appSupportDirectory: appSupportDirectory, withMockTranscriptionPlugin: true)
        }
        let apiContext = try XCTUnwrap(context)
        try await MainActor.run {
            try apiContext.dictionaryService.upsertAPICorrection(
                original: "teh",
                replacement: "the",
                caseSensitive: false
            )
        }

        let fileURL = audioDirectory.appendingPathComponent("corrected.wav")
        try WavEncoder.encode(Array(repeating: Float(0), count: 1600)).write(to: fileURL)

        let response = try Self.jsonObject(await apiContext.router.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/transcribe/local-file",
                queryParams: [:],
                headers: ["content-type": "application/json"],
                body: try JSONSerialization.data(withJSONObject: ["path": fileURL.path])
            )
        ))

        XCTAssertEqual(response["text"] as? String, "the TypeWhisper")
        let usageCount = await MainActor.run {
            apiContext.dictionaryService.corrections.first?.usageCount
        }
        XCTAssertEqual(usageCount, 1)
    }

    func testTranscribeLocalFileEndpointApplyCorrectionsFalsePreservesRawText() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        let audioDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
            TestSupport.remove(audioDirectory)
        }

        MockTranscriptionPlugin.reset()
        defer { MockTranscriptionPlugin.reset() }
        MockTranscriptionPlugin.setResponseText("teh TypeWhisper")
        context = await MainActor.run {
            Self.makeAPIContext(appSupportDirectory: appSupportDirectory, withMockTranscriptionPlugin: true)
        }
        let apiContext = try XCTUnwrap(context)
        try await MainActor.run {
            try apiContext.dictionaryService.upsertAPICorrection(
                original: "teh",
                replacement: "the",
                caseSensitive: false
            )
        }

        let fileURL = audioDirectory.appendingPathComponent("raw.wav")
        try WavEncoder.encode(Array(repeating: Float(0), count: 1600)).write(to: fileURL)

        let response = try Self.jsonObject(await apiContext.router.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/transcribe/local-file",
                queryParams: [:],
                headers: ["content-type": "application/json"],
                body: try JSONSerialization.data(withJSONObject: [
                    "path": fileURL.path,
                    "apply_corrections": false,
                ])
            )
        ))

        XCTAssertEqual(response["text"] as? String, "teh TypeWhisper")
        let usageCount = await MainActor.run {
            apiContext.dictionaryService.corrections.first?.usageCount
        }
        XCTAssertEqual(usageCount, 0)
    }

    func testTranscribeLocalFileEndpointRejectsInvalidApplyCorrectionsValue() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        let audioDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
            TestSupport.remove(audioDirectory)
        }

        context = await MainActor.run {
            Self.makeAPIContext(appSupportDirectory: appSupportDirectory, withMockTranscriptionPlugin: true)
        }
        let fileURL = audioDirectory.appendingPathComponent("invalid-corrections.wav")
        try WavEncoder.encode(Array(repeating: Float(0), count: 1600)).write(to: fileURL)

        let router = try XCTUnwrap(context?.router)
        let response = await router.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/transcribe/local-file",
                queryParams: [:],
                headers: ["content-type": "application/json"],
                body: try JSONSerialization.data(withJSONObject: [
                    "path": fileURL.path,
                    "apply_corrections": "maybe",
                ])
            )
        )
        let json = try Self.jsonObject(response)

        XCTAssertEqual(response.status, 400)
        XCTAssertEqual((json["error"] as? [String: Any])?["message"] as? String, "Invalid 'apply_corrections' value")
    }

    func testTranscribeLocalFileEndpointUsesLanguageHintsAndEngineModelOverrides() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        let audioDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
            TestSupport.remove(audioDirectory)
        }

        MockTranscriptionPlugin.reset()
        context = await MainActor.run {
            Self.makeAPIContext(appSupportDirectory: appSupportDirectory, withMockTranscriptionPlugin: true)
        }

        let fileURL = audioDirectory.appendingPathComponent("hinted.wav")
        try WavEncoder.encode(Array(repeating: Float(0), count: 1600)).write(to: fileURL)

        let body: [String: Any] = [
            "path": fileURL.path,
            "language_hints": ["de", "en"],
            "task": "transcribe",
            "engine": "mock",
            "model": "tiny"
        ]
        let response = try Self.jsonObject(await XCTUnwrap(context?.router).route(
            HTTPRequest(
                method: "POST",
                path: "/v1/transcribe/local-file",
                queryParams: [:],
                headers: ["content-type": "application/json"],
                body: try JSONSerialization.data(withJSONObject: body)
            )
        ))

        XCTAssertEqual(response["text"] as? String, "transcribed")
        XCTAssertEqual(response["engine"] as? String, "mock")
        XCTAssertEqual(response["model"] as? String, "tiny")
        XCTAssertEqual(MockTranscriptionPlugin.lastLanguageSelection.languageHints, ["de", "en"])
        XCTAssertNil(MockTranscriptionPlugin.lastLanguageSelection.requestedLanguage)
    }

    func testTranscribeLocalFileEndpointUsesFirstHintForLegacyEngine() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        let audioDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
            TestSupport.remove(audioDirectory)
        }

        context = await MainActor.run {
            Self.makeAPIContext(appSupportDirectory: appSupportDirectory)
        }
        let plugin = StructuredTranscriptionPlugin()
        await MainActor.run {
            PluginManager.shared.loadedPlugins.append(
                LoadedPlugin(
                    manifest: PluginManifest(
                        id: "com.typewhisper.mock.structured-transcription",
                        name: "Structured Mock Transcription",
                        version: "1.0.0",
                        principalClass: "APIRouterStructuredTranscriptionPlugin"
                    ),
                    instance: plugin,
                    bundle: Bundle.main,
                    sourceURL: appSupportDirectory,
                    isEnabled: true
                )
            )
        }

        let fileURL = audioDirectory.appendingPathComponent("legacy-hinted.wav")
        try WavEncoder.encode(Array(repeating: Float(0), count: 1600)).write(to: fileURL)

        let body: [String: Any] = [
            "path": fileURL.path,
            "language_hints": ["de", "en"],
            "engine": "structured-mock"
        ]
        let response = try Self.jsonObject(await XCTUnwrap(context?.router).route(
            HTTPRequest(
                method: "POST",
                path: "/v1/transcribe/local-file",
                queryParams: [:],
                headers: ["content-type": "application/json"],
                body: try JSONSerialization.data(withJSONObject: body)
            )
        ))

        XCTAssertEqual(response["text"] as? String, "Speaker A: Hello\nSpeaker B: Hi")
        XCTAssertEqual(response["language"] as? String, "de")
    }

    func testTranscribeLocalFileEndpointRejectsMissingAndUnsupportedFiles() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        let audioDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
            TestSupport.remove(audioDirectory)
        }

        context = await MainActor.run {
            Self.makeAPIContext(appSupportDirectory: appSupportDirectory, withMockTranscriptionPlugin: true)
        }
        let router = try XCTUnwrap(context?.router)

        let missingResponse = await router.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/transcribe/local-file",
                queryParams: [:],
                headers: ["content-type": "application/json"],
                body: try JSONSerialization.data(withJSONObject: [
                    "path": audioDirectory.appendingPathComponent("missing.wav").path
                ])
            )
        )
        let missingJSON = try Self.jsonObject(missingResponse)

        XCTAssertEqual(missingResponse.status, 400)
        XCTAssertEqual((missingJSON["error"] as? [String: Any])?["message"] as? String, "File not found")

        let unsupportedURL = audioDirectory.appendingPathComponent("notes.txt")
        try "not audio".write(to: unsupportedURL, atomically: true, encoding: .utf8)

        let unsupportedResponse = await router.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/transcribe/local-file",
                queryParams: [:],
                headers: ["content-type": "application/json"],
                body: try JSONSerialization.data(withJSONObject: ["path": unsupportedURL.path])
            )
        )
        let unsupportedJSON = try Self.jsonObject(unsupportedResponse)

        XCTAssertEqual(unsupportedResponse.status, 400)
        XCTAssertEqual((unsupportedJSON["error"] as? [String: Any])?["message"] as? String, "Unsupported audio format")
    }

    func testTranscribeEndpointRejectsMixedLanguageAndHints() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
        }

        context = await MainActor.run {
            Self.makeAPIContext(appSupportDirectory: appSupportDirectory, withMockTranscriptionPlugin: true)
        }

        let router = try XCTUnwrap(context?.router)
        let response = await router.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/transcribe",
                queryParams: [:],
                headers: [
                    "content-type": "audio/wav",
                    "x-language": "de",
                    "x-language-hints": "en,nl"
                ],
                body: WavEncoder.encode(Array(repeating: Float(0), count: 1600))
            )
        )
        let json = try Self.jsonObject(response)

        XCTAssertEqual(response.status, 400)
        XCTAssertEqual((json["error"] as? [String: Any])?["message"] as? String, "Use either 'language' or 'language_hint', not both")
    }

    func testRaycastDictationAPIContractRemainsStable() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
        }

        context = await MainActor.run { Self.makeAPIContext(appSupportDirectory: appSupportDirectory) }
        let router = try XCTUnwrap(context?.router)

        let statusResponse = await router.route(
            HTTPRequest(method: "GET", path: "/v1/dictation/status", queryParams: [:], headers: [:], body: Data())
        )
        let statusJSON = try Self.jsonObject(statusResponse)
        XCTAssertEqual(statusResponse.status, 200)
        XCTAssertEqual(statusJSON["is_recording"] as? Bool, false)

        let stopResponse = await router.route(
            HTTPRequest(method: "POST", path: "/v1/dictation/stop", queryParams: [:], headers: [:], body: Data())
        )
        let stopJSON = try Self.jsonObject(stopResponse)
        XCTAssertEqual(stopResponse.status, 409)
        XCTAssertEqual((stopJSON["error"] as? [String: Any])?["message"] as? String, "Not recording")

        let transcriptionResponse = await router.route(
            HTTPRequest(
                method: "GET",
                path: "/v1/dictation/transcription",
                queryParams: ["id": "not-a-uuid"],
                headers: [:],
                body: Data()
            )
        )
        let transcriptionJSON = try Self.jsonObject(transcriptionResponse)
        XCTAssertEqual(transcriptionResponse.status, 400)
        XCTAssertEqual(
            (transcriptionJSON["error"] as? [String: Any])?["message"] as? String,
            "Missing or invalid 'id' query parameter"
        )
    }

    func testRecorderStatusEndpointReturnsRecordingBoolean() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
        }

        context = await MainActor.run { Self.makeAPIContext(appSupportDirectory: appSupportDirectory) }
        let router = try XCTUnwrap(context?.router)

        let response = await router.route(
            HTTPRequest(method: "GET", path: "/v1/recorder/status", queryParams: [:], headers: [:], body: Data())
        )
        let json = try Self.jsonObject(response)

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(json["recording"] as? Bool, false)
    }

    func testRecorderStartRejectsWhenNoSourceIsEnabled() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
        }

        context = await MainActor.run { Self.makeAPIContext(appSupportDirectory: appSupportDirectory) }
        let router = try XCTUnwrap(context?.router)

        let response = await router.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/recorder/start",
                queryParams: ["mic": "false", "system_audio": "false"],
                headers: [:],
                body: Data()
            )
        )
        let json = try Self.jsonObject(response)

        XCTAssertEqual(response.status, 400)
        XCTAssertEqual((json["error"] as? [String: Any])?["message"] as? String, "At least one audio source must be enabled.")
    }

    func testRecorderStopWithoutRecordingReturnsConflict() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
        }

        context = await MainActor.run { Self.makeAPIContext(appSupportDirectory: appSupportDirectory) }
        let router = try XCTUnwrap(context?.router)

        let response = await router.route(
            HTTPRequest(method: "POST", path: "/v1/recorder/stop", queryParams: [:], headers: [:], body: Data())
        )
        let json = try Self.jsonObject(response)

        XCTAssertEqual(response.status, 409)
        XCTAssertEqual((json["error"] as? [String: Any])?["message"] as? String, "Not recording")
    }

    func testRecorderEndpointsReturnSessionIDAndCompletedTranscript() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
        }

        context = await MainActor.run {
            Self.makeAPIContext(appSupportDirectory: appSupportDirectory, withMockTranscriptionPlugin: true)
        }
        let apiContext = try XCTUnwrap(context)
        let router = apiContext.router
        let recordingsDirectory = appSupportDirectory.appendingPathComponent("recordings")

        await MainActor.run {
            apiContext.audioRecorderService.recordingsDirectoryOverride = recordingsDirectory
            apiContext.audioRecorderService.startRecordingOverride = { _, _, _, outputURL, _ in
                try Data("placeholder".utf8).write(to: outputURL)
                return outputURL
            }
            apiContext.audioRecorderService.stopRecordingOverride = { outputURL in
                try Data("recorded".utf8).write(to: outputURL)
                return outputURL
            }
            apiContext.audioRecorderService.currentBufferOverride = {
                Array(repeating: 0.25, count: Int(AudioRecorderService.transcriptionSampleRate))
            }
            apiContext.audioRecorderViewModel.transcriptionEnabled = true
        }

        let startResponse = await router.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/recorder/start",
                queryParams: ["mic": "true", "system_audio": "false"],
                headers: [:],
                body: Data()
            )
        )
        let start = try Self.jsonObject(startResponse)
        let startID = try XCTUnwrap(start["id"] as? String)
        XCTAssertEqual(startResponse.status, 200)
        XCTAssertEqual(start["status"] as? String, "recording")
        XCTAssertNotNil(UUID(uuidString: startID))

        let statusWhileRecording = try Self.jsonObject(
            await router.route(HTTPRequest(method: "GET", path: "/v1/recorder/status", queryParams: [:], headers: [:], body: Data()))
        )
        XCTAssertEqual(statusWhileRecording["recording"] as? Bool, true)

        let stopResponse = await router.route(
            HTTPRequest(method: "POST", path: "/v1/recorder/stop", queryParams: [:], headers: [:], body: Data())
        )
        let stop = try Self.jsonObject(stopResponse)
        XCTAssertEqual(stopResponse.status, 200)
        XCTAssertEqual(stop["id"] as? String, startID)
        XCTAssertEqual(stop["status"] as? String, "finalizing")

        var completedResponse: [String: Any]?
        for _ in 0..<40 {
            let response = try Self.jsonObject(
                await router.route(
                    HTTPRequest(
                        method: "GET",
                        path: "/v1/recorder/session",
                        queryParams: ["id": startID],
                        headers: [:],
                        body: Data()
                    )
                )
            )
            if response["status"] as? String == "completed" {
                completedResponse = response
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }

        let completed = try XCTUnwrap(completedResponse)
        XCTAssertEqual(completed["id"] as? String, startID)
        XCTAssertEqual(completed["text"] as? String, "transcribed")
        let outputFile = try XCTUnwrap(completed["output_file"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputFile))
    }

    func testRecorderSessionCompletesWhenAPIStartedRecordingStopsFromUI() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
        }

        context = await MainActor.run { Self.makeAPIContext(appSupportDirectory: appSupportDirectory) }
        let apiContext = try XCTUnwrap(context)
        let router = apiContext.router
        let recordingsDirectory = appSupportDirectory.appendingPathComponent("recordings")

        await MainActor.run {
            apiContext.audioRecorderService.recordingsDirectoryOverride = recordingsDirectory
            apiContext.audioRecorderService.startRecordingOverride = { _, _, _, outputURL, _ in
                try Data("placeholder".utf8).write(to: outputURL)
                return outputURL
            }
            apiContext.audioRecorderService.stopRecordingOverride = { outputURL in
                try Data("recorded".utf8).write(to: outputURL)
                return outputURL
            }
            apiContext.audioRecorderViewModel.transcriptionEnabled = false
        }

        let startResponse = await router.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/recorder/start",
                queryParams: ["mic": "true", "system_audio": "false"],
                headers: [:],
                body: Data()
            )
        )
        let start = try Self.jsonObject(startResponse)
        let startID = try XCTUnwrap(start["id"] as? String)
        XCTAssertEqual(startResponse.status, 200)

        await MainActor.run {
            apiContext.audioRecorderViewModel.stopRecording()
        }

        var completedResponse: [String: Any]?
        for _ in 0..<40 {
            let response = try Self.jsonObject(
                await router.route(
                    HTTPRequest(
                        method: "GET",
                        path: "/v1/recorder/session",
                        queryParams: ["id": startID],
                        headers: [:],
                        body: Data()
                    )
                )
            )
            if response["status"] as? String == "completed" {
                completedResponse = response
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }

        let completed = try XCTUnwrap(completedResponse)
        XCTAssertEqual(completed["id"] as? String, startID)
        let outputFile = try XCTUnwrap(completed["output_file"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputFile))
    }

    func testRecorderStartRejectsConcurrentStartWhileRecorderIsStarting() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
        }

        context = await MainActor.run { Self.makeAPIContext(appSupportDirectory: appSupportDirectory) }
        let apiContext = try XCTUnwrap(context)
        let router = apiContext.router
        let recordingsDirectory = appSupportDirectory.appendingPathComponent("recordings")
        let gate = RecorderStartGate()

        await MainActor.run {
            apiContext.audioRecorderService.recordingsDirectoryOverride = recordingsDirectory
            apiContext.audioRecorderService.startRecordingOverride = { _, _, _, outputURL, _ in
                try Data("placeholder".utf8).write(to: outputURL)
                let entry = await gate.enter()
                if entry == 1 {
                    await gate.waitForRelease()
                }
                return outputURL
            }
            apiContext.audioRecorderService.stopRecordingOverride = { outputURL in
                try Data("recorded".utf8).write(to: outputURL)
                return outputURL
            }
            apiContext.audioRecorderViewModel.transcriptionEnabled = false
        }

        let firstStartTask = Task {
            await router.route(
                HTTPRequest(
                    method: "POST",
                    path: "/v1/recorder/start",
                    queryParams: ["mic": "true", "system_audio": "false"],
                    headers: [:],
                    body: Data()
                )
            )
        }
        await gate.waitForFirstEntry()

        let secondStartResponse = await router.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/recorder/start",
                queryParams: ["mic": "true", "system_audio": "false"],
                headers: [:],
                body: Data()
            )
        )
        let secondStart = try Self.jsonObject(secondStartResponse)

        await gate.release()
        let firstStartResponse = await firstStartTask.value
        XCTAssertEqual(firstStartResponse.status, 200)

        let stopResponse = await router.route(
            HTTPRequest(method: "POST", path: "/v1/recorder/stop", queryParams: [:], headers: [:], body: Data())
        )
        XCTAssertEqual(stopResponse.status, 200)

        XCTAssertEqual(secondStartResponse.status, 409)
        XCTAssertEqual((secondStart["error"] as? [String: Any])?["message"] as? String, "Already recording")
    }

    func testRecorderSessionRejectsInvalidID() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
        }

        context = await MainActor.run { Self.makeAPIContext(appSupportDirectory: appSupportDirectory) }
        let router = try XCTUnwrap(context?.router)

        let response = await router.route(
            HTTPRequest(
                method: "GET",
                path: "/v1/recorder/session",
                queryParams: ["id": "not-a-uuid"],
                headers: [:],
                body: Data()
            )
        )
        let json = try Self.jsonObject(response)

        XCTAssertEqual(response.status, 400)
        XCTAssertEqual((json["error"] as? [String: Any])?["message"] as? String, "Missing or invalid 'id' query parameter")
    }

    func testRecorderSessionReturnsNotFoundForUnknownID() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
        }

        context = await MainActor.run { Self.makeAPIContext(appSupportDirectory: appSupportDirectory) }
        let router = try XCTUnwrap(context?.router)

        let response = await router.route(
            HTTPRequest(
                method: "GET",
                path: "/v1/recorder/session",
                queryParams: ["id": UUID().uuidString],
                headers: [:],
                body: Data()
            )
        )
        let json = try Self.jsonObject(response)

        XCTAssertEqual(response.status, 404)
        XCTAssertEqual((json["error"] as? [String: Any])?["message"] as? String, "Recorder session not found")
    }

    func testDictationStartReturnsConflictWhenRecordingCannotStart() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
        }

        context = await MainActor.run { Self.makeAPIContext(appSupportDirectory: appSupportDirectory) }
        let router = try XCTUnwrap(context?.router)

        let response = await router.route(
            HTTPRequest(method: "POST", path: "/v1/dictation/start", queryParams: [:], headers: [:], body: Data())
        )
        let json = try Self.jsonObject(response)

        XCTAssertEqual(response.status, 409)
        XCTAssertEqual((json["error"] as? [String: Any])?["message"] as? String, TranscriptionEngineError.modelNotLoaded.localizedDescription)
    }

    func testDictationEndpointsReturnSessionIDAndCompletedTranscription() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        let historyEnabledKey = UserDefaultsKeys.historyEnabled
        let originalHistoryEnabled = UserDefaults.standard.object(forKey: historyEnabledKey)
        var context: APIContext?
        defer {
            context = nil
            if let originalHistoryEnabled {
                UserDefaults.standard.set(originalHistoryEnabled, forKey: historyEnabledKey)
            } else {
                UserDefaults.standard.removeObject(forKey: historyEnabledKey)
            }
            TestSupport.remove(appSupportDirectory)
        }

        UserDefaults.standard.set(true, forKey: historyEnabledKey)

        context = await MainActor.run {
            Self.makeAPIContext(appSupportDirectory: appSupportDirectory, withMockTranscriptionPlugin: true)
        }
        let apiContext = try XCTUnwrap(context)
        let router = apiContext.router

        await MainActor.run {
            apiContext.audioRecordingService.hasMicrophonePermissionOverride = true
            apiContext.audioRecordingService.inputAvailabilityOverride = { _ in true }
            apiContext.audioRecordingService.startRecordingOverride = {}
            apiContext.audioRecordingService.stopRecordingOverride = { _ in
                Array(repeating: 0.25, count: Int(AudioRecordingService.targetSampleRate))
            }
            apiContext.textInsertionService.accessibilityGrantedOverride = true
            apiContext.textInsertionService.captureActiveAppOverride = {
                ("Notes", "com.apple.Notes", nil)
            }
            apiContext.textInsertionService.selectedTextOverride = { nil }
            apiContext.textInsertionService.pasteSimulatorOverride = {}
        }

        let start = try Self.jsonObject(
            await router.route(HTTPRequest(method: "POST", path: "/v1/dictation/start", queryParams: [:], headers: [:], body: Data()))
        )
        let startID = try XCTUnwrap(start["id"] as? String)
        XCTAssertEqual(start["status"] as? String, "recording")
        XCTAssertNotNil(UUID(uuidString: startID))

        await MainActor.run {
            apiContext.dictationViewModel.partialText = "transcribed"
        }

        let stop = try Self.jsonObject(
            await router.route(HTTPRequest(method: "POST", path: "/v1/dictation/stop", queryParams: [:], headers: [:], body: Data()))
        )
        XCTAssertEqual(stop["id"] as? String, startID)
        XCTAssertEqual(stop["status"] as? String, "stopped")

        var completedResponse: [String: Any]?
        for _ in 0..<40 {
            let response = try Self.jsonObject(
                await router.route(
                    HTTPRequest(
                        method: "GET",
                        path: "/v1/dictation/transcription",
                        queryParams: ["id": startID],
                        headers: [:],
                        body: Data()
                    )
                )
            )
            if response["status"] as? String == "completed" {
                completedResponse = response
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }

        let completedPayload = try XCTUnwrap(completedResponse)
        XCTAssertEqual(completedPayload["id"] as? String, startID)
        XCTAssertEqual(completedPayload["status"] as? String, "completed")

        let transcription = try XCTUnwrap(completedPayload["transcription"] as? [String: Any])
        XCTAssertEqual(transcription["text"] as? String, "transcribed")
        XCTAssertEqual(transcription["raw_text"] as? String, "transcribed")
        XCTAssertEqual(transcription["app_name"] as? String, "Notes")
        XCTAssertEqual(transcription["app_bundle_id"] as? String, "com.apple.Notes")
        XCTAssertEqual(transcription["words_count"] as? Int, 1)

        let recordID = await MainActor.run { apiContext.historyService.records.first?.id.uuidString }
        XCTAssertEqual(recordID, startID)
    }

    func testDictationEndpointsSpeakCompletedTranscriptionOnly() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var context: APIContext?
        defer {
            context = nil
            TestSupport.remove(appSupportDirectory)
        }

        context = await MainActor.run {
            Self.makeAPIContext(appSupportDirectory: appSupportDirectory, withMockTranscriptionPlugin: true)
        }
        let apiContext = try XCTUnwrap(context)
        let router = apiContext.router
        let ttsExpectation = expectation(description: "tts speak called")

        await MainActor.run {
            apiContext.ttsProvider.onSpeak = { request in
                if request.purpose == .transcription {
                    ttsExpectation.fulfill()
                }
            }
            apiContext.dictationViewModel.spokenFeedbackEnabled = true
            apiContext.audioRecordingService.hasMicrophonePermissionOverride = true
            apiContext.audioRecordingService.inputAvailabilityOverride = { _ in true }
            apiContext.audioRecordingService.startRecordingOverride = {}
            apiContext.audioRecordingService.stopRecordingOverride = { _ in
                Array(repeating: 0.25, count: Int(AudioRecordingService.targetSampleRate))
            }
            apiContext.textInsertionService.accessibilityGrantedOverride = true
            apiContext.textInsertionService.captureActiveAppOverride = {
                ("Notes", "com.apple.Notes", nil)
            }
            apiContext.textInsertionService.selectedTextOverride = { nil }
            apiContext.textInsertionService.pasteSimulatorOverride = {}
        }

        let start = try Self.jsonObject(
            await router.route(HTTPRequest(method: "POST", path: "/v1/dictation/start", queryParams: [:], headers: [:], body: Data()))
        )
        let startID = try XCTUnwrap(start["id"] as? String)
        let initialRequestsAreEmpty = await MainActor.run { apiContext.ttsProvider.recordedRequests.isEmpty }
        XCTAssertTrue(initialRequestsAreEmpty)

        await MainActor.run {
            apiContext.dictationViewModel.partialText = "transcribed"
        }

        _ = try Self.jsonObject(
            await router.route(HTTPRequest(method: "POST", path: "/v1/dictation/stop", queryParams: [:], headers: [:], body: Data()))
        )

        var completedResponse: [String: Any]?
        for _ in 0..<40 {
            let response = try Self.jsonObject(
                await router.route(
                    HTTPRequest(
                        method: "GET",
                        path: "/v1/dictation/transcription",
                        queryParams: ["id": startID],
                        headers: [:],
                        body: Data()
                    )
                )
            )
            if response["status"] as? String == "completed" {
                completedResponse = response
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }

        _ = try XCTUnwrap(completedResponse)
        await fulfillment(of: [ttsExpectation], timeout: 1.0)

        let requests = await MainActor.run { apiContext.ttsProvider.recordedRequests }
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.purpose, .transcription)
        XCTAssertEqual(requests.first?.text, "transcribed")
    }

    @MainActor
    func testClipboardSnapshotRoundTripsMultiplePasteboardItems() {
        let firstItem = NSPasteboardItem()
        firstItem.setString("first", forType: .string)
        firstItem.setData(Data([0x01, 0x02]), forType: .png)

        let secondItem = NSPasteboardItem()
        secondItem.setString("second", forType: .string)
        secondItem.setData(Data([0x03, 0x04]), forType: .tiff)

        let snapshot = TextInsertionService.clipboardSnapshot(from: [firstItem, secondItem])
        let restoredItems = TextInsertionService.pasteboardItems(from: snapshot)

        XCTAssertEqual(restoredItems.count, 2)
        XCTAssertEqual(restoredItems[0].string(forType: .string), "first")
        XCTAssertEqual(restoredItems[0].data(forType: .png), Data([0x01, 0x02]))
        XCTAssertEqual(restoredItems[1].string(forType: .string), "second")
        XCTAssertEqual(restoredItems[1].data(forType: .tiff), Data([0x03, 0x04]))
    }

    @MainActor
    func testFocusedTextChangeDetectionRequiresAnActualChange() {
        XCTAssertFalse(
            TextInsertionService.focusedTextDidChange(
                from: (value: "Hello", selectedText: nil, selectedRange: NSRange(location: 5, length: 0)),
                to: (value: "Hello", selectedText: nil, selectedRange: NSRange(location: 5, length: 0))
            )
        )

        XCTAssertTrue(
            TextInsertionService.focusedTextDidChange(
                from: (value: "Hello", selectedText: nil, selectedRange: NSRange(location: 5, length: 0)),
                to: (value: "Hello world", selectedText: nil, selectedRange: NSRange(location: 11, length: 0))
            )
        )
    }

    @MainActor
    func testCaptureInsertionContextIncludesCharactersAroundSelectionRange() throws {
        let service = TextInsertionService()
        let element = AXUIElementCreateSystemWide()
        service.accessibilityGrantedOverride = true
        service.focusedTextElementOverride = { element }
        service.focusedTextStateOverride = { _ in
            (value: "coffeemachine", selectedText: nil, selectedRange: NSRange(location: 6, length: 0))
        }

        let context = try XCTUnwrap(service.captureInsertionContext())

        XCTAssertEqual(context.value, "coffeemachine")
        XCTAssertEqual(context.selectedRange, NSRange(location: 6, length: 0))
        XCTAssertNil(context.selectedText)
        XCTAssertEqual(context.previousCharacter, "e")
        XCTAssertEqual(context.nextCharacter, "m")
    }

    @MainActor
    func testCaptureInsertionContextReturnsNilWhenFocusedTextStateIsIncomplete() {
        let service = TextInsertionService()
        let element = AXUIElementCreateSystemWide()
        service.accessibilityGrantedOverride = true
        service.focusedTextElementOverride = { element }
        service.focusedTextStateOverride = { _ in
            (value: "coffee", selectedText: nil, selectedRange: nil)
        }

        XCTAssertNil(service.captureInsertionContext())
    }

    @MainActor
    func testGetTextSelectionDerivesSelectedTextFromFocusedValueAndRange() {
        let service = TextInsertionService()
        let element = AXUIElementCreateSystemWide()
        service.accessibilityGrantedOverride = true
        service.focusedTextElementOverride = { element }
        service.focusedTextStateOverride = { _ in
            (value: "Before selected after", selectedText: nil, selectedRange: NSRange(location: 7, length: 8))
        }

        let selection = service.getTextSelection()

        XCTAssertEqual(selection?.text, "selected")
    }

    @MainActor
    func testSyntheticPasteReturnsUnverifiedWhenFocusedTextStateIsUnavailable() async throws {
        let service = TextInsertionService()
        let pasteboard = NSPasteboard.withUniqueName()
        service.accessibilityGrantedOverride = true
        service.pasteboardProvider = { pasteboard }
        service.focusedTextElementOverride = { nil }

        var pasteCount = 0
        service.pasteSimulatorOverride = {
            pasteCount += 1
        }

        let result = try await service.insertText("Hello")

        XCTAssertEqual(result, .pasted(verification: .unverified(.focusedTextStateUnavailable)))
        XCTAssertEqual(pasteCount, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "Hello")
    }

    @MainActor
    func testPreserveClipboardKeepsGeneratedTextUntilFallbackRestoreWhenPasteIsUnverified() async throws {
        let service = TextInsertionService()
        let pasteboard = NSPasteboard.withUniqueName()
        service.accessibilityGrantedOverride = true
        service.pasteboardProvider = { pasteboard }
        service.focusedTextElementOverride = { nil }
        service.defaultPasteFallbackRestoreDelay = .milliseconds(80)

        let pasteStarted = expectation(description: "synthetic paste started")
        service.pasteSimulatorOverride = {
            pasteStarted.fulfill()
        }

        pasteboard.clearContents()
        pasteboard.setString("Existing", forType: .string)

        let insertionTask = Task {
            try await service.insertText("Hello", preserveClipboard: true)
        }

        await fulfillment(of: [pasteStarted], timeout: 1.0)
        XCTAssertEqual(pasteboard.string(forType: .string), "Hello")

        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(pasteboard.string(forType: .string), "Hello")

        let result = try await insertionTask.value
        XCTAssertEqual(result, .pasted(verification: .unverified(.focusedTextStateUnavailable)))
        XCTAssertEqual(pasteboard.string(forType: .string), "Existing")
    }

    @MainActor
    func testDeferredCopySelectionRestoresOriginalClipboardAfterVerifiedPaste() async throws {
        let service = TextInsertionService()
        let pasteboard = NSPasteboard.withUniqueName()
        let element = AXUIElementCreateSystemWide()
        service.accessibilityGrantedOverride = true
        service.pasteboardProvider = { pasteboard }
        service.focusedTextElementOverride = { element }
        service.captureActiveAppOverride = { ("Pages", "com.apple.iWork.Pages", nil) }
        service.verifiedRestoreGraceDelay = .milliseconds(1)

        pasteboard.clearContents()
        pasteboard.setString("Existing", forType: .string)
        service.copySimulatorOverride = {
            pasteboard.clearContents()
            pasteboard.setString("Selected source", forType: .string)
        }

        let copiedSelectionResult = await service.getTextSelectionViaCopyPreservingClipboardForInsertion()
        let copiedSelection = try XCTUnwrap(copiedSelectionResult)
        XCTAssertEqual(copiedSelection.text, "Selected source")
        XCTAssertEqual(pasteboard.string(forType: .string), "Selected source")

        var pasteCount = 0
        service.pasteSimulatorOverride = {
            pasteCount += 1
        }
        service.focusedTextStateOverride = { _ in
            if pasteCount == 0 {
                return (value: "Selected source", selectedText: "Selected source", selectedRange: NSRange(location: 0, length: 15))
            }
            return (value: "Processed result", selectedText: nil, selectedRange: NSRange(location: 16, length: 0))
        }

        let result = try await service.insertText(
            "**Processed result**",
            preserveClipboard: true,
            outputFormat: "rtf",
            deferredClipboardRestore: copiedSelection.deferredClipboardRestore
        )

        XCTAssertEqual(result, .pasted(verification: .verified))
        XCTAssertEqual(pasteboard.string(forType: .string), "Existing")
    }

    @MainActor
    func testCopySelectionRetriesWhenFirstCopyAttemptDoesNotUpdatePasteboard() async throws {
        let service = TextInsertionService()
        let pasteboard = NSPasteboard.withUniqueName()
        service.pasteboardProvider = { pasteboard }
        service.copySelectionRetryDelay = .milliseconds(1)
        service.copySelectionReadSettleDelay = .milliseconds(1)

        pasteboard.clearContents()
        pasteboard.setString("Existing", forType: .string)

        var copyAttempts = 0
        service.copySimulatorOverride = {
            copyAttempts += 1
            guard copyAttempts == 2 else { return }
            pasteboard.clearContents()
            pasteboard.setString("Selected source", forType: .string)
        }

        let copiedSelection = await service.getTextSelectionViaCopy()

        XCTAssertEqual(copiedSelection, "Selected source")
        XCTAssertEqual(copyAttempts, 2)
        XCTAssertEqual(pasteboard.string(forType: .string), "Existing")
    }

    @MainActor
    func testTerminalBundleForcesSyntheticPasteInsteadOfDirectAccessibilityInsertion() async throws {
        let service = TextInsertionService()
        let pasteboard = NSPasteboard.withUniqueName()
        let element = AXUIElementCreateSystemWide()
        service.accessibilityGrantedOverride = true
        service.pasteboardProvider = { pasteboard }
        service.focusedTextElementOverride = { element }
        service.captureActiveAppOverride = { ("iTerm2", "com.googlecode.iterm2", nil) }
        service.terminalPasteFallbackRestoreDelay = .milliseconds(1)

        var pasteCount = 0
        service.pasteSimulatorOverride = {
            pasteCount += 1
        }
        service.focusedTextStateOverride = { _ in
            if pasteCount == 0 {
                return (value: "", selectedText: nil, selectedRange: NSRange(location: 0, length: 0))
            }
            return (value: "Hello", selectedText: nil, selectedRange: NSRange(location: 5, length: 0))
        }

        var didAttemptDirectAXInsertion = false
        service.insertTextAtOverride = { _, _ in
            didAttemptDirectAXInsertion = true
            return true
        }

        pasteboard.clearContents()
        pasteboard.setString("Existing", forType: .string)

        let result = try await service.insertText("Hello", preserveClipboard: true)

        XCTAssertFalse(didAttemptDirectAXInsertion)
        XCTAssertEqual(pasteCount, 1)
        XCTAssertEqual(result, .pasted(verification: .verified))
        XCTAssertEqual(pasteboard.string(forType: .string), "Existing")
    }

    @MainActor
    func testVerifiedTerminalPasteKeepsGeneratedTextUntilTerminalRestoreDelay() async throws {
        let service = TextInsertionService()
        let pasteboard = NSPasteboard.withUniqueName()
        let element = AXUIElementCreateSystemWide()
        service.accessibilityGrantedOverride = true
        service.pasteboardProvider = { pasteboard }
        service.focusedTextElementOverride = { element }
        service.captureActiveAppOverride = { ("Terminal", "com.apple.Terminal", nil) }
        service.terminalPasteFallbackRestoreDelay = .milliseconds(80)
        service.verifiedRestoreGraceDelay = .milliseconds(1)

        let pasteStarted = expectation(description: "terminal synthetic paste started")
        var pasteCount = 0
        service.pasteSimulatorOverride = {
            pasteCount += 1
            pasteStarted.fulfill()
        }
        service.focusedTextStateOverride = { _ in
            if pasteCount == 0 {
                return (value: "", selectedText: nil, selectedRange: NSRange(location: 0, length: 0))
            }
            return (value: "Hello", selectedText: nil, selectedRange: NSRange(location: 5, length: 0))
        }

        pasteboard.clearContents()
        pasteboard.setString("Existing", forType: .string)

        let insertionTask = Task {
            try await service.insertText("Hello", preserveClipboard: true)
        }

        await fulfillment(of: [pasteStarted], timeout: 1.0)
        XCTAssertEqual(pasteboard.string(forType: .string), "Hello")

        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(pasteboard.string(forType: .string), "Hello")

        let result = try await insertionTask.value
        XCTAssertEqual(result, .pasted(verification: .verified))
        XCTAssertEqual(pasteboard.string(forType: .string), "Existing")
    }

    @MainActor
    func testVerifiedNonTerminalSyntheticPasteUsesGraceDelayBeforeClipboardRestore() async throws {
        let service = TextInsertionService()
        let pasteboard = NSPasteboard.withUniqueName()
        let element = AXUIElementCreateSystemWide()
        service.accessibilityGrantedOverride = true
        service.pasteboardProvider = { pasteboard }
        service.focusedTextElementOverride = { element }
        service.captureActiveAppOverride = { ("Notes", "com.apple.Notes", nil) }
        service.defaultPasteFallbackRestoreDelay = .milliseconds(1)
        service.verifiedRestoreGraceDelay = .milliseconds(80)

        let pasteStarted = expectation(description: "non-terminal synthetic paste started")
        var pasteCount = 0
        service.pasteSimulatorOverride = {
            pasteCount += 1
            pasteStarted.fulfill()
        }
        service.focusedTextStateOverride = { _ in
            if pasteCount == 0 {
                return (value: "", selectedText: nil, selectedRange: NSRange(location: 0, length: 0))
            }
            return (value: "Hello", selectedText: nil, selectedRange: NSRange(location: 5, length: 0))
        }

        pasteboard.clearContents()
        pasteboard.setString("Existing", forType: .string)

        let insertionTask = Task {
            try await service.insertText("**Hello**", preserveClipboard: true, outputFormat: "rtf")
        }

        await fulfillment(of: [pasteStarted], timeout: 1.0)
        XCTAssertEqual(pasteboard.string(forType: .string), "Hello")

        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(pasteboard.string(forType: .string), "Hello")

        let result = try await insertionTask.value
        XCTAssertEqual(result, .pasted(verification: .verified))
        XCTAssertEqual(pasteboard.string(forType: .string), "Existing")
    }

    @MainActor
    func testSilentAXNoopFallsBackToSyntheticPasteInsteadOfReportingDirectSuccess() async throws {
        let service = TextInsertionService()
        let pasteboard = NSPasteboard.withUniqueName()
        let element = AXUIElementCreateSystemWide()
        service.accessibilityGrantedOverride = true
        service.pasteboardProvider = { pasteboard }
        service.focusedTextElementOverride = { element }
        service.captureActiveAppOverride = { ("Notes", "com.apple.Notes", nil) }
        service.pasteVerificationAttempts = 0
        service.defaultPasteFallbackRestoreDelay = .milliseconds(1)
        service.focusedTextStateOverride = { _ in
            (value: "", selectedText: nil, selectedRange: NSRange(location: 0, length: 0))
        }

        var didAttemptDirectAXInsertion = false
        service.insertTextAtOverride = { _, _ in
            didAttemptDirectAXInsertion = true
            return true
        }

        var pasteCount = 0
        service.pasteSimulatorOverride = {
            pasteCount += 1
        }

        pasteboard.clearContents()
        pasteboard.setString("Existing", forType: .string)

        let result = try await service.insertText("Hello", preserveClipboard: true)

        XCTAssertTrue(didAttemptDirectAXInsertion)
        XCTAssertEqual(pasteCount, 1)
        XCTAssertEqual(result, .pasted(verification: .unverified(.focusedTextUnchanged)))
        XCTAssertEqual(pasteboard.string(forType: .string), "Existing")
    }

    @MainActor
    func testPreserveClipboardFallsBackToSyntheticPasteWhenDirectAXOnlyMovesSelection() async throws {
        let service = TextInsertionService()
        let pasteboard = NSPasteboard.withUniqueName()
        let element = AXUIElementCreateSystemWide()
        service.accessibilityGrantedOverride = true
        service.pasteboardProvider = { pasteboard }
        service.focusedTextElementOverride = { element }
        service.captureActiveAppOverride = { ("Notes", "com.apple.Notes", nil) }
        service.verifiedRestoreGraceDelay = .milliseconds(1)

        var didAttemptDirectAXInsertion = false
        var pasteCount = 0
        service.focusedTextStateOverride = { _ in
            if pasteCount > 0 {
                return (value: "Hello", selectedText: nil, selectedRange: NSRange(location: 5, length: 0))
            }
            if didAttemptDirectAXInsertion {
                return (value: "", selectedText: nil, selectedRange: NSRange(location: 1, length: 0))
            }
            return (value: "", selectedText: nil, selectedRange: NSRange(location: 0, length: 0))
        }

        var insertedText: String?
        service.insertTextAtOverride = { _, text in
            insertedText = text
            didAttemptDirectAXInsertion = true
            return true
        }
        service.pasteSimulatorOverride = {
            pasteCount += 1
        }

        pasteboard.clearContents()
        pasteboard.setString("Existing", forType: .string)

        let result = try await service.insertText("Hello", preserveClipboard: true)

        XCTAssertEqual(insertedText, "Hello")
        XCTAssertEqual(pasteCount, 1)
        XCTAssertEqual(result, .pasted(verification: .verified))
        XCTAssertEqual(pasteboard.string(forType: .string), "Existing")
    }

    @MainActor
    func testAutoEnterSkipsReturnWithoutFocusedTextField() async throws {
        let service = TextInsertionService()
        let pasteboard = NSPasteboard.withUniqueName()
        service.accessibilityGrantedOverride = true
        service.pasteboardProvider = { pasteboard }
        service.focusedTextFieldOverride = { false }

        var didSimulatePaste = false
        service.pasteSimulatorOverride = {
            didSimulatePaste = true
        }

        var didSimulateReturn = false
        service.returnSimulatorOverride = {
            didSimulateReturn = true
        }

        _ = try await service.insertText("Hello", autoEnter: true)

        XCTAssertTrue(didSimulatePaste)
        XCTAssertFalse(didSimulateReturn)
        XCTAssertEqual(pasteboard.string(forType: .string), "Hello")
    }

    @MainActor
    func testAutoEnterTriggersReturnWithFocusedTextField() async throws {
        let service = TextInsertionService()
        let pasteboard = NSPasteboard.withUniqueName()
        service.accessibilityGrantedOverride = true
        service.pasteboardProvider = { pasteboard }
        service.focusedTextFieldOverride = { true }
        service.pasteSimulatorOverride = {}

        var didSimulateReturn = false
        service.returnSimulatorOverride = {
            didSimulateReturn = true
        }

        _ = try await service.insertText("Hello", autoEnter: true)

        XCTAssertTrue(didSimulateReturn)
        XCTAssertEqual(pasteboard.string(forType: .string), "Hello")
    }

    @MainActor
    func testPreserveClipboardAvoidsPasteboardWhenVerifiedAccessibilityInsertionSucceeds() async throws {
        let service = TextInsertionService()
        let pasteboard = NSPasteboard.withUniqueName()
        let element = AXUIElementCreateSystemWide()
        service.accessibilityGrantedOverride = true
        service.pasteboardProvider = { pasteboard }
        service.focusedTextElementOverride = { element }
        service.captureActiveAppOverride = { ("Notes", "com.apple.Notes", nil) }

        var stateReadCount = 0
        service.focusedTextStateOverride = { _ in
            defer { stateReadCount += 1 }
            if stateReadCount == 0 {
                return (value: "", selectedText: nil, selectedRange: NSRange(location: 0, length: 0))
            }
            return (value: "Hello", selectedText: nil, selectedRange: NSRange(location: 5, length: 0))
        }

        var insertedText: String?
        service.insertTextAtOverride = { _, text in
            insertedText = text
            return true
        }

        var didSimulatePaste = false
        service.pasteSimulatorOverride = {
            didSimulatePaste = true
        }

        pasteboard.clearContents()
        pasteboard.setString("Existing", forType: .string)

        _ = try await service.insertText("Hello", preserveClipboard: true)

        XCTAssertEqual(insertedText, "Hello")
        XCTAssertFalse(didSimulatePaste)
        XCTAssertEqual(pasteboard.string(forType: .string), "Existing")
    }

    @MainActor
    func testPreserveClipboardAvoidsPasteboardWhenAccessibilityInsertionChangesNilValue() async throws {
        let service = TextInsertionService()
        let pasteboard = NSPasteboard.withUniqueName()
        let element = AXUIElementCreateSystemWide()
        service.accessibilityGrantedOverride = true
        service.pasteboardProvider = { pasteboard }
        service.focusedTextElementOverride = { element }
        service.captureActiveAppOverride = { ("Notes", "com.apple.Notes", nil) }

        var stateReadCount = 0
        service.focusedTextStateOverride = { _ in
            defer { stateReadCount += 1 }
            if stateReadCount == 0 {
                return (value: nil, selectedText: nil, selectedRange: NSRange(location: 0, length: 0))
            }
            return (value: "Hello", selectedText: nil, selectedRange: NSRange(location: 5, length: 0))
        }

        var insertedText: String?
        service.insertTextAtOverride = { _, text in
            insertedText = text
            return true
        }

        var didSimulatePaste = false
        service.pasteSimulatorOverride = {
            didSimulatePaste = true
        }

        pasteboard.clearContents()
        pasteboard.setString("Existing", forType: .string)

        _ = try await service.insertText("Hello", preserveClipboard: true)

        XCTAssertEqual(insertedText, "Hello")
        XCTAssertFalse(didSimulatePaste)
        XCTAssertEqual(pasteboard.string(forType: .string), "Existing")
    }

    @MainActor
    func testPreserveClipboardFallsBackToPasteboardWhenVerifiedAccessibilityInsertionFails() async throws {
        let service = TextInsertionService()
        let pasteboard = NSPasteboard.withUniqueName()
        let element = AXUIElementCreateSystemWide()
        service.accessibilityGrantedOverride = true
        service.pasteboardProvider = { pasteboard }
        service.focusedTextElementOverride = { element }
        service.defaultPasteFallbackRestoreDelay = .milliseconds(1)
        service.pasteVerificationAttempts = 0
        service.focusedTextStateOverride = { _ in
            (value: "", selectedText: nil, selectedRange: NSRange(location: 0, length: 0))
        }
        service.insertTextAtOverride = { _, _ in true }

        var didSimulatePaste = false
        service.pasteSimulatorOverride = {
            didSimulatePaste = true
        }

        pasteboard.clearContents()
        pasteboard.setString("Existing", forType: .string)

        _ = try await service.insertText("Hello", preserveClipboard: true)

        XCTAssertTrue(didSimulatePaste)
        XCTAssertEqual(pasteboard.string(forType: .string), "Existing")
    }

    @MainActor
    func testRTFOutputWritesPlainTextFallbackAndRichTextData() async throws {
        let service = TextInsertionService()
        let pasteboard = NSPasteboard.withUniqueName()
        service.accessibilityGrantedOverride = true
        service.pasteboardProvider = { pasteboard }
        service.pasteSimulatorOverride = {}

        _ = try await service.insertText(
            "Meeting\n- **Launch** plan\n- _Budget_ review",
            outputFormat: "rtf"
        )

        XCTAssertEqual(pasteboard.string(forType: .string), "Meeting\n- Launch plan\n- Budget review")

        let rtfData = try XCTUnwrap(pasteboard.data(forType: .rtf))
        let attributed = try NSAttributedString(
            data: rtfData,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        )

        XCTAssertEqual(attributed.string, "Meeting\n\u{2022} Launch plan\n\u{2022} Budget review")
        XCTAssertTrue(rtfAttributedStringContainsFontTrait(NSFontTraitMask.boldFontMask, in: attributed, matching: "Launch"))
        XCTAssertTrue(rtfAttributedStringContainsFontTrait(NSFontTraitMask.italicFontMask, in: attributed, matching: "Budget"))
    }

    @MainActor
    func testRTFOutputStripsLLMMarkdownFenceAndInputBoundaryMarkers() async throws {
        let service = TextInsertionService()
        let pasteboard = NSPasteboard.withUniqueName()
        service.accessibilityGrantedOverride = true
        service.pasteboardProvider = { pasteboard }
        service.pasteSimulatorOverride = {}

        let llmResponse = """
        Here is the Markdown-compatible text for rich-text conversion:

        ```markdown
        BEGIN TYPEWHISPER DICTATED TEXT
        - **Launch** plan
        - _Budget_ review
        END TYPEWHISPER DICTATED TEXT
        ```
        """

        _ = try await service.insertText(llmResponse, outputFormat: "rtf")

        XCTAssertEqual(pasteboard.string(forType: .string), "- Launch plan\n- Budget review")

        let rtfData = try XCTUnwrap(pasteboard.data(forType: .rtf))
        let attributed = try NSAttributedString(
            data: rtfData,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        )

        XCTAssertEqual(attributed.string, "\u{2022} Launch plan\n\u{2022} Budget review")
        XCTAssertFalse(attributed.string.contains("TYPEWHISPER"))
        XCTAssertFalse(attributed.string.contains("```"))
        XCTAssertTrue(rtfAttributedStringContainsFontTrait(NSFontTraitMask.boldFontMask, in: attributed, matching: "Launch"))
        XCTAssertTrue(rtfAttributedStringContainsFontTrait(NSFontTraitMask.italicFontMask, in: attributed, matching: "Budget"))
    }

    @MainActor
    func testRTFOutputUsesMarkdownParserForInlineSyntax() async throws {
        let service = TextInsertionService()
        let pasteboard = NSPasteboard.withUniqueName()
        service.accessibilityGrantedOverride = true
        service.pasteboardProvider = { pasteboard }
        service.pasteSimulatorOverride = {}

        _ = try await service.insertText(
            "See [release notes](https://typewhisper.app) and `build 1.4`.",
            outputFormat: "rtf"
        )

        XCTAssertEqual(pasteboard.string(forType: .string), "See release notes and build 1.4.")

        let rtfData = try XCTUnwrap(pasteboard.data(forType: .rtf))
        let attributed = try NSAttributedString(
            data: rtfData,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        )

        XCTAssertEqual(attributed.string, "See release notes and build 1.4.")
    }

    @MainActor
    func testRTFPreserveClipboardUsesPasteboardInsteadOfPlainAccessibilityInsertion() async throws {
        let service = TextInsertionService()
        let pasteboard = NSPasteboard.withUniqueName()
        let element = AXUIElementCreateSystemWide()
        service.accessibilityGrantedOverride = true
        service.pasteboardProvider = { pasteboard }
        service.focusedTextElementOverride = { element }
        service.defaultPasteFallbackRestoreDelay = .milliseconds(1)
        service.pasteVerificationAttempts = 0
        service.focusedTextStateOverride = { _ in
            (value: "", selectedText: nil, selectedRange: NSRange(location: 0, length: 0))
        }

        var insertedText: String?
        service.insertTextAtOverride = { _, text in
            insertedText = text
            return true
        }

        var didSimulatePaste = false
        var pasteboardTypesAtPaste: [NSPasteboard.PasteboardType] = []
        service.pasteSimulatorOverride = {
            didSimulatePaste = true
            pasteboardTypesAtPaste = pasteboard.pasteboardItems?.first?.types ?? []
        }

        pasteboard.clearContents()
        pasteboard.setString("Existing", forType: .string)

        _ = try await service.insertText("**Hello**", preserveClipboard: true, outputFormat: "rtf")

        XCTAssertNil(insertedText)
        XCTAssertTrue(didSimulatePaste)
        XCTAssertTrue(pasteboardTypesAtPaste.contains(.init("org.nspasteboard.TransientType")))
        XCTAssertTrue(pasteboardTypesAtPaste.contains(.init("org.nspasteboard.AutoGeneratedType")))
        XCTAssertTrue(pasteboardTypesAtPaste.contains(.init("com.typewhisper.SpeechTranscription")))
        XCTAssertEqual(pasteboard.string(forType: .string), "Existing")
    }

    @MainActor
    func testApiStartRecording_startsAudioBeforeContextAndDeferredSelectedTextCapture() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
        }

        dictationContext = Self.makeDictationContext(appSupportDirectory: appSupportDirectory)
        let context = try XCTUnwrap(dictationContext)

        var events: [String] = []
        let selectedTextCaptured = expectation(description: "selected text captured")

        context.textInsertionService.captureActiveAppOverride = { () -> (name: String?, bundleId: String?, url: String?) in
            events.append("capture_app")
            return ("Notes", nil, nil)
        }
        context.audioRecordingService.hasMicrophonePermissionOverride = true
        context.audioRecordingService.inputAvailabilityOverride = { _ in true }
        context.audioRecordingService.startRecordingOverride = {
            events.append("start_audio")
        }
        context.textInsertionService.selectedTextOverride = { () -> String? in
            events.append("selected_text")
            selectedTextCaptured.fulfill()
            return "Already selected"
        }

        _ = context.dictationViewModel.apiStartRecording()

        XCTAssertEqual(context.dictationViewModel.state, DictationViewModel.State.recording)
        XCTAssertEqual(events, ["start_audio", "capture_app"])

        await fulfillment(of: [selectedTextCaptured], timeout: 1.0)
        XCTAssertEqual(Array(events.prefix(3)), ["start_audio", "capture_app", "selected_text"])
    }

    @MainActor
    func testApiStopRecordingMovesToProcessingAndRejectsRestartWhileRecorderDrains() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
        }

        dictationContext = Self.makeDictationContext(appSupportDirectory: appSupportDirectory)
        let context = try XCTUnwrap(dictationContext)
        let stopGate = RecorderStartGate()

        var startCount = 0
        context.audioRecordingService.hasMicrophonePermissionOverride = true
        context.audioRecordingService.inputAvailabilityOverride = { _ in true }
        context.audioRecordingService.startRecordingOverride = {
            startCount += 1
        }
        context.audioRecordingService.stopRecordingOverride = { _ in
            _ = await stopGate.enter()
            await stopGate.waitForRelease()
            return []
        }

        let sessionID = context.dictationViewModel.apiStartRecording()
        XCTAssertEqual(context.dictationViewModel.state, .recording)
        XCTAssertEqual(startCount, 1)

        _ = context.dictationViewModel.apiStopRecording()
        XCTAssertEqual(context.dictationViewModel.state, .processing)
        XCTAssertEqual(context.dictationViewModel.apiDictationSession(id: sessionID)?.status, .processing)

        await stopGate.waitForFirstEntry()

        let ignoredSessionID = context.dictationViewModel.apiStartRecording()
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(context.dictationViewModel.state, .processing)
        XCTAssertNil(context.dictationViewModel.apiDictationSession(id: ignoredSessionID))

        await stopGate.release()

        for _ in 0..<40 {
            if context.dictationViewModel.apiDictationSession(id: sessionID)?.status == .failed {
                break
            }
            try? await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertEqual(context.dictationViewModel.apiDictationSession(id: sessionID)?.status, .failed)
    }

    @MainActor
    func testCancelDuringProcessingCancelsStopFinalizationBeforeTranscriptionTaskExists() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var dictationContext: DictationContext?
        defer {
            MockTranscriptionPlugin.reset()
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
        }

        MockTranscriptionPlugin.reset()
        dictationContext = Self.makeDictationContext(appSupportDirectory: appSupportDirectory)
        let context = try XCTUnwrap(dictationContext)
        let stopGate = RecorderStartGate()
        var pasteCount = 0

        context.textInsertionService.captureActiveAppOverride = {
            ("Notes", "com.apple.Notes", nil)
        }
        context.textInsertionService.accessibilityGrantedOverride = true
        context.textInsertionService.selectedTextOverride = { nil }
        context.textInsertionService.pasteSimulatorOverride = {
            pasteCount += 1
        }
        context.audioRecordingService.hasMicrophonePermissionOverride = true
        context.audioRecordingService.inputAvailabilityOverride = { _ in true }
        context.audioRecordingService.startRecordingOverride = {}
        context.audioRecordingService.stopRecordingOverride = { _ in
            _ = await stopGate.enter()
            await stopGate.waitForRelease()
            return Array(repeating: 0.25, count: Int(AudioRecordingService.targetSampleRate))
        }

        let sessionID = context.dictationViewModel.apiStartRecording()
        XCTAssertEqual(context.dictationViewModel.state, .recording)

        _ = context.dictationViewModel.apiStopRecording()
        XCTAssertEqual(context.dictationViewModel.state, .processing)

        await stopGate.waitForFirstEntry()
        context.dictationViewModel.handleCancelHotkey()
        context.dictationViewModel.handleCancelHotkey()

        XCTAssertEqual(context.dictationViewModel.apiDictationSession(id: sessionID)?.status, .failed)
        XCTAssertEqual(
            context.dictationViewModel.apiDictationSession(id: sessionID)?.error,
            try TestSupport.localizedCatalogValueForCurrentLocale(for: "Cancelled")
        )

        await stopGate.release()

        for _ in 0..<20 {
            if MockTranscriptionPlugin.transcribeCallCount > 0 || pasteCount > 0 {
                break
            }
            try? await Task.sleep(for: .milliseconds(25))
        }

        let session = try XCTUnwrap(context.dictationViewModel.apiDictationSession(id: sessionID))
        XCTAssertEqual(session.status, .failed)
        XCTAssertNil(session.transcription)
        XCTAssertEqual(MockTranscriptionPlugin.transcribeCallCount, 0)
        XCTAssertEqual(pasteCount, 0)
    }

    @MainActor
    func testApiStopRecordingUsesStableLivePreviewInsteadOfSlowBatchFallback() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
        }

        MockTranscriptionPlugin.reset()
        dictationContext = Self.makeDictationContext(appSupportDirectory: appSupportDirectory)
        let context = try XCTUnwrap(dictationContext)
        let livePlugin = MockLiveTranscriptionPlugin()
        PluginManager.shared.loadedPlugins.append(LoadedPlugin(
            manifest: PluginManifest(
                id: "com.typewhisper.mock.live-transcription",
                name: "Mock Live",
                version: "1.0.0",
                principalClass: "APIRouterMockLiveTranscriptionPlugin"
            ),
            instance: livePlugin,
            bundle: Bundle.main,
            sourceURL: appSupportDirectory,
            isEnabled: true
        ))
        context.modelManager.selectProvider(livePlugin.providerId)
        let pasteboard = NSPasteboard.withUniqueName()
        context.textInsertionService.pasteboardProvider = { pasteboard }
        context.textInsertionService.captureActiveAppOverride = {
            ("Notes", "com.apple.Notes", nil)
        }
        context.textInsertionService.accessibilityGrantedOverride = true
        context.textInsertionService.selectedTextOverride = { nil }
        context.textInsertionService.pasteSimulatorOverride = {}
        context.audioRecordingService.hasMicrophonePermissionOverride = true
        context.audioRecordingService.inputAvailabilityOverride = { _ in true }
        context.audioRecordingService.startRecordingOverride = {}
        context.audioRecordingService.stopRecordingOverride = { _ in
            Array(repeating: 0.25, count: Int(AudioRecordingService.targetSampleRate))
        }

        let sessionID = context.dictationViewModel.apiStartRecording()
        context.dictationViewModel.partialText = "live preview text"

        _ = context.dictationViewModel.apiStopRecording()

        for _ in 0..<40 {
            if context.dictationViewModel.apiDictationSession(id: sessionID)?.status == .completed {
                break
            }
            try? await Task.sleep(for: .milliseconds(25))
        }

        let session = try XCTUnwrap(context.dictationViewModel.apiDictationSession(id: sessionID))
        XCTAssertEqual(session.status, .completed)
        XCTAssertEqual(session.transcription?.rawText, "live preview text")
        XCTAssertEqual(session.transcription?.text, "live preview text")
        XCTAssertEqual(MockTranscriptionPlugin.transcribeCallCount, 0)
    }

    @MainActor
    func testPushToTalkInterruptionDiscardStopsImmediatelyAndMarksSessionFailedByDefault() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
        }

        dictationContext = Self.makeDictationContext(appSupportDirectory: appSupportDirectory)
        let context = try XCTUnwrap(dictationContext)
        XCTAssertTrue(context.hotkeyService.discardPushToTalkRecordingOnExtraKeyPress)

        var stopPolicies: [String] = []
        context.audioRecordingService.hasMicrophonePermissionOverride = true
        context.audioRecordingService.inputAvailabilityOverride = { _ in true }
        context.audioRecordingService.startRecordingOverride = {}
        context.audioRecordingService.stopRecordingOverride = { policy in
            stopPolicies.append(policy.logDescription)
            return []
        }

        let sessionID = context.dictationViewModel.apiStartRecording()
        XCTAssertEqual(context.dictationViewModel.state, .recording)

        context.hotkeyService.onPushToTalkInterruption?()
        _ = context.dictationViewModel.apiStopRecording()

        for _ in 0..<20 {
            if context.dictationViewModel.apiDictationSession(id: sessionID)?.status == .failed {
                break
            }
            try? await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertEqual(stopPolicies, [AudioRecordingService.StopPolicy.immediate.logDescription])
        XCTAssertEqual(
            context.dictationViewModel.actionFeedbackMessage,
            "Recording discarded because additional keys were pressed"
        )
        XCTAssertEqual(context.dictationViewModel.apiDictationSession(id: sessionID)?.status, .failed)
        XCTAssertEqual(
            context.dictationViewModel.apiDictationSession(id: sessionID)?.error,
            "Recording discarded because additional keys were pressed"
        )
    }

    @MainActor
    func testApiStartRecording_ignoresLegacyBundleProfileBeforeDeferredMetadataCapture() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
        }

        dictationContext = Self.makeDictationContext(appSupportDirectory: appSupportDirectory)
        let context = try XCTUnwrap(dictationContext)
        context.profileService.addProfile(name: "Docs", bundleIdentifiers: ["com.typewhisper.tests"])

        let selectedTextCaptured = expectation(description: "selected text captured")
        context.textInsertionService.captureActiveAppOverride = { () -> (name: String?, bundleId: String?, url: String?) in
            ("Docs App", "com.typewhisper.tests", nil)
        }
        context.audioRecordingService.hasMicrophonePermissionOverride = true
        context.audioRecordingService.inputAvailabilityOverride = { _ in true }
        context.audioRecordingService.startRecordingOverride = {}
        context.textInsertionService.selectedTextOverride = { () -> String? in
            selectedTextCaptured.fulfill()
            return nil
        }

        _ = context.dictationViewModel.apiStartRecording()

        XCTAssertEqual(context.dictationViewModel.state, DictationViewModel.State.recording)
        XCTAssertNil(context.dictationViewModel.activeRuleName)

        await fulfillment(of: [selectedTextCaptured], timeout: 1.0)
    }

    @MainActor
    func testDictationRuntimeIgnoresLegacyProfileLanguageSelection() async throws {
        let selectedLanguageKey = UserDefaultsKeys.selectedLanguage
        let originalSelectedLanguage = UserDefaults.standard.object(forKey: selectedLanguageKey)
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            if let originalSelectedLanguage {
                UserDefaults.standard.set(originalSelectedLanguage, forKey: selectedLanguageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: selectedLanguageKey)
            }
            TestSupport.remove(appSupportDirectory)
        }

        UserDefaults.standard.set("de", forKey: selectedLanguageKey)
        MockTranscriptionPlugin.reset()
        dictationContext = Self.makeDictationContext(appSupportDirectory: appSupportDirectory)
        let context = try XCTUnwrap(dictationContext)
        context.profileService.addProfile(
            name: "Legacy Notes",
            bundleIdentifiers: ["com.apple.Notes"],
            inputLanguage: "en",
            translationTargetLanguage: "en"
        )
        context.textInsertionService.captureActiveAppOverride = {
            ("Notes", "com.apple.Notes", nil)
        }
        context.audioRecordingService.hasMicrophonePermissionOverride = true
        context.audioRecordingService.inputAvailabilityOverride = { _ in true }
        context.audioRecordingService.startRecordingOverride = {}
        context.audioRecordingService.stopRecordingOverride = { _ in
            Array(repeating: 0.25, count: Int(AudioRecordingService.targetSampleRate))
        }
        context.textInsertionService.accessibilityGrantedOverride = true
        context.textInsertionService.selectedTextOverride = { nil }
        context.textInsertionService.pasteSimulatorOverride = {}

        let sessionID = context.dictationViewModel.apiStartRecording()

        XCTAssertEqual(context.dictationViewModel.state, .recording)
        XCTAssertNil(context.dictationViewModel.activeRuleName)

        _ = context.dictationViewModel.apiStopRecording()
        for _ in 0..<40 {
            if context.dictationViewModel.apiDictationSession(id: sessionID)?.status == .completed {
                break
            }
            try? await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertEqual(context.dictationViewModel.apiDictationSession(id: sessionID)?.status, .completed)
        XCTAssertEqual(MockTranscriptionPlugin.lastLanguageSelection.requestedLanguage, "de")
    }

    @MainActor
    func testDictationRuntimeUsesWorkflowInsteadOfCompetingLegacyProfile() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
        }

        MockTranscriptionPlugin.reset()
        dictationContext = Self.makeDictationContext(appSupportDirectory: appSupportDirectory)
        let context = try XCTUnwrap(dictationContext)
        context.profileService.addProfile(
            name: "Legacy Notes",
            bundleIdentifiers: ["com.apple.Notes"],
            inputLanguage: "en",
            translationTargetLanguage: "en"
        )
        _ = context.workflowService.addWorkflow(
            name: "Workflow Notes",
            template: .dictation,
            trigger: .app("com.apple.Notes"),
            behavior: WorkflowBehavior(settings: [
                WorkflowBehavior.inputLanguageSettingKey: "de"
            ])
        )
        context.textInsertionService.captureActiveAppOverride = {
            ("Notes", "com.apple.Notes", nil)
        }
        context.audioRecordingService.hasMicrophonePermissionOverride = true
        context.audioRecordingService.inputAvailabilityOverride = { _ in true }
        context.audioRecordingService.startRecordingOverride = {}
        context.audioRecordingService.stopRecordingOverride = { _ in
            Array(repeating: 0.25, count: Int(AudioRecordingService.targetSampleRate))
        }
        context.textInsertionService.accessibilityGrantedOverride = true
        context.textInsertionService.selectedTextOverride = { nil }
        context.textInsertionService.pasteSimulatorOverride = {}

        let sessionID = context.dictationViewModel.apiStartRecording()

        XCTAssertEqual(context.dictationViewModel.state, .recording)
        XCTAssertEqual(context.dictationViewModel.activeRuleName, "Workflow Notes")

        _ = context.dictationViewModel.apiStopRecording()
        for _ in 0..<40 {
            if context.dictationViewModel.apiDictationSession(id: sessionID)?.status == .completed {
                break
            }
            try? await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertEqual(context.dictationViewModel.apiDictationSession(id: sessionID)?.status, .completed)
        XCTAssertEqual(MockTranscriptionPlugin.lastLanguageSelection.requestedLanguage, "de")
    }

    @MainActor
    func testDictationDirectInsertionAddsTrailingSpaceWithoutMutatingStoredTranscription() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        let historyEnabledKey = UserDefaultsKeys.historyEnabled
        let preserveClipboardKey = UserDefaultsKeys.preserveClipboard
        let originalHistoryEnabled = UserDefaults.standard.object(forKey: historyEnabledKey)
        let originalPreserveClipboard = UserDefaults.standard.object(forKey: preserveClipboardKey)
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            if let originalHistoryEnabled {
                UserDefaults.standard.set(originalHistoryEnabled, forKey: historyEnabledKey)
            } else {
                UserDefaults.standard.removeObject(forKey: historyEnabledKey)
            }
            if let originalPreserveClipboard {
                UserDefaults.standard.set(originalPreserveClipboard, forKey: preserveClipboardKey)
            } else {
                UserDefaults.standard.removeObject(forKey: preserveClipboardKey)
            }
            TestSupport.remove(appSupportDirectory)
        }

        UserDefaults.standard.set(true, forKey: historyEnabledKey)
        UserDefaults.standard.set(false, forKey: preserveClipboardKey)

        dictationContext = Self.makeDictationContext(appSupportDirectory: appSupportDirectory)
        let context = try XCTUnwrap(dictationContext)
        context.dictationViewModel.preserveClipboard = false
        let pasteboard = NSPasteboard.withUniqueName()
        context.textInsertionService.pasteboardProvider = { pasteboard }
        context.textInsertionService.captureActiveAppOverride = {
            ("Notes", "com.apple.Notes", nil)
        }
        context.audioRecordingService.hasMicrophonePermissionOverride = true
        context.audioRecordingService.inputAvailabilityOverride = { _ in true }
        context.audioRecordingService.startRecordingOverride = {}
        context.audioRecordingService.stopRecordingOverride = { _ in
            Array(repeating: 0.25, count: Int(AudioRecordingService.targetSampleRate))
        }
        context.textInsertionService.accessibilityGrantedOverride = true
        context.textInsertionService.selectedTextOverride = { nil }
        context.textInsertionService.pasteSimulatorOverride = {}

        let sessionID = context.dictationViewModel.apiStartRecording()
        _ = context.dictationViewModel.apiStopRecording()

        for _ in 0..<40 {
            if context.dictationViewModel.apiDictationSession(id: sessionID)?.status == .completed {
                break
            }
            try? await Task.sleep(for: .milliseconds(25))
        }

        let session = try XCTUnwrap(context.dictationViewModel.apiDictationSession(id: sessionID))
        XCTAssertEqual(session.status, .completed)
        XCTAssertEqual(pasteboard.string(forType: .string), "transcribed ")
        XCTAssertEqual(session.transcription?.text, "transcribed")
        XCTAssertEqual(context.historyService.records.first?.finalText, "transcribed")
        XCTAssertEqual(
            context.recentTranscriptionStore.latestEntry(historyRecords: context.historyService.records)?.finalText,
            "transcribed"
        )
    }

    @MainActor
    func testDictationDirectInsertionUsesContextWhenAppAwareFormattingIsEnabled() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        let historyEnabledKey = UserDefaultsKeys.historyEnabled
        let preserveClipboardKey = UserDefaultsKeys.preserveClipboard
        let appFormattingKey = UserDefaultsKeys.appFormattingEnabled
        let originalHistoryEnabled = UserDefaults.standard.object(forKey: historyEnabledKey)
        let originalPreserveClipboard = UserDefaults.standard.object(forKey: preserveClipboardKey)
        let originalAppFormatting = UserDefaults.standard.object(forKey: appFormattingKey)
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            MockTranscriptionPlugin.reset()
            if let originalHistoryEnabled {
                UserDefaults.standard.set(originalHistoryEnabled, forKey: historyEnabledKey)
            } else {
                UserDefaults.standard.removeObject(forKey: historyEnabledKey)
            }
            if let originalPreserveClipboard {
                UserDefaults.standard.set(originalPreserveClipboard, forKey: preserveClipboardKey)
            } else {
                UserDefaults.standard.removeObject(forKey: preserveClipboardKey)
            }
            if let originalAppFormatting {
                UserDefaults.standard.set(originalAppFormatting, forKey: appFormattingKey)
            } else {
                UserDefaults.standard.removeObject(forKey: appFormattingKey)
            }
            TestSupport.remove(appSupportDirectory)
        }

        UserDefaults.standard.set(true, forKey: historyEnabledKey)
        UserDefaults.standard.set(false, forKey: preserveClipboardKey)
        UserDefaults.standard.set(true, forKey: appFormattingKey)
        MockTranscriptionPlugin.reset()
        MockTranscriptionPlugin.setResponseText("Strong.")

        dictationContext = Self.makeDictationContext(appSupportDirectory: appSupportDirectory)
        let context = try XCTUnwrap(dictationContext)
        context.dictationViewModel.preserveClipboard = false
        let pasteboard = NSPasteboard.withUniqueName()
        let element = AXUIElementCreateSystemWide()
        context.textInsertionService.pasteboardProvider = { pasteboard }
        context.textInsertionService.captureActiveAppOverride = {
            ("Notes", "com.apple.Notes", nil)
        }
        context.audioRecordingService.hasMicrophonePermissionOverride = true
        context.audioRecordingService.inputAvailabilityOverride = { _ in true }
        context.audioRecordingService.startRecordingOverride = {}
        context.audioRecordingService.stopRecordingOverride = { _ in
            Array(repeating: 0.25, count: Int(AudioRecordingService.targetSampleRate))
        }
        context.textInsertionService.accessibilityGrantedOverride = true
        context.textInsertionService.selectedTextOverride = { nil }
        context.textInsertionService.focusedTextElementOverride = { element }
        context.textInsertionService.focusedTextStateOverride = { _ in
            (value: "coffeemachine", selectedText: nil, selectedRange: NSRange(location: 6, length: 0))
        }
        context.textInsertionService.pasteVerificationAttempts = 0
        context.textInsertionService.pasteSimulatorOverride = {}

        let sessionID = context.dictationViewModel.apiStartRecording()
        _ = context.dictationViewModel.apiStopRecording()

        for _ in 0..<40 {
            if context.dictationViewModel.apiDictationSession(id: sessionID)?.status == .completed {
                break
            }
            try? await Task.sleep(for: .milliseconds(25))
        }

        let session = try XCTUnwrap(context.dictationViewModel.apiDictationSession(id: sessionID))
        XCTAssertEqual(session.status, .completed)
        XCTAssertEqual(pasteboard.string(forType: .string), " strong ")
        XCTAssertEqual(session.transcription?.text, "Strong.")
        XCTAssertEqual(context.historyService.records.first?.finalText, "Strong.")
    }

    @MainActor
    func testApiStartRecording_pausesMediaAfterAudioStart() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var events: [String] = []
        let mediaPlaybackService = MockMediaPlaybackService {
            events.append("pause_media")
        }
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
        }

        dictationContext = Self.makeDictationContext(
            appSupportDirectory: appSupportDirectory,
            mediaPlaybackService: mediaPlaybackService
        )
        let context = try XCTUnwrap(dictationContext)
        context.dictationViewModel.mediaPauseEnabled = true

        context.textInsertionService.captureActiveAppOverride = { () -> (name: String?, bundleId: String?, url: String?) in
            events.append("capture_app")
            return ("Music", "com.apple.Music", nil)
        }
        context.audioRecordingService.hasMicrophonePermissionOverride = true
        context.audioRecordingService.inputAvailabilityOverride = { _ in true }
        context.audioRecordingService.startRecordingOverride = {
            events.append("start_audio")
        }

        _ = context.dictationViewModel.apiStartRecording()

        XCTAssertEqual(Array(events.prefix(3)), ["start_audio", "pause_media", "capture_app"])
    }

    @MainActor
    func testApiStartRecordingFailureSkipsPostAudioStartSideEffects() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var events: [String] = []
        let mediaPlaybackService = MockMediaPlaybackService {
            events.append("pause_media")
        }
        let soundService = MockSoundService { event, enabled in
            guard event == .recordingStarted, enabled else { return }
            events.append("start_sound")
        }
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
        }

        dictationContext = Self.makeDictationContext(
            appSupportDirectory: appSupportDirectory,
            mediaPlaybackService: mediaPlaybackService,
            soundService: soundService
        )
        let context = try XCTUnwrap(dictationContext)
        context.dictationViewModel.mediaPauseEnabled = true
        context.dictationViewModel.soundFeedbackEnabled = true
        context.audioRecordingService.hasMicrophonePermissionOverride = true
        context.audioRecordingService.inputAvailabilityOverride = { _ in true }
        context.textInsertionService.captureActiveAppOverride = {
            events.append("capture_app")
            return ("Notes", "com.apple.Notes", nil)
        }
        context.audioRecordingService.startRecordingOverride = {
            events.append("start_audio")
            throw NSError(
                domain: "TypeWhisperTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Audio start failed"]
            )
        }

        let sessionID = context.dictationViewModel.apiStartRecording()

        XCTAssertEqual(events, ["start_audio"])
        XCTAssertFalse(context.dictationViewModel.isRecordingInputReady)
        XCTAssertEqual(context.dictationViewModel.state, .inserting)
        XCTAssertEqual(context.dictationViewModel.actionFeedbackMessage, "Audio start failed")
        XCTAssertEqual(context.dictationViewModel.apiDictationSession(id: sessionID)?.status, .failed)
        XCTAssertEqual(context.dictationViewModel.apiDictationSession(id: sessionID)?.error, "Audio start failed")
    }

    @MainActor
    func testApiStartRecording_defersStartSoundUntilInputIsReady() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        let originalSelectedInputDeviceUID = UserDefaults.standard.object(forKey: UserDefaultsKeys.selectedInputDeviceUID)
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.selectedInputDeviceUID)
        var events: [String] = []
        let soundService = MockSoundService { event, enabled in
            guard event == .recordingStarted, enabled else { return }
            events.append("start_sound")
        }
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
            Self.restoreSelectedInputDeviceUID(originalSelectedInputDeviceUID)
        }

        dictationContext = Self.makeDictationContext(
            appSupportDirectory: appSupportDirectory,
            soundService: soundService
        )
        let context = try XCTUnwrap(dictationContext)
        context.dictationViewModel.soundFeedbackEnabled = true
        context.audioRecordingService.hasMicrophonePermissionOverride = true
        context.audioRecordingService.inputAvailabilityOverride = { _ in true }
        context.audioRecordingService.startRecordingOverride = {
            events.append("start_audio")
        }

        _ = context.dictationViewModel.apiStartRecording()

        XCTAssertEqual(events, ["start_audio"])
        XCTAssertFalse(context.dictationViewModel.isRecordingInputReady)

        context.audioRecordingService.testingNotifyFirstRecordingAudioBuffer()

        XCTAssertEqual(events, ["start_audio", "start_sound"])
        XCTAssertTrue(context.dictationViewModel.isRecordingInputReady)
    }

    @MainActor
    func testApiStartRecording_ducksAudioAfterStartSoundWhenInputIsReady() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        let originalSelectedInputDeviceUID = UserDefaults.standard.object(forKey: UserDefaultsKeys.selectedInputDeviceUID)
        let originalAudioDuckingEnabled = UserDefaults.standard.object(forKey: UserDefaultsKeys.audioDuckingEnabled)
        let originalAudioDuckingLevel = UserDefaults.standard.object(forKey: UserDefaultsKeys.audioDuckingLevel)
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.selectedInputDeviceUID)
        var events: [String] = []
        let soundService = MockSoundService { event, enabled in
            guard event == .recordingStarted, enabled else { return }
            events.append("start_sound")
        }
        let audioDuckingService = MockAudioDuckingService(onDuck: { factor in
            events.append("duck_audio_\(factor)")
        })
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
            Self.restoreSelectedInputDeviceUID(originalSelectedInputDeviceUID)
            Self.restoreUserDefault(originalAudioDuckingEnabled, forKey: UserDefaultsKeys.audioDuckingEnabled)
            Self.restoreUserDefault(originalAudioDuckingLevel, forKey: UserDefaultsKeys.audioDuckingLevel)
        }

        dictationContext = Self.makeDictationContext(
            appSupportDirectory: appSupportDirectory,
            audioDuckingService: audioDuckingService,
            soundService: soundService
        )
        let context = try XCTUnwrap(dictationContext)
        context.dictationViewModel.soundFeedbackEnabled = true
        context.dictationViewModel.audioDuckingEnabled = true
        context.dictationViewModel.audioDuckingLevel = 0.2
        context.audioRecordingService.hasMicrophonePermissionOverride = true
        context.audioRecordingService.inputAvailabilityOverride = { _ in true }
        context.audioRecordingService.startRecordingOverride = {
            events.append("start_audio")
        }

        _ = context.dictationViewModel.apiStartRecording()

        XCTAssertEqual(events, ["start_audio"])
        XCTAssertFalse(context.dictationViewModel.isRecordingInputReady)

        context.audioRecordingService.testingNotifyFirstRecordingAudioBuffer()

        XCTAssertEqual(events, ["start_audio", "start_sound", "duck_audio_0.2"])
        XCTAssertTrue(context.dictationViewModel.isRecordingInputReady)
    }

    @MainActor
    func testApiStartRecording_waitsForStartSoundDurationBeforeDuckingAudio() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        let originalSelectedInputDeviceUID = UserDefaults.standard.object(forKey: UserDefaultsKeys.selectedInputDeviceUID)
        let originalAudioDuckingEnabled = UserDefaults.standard.object(forKey: UserDefaultsKeys.audioDuckingEnabled)
        let originalAudioDuckingLevel = UserDefaults.standard.object(forKey: UserDefaultsKeys.audioDuckingLevel)
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.selectedInputDeviceUID)
        var events: [String] = []
        let soundService = MockSoundService(
            onPlay: { event, enabled in
                guard event == .recordingStarted, enabled else { return }
                events.append("start_sound")
            },
            playbackDurationForEvent: { event, enabled in
                event == .recordingStarted && enabled ? 0.05 : nil
            }
        )
        let duckingApplied = expectation(description: "ducking applied after start sound duration")
        let audioDuckingService = MockAudioDuckingService(onDuck: { factor in
            events.append("duck_audio_\(factor)")
            duckingApplied.fulfill()
        })
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
            Self.restoreSelectedInputDeviceUID(originalSelectedInputDeviceUID)
            Self.restoreUserDefault(originalAudioDuckingEnabled, forKey: UserDefaultsKeys.audioDuckingEnabled)
            Self.restoreUserDefault(originalAudioDuckingLevel, forKey: UserDefaultsKeys.audioDuckingLevel)
        }

        dictationContext = Self.makeDictationContext(
            appSupportDirectory: appSupportDirectory,
            audioDuckingService: audioDuckingService,
            soundService: soundService
        )
        let context = try XCTUnwrap(dictationContext)
        context.dictationViewModel.soundFeedbackEnabled = true
        context.dictationViewModel.audioDuckingEnabled = true
        context.dictationViewModel.audioDuckingLevel = 0.2
        context.audioRecordingService.hasMicrophonePermissionOverride = true
        context.audioRecordingService.inputAvailabilityOverride = { _ in true }
        context.audioRecordingService.startRecordingOverride = {
            events.append("start_audio")
        }

        _ = context.dictationViewModel.apiStartRecording()
        context.audioRecordingService.testingNotifyFirstRecordingAudioBuffer()

        XCTAssertEqual(events, ["start_audio", "start_sound"])

        await fulfillment(of: [duckingApplied], timeout: 1.0)

        XCTAssertEqual(events, ["start_audio", "start_sound", "duck_audio_0.2"])
    }

    @MainActor
    func testApiStartRecording_ducksAudioAfterInputReadyWhenStartSoundIsDisabled() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        let originalSelectedInputDeviceUID = UserDefaults.standard.object(forKey: UserDefaultsKeys.selectedInputDeviceUID)
        let originalAudioDuckingEnabled = UserDefaults.standard.object(forKey: UserDefaultsKeys.audioDuckingEnabled)
        let originalAudioDuckingLevel = UserDefaults.standard.object(forKey: UserDefaultsKeys.audioDuckingLevel)
        let originalSoundFeedbackEnabled = UserDefaults.standard.object(forKey: UserDefaultsKeys.soundFeedbackEnabled)
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.selectedInputDeviceUID)
        var events: [String] = []
        let soundService = MockSoundService { event, enabled in
            guard event == .recordingStarted, enabled else { return }
            events.append("start_sound")
        }
        let audioDuckingService = MockAudioDuckingService(onDuck: { factor in
            events.append("duck_audio_\(factor)")
        })
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
            Self.restoreSelectedInputDeviceUID(originalSelectedInputDeviceUID)
            Self.restoreUserDefault(originalAudioDuckingEnabled, forKey: UserDefaultsKeys.audioDuckingEnabled)
            Self.restoreUserDefault(originalAudioDuckingLevel, forKey: UserDefaultsKeys.audioDuckingLevel)
            Self.restoreUserDefault(originalSoundFeedbackEnabled, forKey: UserDefaultsKeys.soundFeedbackEnabled)
        }

        dictationContext = Self.makeDictationContext(
            appSupportDirectory: appSupportDirectory,
            audioDuckingService: audioDuckingService,
            soundService: soundService
        )
        let context = try XCTUnwrap(dictationContext)
        context.dictationViewModel.soundFeedbackEnabled = false
        context.dictationViewModel.audioDuckingEnabled = true
        context.dictationViewModel.audioDuckingLevel = 0.25
        context.audioRecordingService.hasMicrophonePermissionOverride = true
        context.audioRecordingService.inputAvailabilityOverride = { _ in true }
        context.audioRecordingService.startRecordingOverride = {
            events.append("start_audio")
        }

        _ = context.dictationViewModel.apiStartRecording()

        XCTAssertEqual(events, ["start_audio"])
        XCTAssertFalse(context.dictationViewModel.isRecordingInputReady)

        context.audioRecordingService.testingNotifyFirstRecordingAudioBuffer()

        XCTAssertEqual(events, ["start_audio", "duck_audio_0.25"])
        XCTAssertTrue(context.dictationViewModel.isRecordingInputReady)
    }

    @MainActor
    func testApiStartRecording_clampsPendingAudioDuckingLevel() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        let originalSelectedInputDeviceUID = UserDefaults.standard.object(forKey: UserDefaultsKeys.selectedInputDeviceUID)
        let originalAudioDuckingEnabled = UserDefaults.standard.object(forKey: UserDefaultsKeys.audioDuckingEnabled)
        let originalAudioDuckingLevel = UserDefaults.standard.object(forKey: UserDefaultsKeys.audioDuckingLevel)
        let originalSoundFeedbackEnabled = UserDefaults.standard.object(forKey: UserDefaultsKeys.soundFeedbackEnabled)
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.selectedInputDeviceUID)
        var duckingLevels: [Float] = []
        let audioDuckingService = MockAudioDuckingService(onDuck: { factor in
            duckingLevels.append(factor)
        })
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
            Self.restoreSelectedInputDeviceUID(originalSelectedInputDeviceUID)
            Self.restoreUserDefault(originalAudioDuckingEnabled, forKey: UserDefaultsKeys.audioDuckingEnabled)
            Self.restoreUserDefault(originalAudioDuckingLevel, forKey: UserDefaultsKeys.audioDuckingLevel)
            Self.restoreUserDefault(originalSoundFeedbackEnabled, forKey: UserDefaultsKeys.soundFeedbackEnabled)
        }

        dictationContext = Self.makeDictationContext(
            appSupportDirectory: appSupportDirectory,
            audioDuckingService: audioDuckingService
        )
        let context = try XCTUnwrap(dictationContext)
        context.dictationViewModel.soundFeedbackEnabled = false
        context.dictationViewModel.audioDuckingEnabled = true
        context.dictationViewModel.audioDuckingLevel = 1.5
        context.audioRecordingService.hasMicrophonePermissionOverride = true
        context.audioRecordingService.inputAvailabilityOverride = { _ in true }
        context.audioRecordingService.startRecordingOverride = {}

        _ = context.dictationViewModel.apiStartRecording()

        XCTAssertTrue(duckingLevels.isEmpty)

        context.audioRecordingService.testingNotifyFirstRecordingAudioBuffer()

        XCTAssertEqual(duckingLevels, [1.0])
        XCTAssertTrue(context.dictationViewModel.isRecordingInputReady)
    }

    @MainActor
    func testApiStartRecording_skipsStartSoundForBluetoothInput() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        let originalSelectedInputDeviceUID = UserDefaults.standard.object(forKey: UserDefaultsKeys.selectedInputDeviceUID)
        let originalPriorityList = UserDefaults.standard.object(forKey: UserDefaultsKeys.inputDevicePriorityList)
        let originalAudioDuckingEnabled = UserDefaults.standard.object(forKey: UserDefaultsKeys.audioDuckingEnabled)
        let originalAudioDuckingLevel = UserDefaults.standard.object(forKey: UserDefaultsKeys.audioDuckingLevel)
        var events: [String] = []
        let bluetoothDeviceID = AudioDeviceID(409)
        let soundService = MockSoundService { event, enabled in
            guard event == .recordingStarted, enabled else { return }
            events.append("start_sound")
        }
        let audioDuckingService = MockAudioDuckingService(onDuck: { factor in
            events.append("duck_audio_\(factor)")
        })
        let transportResolver = FakeAudioDeviceTransportResolver(
            transports: [bluetoothDeviceID: kAudioDeviceTransportTypeBluetooth]
        ) { deviceID in
            XCTAssertEqual(deviceID, bluetoothDeviceID)
        }
        let deviceRouteStabilizer = FakeBluetoothInputRouteStabilizer { inputDeviceID, reason in
            XCTAssertEqual(inputDeviceID, bluetoothDeviceID)
            XCTAssertEqual(reason, "selection-validation")
            return true
        }
        let selectionEngineValidator = FakeAudioInputSelectionEngineValidator { preferredDeviceID in
            XCTAssertNil(preferredDeviceID)
        }
        let recordingRouteStabilizer = FakeBluetoothInputRouteStabilizer { inputDeviceID, reason in
            XCTAssertEqual(inputDeviceID, bluetoothDeviceID)
            XCTAssertEqual(reason, "recording-start")
            return true
        }
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
            Self.restoreSelectedInputDeviceUID(originalSelectedInputDeviceUID)
            Self.restoreUserDefault(originalPriorityList, forKey: UserDefaultsKeys.inputDevicePriorityList)
            Self.restoreUserDefault(originalAudioDuckingEnabled, forKey: UserDefaultsKeys.audioDuckingEnabled)
            Self.restoreUserDefault(originalAudioDuckingLevel, forKey: UserDefaultsKeys.audioDuckingLevel)
        }

        dictationContext = Self.makeDictationContext(
            appSupportDirectory: appSupportDirectory,
            audioDuckingService: audioDuckingService,
            soundService: soundService,
            audioDeviceTransportResolver: transportResolver,
            audioDeviceBluetoothInputRouteStabilizer: deviceRouteStabilizer,
            audioDeviceSelectionEngineValidator: selectionEngineValidator,
            audioRecordingBluetoothInputRouteStabilizer: recordingRouteStabilizer
        )
        let context = try XCTUnwrap(dictationContext)
        context.dictationViewModel.soundFeedbackEnabled = true
        context.dictationViewModel.audioDuckingEnabled = true
        context.dictationViewModel.audioDuckingLevel = 0.3
        context.audioDeviceService.inputDevices = [
            AudioInputDevice(deviceID: bluetoothDeviceID, name: "AirPods Max", uid: "bt-input")
        ]
        context.audioDeviceService.audioDeviceIDResolverOverride = { uid in
            uid == "bt-input" ? bluetoothDeviceID : nil
        }
        context.audioDeviceService.selectedDeviceUID = "bt-input"
        context.audioRecordingService.hasMicrophonePermissionOverride = true
        context.audioRecordingService.inputAvailabilityOverride = { selectedDeviceID in
            XCTAssertEqual(selectedDeviceID, bluetoothDeviceID)
            return true
        }
        context.audioRecordingService.startRecordingOverride = {
            XCTAssertTrue(context.audioRecordingService.selectedInputDeviceUsesBluetoothTransport)
            events.append("start_audio")
        }

        _ = context.dictationViewModel.apiStartRecording()

        XCTAssertEqual(events, ["start_audio"])
        XCTAssertFalse(context.dictationViewModel.isRecordingInputReady)

        context.audioRecordingService.testingNotifyFirstRecordingAudioBuffer()

        XCTAssertEqual(events, ["start_audio", "duck_audio_0.3"])
        XCTAssertTrue(context.dictationViewModel.isRecordingInputReady)
        XCTAssertTrue(context.audioRecordingService.hasExplicitDeviceSelection)
    }

    @MainActor
    func testApiStartRecording_keepsStartSoundForUSBInputAfterInputIsReady() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        let originalSelectedInputDeviceUID = UserDefaults.standard.object(forKey: UserDefaultsKeys.selectedInputDeviceUID)
        let originalPriorityList = UserDefaults.standard.object(forKey: UserDefaultsKeys.inputDevicePriorityList)
        var events: [String] = []
        let usbDeviceID = AudioDeviceID(410)
        let soundService = MockSoundService { event, enabled in
            guard event == .recordingStarted, enabled else { return }
            events.append("start_sound")
        }
        let transportResolver = FakeAudioDeviceTransportResolver(
            transports: [usbDeviceID: kAudioDeviceTransportTypeUSB]
        ) { deviceID in
            XCTAssertEqual(deviceID, usbDeviceID)
        }
        let selectionEngineValidator = FakeAudioInputSelectionEngineValidator { preferredDeviceID in
            XCTAssertEqual(preferredDeviceID, usbDeviceID)
        }
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
            Self.restoreSelectedInputDeviceUID(originalSelectedInputDeviceUID)
            Self.restoreUserDefault(originalPriorityList, forKey: UserDefaultsKeys.inputDevicePriorityList)
        }

        dictationContext = Self.makeDictationContext(
            appSupportDirectory: appSupportDirectory,
            soundService: soundService,
            audioDeviceTransportResolver: transportResolver,
            audioDeviceSelectionEngineValidator: selectionEngineValidator
        )
        let context = try XCTUnwrap(dictationContext)
        context.dictationViewModel.soundFeedbackEnabled = true
        context.audioDeviceService.inputDevices = [
            AudioInputDevice(deviceID: usbDeviceID, name: "USB Mic", uid: "usb-input")
        ]
        context.audioDeviceService.audioDeviceIDResolverOverride = { uid in
            uid == "usb-input" ? usbDeviceID : nil
        }
        context.audioDeviceService.selectedDeviceUID = "usb-input"
        context.audioRecordingService.hasMicrophonePermissionOverride = true
        context.audioRecordingService.inputAvailabilityOverride = { selectedDeviceID in
            XCTAssertEqual(selectedDeviceID, usbDeviceID)
            return true
        }
        context.audioRecordingService.startRecordingOverride = {
            XCTAssertFalse(context.audioRecordingService.selectedInputDeviceUsesBluetoothTransport)
            events.append("start_audio")
        }

        _ = context.dictationViewModel.apiStartRecording()

        XCTAssertEqual(events, ["start_audio"])
        XCTAssertFalse(context.dictationViewModel.isRecordingInputReady)

        context.audioRecordingService.testingNotifyFirstRecordingAudioBuffer()

        XCTAssertEqual(events, ["start_audio", "start_sound"])
        XCTAssertTrue(context.dictationViewModel.isRecordingInputReady)
    }

    @MainActor
    func testApiStartRecordingUsesNextAvailablePriorityMicrophone() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        let originalSelectedInputDeviceUID = UserDefaults.standard.object(forKey: UserDefaultsKeys.selectedInputDeviceUID)
        let originalPriorityList = UserDefaults.standard.object(forKey: UserDefaultsKeys.inputDevicePriorityList)
        let usbDeviceID = AudioDeviceID(510)
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.selectedInputDeviceUID)
        UserDefaults.standard.set(
            try JSONEncoder().encode([
                AudioInputDevicePriorityItem(uid: "missing-primary", name: "Desk Mic"),
                AudioInputDevicePriorityItem(uid: "usb-input", name: "USB Mic")
            ]),
            forKey: UserDefaultsKeys.inputDevicePriorityList
        )
        let transportResolver = FakeAudioDeviceTransportResolver(
            transports: [usbDeviceID: kAudioDeviceTransportTypeUSB]
        )
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
            Self.restoreSelectedInputDeviceUID(originalSelectedInputDeviceUID)
            Self.restoreUserDefault(originalPriorityList, forKey: UserDefaultsKeys.inputDevicePriorityList)
        }

        dictationContext = Self.makeDictationContext(
            appSupportDirectory: appSupportDirectory,
            audioDeviceTransportResolver: transportResolver
        )
        let context = try XCTUnwrap(dictationContext)
        context.audioDeviceService.inputDevices = [
            AudioInputDevice(deviceID: usbDeviceID, name: "USB Mic", uid: "usb-input")
        ]
        context.audioDeviceService.audioDeviceIDResolverOverride = { uid in
            uid == "usb-input" ? usbDeviceID : nil
        }
        context.audioRecordingService.hasMicrophonePermissionOverride = true
        context.audioRecordingService.inputAvailabilityOverride = { selectedDeviceID in
            XCTAssertEqual(selectedDeviceID, usbDeviceID)
            return true
        }
        context.audioRecordingService.startRecordingOverride = {
            XCTAssertEqual(context.audioRecordingService.selectedDeviceID, usbDeviceID)
        }

        _ = context.dictationViewModel.apiStartRecording()

        XCTAssertTrue(context.audioRecordingService.hasExplicitDeviceSelection)
    }

    @MainActor
    func testApiStartRecordingFallsBackToSystemDefaultWhenPriorityMicrophonesUnavailable() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        let originalSelectedInputDeviceUID = UserDefaults.standard.object(forKey: UserDefaultsKeys.selectedInputDeviceUID)
        let originalPriorityList = UserDefaults.standard.object(forKey: UserDefaultsKeys.inputDevicePriorityList)
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.selectedInputDeviceUID)
        UserDefaults.standard.set(
            try JSONEncoder().encode([
                AudioInputDevicePriorityItem(uid: "missing-primary", name: "Desk Mic")
            ]),
            forKey: UserDefaultsKeys.inputDevicePriorityList
        )
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
            Self.restoreSelectedInputDeviceUID(originalSelectedInputDeviceUID)
            Self.restoreUserDefault(originalPriorityList, forKey: UserDefaultsKeys.inputDevicePriorityList)
        }

        dictationContext = Self.makeDictationContext(appSupportDirectory: appSupportDirectory)
        let context = try XCTUnwrap(dictationContext)
        context.audioDeviceService.inputDevices = []
        context.audioRecordingService.hasMicrophonePermissionOverride = true
        context.audioRecordingService.inputAvailabilityOverride = { selectedDeviceID in
            XCTAssertNil(selectedDeviceID)
            return true
        }
        context.audioRecordingService.startRecordingOverride = {
            XCTAssertNil(context.audioRecordingService.selectedDeviceID)
            XCTAssertFalse(context.audioRecordingService.hasExplicitDeviceSelection)
        }

        _ = context.dictationViewModel.apiStartRecording()
    }

    #if !APPSTORE
    @MainActor
    func testMediaPlaybackServicePausesAndResumesFromConfirmedTrackInfo() {
        let controller = FakeMediaPlaybackController()
        let scheduler = TestMediaPlaybackResumeScheduler()
        controller.returnedSnapshot = FakeMediaPlaybackController.snapshot(isPlaying: true, playbackRate: 1)
        let service = MediaPlaybackService(
            startListening: false,
            resumeDelay: 0.6,
            resumeScheduler: scheduler.schedule(after:action:)
        ) { controller }

        service.pauseIfPlaying()

        XCTAssertEqual(controller.pauseCalls, 0)
        XCTAssertEqual(scheduler.scheduledDelays, [0.15])

        scheduler.runNextAction()

        XCTAssertEqual(controller.pauseCalls, 1)

        service.resumeIfWePaused()

        XCTAssertEqual(controller.pauseCalls, 1)
        XCTAssertEqual(controller.playCalls, 0)
        XCTAssertEqual(scheduler.scheduledDelays, [0.15, 0.6])

        scheduler.runNextAction()

        XCTAssertEqual(controller.playCalls, 1)
        XCTAssertEqual(scheduler.scheduledDelays, [0.15, 0.6, 0.25])

        scheduler.runNextAction()

        XCTAssertEqual(controller.togglePlayPauseCalls, 0)
    }

    @MainActor
    func testMediaPlaybackServiceSkipsPauseWhenPlaybackIsAlreadyStopped() {
        let controller = FakeMediaPlaybackController()
        controller.returnedSnapshot = FakeMediaPlaybackController.snapshot(isPlaying: false, playbackRate: nil, bundleIdentifier: nil)
        let service = MediaPlaybackService(startListening: false) { controller }

        service.pauseIfPlaying()
        service.resumeIfWePaused()

        XCTAssertEqual(controller.pauseCalls, 0)
        XCTAssertEqual(controller.playCalls, 0)
    }

    @MainActor
    func testMediaPlaybackServiceSkipsPauseForSpotifyPausedSnapshot() {
        let controller = FakeMediaPlaybackController()
        let scheduler = TestMediaPlaybackResumeScheduler()
        controller.returnedSnapshot = FakeMediaPlaybackController.snapshot(
            isPlaying: false,
            playbackRate: nil,
            bundleIdentifier: "com.spotify.client",
            trackIdentifier: "Wildberry Lillet||Nina Chuba||Glas"
        )
        let service = MediaPlaybackService(
            startListening: false,
            resumeDelay: 0.6,
            resumeScheduler: scheduler.schedule(after:action:)
        ) { controller }

        service.pauseIfPlaying()
        service.resumeIfWePaused()
        scheduler.runPendingActions()

        XCTAssertEqual(controller.pauseCalls, 0)
        XCTAssertEqual(controller.playCalls, 0)
        XCTAssertTrue(scheduler.scheduledDelays.isEmpty)
    }

    @MainActor
    func testMediaPlaybackServicePausesAndResumesForSpotifyPlayingSnapshot() {
        let controller = FakeMediaPlaybackController()
        let scheduler = TestMediaPlaybackResumeScheduler()
        controller.returnedSnapshot = FakeMediaPlaybackController.snapshot(
            isPlaying: true,
            playbackRate: 1,
            bundleIdentifier: "com.spotify.client",
            trackIdentifier: "Wildberry Lillet||Nina Chuba||Glas"
        )
        let service = MediaPlaybackService(
            startListening: false,
            resumeDelay: 0.6,
            resumeScheduler: scheduler.schedule(after:action:)
        ) { controller }

        service.pauseIfPlaying()
        scheduler.runNextAction()
        service.resumeIfWePaused()
        scheduler.runNextAction()

        XCTAssertEqual(controller.pauseCalls, 1)
        XCTAssertEqual(controller.playCalls, 1)
        XCTAssertEqual(scheduler.scheduledDelays, [0.15, 0.6, 0.25])

        scheduler.runNextAction()

        XCTAssertEqual(controller.togglePlayPauseCalls, 0)
    }

    @MainActor
    func testMediaPlaybackServiceFallsBackToToggleWhenResumePlayDoesNotRestartConfirmedMedia() {
        let controller = FakeMediaPlaybackController()
        let scheduler = TestMediaPlaybackResumeScheduler()
        controller.snapshotQueue = [
            FakeMediaPlaybackController.snapshot(
                isPlaying: true,
                playbackRate: 1,
                bundleIdentifier: "com.spotify.client",
                trackIdentifier: "Wildberry Lillet||Nina Chuba||Glas"
            ),
            FakeMediaPlaybackController.snapshot(
                isPlaying: true,
                playbackRate: 1,
                bundleIdentifier: "com.spotify.client",
                trackIdentifier: "Wildberry Lillet||Nina Chuba||Glas"
            ),
            FakeMediaPlaybackController.snapshot(
                isPlaying: false,
                playbackRate: nil,
                bundleIdentifier: "com.spotify.client",
                trackIdentifier: "Wildberry Lillet||Nina Chuba||Glas"
            )
        ]
        let service = MediaPlaybackService(
            startListening: false,
            resumeDelay: 0.6,
            resumeScheduler: scheduler.schedule(after:action:)
        ) { controller }

        service.pauseIfPlaying()
        scheduler.runNextAction()
        service.resumeIfWePaused()
        scheduler.runNextAction()
        scheduler.runNextAction()

        XCTAssertEqual(controller.pauseCalls, 1)
        XCTAssertEqual(controller.playCalls, 1)
        XCTAssertEqual(controller.togglePlayPauseCalls, 1)
        XCTAssertEqual(scheduler.scheduledDelays, [0.15, 0.6, 0.25])

        service.resumeIfWePaused()
        scheduler.runPendingActions()

        XCTAssertEqual(controller.playCalls, 1)
        XCTAssertEqual(controller.togglePlayPauseCalls, 1)
    }

    @MainActor
    func testMediaPlaybackServiceSkipsTransientStalePlaybackStateWhenConfirmReportsPaused() {
        let controller = FakeMediaPlaybackController()
        let scheduler = TestMediaPlaybackResumeScheduler()
        controller.snapshotQueue = [
            FakeMediaPlaybackController.snapshot(
                isPlaying: true,
                playbackRate: 1,
                bundleIdentifier: "com.spotify.client",
                trackIdentifier: "Wildberry Lillet||Nina Chuba||Glas"
            ),
            FakeMediaPlaybackController.snapshot(
                isPlaying: false,
                playbackRate: nil,
                bundleIdentifier: "com.spotify.client",
                trackIdentifier: "Wildberry Lillet||Nina Chuba||Glas"
            )
        ]
        let service = MediaPlaybackService(
            startListening: false,
            resumeDelay: 0.6,
            resumeScheduler: scheduler.schedule(after:action:)
        ) { controller }

        service.pauseIfPlaying()
        scheduler.runNextAction()
        service.resumeIfWePaused()
        scheduler.runPendingActions()

        XCTAssertEqual(controller.pauseCalls, 0)
        XCTAssertEqual(controller.playCalls, 0)
    }

    @MainActor
    func testMediaPlaybackServiceSkipsPauseWhenPlaybackRateIsActiveButApplicationIsNotPlaying() {
        let controller = FakeMediaPlaybackController()
        let scheduler = TestMediaPlaybackResumeScheduler()
        controller.returnedSnapshot = FakeMediaPlaybackController.snapshot(isPlaying: false, playbackRate: 1)
        let service = MediaPlaybackService(
            startListening: false,
            resumeDelay: 0.6,
            resumeScheduler: scheduler.schedule(after:action:)
        ) { controller }

        service.pauseIfPlaying()
        service.resumeIfWePaused()
        scheduler.runPendingActions()

        XCTAssertEqual(controller.pauseCalls, 0)
        XCTAssertEqual(controller.playCalls, 0)
        XCTAssertTrue(scheduler.scheduledDelays.isEmpty)
    }

    @MainActor
    func testMediaPlaybackServiceSkipsPauseWhenPlaybackRateIsZero() {
        let controller = FakeMediaPlaybackController()
        let scheduler = TestMediaPlaybackResumeScheduler()
        controller.returnedSnapshot = FakeMediaPlaybackController.snapshot(isPlaying: true, playbackRate: 0)
        let service = MediaPlaybackService(
            startListening: false,
            resumeDelay: 0.6,
            resumeScheduler: scheduler.schedule(after:action:)
        ) { controller }

        service.pauseIfPlaying()
        service.resumeIfWePaused()
        scheduler.runPendingActions()

        XCTAssertEqual(controller.pauseCalls, 0)
        XCTAssertEqual(controller.playCalls, 0)
        XCTAssertTrue(scheduler.scheduledDelays.isEmpty)
    }

    @MainActor
    func testMediaPlaybackServicePausesWhenApplicationIsPlayingAndPlaybackRateIsMissing() {
        let controller = FakeMediaPlaybackController()
        let scheduler = TestMediaPlaybackResumeScheduler()
        controller.returnedSnapshot = FakeMediaPlaybackController.snapshot(isPlaying: true, playbackRate: nil)
        let service = MediaPlaybackService(
            startListening: false,
            resumeDelay: 0.6,
            resumeScheduler: scheduler.schedule(after:action:)
        ) { controller }

        service.pauseIfPlaying()
        scheduler.runNextAction()

        XCTAssertEqual(controller.pauseCalls, 1)
    }

    @MainActor
    func testMediaPlaybackServiceStopBeforePauseConfirmInvalidatesPendingPause() {
        let controller = FakeMediaPlaybackController()
        let scheduler = TestMediaPlaybackResumeScheduler()
        controller.snapshotQueue = [
            FakeMediaPlaybackController.snapshot(isPlaying: true, playbackRate: 1),
            FakeMediaPlaybackController.snapshot(isPlaying: true, playbackRate: 1)
        ]
        let service = MediaPlaybackService(
            startListening: false,
            resumeDelay: 0.6,
            resumeScheduler: scheduler.schedule(after:action:)
        ) { controller }

        service.pauseIfPlaying()
        service.resumeIfWePaused()
        scheduler.runPendingActions()

        XCTAssertEqual(controller.pauseCalls, 0)
        XCTAssertEqual(controller.playCalls, 0)
    }

    @MainActor
    func testMediaPlaybackServiceIgnoresStalePauseProbeAfterResume() {
        let controller = FakeMediaPlaybackController()
        let scheduler = TestMediaPlaybackResumeScheduler()
        var deferredCallback: ((_ snapshot: MediaPlaybackSnapshot?) -> Void)?
        controller.onGetPlaybackSnapshot = { callback in
            deferredCallback = callback
        }
        let service = MediaPlaybackService(
            startListening: false,
            resumeDelay: 0.6,
            resumeScheduler: scheduler.schedule(after:action:)
        ) { controller }

        service.pauseIfPlaying()
        service.resumeIfWePaused()
        deferredCallback?(FakeMediaPlaybackController.snapshot(isPlaying: true, playbackRate: 1))

        XCTAssertEqual(controller.pauseCalls, 0)
        XCTAssertEqual(controller.playCalls, 0)

        scheduler.runPendingActions()

        XCTAssertEqual(controller.pauseCalls, 0)
        XCTAssertEqual(controller.playCalls, 0)
    }

    @MainActor
    func testMediaPlaybackServiceCancelsPendingResumeWhenRecordingRestartsBeforeDelayElapses() {
        let controller = FakeMediaPlaybackController()
        let scheduler = TestMediaPlaybackResumeScheduler()
        controller.returnedSnapshot = FakeMediaPlaybackController.snapshot(isPlaying: true, playbackRate: 1)
        let service = MediaPlaybackService(
            startListening: false,
            resumeDelay: 0.6,
            resumeScheduler: scheduler.schedule(after:action:)
        ) { controller }

        service.pauseIfPlaying()
        scheduler.runNextAction()
        service.resumeIfWePaused()
        service.pauseIfPlaying()

        scheduler.runPendingActions()

        XCTAssertEqual(controller.pauseCalls, 1)
        XCTAssertEqual(controller.playCalls, 0)

        service.resumeIfWePaused()
        scheduler.runPendingActions()

        XCTAssertEqual(controller.playCalls, 1)
    }

    @MainActor
    func testMediaPlaybackServiceCoalescesDuplicateResumeRequestsIntoSinglePlay() {
        let controller = FakeMediaPlaybackController()
        let scheduler = TestMediaPlaybackResumeScheduler()
        controller.returnedSnapshot = FakeMediaPlaybackController.snapshot(isPlaying: true, playbackRate: 1)
        let service = MediaPlaybackService(
            startListening: false,
            resumeDelay: 0.6,
            resumeScheduler: scheduler.schedule(after:action:)
        ) { controller }

        service.pauseIfPlaying()
        scheduler.runNextAction()
        service.resumeIfWePaused()
        service.resumeIfWePaused()

        scheduler.runPendingActions()

        XCTAssertEqual(controller.pauseCalls, 1)
        XCTAssertEqual(controller.playCalls, 1)
    }
    #endif

    @MainActor
    func testApiStartRecording_showsSelectModelErrorWhenNoProviderIsSelected() async throws {
        let selectedEngineKey = UserDefaultsKeys.selectedEngine
        let originalSelection = UserDefaults.standard.object(forKey: selectedEngineKey)
        UserDefaults.standard.removeObject(forKey: selectedEngineKey)
        defer {
            if let originalSelection {
                UserDefaults.standard.set(originalSelection, forKey: selectedEngineKey)
            } else {
                UserDefaults.standard.removeObject(forKey: selectedEngineKey)
            }
        }

        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let modelManager = ModelManagerService()
        let audioRecordingService = AudioRecordingService()
        let hotkeyService = HotkeyService()
        let textInsertionService = TextInsertionService()
        let historyService = HistoryService(appSupportDirectory: appSupportDirectory)
        let recentTranscriptionStore = RecentTranscriptionStore()
        let profileService = ProfileService(appSupportDirectory: appSupportDirectory)
        let workflowService = WorkflowService(appSupportDirectory: appSupportDirectory)
        let audioDuckingService = AudioDuckingService()
        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        let snippetService = SnippetService(appSupportDirectory: appSupportDirectory)
        let soundService = SoundService()
        let originalSelectedInputDeviceUID = UserDefaults.standard.object(forKey: UserDefaultsKeys.selectedInputDeviceUID)
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.selectedInputDeviceUID)
        let audioDeviceService = AudioDeviceService()
        Self.restoreSelectedInputDeviceUID(originalSelectedInputDeviceUID)
        let promptActionService = PromptActionService(appSupportDirectory: appSupportDirectory)
        let promptProcessingService = PromptProcessingService()
        let appFormatterService = AppFormatterService()
        let punctuationProfileStore = DictationPunctuationProfileStore(
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            storageKey: UUID().uuidString
        )
        let punctuationRulesLoader = PunctuationRulesLoader()
        let punctuationStrategyResolver = PunctuationStrategyResolver(profileStore: punctuationProfileStore)
        let speechFeedbackService = SpeechFeedbackService()
        let accessibilityAnnouncementService = AccessibilityAnnouncementService()
        let errorLogService = ErrorLogService(appSupportDirectory: appSupportDirectory)
        let settingsViewModel = SettingsViewModel(modelManager: modelManager)

        let dictationViewModel = DictationViewModel(
            audioRecordingService: audioRecordingService,
            textInsertionService: textInsertionService,
            hotkeyService: hotkeyService,
            modelManager: modelManager,
            settingsViewModel: settingsViewModel,
            historyService: historyService,
            recentTranscriptionStore: recentTranscriptionStore,
            profileService: profileService,
            workflowService: workflowService,
            translationService: nil,
            audioDuckingService: audioDuckingService,
            dictionaryService: dictionaryService,
            snippetService: snippetService,
            soundService: soundService,
            audioDeviceService: audioDeviceService,
            promptActionService: promptActionService,
            promptProcessingService: promptProcessingService,
            appFormatterService: appFormatterService,
            punctuationStrategyResolver: punctuationStrategyResolver,
            speechPunctuationService: SpeechPunctuationService(rulesLoader: punctuationRulesLoader),
            speechFeedbackService: speechFeedbackService,
            accessibilityAnnouncementService: accessibilityAnnouncementService,
            errorLogService: errorLogService,
            mediaPlaybackService: MediaPlaybackService(startListening: false)
        )
        dictationViewModel.soundFeedbackEnabled = false
        dictationViewModel.spokenFeedbackEnabled = false

        _ = dictationViewModel.apiStartRecording()

        XCTAssertEqual(dictationViewModel.state, .inserting)
        XCTAssertEqual(
            dictationViewModel.actionFeedbackMessage,
            TranscriptionEngineError.modelNotLoaded.localizedDescription
        )
    }

    @MainActor
    func testApiStartRecording_showsNoMicDetectedErrorWhenSelectedInputUnavailable() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        let originalSelectedInputDeviceUID = UserDefaults.standard.object(forKey: UserDefaultsKeys.selectedInputDeviceUID)
        let originalPriorityList = UserDefaults.standard.object(forKey: UserDefaultsKeys.inputDevicePriorityList)
        let deviceID = AudioDeviceID(42)
        let transportResolver = FakeAudioDeviceTransportResolver(
            transports: [deviceID: kAudioDeviceTransportTypeUSB]
        ) { requestedDeviceID in
            XCTAssertEqual(requestedDeviceID, deviceID)
        }
        let selectionEngineValidator = FakeAudioInputSelectionEngineValidator { preferredDeviceID in
            XCTAssertEqual(preferredDeviceID, deviceID)
        }
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
            Self.restoreSelectedInputDeviceUID(originalSelectedInputDeviceUID)
            Self.restoreUserDefault(originalPriorityList, forKey: UserDefaultsKeys.inputDevicePriorityList)
        }

        dictationContext = Self.makeDictationContext(
            appSupportDirectory: appSupportDirectory,
            audioDeviceTransportResolver: transportResolver,
            audioDeviceSelectionEngineValidator: selectionEngineValidator
        )
        let context = try XCTUnwrap(dictationContext)
        context.audioDeviceService.inputDevices = [
            AudioInputDevice(deviceID: deviceID, name: "USB Mic", uid: "usb-input")
        ]
        context.audioDeviceService.audioDeviceIDResolverOverride = { uid in
            uid == "usb-input" ? deviceID : nil
        }
        context.audioDeviceService.selectedDeviceUID = "usb-input"
        context.audioRecordingService.hasMicrophonePermissionOverride = true
        context.audioRecordingService.inputAvailabilityOverride = { selectedDeviceID in
            XCTAssertEqual(selectedDeviceID, deviceID)
            return false
        }

        _ = context.dictationViewModel.apiStartRecording()

        XCTAssertEqual(context.dictationViewModel.state, .inserting)
        XCTAssertEqual(
            context.dictationViewModel.actionFeedbackMessage,
            try TestSupport.localizedCatalogValueForCurrentLocale(for: "No mic detected.")
        )
        XCTAssertTrue(context.ttsProvider.recordedRequests.isEmpty)
    }

    @MainActor
    func testApiStartRecording_preservesPermissionDeniedError() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
        }

        dictationContext = Self.makeDictationContext(appSupportDirectory: appSupportDirectory)
        let context = try XCTUnwrap(dictationContext)
        context.audioRecordingService.hasMicrophonePermissionOverride = false

        _ = context.dictationViewModel.apiStartRecording()

        XCTAssertEqual(context.dictationViewModel.state, .inserting)
        XCTAssertEqual(
            context.dictationViewModel.actionFeedbackMessage,
            "Microphone permission required."
        )
        XCTAssertTrue(context.ttsProvider.recordedRequests.isEmpty)
    }

    @MainActor
    func testApiStartRecording_doesNotSpeakStatusFeedback() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
        }

        dictationContext = Self.makeDictationContext(appSupportDirectory: appSupportDirectory)
        let context = try XCTUnwrap(dictationContext)
        context.dictationViewModel.spokenFeedbackEnabled = true
        context.audioRecordingService.hasMicrophonePermissionOverride = true
        context.audioRecordingService.inputAvailabilityOverride = { _ in true }
        context.audioRecordingService.startRecordingOverride = {}
        context.textInsertionService.captureActiveAppOverride = { ("Notes", nil, nil) }
        context.textInsertionService.selectedTextOverride = { nil }

        _ = context.dictationViewModel.apiStartRecording()

        XCTAssertEqual(context.dictationViewModel.state, .recording)
        XCTAssertTrue(context.ttsProvider.recordedRequests.isEmpty)
    }

    @MainActor
    func testApiStartRecordingError_doesNotSpeakStatusFeedback() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
        }

        dictationContext = Self.makeDictationContext(appSupportDirectory: appSupportDirectory)
        let context = try XCTUnwrap(dictationContext)
        context.dictationViewModel.spokenFeedbackEnabled = true
        context.audioRecordingService.hasMicrophonePermissionOverride = false

        _ = context.dictationViewModel.apiStartRecording()

        XCTAssertEqual(context.dictationViewModel.state, .inserting)
        XCTAssertTrue(context.ttsProvider.recordedRequests.isEmpty)
    }

    @MainActor
    func testModelManagerAutoSelectsConfiguredEngineAfterPluginCapabilityChange() async throws {
        let selectedEngineKey = UserDefaultsKeys.selectedEngine
        let originalSelection = UserDefaults.standard.object(forKey: selectedEngineKey)
        UserDefaults.standard.removeObject(forKey: selectedEngineKey)
        defer {
            if let originalSelection {
                UserDefaults.standard.set(originalSelection, forKey: selectedEngineKey)
            } else {
                UserDefaults.standard.removeObject(forKey: selectedEngineKey)
            }
        }

        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let plugin = ConfigurableTranscriptionPlugin()
        let manifest = PluginManifest(
            id: "com.typewhisper.mock.configurable-transcription",
            name: "Configurable Mock Transcription",
            version: "1.0.0",
            principalClass: "APIRouterConfigurableTranscriptionPlugin"
        )
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: manifest,
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let modelManager = ModelManagerService()
        modelManager.observePluginManager()
        XCTAssertNil(modelManager.selectedProviderId)

        plugin.currentModelId = "tiny"
        plugin.configured = true
        PluginManager.shared.notifyPluginStateChanged()

        let propagation = expectation(description: "plugin capability propagation")
        DispatchQueue.main.async {
            propagation.fulfill()
        }
        await fulfillment(of: [propagation], timeout: 1.0)

        XCTAssertEqual(modelManager.selectedProviderId, plugin.providerId)
    }

    @MainActor
    func testTranslationTargetLanguagesKeepScriptVariantsDistinct() {
        guard #available(macOS 15.0, *) else { return }

        let namesByCode = Dictionary(uniqueKeysWithValues: TranslationService.availableTargetLanguages.map { ($0.code, $0.name) })

        XCTAssertNotEqual(namesByCode["zh-Hans"], namesByCode["zh-Hant"])
    }

    func testLocalizedAppLanguageNameKeepsScriptVariantsDistinct() {
        XCTAssertNotEqual(localizedAppLanguageName(for: "zh-Hans"), localizedAppLanguageName(for: "zh-Hant"))
    }

    func testLocalizedAppLanguageBadgeDescriptorUsesNeutralLanguageCodes() {
        XCTAssertEqual(localizedAppLanguageBadgeDescriptor(for: "en").text, "EN")
        XCTAssertEqual(localizedAppLanguageBadgeDescriptor(for: "de").text, "DE")
        XCTAssertEqual(localizedAppLanguageBadgeDescriptor(for: "en-GB").text, "EN-GB")
        XCTAssertEqual(localizedAppLanguageBadgeDescriptor(for: "zh-Hans").text, "ZH-HANS")
        XCTAssertEqual(localizedAppLanguageBadgeDescriptor(for: "multi").text, "MULTI")
        XCTAssertEqual(localizedAppLanguageBadgeDescriptor(for: "en").accessibilityLabel, localizedAppLanguageName(for: "en"))
    }

    func testFeaturedAppLanguageRankPromotesCommonLanguages() {
        XCTAssertEqual(featuredAppLanguageRank(for: "de"), 0)
        XCTAssertEqual(featuredAppLanguageRank(for: "en"), 1)
        XCTAssertEqual(featuredAppLanguageRank(for: "fr"), 2)
        XCTAssertEqual(featuredAppLanguageRank(for: "es"), 3)
        XCTAssertEqual(featuredAppLanguageRank(for: "zh-Hans"), 4)
        XCTAssertNil(featuredAppLanguageRank(for: "cs"))
    }

    func testLanguageSelectionCodecSupportsLegacyAndHintValues() {
        XCTAssertEqual(LanguageSelection(storedValue: nil, nilBehavior: .auto), .auto)
        XCTAssertEqual(LanguageSelection(storedValue: nil, nilBehavior: .inheritGlobal), .inheritGlobal)
        XCTAssertEqual(LanguageSelection(storedValue: "auto", nilBehavior: .auto), .auto)
        XCTAssertEqual(LanguageSelection(storedValue: "de", nilBehavior: .auto), .exact("de"))
        XCTAssertEqual(LanguageSelection(storedValue: "zh", nilBehavior: .auto), .exact("zh"))
        XCTAssertEqual(
            LanguageSelection(storedValue: #"["de","en"]"#, nilBehavior: .auto),
            .hints(["de", "en"])
        )
    }

    func testProfileLanguageSelectionPersistsHintListsWithoutSchemaChanges() {
        let profile = Profile(name: "Hints")
        profile.inputLanguageSelection = .hints(["de", "en"])

        XCTAssertEqual(profile.inputLanguage, #"["de","en"]"#)
        XCTAssertEqual(profile.inputLanguageSelection, .hints(["de", "en"]))
    }

    func testLanguageSelectionMovesSelectedCodesInStoredOrder() {
        let selection = LanguageSelection.hints(["de", "en", "nl"])

        XCTAssertEqual(
            selection.withSelectedCodeMoved("nl", by: -1, nilBehavior: .auto),
            .hints(["de", "nl", "en"])
        )
        XCTAssertEqual(
            selection.withSelectedCodeMoved("de", droppedOn: "nl", nilBehavior: .auto),
            .hints(["en", "de", "nl"])
        )
        XCTAssertEqual(
            selection.withSelectedCodeMoved("nl", droppedOn: "de", nilBehavior: .auto),
            .hints(["nl", "de", "en"])
        )
    }

    func testLanguageSelectionNormalizesAgainstSupportedLanguages() {
        XCTAssertEqual(
            LanguageSelection.hints(["de", "en", "nl"]).normalizedForSupportedLanguages(["de", "nl"]),
            .hints(["de", "nl"])
        )
        XCTAssertEqual(
            LanguageSelection.hints(["de", "en"]).normalizedForSupportedLanguages(["de"]),
            .exact("de")
        )
        XCTAssertEqual(
            LanguageSelection.hints(["de", "en"]).normalizedForSupportedLanguages(["fr"]),
            .auto
        )
    }

    @MainActor
    func testSettingsViewModelAvailableLanguagesKeepsRegionalAndScriptVariantsDistinct() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let plugin = MockTranscriptionPlugin()
        plugin.languages = ["zh-Hans", "zh-Hant", "pt-BR", "pt-PT"]
        let manifest = PluginManifest(
            id: "com.typewhisper.mock.transcription",
            name: "Mock Transcription",
            version: "1.0.0",
            principalClass: "APIRouterMockTranscriptionPlugin"
        )
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: manifest,
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let settingsViewModel = SettingsViewModel(modelManager: ModelManagerService())
        let namesByCode = Dictionary(uniqueKeysWithValues: settingsViewModel.availableLanguages.map { ($0.code, $0.name) })

        XCTAssertNotEqual(namesByCode["zh-Hans"], namesByCode["zh-Hant"])
        XCTAssertNotEqual(namesByCode["pt-BR"], namesByCode["pt-PT"])
    }

    @MainActor
    private static func makeAPIContext(appSupportDirectory: URL, withMockTranscriptionPlugin: Bool = false) -> APIContext {
        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)
        let ttsProvider = MockTTSProviderPlugin()
        let ttsManifest = PluginManifest(
            id: "com.typewhisper.mock.tts",
            name: "Mock TTS",
            version: "1.0.0",
            principalClass: "APIRouterMockTTSPlugin",
            category: "tts"
        )

        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: ttsManifest,
                instance: ttsProvider,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let modelManager = ModelManagerService()
        if withMockTranscriptionPlugin {
            let mockPlugin = MockTranscriptionPlugin()
            let manifest = PluginManifest(
                id: "com.typewhisper.mock.transcription",
                name: "Mock Transcription",
                version: "1.0.0",
                principalClass: "APIRouterMockTranscriptionPlugin"
            )
            PluginManager.shared.loadedPlugins.append(
                LoadedPlugin(
                    manifest: manifest,
                    instance: mockPlugin,
                    bundle: Bundle.main,
                    sourceURL: appSupportDirectory,
                    isEnabled: true
                )
            )
            modelManager.selectProvider(mockPlugin.providerId)
        }
        let audioFileService = AudioFileService()
        let audioRecordingService = AudioRecordingService()
        let audioRecorderService = AudioRecorderService()
        audioRecorderService.recordingsDirectoryOverride = appSupportDirectory.appendingPathComponent("recordings")
        let hotkeyService = HotkeyService()
        let textInsertionService = TextInsertionService()
        let historyService = HistoryService(appSupportDirectory: appSupportDirectory)
        let recentTranscriptionStore = RecentTranscriptionStore()
        let profileService = ProfileService(appSupportDirectory: appSupportDirectory)
        let workflowService = WorkflowService(appSupportDirectory: appSupportDirectory)
        let audioDuckingService = AudioDuckingService()
        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        let snippetService = SnippetService(appSupportDirectory: appSupportDirectory)
        let soundService = SoundService()
        let audioDeviceService = AudioDeviceService()
        let promptActionService = PromptActionService(appSupportDirectory: appSupportDirectory)
        let promptProcessingService = PromptProcessingService()
        let appFormatterService = AppFormatterService()
        let punctuationProfileStore = DictationPunctuationProfileStore(
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            storageKey: UUID().uuidString
        )
        let punctuationRulesLoader = PunctuationRulesLoader()
        let punctuationStrategyResolver = PunctuationStrategyResolver(profileStore: punctuationProfileStore)
        let speechFeedbackService = SpeechFeedbackService()
        let accessibilityAnnouncementService = AccessibilityAnnouncementService()
        let errorLogService = ErrorLogService(appSupportDirectory: appSupportDirectory)
        let settingsViewModel = SettingsViewModel(modelManager: modelManager)

        let dictationViewModel = DictationViewModel(
            audioRecordingService: audioRecordingService,
            textInsertionService: textInsertionService,
            hotkeyService: hotkeyService,
            modelManager: modelManager,
            settingsViewModel: settingsViewModel,
            historyService: historyService,
            recentTranscriptionStore: recentTranscriptionStore,
            profileService: profileService,
            workflowService: workflowService,
            translationService: nil,
            audioDuckingService: audioDuckingService,
            dictionaryService: dictionaryService,
            snippetService: snippetService,
            soundService: soundService,
            audioDeviceService: audioDeviceService,
            promptActionService: promptActionService,
            promptProcessingService: promptProcessingService,
            appFormatterService: appFormatterService,
            punctuationStrategyResolver: punctuationStrategyResolver,
            speechPunctuationService: SpeechPunctuationService(rulesLoader: punctuationRulesLoader),
            speechFeedbackService: speechFeedbackService,
            accessibilityAnnouncementService: accessibilityAnnouncementService,
            errorLogService: errorLogService,
            mediaPlaybackService: MediaPlaybackService(startListening: false)
        )
        let audioRecorderViewModel = AudioRecorderViewModel(
            recorderService: audioRecorderService,
            modelManager: modelManager,
            dictionaryService: dictionaryService,
            audioDeviceService: audioDeviceService
        )

        let router = APIRouter()
        let handlers = APIHandlers(
            modelManager: modelManager,
            audioFileService: audioFileService,
            translationService: nil,
            historyService: historyService,
            workflowService: workflowService,
            dictionaryService: dictionaryService,
            dictationViewModel: dictationViewModel,
            audioRecorderViewModel: audioRecorderViewModel
        )
        handlers.register(on: router)

        return APIContext(
            router: router,
            modelManager: modelManager,
            historyService: historyService,
            profileService: profileService,
            workflowService: workflowService,
            dictionaryService: dictionaryService,
            dictationViewModel: dictationViewModel,
            audioRecordingService: audioRecordingService,
            audioRecorderViewModel: audioRecorderViewModel,
            audioRecorderService: audioRecorderService,
            textInsertionService: textInsertionService,
            ttsProvider: ttsProvider,
            retainedObjects: [
                PluginManager.shared,
                ttsProvider,
                modelManager,
                audioFileService,
                audioRecordingService,
                audioRecorderService,
                hotkeyService,
                textInsertionService,
                historyService,
                profileService,
                audioDuckingService,
                dictionaryService,
                snippetService,
                soundService,
                audioDeviceService,
                promptActionService,
                promptProcessingService,
                appFormatterService,
                speechFeedbackService,
                accessibilityAnnouncementService,
                errorLogService,
                settingsViewModel,
                dictationViewModel,
                audioRecorderViewModel,
                router,
                handlers
            ]
        )
    }

    private static func makeLongTerms(count: Int, length: Int) -> [String] {
        (1...count).map { index in
            let prefix = "Term\(index)-"
            let paddingLength = max(0, length - prefix.count)
            return prefix + String(repeating: "x", count: paddingLength)
        }
    }

    @MainActor
    func testCopyLastTranscriptionToClipboardUsesNewestSessionEntry() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
        }

        dictationContext = Self.makeDictationContext(appSupportDirectory: appSupportDirectory)
        let context = try XCTUnwrap(dictationContext)
        let pasteboard = NSPasteboard.withUniqueName()
        context.dictationViewModel.pasteboardProvider = { pasteboard }

        context.recentTranscriptionStore.recordTranscription(
            id: UUID(),
            finalText: "Newest session text",
            timestamp: Date(),
            appName: "Notes",
            appBundleIdentifier: "com.apple.Notes"
        )

        context.dictationViewModel.copyLastTranscriptionToClipboard()

        XCTAssertEqual(pasteboard.string(forType: .string), "Newest session text")
    }

    @MainActor
    func testCopyLastTranscriptionToClipboardFallsBackToHistory() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
        }

        dictationContext = Self.makeDictationContext(appSupportDirectory: appSupportDirectory)
        let context = try XCTUnwrap(dictationContext)
        let pasteboard = NSPasteboard.withUniqueName()
        context.dictationViewModel.pasteboardProvider = { pasteboard }

        context.historyService.addRecord(
            id: UUID(),
            rawText: "raw history text",
            finalText: "History fallback text",
            appName: "Safari",
            appBundleIdentifier: "com.apple.Safari",
            durationSeconds: 1,
            language: "en",
            engineUsed: "mock"
        )

        context.dictationViewModel.copyLastTranscriptionToClipboard()

        XCTAssertEqual(pasteboard.string(forType: .string), "History fallback text")
    }

    @MainActor
    func testCopyLastTranscriptionToClipboardIsNoOpWithoutEntries() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
        }

        dictationContext = Self.makeDictationContext(appSupportDirectory: appSupportDirectory)
        let context = try XCTUnwrap(dictationContext)
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("Existing", forType: .string)
        context.dictationViewModel.pasteboardProvider = { pasteboard }

        context.dictationViewModel.copyLastTranscriptionToClipboard()

        XCTAssertEqual(pasteboard.string(forType: .string), "Existing")
    }

    private final class DictationContext: @unchecked Sendable {
        let dictationViewModel: DictationViewModel
        let modelManager: ModelManagerService
        let audioRecordingService: AudioRecordingService
        let hotkeyService: HotkeyService
        let audioDeviceService: AudioDeviceService
        let audioDuckingService: AudioDuckingService
        let textInsertionService: TextInsertionService
        let historyService: HistoryService
        let recentTranscriptionStore: RecentTranscriptionStore
        let profileService: ProfileService
        let workflowService: WorkflowService
        let ttsProvider: MockTTSProviderPlugin
        private let retainedObjects: [AnyObject]

        init(
            dictationViewModel: DictationViewModel,
            modelManager: ModelManagerService,
            audioRecordingService: AudioRecordingService,
            hotkeyService: HotkeyService,
            audioDeviceService: AudioDeviceService,
            audioDuckingService: AudioDuckingService,
            textInsertionService: TextInsertionService,
            historyService: HistoryService,
            recentTranscriptionStore: RecentTranscriptionStore,
            profileService: ProfileService,
            workflowService: WorkflowService,
            ttsProvider: MockTTSProviderPlugin,
            retainedObjects: [AnyObject]
        ) {
            self.dictationViewModel = dictationViewModel
            self.modelManager = modelManager
            self.audioRecordingService = audioRecordingService
            self.hotkeyService = hotkeyService
            self.audioDeviceService = audioDeviceService
            self.audioDuckingService = audioDuckingService
            self.textInsertionService = textInsertionService
            self.historyService = historyService
            self.recentTranscriptionStore = recentTranscriptionStore
            self.profileService = profileService
            self.workflowService = workflowService
            self.ttsProvider = ttsProvider
            self.retainedObjects = retainedObjects
        }
    }

    @MainActor
    private static func makeDictationContext(
        appSupportDirectory: URL,
        audioDuckingService: AudioDuckingService? = nil,
        mediaPlaybackService: MediaPlaybackService? = nil,
        soundService: SoundService? = nil,
        audioDeviceTransportResolver: AudioDeviceTransportResolving = CoreAudioDeviceTransportResolver(),
        audioDeviceBluetoothInputRouteStabilizer: BluetoothInputRouteStabilizing = CoreAudioBluetoothInputRouteStabilizer(),
        audioDeviceSelectionEngineValidator: AudioInputSelectionEngineValidating = AVAudioInputSelectionEngineValidator(),
        audioRecordingBluetoothInputRouteStabilizer: BluetoothInputRouteStabilizing = CoreAudioBluetoothInputRouteStabilizer()
    ) -> DictationContext {
        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let mockPlugin = MockTranscriptionPlugin()
        let ttsProvider = MockTTSProviderPlugin()
        let manifest = PluginManifest(
            id: "com.typewhisper.mock.transcription",
            name: "Mock Transcription",
            version: "1.0.0",
            principalClass: "APIRouterMockTranscriptionPlugin"
        )
        let ttsManifest = PluginManifest(
            id: "com.typewhisper.mock.tts",
            name: "Mock TTS",
            version: "1.0.0",
            principalClass: "APIRouterMockTTSPlugin",
            category: "tts"
        )
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: ttsManifest,
                instance: ttsProvider,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            ),
            LoadedPlugin(
                manifest: manifest,
                instance: mockPlugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let modelManager = ModelManagerService()
        modelManager.selectProvider(mockPlugin.providerId)

        let audioRecordingService = AudioRecordingService(
            bluetoothInputRouteStabilizer: audioRecordingBluetoothInputRouteStabilizer
        )
        let hotkeyService = HotkeyService()
        let textInsertionService = TextInsertionService()
        let historyService = HistoryService(appSupportDirectory: appSupportDirectory)
        let recentTranscriptionStore = RecentTranscriptionStore()
        let profileService = ProfileService(appSupportDirectory: appSupportDirectory)
        let workflowService = WorkflowService(appSupportDirectory: appSupportDirectory)
        let audioDuckingService = audioDuckingService ?? AudioDuckingService()
        let dictionaryService = DictionaryService(appSupportDirectory: appSupportDirectory)
        let snippetService = SnippetService(appSupportDirectory: appSupportDirectory)
        let soundService = soundService ?? SoundService()
        let audioDeviceService = AudioDeviceService(
            transportResolver: audioDeviceTransportResolver,
            bluetoothInputRouteStabilizer: audioDeviceBluetoothInputRouteStabilizer,
            selectionEngineValidator: audioDeviceSelectionEngineValidator
        )
        let promptActionService = PromptActionService(appSupportDirectory: appSupportDirectory)
        let promptProcessingService = PromptProcessingService()
        let appFormatterService = AppFormatterService()
        let punctuationProfileStore = DictationPunctuationProfileStore(
            defaults: UserDefaults(suiteName: UUID().uuidString)!,
            storageKey: UUID().uuidString
        )
        let punctuationRulesLoader = PunctuationRulesLoader()
        let punctuationStrategyResolver = PunctuationStrategyResolver(profileStore: punctuationProfileStore)
        let speechFeedbackService = SpeechFeedbackService()
        let accessibilityAnnouncementService = AccessibilityAnnouncementService()
        let errorLogService = ErrorLogService(appSupportDirectory: appSupportDirectory)
        let settingsViewModel = SettingsViewModel(modelManager: modelManager)
        let mediaPlaybackService = mediaPlaybackService ?? MediaPlaybackService(startListening: false)

        let dictationViewModel = DictationViewModel(
            audioRecordingService: audioRecordingService,
            textInsertionService: textInsertionService,
            hotkeyService: hotkeyService,
            modelManager: modelManager,
            settingsViewModel: settingsViewModel,
            historyService: historyService,
            recentTranscriptionStore: recentTranscriptionStore,
            profileService: profileService,
            workflowService: workflowService,
            translationService: nil,
            audioDuckingService: audioDuckingService,
            dictionaryService: dictionaryService,
            snippetService: snippetService,
            soundService: soundService,
            audioDeviceService: audioDeviceService,
            promptActionService: promptActionService,
            promptProcessingService: promptProcessingService,
            appFormatterService: appFormatterService,
            punctuationStrategyResolver: punctuationStrategyResolver,
            speechPunctuationService: SpeechPunctuationService(rulesLoader: punctuationRulesLoader),
            speechFeedbackService: speechFeedbackService,
            accessibilityAnnouncementService: accessibilityAnnouncementService,
            errorLogService: errorLogService,
            mediaPlaybackService: mediaPlaybackService
        )
        dictationViewModel.soundFeedbackEnabled = false
        dictationViewModel.spokenFeedbackEnabled = false
        dictationViewModel.audioDuckingEnabled = false
        dictationViewModel.mediaPauseEnabled = false

        return DictationContext(
            dictationViewModel: dictationViewModel,
            modelManager: modelManager,
            audioRecordingService: audioRecordingService,
            hotkeyService: hotkeyService,
            audioDeviceService: audioDeviceService,
            audioDuckingService: audioDuckingService,
            textInsertionService: textInsertionService,
            historyService: historyService,
            recentTranscriptionStore: recentTranscriptionStore,
            profileService: profileService,
            workflowService: workflowService,
            ttsProvider: ttsProvider,
            retainedObjects: [
                EventBus.shared,
                PluginManager.shared,
                modelManager,
                audioRecordingService,
                hotkeyService,
                textInsertionService,
                historyService,
                recentTranscriptionStore,
                profileService,
                audioDuckingService,
                dictionaryService,
                snippetService,
                soundService,
                audioDeviceService,
                promptActionService,
                promptProcessingService,
                appFormatterService,
                speechFeedbackService,
                ttsProvider,
                accessibilityAnnouncementService,
                errorLogService,
                settingsViewModel,
                mediaPlaybackService,
                dictationViewModel
            ]
        )
    }

    private static func restoreSelectedInputDeviceUID(_ value: Any?) {
        if let value {
            UserDefaults.standard.set(value, forKey: UserDefaultsKeys.selectedInputDeviceUID)
        } else {
            UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.selectedInputDeviceUID)
        }
    }

    private static func restoreUserDefault(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private static func makeEmptyLLMFallbackDefaults() -> (suiteName: String, defaults: UserDefaults) {
        let suiteName = "APIRouterAndHandlersTests.LLMFallbacks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(Data("[]".utf8), forKey: UserDefaultsKeys.llmFallbackPriorityList)
        return (suiteName, defaults)
    }

    @MainActor
    private static func installLLMFallbackTestProviders(
        _ providers: [MockLLMProviderPlugin],
        appSupportDirectory: URL
    ) {
        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)
        PluginManager.shared.loadedPlugins = providers.enumerated().map { index, provider in
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.tests.llm-fallback.\(index)",
                    name: "LLM Fallback Test \(index)",
                    version: "1.0.0",
                    principalClass: "APIRouterMockLLMProviderPlugin"
                ),
                instance: provider,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        }
    }

    private static func multipartTranscribeBody(
        wavData: Data,
        boundary: String,
        fields: [(name: String, value: String)] = []
    ) -> Data {
        var body = Data()

        func append(_ string: String) {
            body.append(Data(string.utf8))
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"test.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(wavData)
        append("\r\n")

        for field in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n")
            append("\(field.value)\r\n")
        }

        append("--\(boundary)--\r\n")
        return body
    }

    private static func jsonObject(_ response: HTTPResponse) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: response.body)
        return try XCTUnwrap(object as? [String: Any])
    }

    @MainActor
    func testPromptProcessingInjectsMemoryByDefault() async throws {
        let providerKey = "llmProviderType"
        let modelKey = "llmCloudModel"
        let originalProvider = UserDefaults.standard.object(forKey: providerKey)
        let originalModel = UserDefaults.standard.object(forKey: modelKey)
        defer {
            if let originalProvider {
                UserDefaults.standard.set(originalProvider, forKey: providerKey)
            } else {
                UserDefaults.standard.removeObject(forKey: providerKey)
            }
            if let originalModel {
                UserDefaults.standard.set(originalModel, forKey: modelKey)
            } else {
                UserDefaults.standard.removeObject(forKey: modelKey)
            }
        }

        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let plugin = MockLLMProviderPlugin()
        plugin.models = [PluginModelInfo(id: "gemini-2.5-flash", displayName: "Gemini 2.5 Flash")]

        let manifest = PluginManifest(
            id: "com.typewhisper.mock.llm",
            name: "Mock LLM",
            version: "1.0.0",
            principalClass: "APIRouterMockLLMProviderPlugin"
        )
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: manifest,
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let memoryRetriever = MemoryRetrieverSpy()
        let service = PromptProcessingService()
        service.memoryService = memoryRetriever

        _ = try await service.process(
            prompt: "Fix grammar.",
            text: "hello world",
            providerOverride: "Gemini"
        )

        XCTAssertEqual(memoryRetriever.requestedTexts, ["hello world"])
        XCTAssertTrue(plugin.lastSystemPrompt?.contains("<memory_context>") == true)
        XCTAssertTrue(plugin.lastSystemPrompt?.contains("The user prefers concise wording.") == true)
        XCTAssertTrue(plugin.lastSystemPrompt?.contains("Fix grammar.") == true)
        XCTAssertEqual(plugin.lastUserText, "hello world")
    }

    @MainActor
    func testPromptProcessingUsesStableProviderIdsAndLegacyAliases() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }
        let suiteName = "APIRouterAndHandlersTests.LegacyLLMAlias.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let plugin = MockLLMProviderPlugin()
        plugin.configuredProviderName = "Alter"
        plugin.configuredProviderId = "openai-compatible:alter"
        plugin.configuredProviderDisplayName = "Alter"
        plugin.configuredProviderLegacyAliases = ["OpenAI Compatible"]
        plugin.models = [PluginModelInfo(id: "alter-chat", displayName: "Alter Chat")]

        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.llm.identity",
                    name: "Mock LLM Identity",
                    version: "1.0.0",
                    principalClass: "APIRouterMockLLMProviderPlugin"
                ),
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        defaults.set("OpenAI Compatible", forKey: "llmProviderType")
        let service = PromptProcessingService(userDefaults: defaults)
        service.validateSelectionAfterPluginLoad()

        XCTAssertEqual(service.selectedProviderId, "openai-compatible:alter")
        XCTAssertTrue(service.availableProviders.contains {
            $0.id == "openai-compatible:alter" && $0.displayName == "Alter"
        })

        _ = try await service.process(
            prompt: "Fix grammar.",
            text: "hello world",
            providerOverride: "OpenAI Compatible"
        )

        XCTAssertEqual(plugin.lastRequestedModel, "alter-chat")
    }

    @MainActor
    func testPluginManagerExpandsAdditionalProviderRoles() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let llmProvider = MockLLMProviderPlugin()
        llmProvider.configuredProviderName = "Inception"
        llmProvider.configuredProviderId = "openai-compatible:inception"
        llmProvider.configuredProviderDisplayName = "Inception"
        let engine = NamedTranscriptionPlugin(
            providerId: "openai-compatible:inception",
            providerDisplayName: "Inception",
            modelId: "inception-whisper"
        )
        let expandedPlugin = ExpandedRolePlugin(
            additionalLLMProviders: [llmProvider],
            additionalTranscriptionEngines: [engine]
        )

        let loaded = LoadedPlugin(
            manifest: PluginManifest(
                id: "com.typewhisper.mock.expanded-role",
                name: "Expanded Role Mock",
                version: "1.0.0",
                principalClass: "APIRouterExpandedRolePlugin"
            ),
            instance: expandedPlugin,
            bundle: Bundle.main,
            sourceURL: appSupportDirectory,
            isEnabled: true
        )
        PluginManager.shared.loadedPlugins = [loaded]

        XCTAssertEqual(
            PluginManager.shared.llmProvider(for: "openai-compatible:inception")?.llmProviderDisplayName,
            "Inception"
        )
        XCTAssertEqual(
            PluginManager.shared.transcriptionEngine(for: "openai-compatible:inception")?.providerDisplayName,
            "Inception"
        )
        XCTAssertEqual(
            PluginManager.shared.loadedTranscriptionPlugin(for: "openai-compatible:inception")?.manifest.id,
            loaded.manifest.id
        )
    }

    @MainActor
    func testPluginManagerPrioritizesLLMProviderIdOverAliases() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let aliasProvider = MockLLMProviderPlugin()
        aliasProvider.configuredProviderName = "Alias Provider"
        aliasProvider.configuredProviderId = "alias-provider"
        aliasProvider.configuredProviderDisplayName = "Alias Provider"
        aliasProvider.configuredProviderLegacyAliases = ["openai-compatible:inception"]

        let exactProvider = MockLLMProviderPlugin()
        exactProvider.configuredProviderName = "Exact Provider"
        exactProvider.configuredProviderId = "openai-compatible:inception"
        exactProvider.configuredProviderDisplayName = "Inception"

        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.alias-llm",
                    name: "Alias LLM",
                    version: "1.0.0",
                    principalClass: "APIRouterMockLLMProviderPlugin"
                ),
                instance: aliasProvider,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            ),
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.exact-llm",
                    name: "Exact LLM",
                    version: "1.0.0",
                    principalClass: "APIRouterMockLLMProviderPlugin"
                ),
                instance: exactProvider,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let resolved = try XCTUnwrap(PluginManager.shared.llmProvider(for: "openai-compatible:inception") as? MockLLMProviderPlugin)
        XCTAssertTrue(resolved === exactProvider)
    }

    @MainActor
    func testExpandedPluginFallbackIncludesAdditionalTranscriptionEngine() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let selectedEngineKey = UserDefaultsKeys.selectedEngine
        let originalSelection = UserDefaults.standard.object(forKey: selectedEngineKey)
        defer {
            if let originalSelection {
                UserDefaults.standard.set(originalSelection, forKey: selectedEngineKey)
            } else {
                UserDefaults.standard.removeObject(forKey: selectedEngineKey)
            }
        }

        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let fallbackEngine = MockTranscriptionPlugin()
        let expandedEngine = NamedTranscriptionPlugin(
            providerId: "openai-compatible:inception",
            providerDisplayName: "Inception",
            modelId: "inception-whisper"
        )
        let expandedPlugin = ExpandedRolePlugin(
            additionalLLMProviders: [],
            additionalTranscriptionEngines: [expandedEngine]
        )

        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.transcription",
                    name: "Mock Transcription",
                    version: "1.0.0",
                    principalClass: "APIRouterMockTranscriptionPlugin"
                ),
                instance: fallbackEngine,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            ),
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.expanded-role",
                    name: "Expanded Role Mock",
                    version: "1.0.0",
                    principalClass: "APIRouterExpandedRolePlugin"
                ),
                instance: expandedPlugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]
        UserDefaults.standard.set(expandedEngine.providerId, forKey: selectedEngineKey)

        let disabledProviderIds = PluginManager.shared.transcriptionProviderIds(exposedBy: expandedPlugin)
        let fallbackProviderId = PluginManager.shared.fallbackTranscriptionProviderId(disabling: disabledProviderIds)

        XCTAssertEqual(fallbackProviderId, fallbackEngine.providerId)
    }

    @MainActor
    func testWorkflowPromptProcessingSkipsMemoryAndUsesWorkflowBehavior() async throws {
        let providerKey = "llmProviderType"
        let modelKey = "llmCloudModel"
        let originalProvider = UserDefaults.standard.object(forKey: providerKey)
        let originalModel = UserDefaults.standard.object(forKey: modelKey)
        defer {
            if let originalProvider {
                UserDefaults.standard.set(originalProvider, forKey: providerKey)
            } else {
                UserDefaults.standard.removeObject(forKey: providerKey)
            }
            if let originalModel {
                UserDefaults.standard.set(originalModel, forKey: modelKey)
            } else {
                UserDefaults.standard.removeObject(forKey: modelKey)
            }
        }

        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let plugin = MockLLMProviderPlugin()
        plugin.models = [
            PluginModelInfo(id: "gemini-2.5-flash", displayName: "Gemini 2.5 Flash"),
            PluginModelInfo(id: "gemini-2.5-pro", displayName: "Gemini 2.5 Pro")
        ]

        let manifest = PluginManifest(
            id: "com.typewhisper.mock.llm",
            name: "Mock LLM",
            version: "1.0.0",
            principalClass: "APIRouterMockLLMProviderPlugin"
        )
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: manifest,
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let memoryRetriever = MemoryRetrieverSpy()
        let service = PromptProcessingService()
        service.memoryService = memoryRetriever

        let behavior = WorkflowBehavior(
            providerId: "Gemini",
            cloudModel: "gemini-2.5-pro",
            temperatureModeRaw: PluginLLMTemperatureMode.custom.rawValue,
            temperatureValue: 0.8
        )

        _ = try await service.processWorkflow(
            prompt: "Clean up the dictated text.",
            text: "hello world",
            behavior: behavior
        )

        XCTAssertTrue(memoryRetriever.requestedTexts.isEmpty)
        XCTAssertEqual(plugin.lastSystemPrompt, "Clean up the dictated text.")
        XCTAssertEqual(
            plugin.lastUserText,
            """
            BEGIN TYPEWHISPER DICTATED TEXT
            hello world
            END TYPEWHISPER DICTATED TEXT
            """
        )
        XCTAssertEqual(plugin.lastRequestedModel, "gemini-2.5-pro")
        XCTAssertEqual(plugin.lastTemperatureDirective, .custom(0.8))
    }

    @MainActor
    func testPromptProcessingFallsBackAfterRateLimitNetworkAndAPIErrors() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }
        let isolatedDefaults = Self.makeEmptyLLMFallbackDefaults()
        defer { isolatedDefaults.defaults.removePersistentDomain(forName: isolatedDefaults.suiteName) }

        let rateLimited = MockLLMProviderPlugin()
        rateLimited.configuredProviderId = "rate-limited"
        rateLimited.queuedProcessOutcomes = [.rateLimit]
        let networkFailed = MockLLMProviderPlugin()
        networkFailed.configuredProviderId = "network-failed"
        networkFailed.queuedProcessOutcomes = [.networkFailure]
        let apiFailed = MockLLMProviderPlugin()
        apiFailed.configuredProviderId = "api-failed"
        apiFailed.queuedProcessOutcomes = [.apiFailure("API rejected the request")]
        let succeeding = MockLLMProviderPlugin()
        succeeding.configuredProviderId = "succeeding"
        succeeding.queuedProcessOutcomes = [.response("fallback result")]

        Self.installLLMFallbackTestProviders(
            [rateLimited, networkFailed, apiFailed, succeeding],
            appSupportDirectory: appSupportDirectory
        )
        let service = PromptProcessingService(userDefaults: isolatedDefaults.defaults)
        for provider in [rateLimited, networkFailed, apiFailed, succeeding] {
            service.addLLMFallback(providerId: provider.providerId)
        }

        let result = try await service.process(prompt: "Fix grammar", text: "hello world")

        XCTAssertEqual(result, "fallback result")
        XCTAssertEqual(rateLimited.processCallCount, 1)
        XCTAssertEqual(networkFailed.processCallCount, 1)
        XCTAssertEqual(apiFailed.processCallCount, 1)
        XCTAssertEqual(succeeding.processCallCount, 1)
    }

    @MainActor
    func testPromptProcessingFallsBackAfterUnavailableLocalProviderCannotRestore() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }
        let isolatedDefaults = Self.makeEmptyLLMFallbackDefaults()
        defer { isolatedDefaults.defaults.removePersistentDomain(forName: isolatedDefaults.suiteName) }

        let unavailableLocal = MockLLMProviderPlugin()
        unavailableLocal.configuredProviderId = "unavailable-local"
        unavailableLocal.available = false
        unavailableLocal.requiresExternalCredentials = false
        unavailableLocal.unavailableReason = "The local model could not be restored."
        let succeeding = MockLLMProviderPlugin()
        succeeding.configuredProviderId = "remote-fallback"
        succeeding.queuedProcessOutcomes = [.response("remote fallback result")]

        Self.installLLMFallbackTestProviders([unavailableLocal, succeeding], appSupportDirectory: appSupportDirectory)
        let service = PromptProcessingService(userDefaults: isolatedDefaults.defaults)
        service.addLLMFallback(providerId: unavailableLocal.providerId)
        service.addLLMFallback(providerId: succeeding.providerId)

        let result = try await service.process(prompt: "Fix grammar", text: "hello world")

        XCTAssertEqual(result, "remote fallback result")
        XCTAssertEqual(unavailableLocal.restoreCount, 1)
        XCTAssertEqual(unavailableLocal.processCallCount, 0)
        XCTAssertEqual(succeeding.processCallCount, 1)
    }

    @MainActor
    func testPromptProcessingFallsBackWhenSavedProviderIsNoLongerInstalled() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }
        let isolatedDefaults = Self.makeEmptyLLMFallbackDefaults()
        defer { isolatedDefaults.defaults.removePersistentDomain(forName: isolatedDefaults.suiteName) }

        let succeeding = MockLLMProviderPlugin()
        succeeding.configuredProviderId = "installed-fallback"
        succeeding.queuedProcessOutcomes = [.response("installed fallback result")]

        Self.installLLMFallbackTestProviders([succeeding], appSupportDirectory: appSupportDirectory)
        let service = PromptProcessingService(userDefaults: isolatedDefaults.defaults)
        service.addLLMFallback(providerId: "removed-provider")
        service.addLLMFallback(providerId: succeeding.providerId)

        let result = try await service.process(prompt: "Fix grammar", text: "hello world")

        XCTAssertEqual(result, "installed fallback result")
        XCTAssertEqual(succeeding.processCallCount, 1)
    }

    @MainActor
    func testPromptProcessingFallsBackAfterEmptyResult() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }
        let isolatedDefaults = Self.makeEmptyLLMFallbackDefaults()
        defer { isolatedDefaults.defaults.removePersistentDomain(forName: isolatedDefaults.suiteName) }

        let empty = MockLLMProviderPlugin()
        empty.configuredProviderId = "empty-result"
        empty.queuedProcessOutcomes = [.response(" \n\t ")]
        let succeeding = MockLLMProviderPlugin()
        succeeding.configuredProviderId = "non-empty-result"
        succeeding.queuedProcessOutcomes = [.response("usable fallback result")]

        Self.installLLMFallbackTestProviders([empty, succeeding], appSupportDirectory: appSupportDirectory)
        let service = PromptProcessingService(userDefaults: isolatedDefaults.defaults)
        service.addLLMFallback(providerId: empty.providerId)
        service.addLLMFallback(providerId: succeeding.providerId)

        let result = try await service.process(prompt: "Fix grammar", text: "hello world")

        XCTAssertEqual(result, "usable fallback result")
        XCTAssertEqual(empty.processCallCount, 1)
        XCTAssertEqual(succeeding.processCallCount, 1)
    }

    @MainActor
    func testWorkflowProcessingFallsBackAfterScaffoldOnlyResult() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }
        let isolatedDefaults = Self.makeEmptyLLMFallbackDefaults()
        defer { isolatedDefaults.defaults.removePersistentDomain(forName: isolatedDefaults.suiteName) }

        let scaffoldOnly = MockLLMProviderPlugin()
        scaffoldOnly.configuredProviderId = "scaffold-only"
        scaffoldOnly.queuedProcessOutcomes = [
            .response(
                """
                BEGIN TYPEWHISPER DICTATED TEXT
                END TYPEWHISPER DICTATED TEXT
                """
            )
        ]
        let succeeding = MockLLMProviderPlugin()
        succeeding.configuredProviderId = "workflow-fallback"
        succeeding.queuedProcessOutcomes = [.response("usable workflow result")]

        Self.installLLMFallbackTestProviders([scaffoldOnly, succeeding], appSupportDirectory: appSupportDirectory)
        let service = PromptProcessingService(userDefaults: isolatedDefaults.defaults)
        service.addLLMFallback(providerId: scaffoldOnly.providerId)
        service.addLLMFallback(providerId: succeeding.providerId)

        let result = try await service.processWorkflow(
            prompt: "Fix grammar",
            text: "hello world",
            behavior: WorkflowBehavior()
        )

        XCTAssertEqual(result, "usable workflow result")
        XCTAssertEqual(scaffoldOnly.processCallCount, 1)
        XCTAssertEqual(succeeding.processCallCount, 1)
    }

    @MainActor
    func testPromptProcessingReportsAggregateErrorAfterFallbackListExhaustion() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }
        let isolatedDefaults = Self.makeEmptyLLMFallbackDefaults()
        defer { isolatedDefaults.defaults.removePersistentDomain(forName: isolatedDefaults.suiteName) }

        let rateLimited = MockLLMProviderPlugin()
        rateLimited.configuredProviderId = "rate-limited"
        rateLimited.queuedProcessOutcomes = [.rateLimit]
        let networkFailed = MockLLMProviderPlugin()
        networkFailed.configuredProviderId = "network-failed"
        networkFailed.queuedProcessOutcomes = [.networkFailure]

        Self.installLLMFallbackTestProviders([rateLimited, networkFailed], appSupportDirectory: appSupportDirectory)
        let service = PromptProcessingService(userDefaults: isolatedDefaults.defaults)
        service.addLLMFallback(providerId: rateLimited.providerId)
        service.addLLMFallback(providerId: networkFailed.providerId)

        do {
            _ = try await service.process(prompt: "Fix grammar", text: "hello world")
            XCTFail("Expected the fallback list to be exhausted")
        } catch let error as LLMFallbackExhaustedError {
            XCTAssertEqual(error.failures.map(\.providerId), ["rate-limited", "network-failed"])
            XCTAssertEqual(error.failures.count, 2)
            XCTAssertTrue(error.failures[0].reason.contains("429"))
            XCTAssertFalse(error.failures[1].reason.isEmpty)
        }
    }

    @MainActor
    func testExplicitWorkflowProviderDoesNotCallGlobalFallbackList() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }
        let isolatedDefaults = Self.makeEmptyLLMFallbackDefaults()
        defer { isolatedDefaults.defaults.removePersistentDomain(forName: isolatedDefaults.suiteName) }

        let explicit = MockLLMProviderPlugin()
        explicit.configuredProviderId = "strict-workflow-provider"
        explicit.queuedProcessOutcomes = [.apiFailure("Explicit workflow provider failed")]
        let fallback = MockLLMProviderPlugin()
        fallback.configuredProviderId = "global-fallback"
        fallback.queuedProcessOutcomes = [.response("must not be used")]

        Self.installLLMFallbackTestProviders([explicit, fallback], appSupportDirectory: appSupportDirectory)
        let service = PromptProcessingService(userDefaults: isolatedDefaults.defaults)
        service.addLLMFallback(providerId: fallback.providerId)

        do {
            _ = try await service.processWorkflow(
                prompt: "Fix grammar",
                text: "hello world",
                behavior: WorkflowBehavior(providerId: explicit.providerId)
            )
            XCTFail("Expected the explicit workflow provider error")
        } catch is LLMFallbackExhaustedError {
            XCTFail("An explicit workflow provider must not use the global fallback list")
        } catch {
            XCTAssertEqual(error.localizedDescription, "LLM error: Explicit workflow provider failed")
        }

        XCTAssertEqual(explicit.processCallCount, 1)
        XCTAssertEqual(fallback.processCallCount, 0)
    }

    @MainActor
    func testPromptProcessingCancellationDoesNotStartNextFallbackAttempt() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }
        let isolatedDefaults = Self.makeEmptyLLMFallbackDefaults()
        defer { isolatedDefaults.defaults.removePersistentDomain(forName: isolatedDefaults.suiteName) }

        let blocking = MockLLMProviderPlugin()
        blocking.configuredProviderId = "blocking"
        blocking.queuedProcessOutcomes = [.waitForCancellation]
        let fallback = MockLLMProviderPlugin()
        fallback.configuredProviderId = "must-not-start"
        fallback.queuedProcessOutcomes = [.response("must not be used")]

        Self.installLLMFallbackTestProviders([blocking, fallback], appSupportDirectory: appSupportDirectory)
        let service = PromptProcessingService(userDefaults: isolatedDefaults.defaults)
        service.addLLMFallback(providerId: blocking.providerId)
        service.addLLMFallback(providerId: fallback.providerId)

        let task = Task { @MainActor in
            try await service.process(prompt: "Fix grammar", text: "hello world")
        }
        for _ in 0..<100 {
            if blocking.processCallCount == 1 { break }
            await Task.yield()
        }
        XCTAssertEqual(blocking.processCallCount, 1)

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected prompt processing to be cancelled")
        } catch is CancellationError {
            // Expected: cancellation bypasses all remaining fallbacks.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        XCTAssertEqual(fallback.processCallCount, 0)
    }

    @MainActor
    func testPromptProcessingFallsBackWhenConfiguredModelIsUnavailable() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }
        let isolatedDefaults = Self.makeEmptyLLMFallbackDefaults()
        defer { isolatedDefaults.defaults.removePersistentDomain(forName: isolatedDefaults.suiteName) }

        let unavailableModel = MockLLMProviderPlugin()
        unavailableModel.configuredProviderId = "unavailable-model"
        unavailableModel.models = [
            PluginModelInfo(id: "gemini-2.5-flash", displayName: "Gemini 2.5 Flash"),
            PluginModelInfo(id: "gemini-2.5-pro", displayName: "Gemini 2.5 Pro")
        ]
        let fallback = MockLLMProviderPlugin()
        fallback.configuredProviderId = "model-fallback"
        fallback.queuedProcessOutcomes = [.response("fallback result")]
        Self.installLLMFallbackTestProviders(
            [unavailableModel, fallback],
            appSupportDirectory: appSupportDirectory
        )

        let service = PromptProcessingService(userDefaults: isolatedDefaults.defaults)
        service.addLLMFallback(
            providerId: unavailableModel.providerId,
            modelId: "legacy-direct-model"
        )
        service.addLLMFallback(providerId: fallback.providerId)
        let result = try await service.process(prompt: "Fix grammar", text: "hello world")

        XCTAssertEqual(result, "fallback result")
        XCTAssertEqual(unavailableModel.processCallCount, 0)
        XCTAssertEqual(fallback.processCallCount, 1)
    }

    @MainActor
    func testPromptProcessingDefersLocalAutoUnloadAcrossSameProviderFallbacks() async throws {
        let originalAutoUnload = UserDefaults.standard.object(forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
        defer {
            Self.restoreUserDefault(originalAutoUnload, forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
        }
        UserDefaults.standard.set(-1, forKey: UserDefaultsKeys.modelAutoUnloadSeconds)

        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }
        let isolatedDefaults = Self.makeEmptyLLMFallbackDefaults()
        defer { isolatedDefaults.defaults.removePersistentDomain(forName: isolatedDefaults.suiteName) }

        let local = MockLLMProviderPlugin()
        local.configuredProviderId = "multi-model-local"
        local.requiresExternalCredentials = false
        local.models = [
            PluginModelInfo(id: "first-model", displayName: "First Model"),
            PluginModelInfo(id: "second-model", displayName: "Second Model")
        ]
        local.queuedProcessOutcomes = [
            .apiFailure("First model failed"),
            .delayedResponse("second model result", milliseconds: 300)
        ]

        Self.installLLMFallbackTestProviders([local], appSupportDirectory: appSupportDirectory)
        let service = PromptProcessingService(userDefaults: isolatedDefaults.defaults)
        let modelManager = ModelManagerService()
        service.modelManagerService = modelManager
        service.addLLMFallback(providerId: local.providerId, modelId: "first-model")
        service.addLLMFallback(providerId: local.providerId, modelId: "second-model")
        modelManager.scheduleAutoUnloadIfNeeded(for: local)

        let processingTask = Task { @MainActor in
            try await service.process(prompt: "Fix grammar", text: "hello world")
        }
        for _ in 0..<100 where local.processCallCount < 2 {
            await Task.yield()
        }
        XCTAssertEqual(local.processCallCount, 2)

        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(local.autoUnloadCount, 0, "Auto-unload must wait until the fallback chain finishes")

        let processingResult = try await processingTask.value
        XCTAssertEqual(processingResult, "second model result")
        await waitForAutoUnloadCount(local, toBecome: 1)
    }

    @MainActor
    func testPromptProcessingIgnoresInvalidPromptOverrideWithoutPersistingIt() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }
        let isolatedDefaults = Self.makeEmptyLLMFallbackDefaults()
        defer { isolatedDefaults.defaults.removePersistentDomain(forName: isolatedDefaults.suiteName) }

        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let plugin = MockLLMProviderPlugin()
        plugin.models = [
            PluginModelInfo(id: "gemini-2.5-flash", displayName: "Gemini 2.5 Flash"),
            PluginModelInfo(id: "gemini-2.5-pro", displayName: "Gemini 2.5 Pro")
        ]

        let manifest = PluginManifest(
            id: "com.typewhisper.mock.llm",
            name: "Mock LLM",
            version: "1.0.0",
            principalClass: "APIRouterMockLLMProviderPlugin"
        )
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: manifest,
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let service = PromptProcessingService(userDefaults: isolatedDefaults.defaults)
        service.addLLMFallback(providerId: plugin.providerId, modelId: "gemini-2.5-pro")
        let result = try await service.process(
            prompt: "Fix grammar",
            text: "hello world",
            cloudModelOverride: "legacy-direct-model"
        )

        XCTAssertEqual(result, "processed")
        XCTAssertEqual(plugin.lastRequestedModel, "gemini-2.5-pro")
        XCTAssertEqual(service.selectedCloudModel, "gemini-2.5-pro")
        XCTAssertEqual(service.primaryFallbackItem?.modelId, "gemini-2.5-pro")
    }

    @MainActor
    func testPromptProcessingPassesTemperatureDirectiveToTemperatureAwareProvider() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }
        let isolatedDefaults = Self.makeEmptyLLMFallbackDefaults()
        defer { isolatedDefaults.defaults.removePersistentDomain(forName: isolatedDefaults.suiteName) }

        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let plugin = MockLLMProviderPlugin()
        plugin.models = [PluginModelInfo(id: "gemini-2.5-pro", displayName: "Gemini 2.5 Pro")]

        let manifest = PluginManifest(
            id: "com.typewhisper.mock.llm",
            name: "Mock LLM",
            version: "1.0.0",
            principalClass: "APIRouterMockLLMProviderPlugin"
        )
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: manifest,
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let service = PromptProcessingService(userDefaults: isolatedDefaults.defaults)
        service.addLLMFallback(providerId: plugin.providerId, modelId: "gemini-2.5-pro")
        _ = try await service.process(
            prompt: "Fix grammar",
            text: "hello world",
            temperatureDirective: .custom(0.8)
        )

        XCTAssertEqual(plugin.lastRequestedModel, "gemini-2.5-pro")
        XCTAssertEqual(plugin.lastTemperatureDirective, .custom(0.8))
    }

    @MainActor
    func testPromptProcessingAggregatesSetupFailureForLocalProviderWithoutLoadedModel() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }
        let isolatedDefaults = Self.makeEmptyLLMFallbackDefaults()
        defer { isolatedDefaults.defaults.removePersistentDomain(forName: isolatedDefaults.suiteName) }

        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let plugin = MockLLMProviderPlugin()
        plugin.available = false
        plugin.configuredProviderName = "Gemma 4 (MLX)"
        plugin.requiresExternalCredentials = false
        plugin.unavailableReason = "Load a Gemma 4 model in Integrations before using it for prompts."

        let manifest = PluginManifest(
            id: "com.typewhisper.mock.local-llm",
            name: "Mock Local LLM",
            version: "1.0.0",
            principalClass: "APIRouterMockLLMProviderPlugin"
        )
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: manifest,
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let service = PromptProcessingService(userDefaults: isolatedDefaults.defaults)
        service.addLLMFallback(providerId: plugin.providerId)

        do {
            _ = try await service.process(prompt: "Fix grammar", text: "hello world")
            XCTFail("Expected the fallback list to be exhausted")
        } catch let error as LLMFallbackExhaustedError {
            XCTAssertEqual(error.failures.map(\.providerId), [plugin.providerId])
            XCTAssertTrue(error.localizedDescription.contains("Load a Gemma 4 model"))
        } catch {
            XCTFail("Expected LLMFallbackExhaustedError, got \(error)")
        }
    }

    @MainActor
    func testPromptProcessingRestoresLocalProviderBeforeProcessingWhenModelWasAutoUnloaded() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let plugin = MockLLMProviderPlugin()
        plugin.available = false
        plugin.configuredProviderName = "Gemma 4 (MLX)"
        plugin.requiresExternalCredentials = false
        plugin.restoreMakesAvailable = true
        plugin.unavailableReason = "Load a Gemma 4 model in Integrations before using it for prompts."

        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.local-llm",
                    name: "Mock Local LLM",
                    version: "1.0.0",
                    principalClass: "APIRouterMockLLMProviderPlugin"
                ),
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let service = PromptProcessingService()
        let result = try await service.process(
            prompt: "Fix grammar",
            text: "hello world",
            providerOverride: "Gemma 4 (MLX)"
        )

        XCTAssertEqual(result, "processed")
        XCTAssertEqual(plugin.restoreCount, 1)
    }

    @MainActor
    func testPromptProcessingUsesHighPriorityActivityForLocalProviders() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let plugin = MockLLMProviderPlugin()
        plugin.configuredProviderName = "Gemma 4 (MLX)"
        plugin.requiresExternalCredentials = false

        let manifest = PluginManifest(
            id: "com.typewhisper.mock.local-llm",
            name: "Mock Local LLM",
            version: "1.0.0",
            principalClass: "APIRouterMockLLMProviderPlugin"
        )
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: manifest,
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let service = PromptProcessingService()
        let activityManager = ProcessActivityManagerSpy()
        service.processActivityManager = activityManager

        let result = try await service.process(
            prompt: "Fix grammar",
            text: "hello world",
            providerOverride: "Gemma 4 (MLX)"
        )

        XCTAssertEqual(result, "processed")
        XCTAssertEqual(activityManager.reasons, ["Local prompt processing with Gemma 4 (MLX)"])
    }

    @MainActor
    func testPromptProcessingSchedulesImmediateAutoUnloadForLocalProvider() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let originalAutoUnload = UserDefaults.standard.object(forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
        defer {
            if let originalAutoUnload {
                UserDefaults.standard.set(originalAutoUnload, forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
            } else {
                UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
            }
        }
        UserDefaults.standard.set(-1, forKey: UserDefaultsKeys.modelAutoUnloadSeconds)

        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let plugin = MockLLMProviderPlugin()
        plugin.configuredProviderName = "Gemma 4 (MLX)"
        plugin.requiresExternalCredentials = false

        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.local-llm",
                    name: "Mock Local LLM",
                    version: "1.0.0",
                    principalClass: "APIRouterMockLLMProviderPlugin"
                ),
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let modelManager = ModelManagerService()
        let service = PromptProcessingService()
        service.modelManagerService = modelManager

        let result = try await service.process(
            prompt: "Fix grammar",
            text: "hello world",
            providerOverride: "Gemma 4 (MLX)"
        )

        XCTAssertEqual(result, "processed")
        await waitForAutoUnloadCount(plugin, toBecome: 1)
    }

    @MainActor
    func testPromptProcessingDoesNotAutoUnloadRemoteProvider() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let originalAutoUnload = UserDefaults.standard.object(forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
        defer {
            if let originalAutoUnload {
                UserDefaults.standard.set(originalAutoUnload, forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
            } else {
                UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
            }
        }
        UserDefaults.standard.set(-1, forKey: UserDefaultsKeys.modelAutoUnloadSeconds)

        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let plugin = MockLLMProviderPlugin()
        plugin.configuredProviderName = "Gemini"
        plugin.requiresExternalCredentials = true

        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.llm",
                    name: "Mock LLM",
                    version: "1.0.0",
                    principalClass: "APIRouterMockLLMProviderPlugin"
                ),
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let modelManager = ModelManagerService()
        let service = PromptProcessingService()
        service.modelManagerService = modelManager

        let result = try await service.process(
            prompt: "Fix grammar",
            text: "hello world",
            providerOverride: "Gemini"
        )

        XCTAssertEqual(result, "processed")
        await assertAutoUnloadCount(plugin, remains: 0)
    }

    @MainActor
    func testPromptProcessingDoesNotAutoUnloadLocalProviderWhenDisabled() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let originalAutoUnload = UserDefaults.standard.object(forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
        defer {
            if let originalAutoUnload {
                UserDefaults.standard.set(originalAutoUnload, forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
            } else {
                UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
            }
        }
        UserDefaults.standard.set(0, forKey: UserDefaultsKeys.modelAutoUnloadSeconds)

        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let plugin = MockLLMProviderPlugin()
        plugin.configuredProviderName = "Gemma 4 (MLX)"
        plugin.requiresExternalCredentials = false

        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.local-llm",
                    name: "Mock Local LLM",
                    version: "1.0.0",
                    principalClass: "APIRouterMockLLMProviderPlugin"
                ),
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let modelManager = ModelManagerService()
        let service = PromptProcessingService()
        service.modelManagerService = modelManager

        let result = try await service.process(
            prompt: "Fix grammar",
            text: "hello world",
            providerOverride: "Gemma 4 (MLX)"
        )

        XCTAssertEqual(result, "processed")
        await assertAutoUnloadCount(plugin, remains: 0)
    }

    @MainActor
    func testModelAutoUnloadDefaultsToTenMinutesWhenUnset() throws {
        let originalAutoUnload = UserDefaults.standard.object(forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
        defer {
            if let originalAutoUnload {
                UserDefaults.standard.set(originalAutoUnload, forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
            } else {
                UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
            }
        }
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.modelAutoUnloadSeconds)

        let modelManager = ModelManagerService()

        XCTAssertEqual(ModelAutoUnloadPolicy.effectiveSeconds(), 600)
        XCTAssertEqual(modelManager.autoUnloadSeconds, 600)
        XCTAssertEqual(ModelAutoUnloadPolicy.policyName(seconds: modelManager.autoUnloadSeconds), "afterSeconds")
    }

    @MainActor
    func testModelAutoUnloadKeepsExplicitNever() throws {
        let originalAutoUnload = UserDefaults.standard.object(forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
        defer {
            if let originalAutoUnload {
                UserDefaults.standard.set(originalAutoUnload, forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
            } else {
                UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
            }
        }
        UserDefaults.standard.set(0, forKey: UserDefaultsKeys.modelAutoUnloadSeconds)

        let modelManager = ModelManagerService()

        XCTAssertEqual(ModelAutoUnloadPolicy.effectiveSeconds(), 0)
        XCTAssertEqual(modelManager.autoUnloadSeconds, 0)
        XCTAssertEqual(ModelAutoUnloadPolicy.policyName(seconds: modelManager.autoUnloadSeconds), "never")
    }

    @MainActor
    func testModelAutoUnloadPolicyOnlyNeverAllowsPassiveStartupRestore() throws {
        let suiteName = "ModelAutoUnloadPolicyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.removeObject(forKey: UserDefaultsKeys.modelAutoUnloadSeconds)

        XCTAssertFalse(ModelAutoUnloadPolicy.shouldRestoreLoadedModelsPassively(defaults: defaults))

        defaults.set(0, forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
        XCTAssertTrue(ModelAutoUnloadPolicy.shouldRestoreLoadedModelsPassively(defaults: defaults))

        for activePolicySeconds in [-1, 120, 300, 600, 1800, 3600] {
            defaults.set(activePolicySeconds, forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
            XCTAssertFalse(
                ModelAutoUnloadPolicy.shouldRestoreLoadedModelsPassively(defaults: defaults),
                "Policy \(activePolicySeconds) should lazy-load models after startup"
            )
        }
    }

    @MainActor
    func testHostServicesSuppressesInheritedPassiveLoadedModelRestoreForLegacyPluginActivation() async throws {
        let originalAutoUnload = UserDefaults.standard.object(forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
        let pluginId = "com.typewhisper.tests.legacy.\(UUID().uuidString)"
        let loadedModelKey = "plugin.\(pluginId).loadedModel"
        defer {
            if let originalAutoUnload {
                UserDefaults.standard.set(originalAutoUnload, forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
            } else {
                UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
            }
            UserDefaults.standard.removeObject(forKey: loadedModelKey)
        }

        UserDefaults.standard.set(600, forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
        UserDefaults.standard.set("legacy-loaded-model", forKey: loadedModelKey)
        let host = HostServicesImpl(
            pluginId: pluginId,
            eventBus: MockEventBus(),
            ruleNamesProvider: { [] }
        )
        defer { try? FileManager.default.removeItem(at: host.pluginDataDirectory) }

        var inheritedRestoreTask: Task<String?, Never>?
        host.performPluginActivation(suppressPassiveLoadedModelRestore: true) {
            XCTAssertEqual(host.userDefault(forKey: "loadedModel") as? String, "legacy-loaded-model")
            inheritedRestoreTask = Task {
                host.userDefault(forKey: "loadedModel") as? String
            }
        }

        let task = try XCTUnwrap(inheritedRestoreTask)
        let observedLoadedModel = await task.value
        XCTAssertNil(observedLoadedModel)
        XCTAssertEqual(host.userDefault(forKey: "loadedModel") as? String, "legacy-loaded-model")
    }

    @MainActor
    func testHostServicesAllowsInheritedPassiveLoadedModelRestoreWhenAutoUnloadIsNever() async throws {
        let originalAutoUnload = UserDefaults.standard.object(forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
        let pluginId = "com.typewhisper.tests.never.\(UUID().uuidString)"
        let loadedModelKey = "plugin.\(pluginId).loadedModel"
        defer {
            if let originalAutoUnload {
                UserDefaults.standard.set(originalAutoUnload, forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
            } else {
                UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
            }
            UserDefaults.standard.removeObject(forKey: loadedModelKey)
        }

        UserDefaults.standard.set(0, forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
        UserDefaults.standard.set("legacy-loaded-model", forKey: loadedModelKey)
        let host = HostServicesImpl(
            pluginId: pluginId,
            eventBus: MockEventBus(),
            ruleNamesProvider: { [] }
        )
        defer { try? FileManager.default.removeItem(at: host.pluginDataDirectory) }

        var inheritedRestoreTask: Task<String?, Never>?
        host.performPluginActivation(suppressPassiveLoadedModelRestore: true) {
            inheritedRestoreTask = Task {
                host.userDefault(forKey: "loadedModel") as? String
            }
        }

        let task = try XCTUnwrap(inheritedRestoreTask)
        let observedLoadedModel = await task.value
        XCTAssertEqual(observedLoadedModel, "legacy-loaded-model")
    }

    @MainActor
    func testModelManagerAutoUnloadsAvailableLocalLLMWithoutPromptProcessing() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let originalAutoUnload = UserDefaults.standard.object(forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
        defer {
            if let originalAutoUnload {
                UserDefaults.standard.set(originalAutoUnload, forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
            } else {
                UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
            }
        }
        UserDefaults.standard.set(-1, forKey: UserDefaultsKeys.modelAutoUnloadSeconds)

        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let plugin = MockLLMProviderPlugin()
        plugin.configuredProviderName = "Gemma 4 (MLX)"
        plugin.requiresExternalCredentials = false

        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.local-llm",
                    name: "Mock Local LLM",
                    version: "1.0.0",
                    principalClass: "APIRouterMockLLMProviderPlugin"
                ),
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let modelManager = ModelManagerService()
        modelManager.scheduleAutoUnloadIfNeeded()

        let scheduledSnapshot = modelManager.autoUnloadDiagnosticsSnapshot()
        let scheduledEntry = try XCTUnwrap(scheduledSnapshot.entries.first)
        XCTAssertEqual(scheduledSnapshot.policySeconds, -1)
        XCTAssertEqual(scheduledSnapshot.policyName, "immediate")
        XCTAssertEqual(scheduledEntry.pluginClassName, "MockLLMProviderPlugin")
        XCTAssertNotNil(scheduledEntry.scheduledAt)
        XCTAssertNotNil(scheduledEntry.dueAt)
        XCTAssertNil(scheduledEntry.lastFiredAt)
        XCTAssertNil(scheduledEntry.lastSelectorResponded)

        await waitForAutoUnloadCount(plugin, toBecome: 1)

        let firedSnapshot = modelManager.autoUnloadDiagnosticsSnapshot()
        let firedEntry = try XCTUnwrap(firedSnapshot.entries.first)
        XCTAssertNil(firedEntry.scheduledAt)
        XCTAssertNil(firedEntry.dueAt)
        XCTAssertNotNil(firedEntry.lastFiredAt)
        XCTAssertEqual(firedEntry.lastSelectorResponded, true)
    }

    @MainActor
    func testModelManagerCancelsAutoUnloadWhenLocalLLMBecomesUnavailable() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let originalAutoUnload = UserDefaults.standard.object(forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
        defer {
            if let originalAutoUnload {
                UserDefaults.standard.set(originalAutoUnload, forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
            } else {
                UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
            }
        }
        UserDefaults.standard.set(-1, forKey: UserDefaultsKeys.modelAutoUnloadSeconds)

        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let plugin = MockLLMProviderPlugin()
        plugin.configuredProviderName = "Gemma 4 (MLX)"
        plugin.requiresExternalCredentials = false

        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.local-llm",
                    name: "Mock Local LLM",
                    version: "1.0.0",
                    principalClass: "APIRouterMockLLMProviderPlugin"
                ),
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let modelManager = ModelManagerService()
        modelManager.scheduleAutoUnloadIfNeeded()

        plugin.available = false
        modelManager.scheduleAutoUnloadIfNeeded()

        await assertAutoUnloadCount(plugin, remains: 0)
    }

    @MainActor
    func testModelManagerSkipsRemoteAndUnavailableLLMProviders() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let originalAutoUnload = UserDefaults.standard.object(forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
        defer {
            if let originalAutoUnload {
                UserDefaults.standard.set(originalAutoUnload, forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
            } else {
                UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.modelAutoUnloadSeconds)
            }
        }
        UserDefaults.standard.set(-1, forKey: UserDefaultsKeys.modelAutoUnloadSeconds)

        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let remotePlugin = MockLLMProviderPlugin()
        remotePlugin.configuredProviderName = "Gemini"
        remotePlugin.requiresExternalCredentials = true

        let unavailableLocalPlugin = MockLLMProviderPlugin()
        unavailableLocalPlugin.configuredProviderName = "Gemma 4 (MLX)"
        unavailableLocalPlugin.requiresExternalCredentials = false
        unavailableLocalPlugin.available = false

        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.remote-llm",
                    name: "Mock Remote LLM",
                    version: "1.0.0",
                    principalClass: "APIRouterMockLLMProviderPlugin"
                ),
                instance: remotePlugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            ),
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.unavailable-local-llm",
                    name: "Mock Unavailable Local LLM",
                    version: "1.0.0",
                    principalClass: "APIRouterMockLLMProviderPlugin"
                ),
                instance: unavailableLocalPlugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            ),
        ]

        let modelManager = ModelManagerService()
        modelManager.scheduleAutoUnloadIfNeeded()

        await assertAutoUnloadCount(remotePlugin, remains: 0)
        await assertAutoUnloadCount(unavailableLocalPlugin, remains: 0)
    }

    @MainActor
    func testPromptProcessingSkipsHighPriorityActivityForRemoteProviders() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let plugin = MockLLMProviderPlugin()
        plugin.configuredProviderName = "Gemini"
        plugin.requiresExternalCredentials = true

        let manifest = PluginManifest(
            id: "com.typewhisper.mock.llm",
            name: "Mock LLM",
            version: "1.0.0",
            principalClass: "APIRouterMockLLMProviderPlugin"
        )
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: manifest,
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let service = PromptProcessingService()
        let activityManager = ProcessActivityManagerSpy()
        service.processActivityManager = activityManager

        let result = try await service.process(
            prompt: "Fix grammar",
            text: "hello world",
            providerOverride: "Gemini"
        )

        XCTAssertEqual(result, "processed")
        XCTAssertTrue(activityManager.reasons.isEmpty)
    }

    @MainActor
    func testPromptProcessingRequiresProcessActivityOnlyForLocalProviders() {
        let remotePlugin = MockLLMProviderPlugin()
        remotePlugin.requiresExternalCredentials = true

        let localPlugin = MockLLMProviderPlugin()
        localPlugin.requiresExternalCredentials = false

        let legacyPlugin = MockLegacyLLMProviderPlugin()

        XCTAssertFalse(PromptProcessingService.requiresProcessActivityBudget(for: remotePlugin))
        XCTAssertTrue(PromptProcessingService.requiresProcessActivityBudget(for: localPlugin))
        XCTAssertFalse(PromptProcessingService.requiresProcessActivityBudget(for: legacyPlugin))
    }

    @MainActor
    func testGeminiPluginCompatibleModelDecodingNormalizesIdsAndFiltersToChatModels() throws {
        let response = Data(
            """
            {
              "object": "list",
              "data": [
                { "id": "models/gemini-2.5-pro", "object": "model", "display_name": "Gemini 2.5 Pro" },
                { "id": "models/gemini-3-flash-preview", "object": "model", "display_name": "Gemini 3 Flash Preview" },
                { "id": "models/gemini-2.5-flash-image", "object": "model", "display_name": "Nano Banana" },
                { "id": "models/gemini-embedding-2-preview", "object": "model", "display_name": "Gemini Embedding 2 Preview" },
                { "id": "models/gemini-2.5-flash-native-audio-latest", "object": "model", "display_name": "Gemini 2.5 Flash Native Audio Latest" },
                { "id": "models/gemma-4-31b-it", "object": "model", "display_name": "Gemma 4 31B IT" }
              ]
            }
            """.utf8
        )

        let models = try GeminiPlugin.decodeCompatibleLLMModels(from: response)

        XCTAssertEqual(models.map(\.id), ["gemini-2.5-pro", "gemini-3-flash-preview"])
        XCTAssertEqual(models.first?.displayName, "Gemini 2.5 Pro")
        XCTAssertEqual(models.last?.displayName, "Gemini 3 Flash Preview")
    }

    @MainActor
    func testGeminiPluginActivationIgnoresLegacyCacheAndDoesNotExposeInvalidSelection() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let legacyCache = try JSONEncoder().encode([
            GeminiFetchedModel(id: "gemini-1.5-pro", displayName: "Gemini 1.5 Pro")
        ])
        let host = MockHostServices(
            pluginDataDirectory: appSupportDirectory,
            defaults: [
                "fetchedLLMModels": legacyCache,
                "selectedLLMModel": "gemini-1.5-pro"
            ]
        )
        let plugin = GeminiPlugin()

        plugin.activate(host: host)

        XCTAssertEqual(plugin.supportedModels.map(\.id), ["gemini-flash-latest", "gemini-pro-latest", "gemini-flash-lite-latest"])
        XCTAssertNil(host.userDefault(forKey: "fetchedLLMModels"), "legacy cache key must be cleared")
        // A stored selection that is not in the current model list is neither
        // exposed as a selection nor rewritten to a fallback; it stays
        // persisted so it can re-validate once models are fetched again.
        XCTAssertNil(plugin.selectedLLMModelId)
        XCTAssertEqual(host.userDefault(forKey: "selectedLLMModel") as? String, "gemini-1.5-pro")
    }

    @MainActor
    func testCloudModelOverrideDoesNotPersistPluginDefault() async throws {
        let selectedEngineKey = UserDefaultsKeys.selectedEngine
        let originalSelection = UserDefaults.standard.object(forKey: selectedEngineKey)
        UserDefaults.standard.removeObject(forKey: selectedEngineKey)
        defer {
            if let originalSelection {
                UserDefaults.standard.set(originalSelection, forKey: selectedEngineKey)
            } else {
                UserDefaults.standard.removeObject(forKey: selectedEngineKey)
            }
        }

        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let plugin = ConfigurableTranscriptionPlugin()
        plugin.currentModelId = "alpha"
        plugin.configured = true

        let manifest = PluginManifest(
            id: "com.typewhisper.mock.configurable-transcription",
            name: "Configurable Mock Transcription",
            version: "1.0.0",
            principalClass: "APIRouterConfigurableTranscriptionPlugin"
        )
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: manifest,
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let modelManager = ModelManagerService()
        modelManager.selectProvider(plugin.providerId)

        XCTAssertEqual(plugin.selectedModelId, "alpha")

        _ = try await modelManager.transcribe(
            audioSamples: [Float](repeating: 0, count: 16_000),
            language: nil,
            task: .transcribe,
            engineOverrideId: nil,
            cloudModelOverride: "beta",
            prompt: nil
        )

        XCTAssertEqual(plugin.selectedModelId, "alpha", "cloudModelOverride must not persist the plugin's default model")
    }

    @MainActor
    func testModelManagerWaitsForBusyTranscriptionRestorePastInitialTimeout() async throws {
        let selectedEngineKey = UserDefaultsKeys.selectedEngine
        let originalSelection = UserDefaults.standard.object(forKey: selectedEngineKey)
        UserDefaults.standard.removeObject(forKey: selectedEngineKey)
        defer {
            if let originalSelection {
                UserDefaults.standard.set(originalSelection, forKey: selectedEngineKey)
            } else {
                UserDefaults.standard.removeObject(forKey: selectedEngineKey)
            }
        }

        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let plugin = RestoringTranscriptionPlugin()
        plugin.currentModelId = "tiny"
        plugin.configured = false
        plugin.activity = PluginSettingsActivity(message: "Optimizing model")
        plugin.restoreDelay = .milliseconds(60)

        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.restoring-transcription",
                    name: "Restoring Mock Transcription",
                    version: "1.0.0",
                    principalClass: "APIRouterRestoringTranscriptionPlugin"
                ),
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let modelManager = ModelManagerService()
        modelManager.setPluginRestoreWaitConfigurationForTesting(
            initialAttempts: 1,
            busyAttempts: 20,
            pollInterval: .milliseconds(10)
        )
        modelManager.selectProvider(plugin.providerId)

        let result = try await modelManager.transcribe(
            audioSamples: [Float](repeating: 0, count: 16_000),
            language: nil,
            task: .transcribe,
            engineOverrideId: nil,
            cloudModelOverride: nil,
            prompt: nil
        )

        XCTAssertEqual(result.text, "transcribed")
        XCTAssertEqual(plugin.restoreCount, 1)
    }

    @MainActor
    func testModelManagerReportsBusyRestoreTimeoutInsteadOfGenericNoModelLoaded() async throws {
        let selectedEngineKey = UserDefaultsKeys.selectedEngine
        let originalSelection = UserDefaults.standard.object(forKey: selectedEngineKey)
        UserDefaults.standard.removeObject(forKey: selectedEngineKey)
        defer {
            if let originalSelection {
                UserDefaults.standard.set(originalSelection, forKey: selectedEngineKey)
            } else {
                UserDefaults.standard.removeObject(forKey: selectedEngineKey)
            }
        }

        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let plugin = RestoringTranscriptionPlugin()
        plugin.currentModelId = "tiny"
        plugin.configured = false
        plugin.activity = PluginSettingsActivity(message: "Optimizing model")
        plugin.restoreShouldConfigure = false

        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.restoring-transcription",
                    name: "Restoring Mock Transcription",
                    version: "1.0.0",
                    principalClass: "APIRouterRestoringTranscriptionPlugin"
                ),
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let modelManager = ModelManagerService()
        modelManager.setPluginRestoreWaitConfigurationForTesting(
            initialAttempts: 1,
            busyAttempts: 2,
            pollInterval: .milliseconds(10)
        )
        modelManager.selectProvider(plugin.providerId)

        do {
            _ = try await modelManager.transcribe(
                audioSamples: [Float](repeating: 0, count: 16_000),
                language: nil,
                task: .transcribe,
                engineOverrideId: nil,
                cloudModelOverride: nil,
                prompt: nil
            )
            XCTFail("Expected restore timeout")
        } catch let error as TranscriptionEngineError {
            guard case .modelLoadFailed(let detail) = error else {
                return XCTFail("Expected modelLoadFailed, got \(error)")
            }
            XCTAssertTrue(detail.contains("Optimizing model"), "Expected activity in detail, got \(detail)")
            XCTAssertFalse(error.localizedDescription.contains("No model loaded"))
        }

        XCTAssertEqual(plugin.restoreCount, 1)
    }

    @MainActor
    func testModelManagerPreservesStructuredSpeakerSegmentsWhenPluginOptsIn() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let plugin = StructuredTranscriptionPlugin()
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.structured-transcription",
                    name: "Structured Mock Transcription",
                    version: "1.0.0",
                    principalClass: "APIRouterStructuredTranscriptionPlugin"
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
            audioSamples: [Float](repeating: 0, count: 16_000),
            language: "en",
            task: .transcribe,
            engineOverrideId: nil,
            cloudModelOverride: nil,
            prompt: nil
        )

        XCTAssertEqual(result.text, "Speaker A: Hello\nSpeaker B: Hi")
        XCTAssertEqual(result.segments.map(\.speakerLabel), ["Speaker A", "Speaker B"])
        XCTAssertEqual(result.segments.first?.speakerConfidence, 0.9)
    }

    @MainActor
    func testModelManagerKeepsLegacyTranscriptionSegmentsSpeakerless() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let plugin = LegacySegmentTranscriptionPlugin()
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.legacy-segment-transcription",
                    name: "Legacy Segment Mock Transcription",
                    version: "1.0.0",
                    principalClass: "APIRouterLegacySegmentTranscriptionPlugin"
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
            audioSamples: [Float](repeating: 0, count: 16_000),
            language: "en",
            task: .transcribe,
            engineOverrideId: nil,
            cloudModelOverride: nil,
            prompt: nil
        )

        XCTAssertEqual(result.segments.map(\.text), ["legacy segment"])
        XCTAssertNil(result.segments.first?.speakerLabel)
        XCTAssertNil(result.segments.first?.speakerConfidence)
    }

    @MainActor
    func testTranscribeRejectsUnknownEngineOverride() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        MockTranscriptionPlugin.reset()
        let context = Self.makeAPIContext(
            appSupportDirectory: appSupportDirectory,
            withMockTranscriptionPlugin: true
        )

        let wavData = WavEncoder.encode(Array(repeating: Float(0), count: 1600))
        let boundary = "TestBoundary-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"test.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"engine\"\r\n\r\n".data(using: .utf8)!)
        body.append("nonexistent-engine\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let response = await context.router.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/transcribe",
                queryParams: [:],
                headers: ["content-type": "multipart/form-data; boundary=\(boundary)"],
                body: body
            )
        )

        XCTAssertEqual(response.status, 400)
        let json = try Self.jsonObject(response)
        let message = (json["error"] as? [String: Any])?["message"] as? String ?? ""
        XCTAssertTrue(message.contains("Unknown engine"), "Expected 'Unknown engine' in message, got: \(message)")
    }

    @MainActor
    func testTranscribeRejectsUnknownModelOverride() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        MockTranscriptionPlugin.reset()
        let context = Self.makeAPIContext(
            appSupportDirectory: appSupportDirectory,
            withMockTranscriptionPlugin: true
        )

        let wavData = WavEncoder.encode(Array(repeating: Float(0), count: 1600))
        let boundary = "TestBoundary-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"test.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("definitely-not-a-real-model\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let response = await context.router.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/transcribe",
                queryParams: [:],
                headers: ["content-type": "multipart/form-data; boundary=\(boundary)"],
                body: body
            )
        )

        XCTAssertEqual(response.status, 400)
        let json = try Self.jsonObject(response)
        let message = (json["error"] as? [String: Any])?["message"] as? String ?? ""
        XCTAssertTrue(message.contains("Unknown model"), "Expected 'Unknown model' in message, got: \(message)")
    }

    @MainActor
    func testTranscribeRejectsAmbiguousModelOverride() async throws {
        let selectedEngineKey = UserDefaultsKeys.selectedEngine
        let originalSelection = UserDefaults.standard.object(forKey: selectedEngineKey)
        UserDefaults.standard.removeObject(forKey: selectedEngineKey)
        defer {
            if let originalSelection {
                UserDefaults.standard.set(originalSelection, forKey: selectedEngineKey)
            } else {
                UserDefaults.standard.removeObject(forKey: selectedEngineKey)
            }
        }

        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        MockTranscriptionPlugin.reset()
        let context = Self.makeAPIContext(
            appSupportDirectory: appSupportDirectory,
            withMockTranscriptionPlugin: true
        )

        // Add a second plugin that advertises the same model id "tiny", making it ambiguous.
        let configurable = ConfigurableTranscriptionPlugin()
        configurable.currentModelId = "tiny"
        configurable.configured = true
        let configurableManifest = PluginManifest(
            id: "com.typewhisper.mock.configurable-transcription",
            name: "Configurable Mock Transcription",
            version: "1.0.0",
            principalClass: "APIRouterConfigurableTranscriptionPlugin"
        )
        PluginManager.shared.loadedPlugins.append(
            LoadedPlugin(
                manifest: configurableManifest,
                instance: configurable,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        )

        let wavData = WavEncoder.encode(Array(repeating: Float(0), count: 1600))
        let boundary = "TestBoundary-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"test.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("tiny\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let response = await context.router.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/transcribe",
                queryParams: [:],
                headers: ["content-type": "multipart/form-data; boundary=\(boundary)"],
                body: body
            )
        )

        XCTAssertEqual(response.status, 400)
        let json = try Self.jsonObject(response)
        let message = (json["error"] as? [String: Any])?["message"] as? String ?? ""
        XCTAssertTrue(message.contains("Ambiguous"), "Expected 'Ambiguous' in message, got: \(message)")
    }

    @MainActor
    func testTranscribeRejectsUnconfiguredEngineOverrideWithConflict() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        MockTranscriptionPlugin.reset()
        let context = Self.makeAPIContext(
            appSupportDirectory: appSupportDirectory,
            withMockTranscriptionPlugin: true
        )

        let configurable = ConfigurableTranscriptionPlugin()
        configurable.configured = false
        let configurableManifest = PluginManifest(
            id: "com.typewhisper.mock.configurable-transcription",
            name: "Configurable Mock Transcription",
            version: "1.0.0",
            principalClass: "APIRouterConfigurableTranscriptionPlugin"
        )
        PluginManager.shared.loadedPlugins.append(
            LoadedPlugin(
                manifest: configurableManifest,
                instance: configurable,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        )

        let wavData = WavEncoder.encode(Array(repeating: Float(0), count: 1600))
        let boundary = "TestBoundary-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"test.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"engine\"\r\n\r\n".data(using: .utf8)!)
        body.append("configurable-mock\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let response = await context.router.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/transcribe",
                queryParams: [:],
                headers: ["content-type": "multipart/form-data; boundary=\(boundary)"],
                body: body
            )
        )

        XCTAssertEqual(response.status, 409)
        let json = try Self.jsonObject(response)
        let message = (json["error"] as? [String: Any])?["message"] as? String ?? ""
        XCTAssertTrue(message.contains("not configured"), "Expected 'not configured' in message, got: \(message)")
    }

    @MainActor
    func testModelsEndpointUsesExpandedCatalogOnlyForCatalogProvidingPlugins() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let context = Self.makeAPIContext(
            appSupportDirectory: appSupportDirectory,
            withMockTranscriptionPlugin: false
        )
        let legacyPlugin = MockTranscriptionPlugin()
        let catalogPlugin = CatalogTranscriptionPlugin()
        let expandedEngine = NamedTranscriptionPlugin(
            providerId: "openai-compatible:inception",
            providerDisplayName: "Inception",
            modelId: "inception-whisper"
        )
        let expandedPlugin = ExpandedRolePlugin(
            additionalLLMProviders: [],
            additionalTranscriptionEngines: [expandedEngine]
        )
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.transcription",
                    name: "Mock Transcription",
                    version: "1.0.0",
                    sdkCompatibilityVersion: PluginSDKCompatibility.currentVersion,
                    principalClass: "APIRouterMockTranscriptionPlugin"
                ),
                instance: legacyPlugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            ),
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.catalog-transcription",
                    name: "Catalog Mock Transcription",
                    version: "1.0.0",
                    sdkCompatibilityVersion: PluginSDKCompatibility.currentVersion,
                    principalClass: "APIRouterCatalogTranscriptionPlugin"
                ),
                instance: catalogPlugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            ),
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.expanded-role",
                    name: "Expanded Role Mock",
                    version: "1.0.0",
                    sdkCompatibilityVersion: PluginSDKCompatibility.currentVersion,
                    principalClass: "APIRouterExpandedRolePlugin"
                ),
                instance: expandedPlugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let response = await context.router.route(
            HTTPRequest(method: "GET", path: "/v1/models", queryParams: [:], headers: [:], body: Data())
        )
        let json = try Self.jsonObject(response)
        let models = try XCTUnwrap(json["models"] as? [[String: Any]])

        let legacyIds = models
            .filter { ($0["engine"] as? String) == legacyPlugin.providerId }
            .compactMap { $0["id"] as? String }
        let catalogIds = models
            .filter { ($0["engine"] as? String) == catalogPlugin.providerId }
            .compactMap { $0["id"] as? String }
        let expandedIds = models
            .filter { ($0["engine"] as? String) == expandedEngine.providerId }
            .compactMap { $0["id"] as? String }

        XCTAssertEqual(legacyIds, ["tiny"])
        XCTAssertEqual(catalogIds.sorted(), ["large", "tiny"])
        XCTAssertEqual(expandedIds, ["inception-whisper"])
    }

    @MainActor
    func testTranscribeWithEngineOverrideRoutesToOverrideEngine() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        MockTranscriptionPlugin.reset()
        let context = Self.makeAPIContext(
            appSupportDirectory: appSupportDirectory,
            withMockTranscriptionPlugin: true
        )

        let configurable = ConfigurableTranscriptionPlugin()
        configurable.configured = true
        configurable.currentModelId = "alpha"
        let configurableManifest = PluginManifest(
            id: "com.typewhisper.mock.configurable-transcription",
            name: "Configurable Mock Transcription",
            version: "1.0.0",
            principalClass: "APIRouterConfigurableTranscriptionPlugin"
        )
        PluginManager.shared.loadedPlugins.append(
            LoadedPlugin(
                manifest: configurableManifest,
                instance: configurable,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        )

        let wavData = WavEncoder.encode(Array(repeating: Float(0), count: 1600))
        let boundary = "TestBoundary-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"test.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"engine\"\r\n\r\n".data(using: .utf8)!)
        body.append("configurable-mock\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let response = try Self.jsonObject(await context.router.route(
            HTTPRequest(
                method: "POST",
                path: "/v1/transcribe",
                queryParams: [:],
                headers: ["content-type": "multipart/form-data; boundary=\(boundary)"],
                body: body
            )
        ))

        XCTAssertEqual(response["engine"] as? String, "configurable-mock")
        XCTAssertEqual(response["model"] as? String, "alpha")
        XCTAssertEqual(response["text"] as? String, "transcribed")
    }

    @MainActor
    func testTranscribeWithoutOverrideLeavesSelectionUntouched() async throws {
        let selectedEngineKey = UserDefaultsKeys.selectedEngine
        let originalSelection = UserDefaults.standard.object(forKey: selectedEngineKey)
        UserDefaults.standard.removeObject(forKey: selectedEngineKey)
        defer {
            if let originalSelection {
                UserDefaults.standard.set(originalSelection, forKey: selectedEngineKey)
            } else {
                UserDefaults.standard.removeObject(forKey: selectedEngineKey)
            }
        }

        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)

        let plugin = ConfigurableTranscriptionPlugin()
        plugin.currentModelId = "alpha"
        plugin.configured = true

        let manifest = PluginManifest(
            id: "com.typewhisper.mock.configurable-transcription",
            name: "Configurable Mock Transcription",
            version: "1.0.0",
            principalClass: "APIRouterConfigurableTranscriptionPlugin"
        )
        PluginManager.shared.loadedPlugins = [
            LoadedPlugin(
                manifest: manifest,
                instance: plugin,
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]

        let modelManager = ModelManagerService()
        modelManager.selectProvider(plugin.providerId)

        _ = try await modelManager.transcribe(
            audioSamples: [Float](repeating: 0, count: 16_000),
            language: nil,
            task: .transcribe,
            engineOverrideId: nil,
            cloudModelOverride: nil,
            prompt: nil
        )

        XCTAssertEqual(plugin.selectedModelId, "alpha")
    }

    @MainActor
    func testHandleCancelHotkey_firstEscapeDuringRecordingShowsWarningWithoutCancelling() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
        }

        dictationContext = Self.makeDictationContext(appSupportDirectory: appSupportDirectory)
        let context = try XCTUnwrap(dictationContext)
        context.dictationViewModel.state = .recording

        context.dictationViewModel.handleCancelHotkey()

        XCTAssertEqual(context.dictationViewModel.state, .recording)
        XCTAssertEqual(
            context.dictationViewModel.cancelWarningMessage,
            try TestSupport.localizedCatalogValueForCurrentLocale(for: "Press Esc again to cancel recording")
        )
        XCTAssertNil(context.dictationViewModel.actionFeedbackMessage)
    }

    @MainActor
    func testHandleCancelHotkey_secondEscapeDuringRecordingCancels() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
        }

        dictationContext = Self.makeDictationContext(appSupportDirectory: appSupportDirectory)
        let context = try XCTUnwrap(dictationContext)
        context.dictationViewModel.state = .recording

        context.dictationViewModel.handleCancelHotkey()
        context.dictationViewModel.handleCancelHotkey()

        XCTAssertEqual(context.dictationViewModel.state, .inserting)
        XCTAssertNil(context.dictationViewModel.cancelWarningMessage)
        XCTAssertEqual(
            context.dictationViewModel.actionFeedbackMessage,
            try TestSupport.localizedCatalogValueForCurrentLocale(for: "Cancelled")
        )
    }

    @MainActor
    func testHandleCancelHotkey_secondEscapeDuringRecordingRestoresAudioThenResumesMediaBeforeImmediateStop() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var events: [String] = []
        let stopRecordingCalled = expectation(description: "stop recording called")
        let audioDuckingService = MockAudioDuckingService {
            events.append("restore_audio")
        }
        let mediaPlaybackService = MockMediaPlaybackService(
            onResume: {
                events.append("resume_media")
            }
        )
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
        }

        dictationContext = Self.makeDictationContext(
            appSupportDirectory: appSupportDirectory,
            audioDuckingService: audioDuckingService,
            mediaPlaybackService: mediaPlaybackService
        )
        let context = try XCTUnwrap(dictationContext)
        context.audioRecordingService.stopRecordingOverride = { policy in
            events.append("stop_recording_\(policy.logDescription)")
            stopRecordingCalled.fulfill()
            return []
        }
        context.dictationViewModel.state = .recording

        context.dictationViewModel.handleCancelHotkey()
        context.dictationViewModel.handleCancelHotkey()

        await fulfillment(of: [stopRecordingCalled], timeout: 1.0)

        XCTAssertEqual(
            events,
            ["restore_audio", "resume_media", "stop_recording_immediate"]
        )
    }

    @MainActor
    func testHandleCancelHotkey_processingRequiresSecondEscapeToCancel() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
        }

        dictationContext = Self.makeDictationContext(appSupportDirectory: appSupportDirectory)
        let context = try XCTUnwrap(dictationContext)
        context.dictationViewModel.state = .processing

        context.dictationViewModel.handleCancelHotkey()

        XCTAssertEqual(context.dictationViewModel.state, .processing)
        XCTAssertEqual(
            context.dictationViewModel.cancelWarningMessage,
            try TestSupport.localizedCatalogValueForCurrentLocale(for: "Press Esc again to cancel transcription")
        )
        XCTAssertNil(context.dictationViewModel.actionFeedbackMessage)

        context.dictationViewModel.handleCancelHotkey()

        XCTAssertEqual(context.dictationViewModel.state, .inserting)
        XCTAssertNil(context.dictationViewModel.cancelWarningMessage)
        XCTAssertEqual(
            context.dictationViewModel.actionFeedbackMessage,
            try TestSupport.localizedCatalogValueForCurrentLocale(for: "Cancelled")
        )
    }

    @MainActor
    func testDisconnectedDeviceDuringRecordingRestoresAudioThenResumesMediaBeforeImmediateStop() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var events: [String] = []
        let stopRecordingCalled = expectation(description: "stop recording called")
        let audioDuckingService = MockAudioDuckingService {
            events.append("restore_audio")
        }
        let mediaPlaybackService = MockMediaPlaybackService(
            onResume: {
                events.append("resume_media")
            }
        )
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
        }

        dictationContext = Self.makeDictationContext(
            appSupportDirectory: appSupportDirectory,
            audioDuckingService: audioDuckingService,
            mediaPlaybackService: mediaPlaybackService
        )
        let context = try XCTUnwrap(dictationContext)
        context.audioRecordingService.stopRecordingOverride = { policy in
            events.append("stop_recording_\(policy.logDescription)")
            stopRecordingCalled.fulfill()
            return []
        }
        context.dictationViewModel.state = .recording

        context.audioDeviceService.disconnectedDeviceName = "USB Mic"

        await fulfillment(of: [stopRecordingCalled], timeout: 1.0)

        XCTAssertEqual(
            events,
            ["restore_audio", "resume_media", "stop_recording_immediate"]
        )
        XCTAssertEqual(
            context.dictationViewModel.actionFeedbackMessage,
            try TestSupport.localizedCatalogValueForCurrentLocale(for: "Microphone disconnected")
        )
    }

    @MainActor
    func testRecordingCancelWarningClearsWhenStateLeavesRecording() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        var dictationContext: DictationContext?
        defer {
            dictationContext = nil
            TestSupport.remove(appSupportDirectory)
        }

        dictationContext = Self.makeDictationContext(appSupportDirectory: appSupportDirectory)
        let context = try XCTUnwrap(dictationContext)
        context.dictationViewModel.state = .recording

        context.dictationViewModel.handleCancelHotkey()
        context.dictationViewModel.state = .processing

        XCTAssertNil(context.dictationViewModel.cancelWarningMessage)
    }
}

final class AudioRecordingServiceInputAvailabilityTests: XCTestCase {
    func testStartRecording_throwsNoMicrophoneDetectedBeforeStartingOverride() {
        let service = AudioRecordingService()
        var didReachStartOverride = false

        service.hasMicrophonePermissionOverride = true
        service.selectedDeviceID = AudioDeviceID(42)
        service.hasExplicitDeviceSelection = true
        service.inputAvailabilityOverride = { selectedDeviceID in
            XCTAssertEqual(selectedDeviceID, AudioDeviceID(42))
            return false
        }
        service.startRecordingOverride = {
            didReachStartOverride = true
        }

        XCTAssertThrowsError(try service.startRecording()) { error in
            guard case AudioRecordingService.AudioRecordingError.noMicrophoneDetected = error else {
                return XCTFail("Expected noMicrophoneDetected, got \(error)")
            }
        }
        XCTAssertFalse(didReachStartOverride)
    }
}

final class HotkeyServiceCompatibilityTests: XCTestCase {
    private var originalDictationHotkeysPausedDefault: Any?

    override func setUp() {
        super.setUp()
        originalDictationHotkeysPausedDefault = UserDefaults.standard.object(forKey: UserDefaultsKeys.dictationHotkeysPaused)
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.dictationHotkeysPaused)
    }

    override func tearDown() {
        let key = UserDefaultsKeys.dictationHotkeysPaused
        if let originalDictationHotkeysPausedDefault {
            UserDefaults.standard.set(originalDictationHotkeysPausedDefault, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        originalDictationHotkeysPausedDefault = nil
        super.tearDown()
    }

    @MainActor
    func testEscapeKeyStillInvokesCancelHandlerWithoutSuppression() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        var cancelCount = 0
        service.onCancelPressed = {
            cancelCount += 1
        }

        let escape = try makeKeyboardEvent(keyCode: 0x35, keyDown: true, flags: [])

        XCTAssertFalse(service.processEventForTesting(escape, source: .monitor))
        XCTAssertEqual(cancelCount, 1)
    }

    @MainActor
    func testEscapeKeyDedupesFollowingEventTapDispatch() async throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        var cancelCount = 0
        service.onCancelPressed = {
            cancelCount += 1
        }

        let escape = try makeKeyboardEvent(keyCode: 0x35, keyDown: true, flags: [])

        XCTAssertFalse(service.processEventForTesting(escape, source: .eventTap))
        await Task.yield()
        XCTAssertEqual(cancelCount, 1)

        XCTAssertFalse(service.processEventForTesting(escape, source: .monitor))
        XCTAssertEqual(cancelCount, 1)
    }

    @MainActor
    func testMonitorFallbackStartsToggleHotkey() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(spaceHotkey(), for: .toggle)

        var startCount = 0
        service.onDictationStart = { _ in
            startCount += 1
        }

        let keyDown = try makeKeyboardEvent(keyCode: 0x31, keyDown: true)
        XCTAssertTrue(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertEqual(startCount, 1)
    }

    @MainActor
    func testPausedDictationHotkeysIgnoreGlobalDictationSlots() throws {
        try withCleanDictationHotkeysPausedDefault {
            let service = HotkeyService()
            service.suspendMonitoring()
            service.dictationHotkeysPaused = true

            service.setHotkeyForTesting(spaceHotkey(), for: .toggle)
            service.setHotkeyForTesting(commandOptionAHotkey(), for: .hybrid)
            service.setHotkeyForTesting(controlShiftComboHotkey(), for: .pushToTalk)

            var startCount = 0
            service.onDictationStart = { _ in startCount += 1 }

            let toggleDown = try makeKeyboardEvent(keyCode: 0x31, keyDown: true)
            let hybridDown = try makeKeyboardEvent(keyCode: 0x00, keyDown: true, flags: [.maskCommand, .maskAlternate])
            let pushToTalkDown = try makeFlagsChangedEvent(keyCode: 0x38, modifierFlags: [.control, .shift])

            XCTAssertFalse(service.processEventForTesting(toggleDown, source: .monitor))
            XCTAssertFalse(service.processEventForTesting(hybridDown, source: .monitor))
            XCTAssertFalse(service.processEventForTesting(pushToTalkDown, source: .monitor))
            XCTAssertEqual(startCount, 0)
            XCTAssertNil(service.currentMode)
        }
    }

    @MainActor
    func testPausedDictationHotkeysPersistAcrossServiceInstances() throws {
        try withCleanDictationHotkeysPausedDefault {
            let service = HotkeyService()
            XCTAssertFalse(service.dictationHotkeysPaused)

            service.dictationHotkeysPaused = true

            let restoredService = HotkeyService()
            XCTAssertTrue(restoredService.dictationHotkeysPaused)
        }
    }

    @MainActor
    func testEventTapDispatchDedupesFollowingMonitorDispatch() async throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(spaceHotkey(), for: .toggle)

        var startCount = 0
        service.onDictationStart = { _ in
            startCount += 1
        }

        let keyDown = try makeKeyboardEvent(keyCode: 0x31, keyDown: true)
        XCTAssertTrue(service.processEventForTesting(keyDown, source: .eventTap))
        await Task.yield()
        XCTAssertEqual(startCount, 1)

        XCTAssertTrue(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertEqual(startCount, 1)
    }

    @MainActor
    func testEventTapPushToTalkStartStopDedupesFollowingMonitorDispatches() async throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(controlSpaceHotkey(), for: .pushToTalk)

        var startCount = 0
        var stopCount = 0
        service.onDictationStart = { _ in startCount += 1 }
        service.onDictationStop = { stopCount += 1 }

        let keyDown = try makeKeyboardEvent(keyCode: 0x31, keyDown: true, flags: [.maskControl])
        let keyUp = try makeKeyboardEvent(keyCode: 0x31, keyDown: false, flags: [.maskControl])

        XCTAssertTrue(service.processEventForTesting(keyDown, source: .eventTap))
        await Task.yield()
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 0)

        XCTAssertTrue(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertEqual(startCount, 1)

        XCTAssertTrue(service.processEventForTesting(keyUp, source: .eventTap))
        await Task.yield()
        XCTAssertEqual(stopCount, 1)

        XCTAssertFalse(service.processEventForTesting(keyUp, source: .monitor))
        XCTAssertEqual(stopCount, 1)
    }

    @MainActor
    func testEventTapDefersDictationStartOutOfCallback() async throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(spaceHotkey(), for: .toggle)

        var startCount = 0
        service.onDictationStart = { _ in
            startCount += 1
        }

        let keyDown = try makeKeyboardEvent(keyCode: 0x31, keyDown: true)
        XCTAssertTrue(service.processEventForTesting(keyDown, source: .eventTap))
        XCTAssertEqual(startCount, 0)

        await Task.yield()
        XCTAssertEqual(startCount, 1)
    }

    @MainActor
    func testEventTapDisableRecoversReleasedPushToTalkHotkey() async throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(spaceHotkey(), for: .pushToTalk)

        var physicalKeyIsDown = true
        service.keyStateProvider = { keyCode in
            keyCode == 0x31 && physicalKeyIsDown
        }

        var startCount = 0
        var stopCount = 0
        service.onDictationStart = { _ in startCount += 1 }
        service.onDictationStop = { stopCount += 1 }

        let keyDown = try makeKeyboardEvent(keyCode: 0x31, keyDown: true)
        XCTAssertTrue(service.processEventForTesting(keyDown, source: .eventTap))
        await Task.yield()
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 0)
        XCTAssertEqual(service.currentMode, .pushToTalk)

        physicalKeyIsDown = false
        service.recoverReleasedActiveHotkeyAfterEventTapDisableForTesting()
        XCTAssertEqual(stopCount, 1)
        XCTAssertNil(service.currentMode)
    }

    @MainActor
    func testSuppressingEventTapMaskOnlyIncludesMouseEventsWhenRequested() {
        let keyboardOnlyMask = HotkeyService.suppressingEventTapMaskForTesting(includeMouse: false)

        XCTAssertNotEqual(keyboardOnlyMask & eventMask(for: .keyDown), 0)
        XCTAssertNotEqual(keyboardOnlyMask & eventMask(for: .keyUp), 0)
        XCTAssertNotEqual(keyboardOnlyMask & eventMask(for: .flagsChanged), 0)
        XCTAssertEqual(keyboardOnlyMask & eventMask(for: .otherMouseDown), 0)
        XCTAssertEqual(keyboardOnlyMask & eventMask(for: .otherMouseUp), 0)

        let mouseAwareMask = HotkeyService.suppressingEventTapMaskForTesting(includeMouse: true)

        XCTAssertNotEqual(mouseAwareMask & eventMask(for: .keyDown), 0)
        XCTAssertNotEqual(mouseAwareMask & eventMask(for: .keyUp), 0)
        XCTAssertNotEqual(mouseAwareMask & eventMask(for: .flagsChanged), 0)
        XCTAssertNotEqual(mouseAwareMask & eventMask(for: .otherMouseDown), 0)
        XCTAssertNotEqual(mouseAwareMask & eventMask(for: .otherMouseUp), 0)
    }

    @MainActor
    func testHotkeyEventTapIsHeadInserted() {
        XCTAssertEqual(HotkeyService.eventTapPlacementForTesting(), .headInsertEventTap)
    }

    @MainActor
    func testCarbonHotkeySupportIsLimitedToSinglePressKeyWithModifiers() {
        XCTAssertTrue(HotkeyService.supportsCarbonHotkeyForTesting(commandOptionAHotkey()))
        XCTAssertTrue(HotkeyService.supportsCarbonHotkeyForTesting(fnF14Hotkey()))
        XCTAssertEqual(
            HotkeyService.carbonModifierFlagsForTesting(commandOptionAHotkey()),
            UInt32(cmdKey) | UInt32(optionKey)
        )
        XCTAssertEqual(
            HotkeyService.carbonModifierFlagsForTesting(fnF14Hotkey()),
            UInt32(kEventKeyModifierFnMask)
        )

        XCTAssertFalse(HotkeyService.supportsCarbonHotkeyForTesting(bareSpaceHotkey()))
        XCTAssertFalse(HotkeyService.supportsCarbonHotkeyForTesting(commandOptionComboHotkey()))
        XCTAssertFalse(HotkeyService.supportsCarbonHotkeyForTesting(controlModifierHotkey()))
        XCTAssertFalse(HotkeyService.supportsCarbonHotkeyForTesting(UnifiedHotkey(mouseButton: 3)))

        let doubleTap = UnifiedHotkey(
            keyCode: 0x00,
            modifierFlags: NSEvent.ModifierFlags([.command, .option]).rawValue,
            isFn: false,
            isDoubleTap: true
        )
        XCTAssertFalse(HotkeyService.supportsCarbonHotkeyForTesting(doubleTap))
    }

    @MainActor
    func testCarbonHotkeyDispatchStartsToggleWithoutKeyboardEvent() {
        let service = HotkeyService()
        service.suspendMonitoring()

        let hotkey = fnF14Hotkey()
        service.setHotkeyForTesting(hotkey, for: .toggle)

        var startCount = 0
        service.onDictationStart = { _ in
            startCount += 1
        }

        service.processCarbonHotkeyForTesting(slotType: .toggle, hotkey: hotkey, isPressed: true)

        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(service.currentMode, .toggle)
    }

    @MainActor
    func testCarbonHotkeyReleaseStopsPushToTalk() {
        let service = HotkeyService()
        service.suspendMonitoring()

        let hotkey = commandOptionAHotkey()
        service.setHotkeyForTesting(hotkey, for: .pushToTalk)

        var startCount = 0
        var stopCount = 0
        service.onDictationStart = { _ in
            startCount += 1
        }
        service.onDictationStop = {
            stopCount += 1
        }

        service.processCarbonHotkeyForTesting(slotType: .pushToTalk, hotkey: hotkey, isPressed: true)
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(service.currentMode, .pushToTalk)

        service.processCarbonHotkeyForTesting(slotType: .pushToTalk, hotkey: hotkey, isPressed: false)
        XCTAssertEqual(stopCount, 1)
        XCTAssertNil(service.currentMode)
    }

    @MainActor
    func testCarbonWorkflowHotkeyStartsDictation() {
        let service = HotkeyService()
        service.suspendMonitoring()

        let workflowId = UUID()
        let hotkey = commandOptionAHotkey()
        service.registerWorkflowHotkeys([(id: workflowId, hotkey: hotkey, behavior: .startDictation)])

        var startedWorkflowId: UUID?
        service.onWorkflowDictationStart = { workflowId, _ in startedWorkflowId = workflowId }

        service.processCarbonWorkflowHotkeyForTesting(
            workflowId: workflowId,
            hotkey: hotkey,
            behavior: .startDictation,
            isPressed: true
        )

        XCTAssertEqual(startedWorkflowId, workflowId)
        XCTAssertEqual(service.currentMode, .pushToTalk)
        XCTAssertEqual(service.activeWorkflowId, workflowId)

        service.processCarbonWorkflowHotkeyForTesting(
            workflowId: workflowId,
            hotkey: hotkey,
            behavior: .startDictation,
            isPressed: false
        )
        XCTAssertEqual(service.currentMode, .toggle)
        XCTAssertEqual(service.activeWorkflowId, workflowId)
    }

    @MainActor
    func testCarbonWorkflowHotkeyTextProcessingDispatchesOnPhysicalKeyRelease() async {
        let (service, workflowId, hotkey) = makeCarbonWorkflowTextProcessingService(
            keyStateProvider: { _ in false }
        )

        var textWorkflowId: UUID?
        let textProcessingCallback = expectation(description: "workflow text processing callback")
        service.onWorkflowTextProcessing = {
            textWorkflowId = $0
            textProcessingCallback.fulfill()
        }

        service.processCarbonWorkflowHotkeyForTesting(
            workflowId: workflowId,
            hotkey: hotkey,
            behavior: .processSelectedText,
            isPressed: true
        )
        XCTAssertNil(textWorkflowId)
        XCTAssertEqual(service.activeWorkflowId, workflowId)

        service.processCarbonWorkflowHotkeyForTesting(
            workflowId: workflowId,
            hotkey: hotkey,
            behavior: .processSelectedText,
            isPressed: false
        )
        await fulfillment(of: [textProcessingCallback], timeout: 1.0)
        XCTAssertEqual(textWorkflowId, workflowId)
        XCTAssertNil(service.activeWorkflowId)
    }

    @MainActor
    func testCarbonWorkflowHotkeyTextProcessingWaitsForPhysicalKeyUpAfterModifierRelease() async throws {
        let workflowId = UUID()
        let hotkey = commandOptionAHotkey()
        var keyIsDown = true
        let service = makeCarbonWorkflowTextProcessingService(
            workflowId: workflowId,
            hotkey: hotkey,
            keyStateProvider: { keyCode in keyCode == hotkey.keyCode && keyIsDown }
        ).service

        var textWorkflowId: UUID?
        let textProcessingCallback = expectation(description: "workflow text processing callback")
        service.onWorkflowTextProcessing = {
            textWorkflowId = $0
            textProcessingCallback.fulfill()
        }

        service.processCarbonWorkflowHotkeyForTesting(
            workflowId: workflowId,
            hotkey: hotkey,
            behavior: .processSelectedText,
            isPressed: true
        )
        XCTAssertNil(textWorkflowId)
        XCTAssertEqual(service.activeWorkflowId, workflowId)

        service.processCarbonWorkflowHotkeyForTesting(
            workflowId: workflowId,
            hotkey: hotkey,
            behavior: .processSelectedText,
            isPressed: false
        )
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(textWorkflowId)
        XCTAssertEqual(service.activeWorkflowId, workflowId)

        keyIsDown = false
        let physicalKeyUp = try makeKeyboardEvent(keyCode: 0x00, keyDown: false, flags: [])
        XCTAssertTrue(service.processEventForTesting(physicalKeyUp, source: .monitor))
        await fulfillment(of: [textProcessingCallback], timeout: 1.0)
        XCTAssertEqual(textWorkflowId, workflowId)
        XCTAssertNil(service.activeWorkflowId)
    }

    @MainActor
    func testCarbonWorkflowHotkeyTextProcessingCompletesWithoutMonitorKeyUpAfterPhysicalKeyRelease() async throws {
        let workflowId = UUID()
        let hotkey = commandOptionAHotkey()
        var keyIsDown = true
        let service = makeCarbonWorkflowTextProcessingService(
            workflowId: workflowId,
            hotkey: hotkey,
            keyStateProvider: { keyCode in keyCode == hotkey.keyCode && keyIsDown }
        ).service

        var textWorkflowId: UUID?
        let textProcessingCallback = expectation(description: "workflow text processing callback")
        service.onWorkflowTextProcessing = {
            textWorkflowId = $0
            textProcessingCallback.fulfill()
        }

        service.processCarbonWorkflowHotkeyForTesting(
            workflowId: workflowId,
            hotkey: hotkey,
            behavior: .processSelectedText,
            isPressed: true
        )
        XCTAssertNil(textWorkflowId)
        XCTAssertEqual(service.activeWorkflowId, workflowId)

        service.processCarbonWorkflowHotkeyForTesting(
            workflowId: workflowId,
            hotkey: hotkey,
            behavior: .processSelectedText,
            isPressed: false
        )
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(textWorkflowId)
        XCTAssertEqual(service.activeWorkflowId, workflowId)

        keyIsDown = false
        await fulfillment(of: [textProcessingCallback], timeout: 1.0)
        XCTAssertEqual(textWorkflowId, workflowId)
        XCTAssertNil(service.activeWorkflowId)
    }

    @MainActor
    func testCarbonHotkeyDispatchDedupesFollowingEventTapDispatch() async throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        let hotkey = commandOptionAHotkey()
        service.setHotkeyForTesting(hotkey, for: .toggle)

        var startCount = 0
        service.onDictationStart = { _ in
            startCount += 1
        }

        let keyDown = try makeKeyboardEvent(keyCode: 0x00, keyDown: true, flags: [.maskCommand, .maskAlternate])
        XCTAssertTrue(service.processEventForTesting(keyDown, source: .eventTap))
        await Task.yield()
        XCTAssertEqual(startCount, 1)

        service.processCarbonHotkeyForTesting(slotType: .toggle, hotkey: hotkey, isPressed: true)
        XCTAssertEqual(startCount, 1)
    }

    @MainActor
    func testCarbonHotkeyDispatchDedupesFollowingMonitorDispatch() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        let hotkey = commandOptionAHotkey()
        service.setHotkeyForTesting(hotkey, for: .toggle)

        var startCount = 0
        service.onDictationStart = { _ in
            startCount += 1
        }

        let keyDown = try makeKeyboardEvent(keyCode: 0x00, keyDown: true, flags: [.maskCommand, .maskAlternate])
        XCTAssertTrue(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertEqual(startCount, 1)

        service.processCarbonHotkeyForTesting(slotType: .toggle, hotkey: hotkey, isPressed: true)
        XCTAssertEqual(startCount, 1)
    }

    @MainActor
    func testMiddleMousePassesThroughWhenNoMouseHotkeyIsBound() throws {
        let service = HotkeyService()
        service.suspendMonitoring()
        service.setHotkeyForTesting(spaceHotkey(), for: .toggle)

        var startCount = 0
        service.onDictationStart = { _ in
            startCount += 1
        }

        let middleMouseDown = try makeOtherMouseEvent(buttonNumber: 2, isDown: true)

        XCTAssertFalse(service.needsMouseEventMonitoringForTesting())
        XCTAssertFalse(service.needsSuppressingMouseEventTapForTesting())
        XCTAssertFalse(service.processEventForTesting(middleMouseDown, source: .eventTap))
        XCTAssertEqual(startCount, 0)
    }

    @MainActor
    func testMiddleMousePassesThroughWhenDifferentMouseHotkeyIsBound() throws {
        let service = HotkeyService()
        service.suspendMonitoring()
        service.setHotkeyForTesting(UnifiedHotkey(mouseButton: 3), for: .toggle)

        var startCount = 0
        service.onDictationStart = { _ in
            startCount += 1
        }

        let middleMouseDown = try makeOtherMouseEvent(buttonNumber: 2, isDown: true)

        XCTAssertTrue(service.needsMouseEventMonitoringForTesting())
        XCTAssertTrue(service.needsSuppressingMouseEventTapForTesting())
        XCTAssertFalse(service.processEventForTesting(middleMouseDown, source: .eventTap))
        XCTAssertEqual(startCount, 0)
    }

    @MainActor
    func testMatchingMiddleMouseHotkeyDispatchesWithoutSuppressingClick() throws {
        let service = HotkeyService()
        service.suspendMonitoring()
        service.setHotkeyForTesting(UnifiedHotkey(mouseButton: 2), for: .toggle)

        var startCount = 0
        service.onDictationStart = { _ in
            startCount += 1
        }

        let middleMouseDown = try makeOtherMouseEvent(buttonNumber: 2, isDown: true)
        let middleMouseUp = try makeOtherMouseEvent(buttonNumber: 2, isDown: false)

        XCTAssertTrue(service.needsMouseEventMonitoringForTesting())
        XCTAssertFalse(service.needsSuppressingMouseEventTapForTesting())
        XCTAssertFalse(service.processEventForTesting(middleMouseDown, source: .monitor))
        XCTAssertEqual(startCount, 1)
        XCTAssertFalse(service.processEventForTesting(middleMouseUp, source: .monitor))
    }

    @MainActor
    func testMiddleMouseHotkeyPassesThroughEvenWhenSideMouseHotkeyUsesSuppressingTap() async throws {
        let service = HotkeyService()
        service.suspendMonitoring()
        service.setHotkeysForTesting([
            UnifiedHotkey(mouseButton: 2),
            UnifiedHotkey(mouseButton: 3)
        ], for: .toggle)

        var startCount = 0
        service.onDictationStart = { _ in
            startCount += 1
        }

        let middleMouseDown = try makeOtherMouseEvent(buttonNumber: 2, isDown: true)

        XCTAssertTrue(service.needsMouseEventMonitoringForTesting())
        XCTAssertTrue(service.needsSuppressingMouseEventTapForTesting())
        XCTAssertFalse(service.processEventForTesting(middleMouseDown, source: .eventTap))
        await Task.yield()
        XCTAssertEqual(startCount, 1)
    }

    @MainActor
    func testMatchingSideMouseHotkeyDispatchesAndSuppressesClick() async throws {
        let service = HotkeyService()
        service.suspendMonitoring()
        service.setHotkeyForTesting(UnifiedHotkey(mouseButton: 3), for: .toggle)

        var startCount = 0
        service.onDictationStart = { _ in
            startCount += 1
        }

        let sideMouseDown = try makeOtherMouseEvent(buttonNumber: 3, isDown: true)
        let sideMouseUp = try makeOtherMouseEvent(buttonNumber: 3, isDown: false)

        XCTAssertTrue(service.needsMouseEventMonitoringForTesting())
        XCTAssertTrue(service.needsSuppressingMouseEventTapForTesting())
        XCTAssertTrue(service.processEventForTesting(sideMouseDown, source: .eventTap))
        await Task.yield()
        XCTAssertEqual(startCount, 1)
        XCTAssertTrue(service.processEventForTesting(sideMouseUp, source: .eventTap))
    }

    @MainActor
    func testPushToTalkStartCallbackIncludesRequestTimestamp() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(spaceHotkey(), for: .pushToTalk)

        let before = DispatchTime.now().uptimeNanoseconds
        var requestTimestamp: UInt64?
        service.onDictationStart = { timestamp in
            requestTimestamp = timestamp
        }

        let keyDown = try makeKeyboardEvent(keyCode: 0x31, keyDown: true)

        XCTAssertTrue(service.processEventForTesting(keyDown, source: .monitor))

        let timestamp = try XCTUnwrap(requestTimestamp)
        XCTAssertGreaterThanOrEqual(timestamp, before)
        XCTAssertLessThanOrEqual(timestamp, DispatchTime.now().uptimeNanoseconds)
    }

    @MainActor
    func testMonitorFallbackStopsPushToTalkOnKeyUp() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(spaceHotkey(), for: .pushToTalk)

        var startCount = 0
        var stopCount = 0
        service.onDictationStart = { _ in
            startCount += 1
        }
        service.onDictationStop = {
            stopCount += 1
        }

        let keyDown = try makeKeyboardEvent(keyCode: 0x31, keyDown: true)
        let keyUp = try makeKeyboardEvent(keyCode: 0x31, keyDown: false)

        XCTAssertTrue(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertTrue(service.processEventForTesting(keyUp, source: .monitor))
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 1)
    }

    @MainActor
    func testModifierComboPushToTalkDoesNotStopOnTransientFlagsChangedLoss() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(commandOptionComboHotkey(), for: .pushToTalk)

        var startCount = 0
        var stopCount = 0
        service.onDictationStart = { _ in startCount += 1 }
        service.onDictationStop = { stopCount += 1 }

        let comboDown = try makeFlagsChangedEvent(keyCode: 0x3D, modifierFlags: [.command, .option])
        let transientLoss = try makeFlagsChangedEvent(keyCode: 0x3D, modifierFlags: [.command])
        let comboRestored = try makeFlagsChangedEvent(keyCode: 0x3D, modifierFlags: [.command, .option])
        let fullRelease = try makeFlagsChangedEvent(keyCode: 0x3D, modifierFlags: [])

        XCTAssertTrue(service.processEventForTesting(comboDown, source: .monitor))
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 0)

        XCTAssertTrue(service.processEventForTesting(transientLoss, source: .monitor))
        XCTAssertEqual(stopCount, 0)

        XCTAssertTrue(service.processEventForTesting(comboRestored, source: .monitor))
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 0)

        XCTAssertTrue(service.processEventForTesting(fullRelease, source: .monitor))
        XCTAssertEqual(stopCount, 1)
    }

    @MainActor
    func testRightSideModifierComboPushToTalkStaysActiveUntilFinalRelease() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(commandOptionComboHotkey(), for: .pushToTalk)

        var startCount = 0
        var stopCount = 0
        service.onDictationStart = { _ in startCount += 1 }
        service.onDictationStop = { stopCount += 1 }

        let rightCommandDown = try makeFlagsChangedEvent(keyCode: 0x36, modifierFlags: [.command])
        let rightOptionDown = try makeFlagsChangedEvent(keyCode: 0x3D, modifierFlags: [.command, .option])
        let transientRightCommandLoss = try makeFlagsChangedEvent(keyCode: 0x36, modifierFlags: [.option])
        let comboRestored = try makeFlagsChangedEvent(keyCode: 0x36, modifierFlags: [.command, .option])
        let finalRelease = try makeFlagsChangedEvent(keyCode: 0x36, modifierFlags: [])

        XCTAssertFalse(service.processEventForTesting(rightCommandDown, source: .monitor))
        XCTAssertEqual(startCount, 0)

        XCTAssertTrue(service.processEventForTesting(rightOptionDown, source: .monitor))
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 0)

        XCTAssertTrue(service.processEventForTesting(transientRightCommandLoss, source: .monitor))
        XCTAssertEqual(stopCount, 0)

        XCTAssertTrue(service.processEventForTesting(comboRestored, source: .monitor))
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 0)

        XCTAssertTrue(service.processEventForTesting(finalRelease, source: .monitor))
        XCTAssertEqual(stopCount, 1)
    }

    @MainActor
    func testRightSpecificModifierComboDoesNotTriggerFromLeftSide() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(try rightCommandRightOptionComboHotkey(), for: .pushToTalk)

        var startCount = 0
        service.onDictationStart = { _ in startCount += 1 }

        let leftCommandDown = try makeFlagsChangedEvent(
            keyCode: 0x37,
            modifierFlags: flags(generic: [.command], deviceKeyCodes: [0x37])
        )
        let leftOptionDown = try makeFlagsChangedEvent(
            keyCode: 0x3A,
            modifierFlags: flags(generic: [.command, .option], deviceKeyCodes: [0x37, 0x3A])
        )

        XCTAssertFalse(service.processEventForTesting(leftCommandDown, source: .monitor))
        XCTAssertFalse(service.processEventForTesting(leftOptionDown, source: .monitor))
        XCTAssertEqual(startCount, 0)
    }

    @MainActor
    func testRightSpecificModifierComboTriggersFromRightSide() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(try rightCommandRightOptionComboHotkey(), for: .pushToTalk)

        var startCount = 0
        var stopCount = 0
        service.onDictationStart = { _ in startCount += 1 }
        service.onDictationStop = { stopCount += 1 }

        let rightCommandDown = try makeFlagsChangedEvent(
            keyCode: 0x36,
            modifierFlags: flags(generic: [.command], deviceKeyCodes: [0x36])
        )
        let rightOptionDown = try makeFlagsChangedEvent(
            keyCode: 0x3D,
            modifierFlags: flags(generic: [.command, .option], deviceKeyCodes: [0x36, 0x3D])
        )
        let finalRelease = try makeFlagsChangedEvent(keyCode: 0x36, modifierFlags: [])

        XCTAssertFalse(service.processEventForTesting(rightCommandDown, source: .monitor))
        XCTAssertTrue(service.processEventForTesting(rightOptionDown, source: .monitor))
        XCTAssertEqual(startCount, 1)

        XCTAssertTrue(service.processEventForTesting(finalRelease, source: .monitor))
        XCTAssertEqual(stopCount, 1)
    }

    @MainActor
    func testRightSpecificModifierComboDoesNotTriggerFromMixedSides() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(try rightCommandRightOptionComboHotkey(), for: .pushToTalk)

        var startCount = 0
        service.onDictationStart = { _ in startCount += 1 }

        let rightCommandDown = try makeFlagsChangedEvent(
            keyCode: 0x36,
            modifierFlags: flags(generic: [.command], deviceKeyCodes: [0x36])
        )
        let leftOptionDown = try makeFlagsChangedEvent(
            keyCode: 0x3A,
            modifierFlags: flags(generic: [.command, .option], deviceKeyCodes: [0x36, 0x3A])
        )

        XCTAssertFalse(service.processEventForTesting(rightCommandDown, source: .monitor))
        XCTAssertFalse(service.processEventForTesting(leftOptionDown, source: .monitor))
        XCTAssertEqual(startCount, 0)
    }

    @MainActor
    func testGenericModifierComboTriggersOnlyForExactModifiers() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(controlShiftComboHotkey(), for: .toggle)

        var startCount = 0
        service.onDictationStart = { _ in startCount += 1 }

        let comboDown = try makeFlagsChangedEvent(keyCode: 0x38, modifierFlags: [.control, .shift])

        XCTAssertTrue(service.processEventForTesting(comboDown, source: .monitor))
        XCTAssertEqual(startCount, 1)
    }

    @MainActor
    func testGenericModifierComboRejectsExtraModifiers() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(controlShiftComboHotkey(), for: .toggle)

        var startCount = 0
        service.onDictationStart = { _ in startCount += 1 }

        let commandControlShift = try makeFlagsChangedEvent(
            keyCode: 0x38,
            modifierFlags: [.command, .control, .shift]
        )
        let controlOptionShift = try makeFlagsChangedEvent(
            keyCode: 0x38,
            modifierFlags: [.control, .option, .shift]
        )
        let fnControlShift = try makeFlagsChangedEvent(
            keyCode: 0x3F,
            modifierFlags: [.function, .control, .shift]
        )

        XCTAssertFalse(service.processEventForTesting(commandControlShift, source: .monitor))
        XCTAssertFalse(service.processEventForTesting(controlOptionShift, source: .monitor))
        XCTAssertFalse(service.processEventForTesting(fnControlShift, source: .monitor))
        XCTAssertEqual(startCount, 0)
    }

    @MainActor
    func testSideSpecificModifierComboRejectsExtraPhysicalModifiers() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(try rightCommandRightOptionComboHotkey(), for: .toggle)

        var startCount = 0
        service.onDictationStart = { _ in startCount += 1 }

        let rightComboWithExtraLeftCommand = try makeFlagsChangedEvent(
            keyCode: 0x37,
            modifierFlags: flags(generic: [.command, .option], deviceKeyCodes: [0x36, 0x3D, 0x37])
        )

        XCTAssertFalse(service.processEventForTesting(rightComboWithExtraLeftCommand, source: .monitor))
        XCTAssertEqual(startCount, 0)
    }

    @MainActor
    func testLegacyGenericModifierComboStillTriggersFromLeftAndRightSides() throws {
        let leftService = HotkeyService()
        leftService.suspendMonitoring()
        leftService.setHotkeyForTesting(try legacyCommandOptionComboHotkey(), for: .toggle)

        var leftStartCount = 0
        leftService.onDictationStart = { _ in leftStartCount += 1 }

        let leftOptionDown = try makeFlagsChangedEvent(
            keyCode: 0x3A,
            modifierFlags: flags(generic: [.command, .option], deviceKeyCodes: [0x37, 0x3A])
        )
        XCTAssertTrue(leftService.processEventForTesting(leftOptionDown, source: .monitor))
        XCTAssertEqual(leftStartCount, 1)

        let rightService = HotkeyService()
        rightService.suspendMonitoring()
        rightService.setHotkeyForTesting(try legacyCommandOptionComboHotkey(), for: .toggle)

        var rightStartCount = 0
        rightService.onDictationStart = { _ in rightStartCount += 1 }

        let rightOptionDown = try makeFlagsChangedEvent(
            keyCode: 0x3D,
            modifierFlags: flags(generic: [.command, .option], deviceKeyCodes: [0x36, 0x3D])
        )
        XCTAssertTrue(rightService.processEventForTesting(rightOptionDown, source: .monitor))
        XCTAssertEqual(rightStartCount, 1)
    }

    @MainActor
    func testSideSpecificModifierComboDisplayNameIncludesSides() throws {
        let hotkey = try rightCommandRightOptionComboHotkey()

        XCTAssertEqual(HotkeyService.displayName(for: hotkey), "Right Command + Right Option")
    }

    @MainActor
    func testSideSpecificModifierComboDisplayNameKeepsFnModifier() throws {
        let hotkey = UnifiedHotkey(
            keyCode: UnifiedHotkey.modifierComboKeyCode,
            modifierFlags: NSEvent.ModifierFlags([.function, .command]).rawValue,
            isFn: false,
            modifierKeyCodes: [0x36]
        )

        XCTAssertEqual(HotkeyService.displayName(for: hotkey), "Fn + Right Command")
    }

    @MainActor
    func testGenericModifierComboConflictsWithSideSpecificCombo() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(try legacyCommandOptionComboHotkey(), for: .toggle)

        XCTAssertEqual(
            service.isHotkeyAssigned(try rightCommandRightOptionComboHotkey(), excluding: .pushToTalk),
            .toggle
        )
    }

    @MainActor
    func testDistinctSideSpecificModifierCombosDoNotConflict() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(try leftCommandLeftOptionComboHotkey(), for: .toggle)

        XCTAssertNil(service.isHotkeyAssigned(try rightCommandRightOptionComboHotkey(), excluding: .pushToTalk))
    }

    @MainActor
    func testPushToTalkExtraKeyInterruptionSignalsDiscardWithoutImmediateStop() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(commandOptionComboHotkey(), for: .pushToTalk)
        service.discardPushToTalkRecordingOnExtraKeyPress = true

        var startCount = 0
        var stopCount = 0
        var interruptionCount = 0
        service.onDictationStart = { _ in startCount += 1 }
        service.onDictationStop = { stopCount += 1 }
        service.onPushToTalkInterruption = { interruptionCount += 1 }

        let comboDown = try makeFlagsChangedEvent(keyCode: 0x3D, modifierFlags: [.command, .option])
        let extraKeyDown = try makeKeyboardEvent(keyCode: 0x25, keyDown: true, flags: [.maskCommand, .maskAlternate])
        let extraKeyUp = try makeKeyboardEvent(keyCode: 0x25, keyDown: false, flags: [.maskCommand, .maskAlternate])
        let fullRelease = try makeFlagsChangedEvent(keyCode: 0x3D, modifierFlags: [])

        XCTAssertTrue(service.processEventForTesting(comboDown, source: .monitor))
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 0)

        XCTAssertFalse(service.processEventForTesting(extraKeyDown, source: .monitor))
        XCTAssertEqual(interruptionCount, 1)
        XCTAssertEqual(stopCount, 0)

        XCTAssertFalse(service.processEventForTesting(extraKeyUp, source: .monitor))
        XCTAssertEqual(interruptionCount, 1)
        XCTAssertEqual(stopCount, 0)

        XCTAssertTrue(service.processEventForTesting(fullRelease, source: .monitor))
        XCTAssertEqual(stopCount, 1)
    }

    @MainActor
    func testPushToTalkExtraKeyInterruptionDoesNothingWhenPolicyDisabled() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(commandOptionComboHotkey(), for: .pushToTalk)
        service.discardPushToTalkRecordingOnExtraKeyPress = false

        var interruptionCount = 0
        service.onPushToTalkInterruption = { interruptionCount += 1 }

        let comboDown = try makeFlagsChangedEvent(keyCode: 0x3D, modifierFlags: [.command, .option])
        let extraKeyDown = try makeKeyboardEvent(keyCode: 0x25, keyDown: true, flags: [.maskCommand, .maskAlternate])

        XCTAssertTrue(service.processEventForTesting(comboDown, source: .monitor))
        XCTAssertFalse(service.processEventForTesting(extraKeyDown, source: .monitor))
        XCTAssertEqual(interruptionCount, 0)
    }

    @MainActor
    func testCapsLockOriginSuppressesModifierComboHotkey() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(commandOptionComboHotkey(), for: .toggle)

        var startCount = 0
        service.onDictationStart = { _ in
            startCount += 1
        }

        let capsLockEvent = try makeFlagsChangedEvent(keyCode: 0x39, modifierFlags: [.capsLock])
        let comboEvent = try makeFlagsChangedEvent(keyCode: 0x3D, modifierFlags: [.command, .option])

        XCTAssertFalse(service.processEventForTesting(capsLockEvent, source: .monitor))
        XCTAssertFalse(service.processEventForTesting(comboEvent, source: .monitor))
        XCTAssertEqual(startCount, 0)
    }

    @MainActor
    func testCapsLockOriginSuppressesKeyWithModifiersHotkey() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(commandOptionAHotkey(), for: .toggle)

        var startCount = 0
        service.onDictationStart = { _ in
            startCount += 1
        }

        let capsLockEvent = try makeFlagsChangedEvent(keyCode: 0x39, modifierFlags: [.capsLock])
        let keyDown = try makeKeyboardEvent(keyCode: 0x00, keyDown: true, flags: [.maskCommand, .maskAlternate])
        let keyUp = try makeKeyboardEvent(keyCode: 0x00, keyDown: false, flags: [.maskCommand, .maskAlternate])

        XCTAssertFalse(service.processEventForTesting(capsLockEvent, source: .monitor))
        XCTAssertFalse(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertFalse(service.processEventForTesting(keyUp, source: .monitor))
        XCTAssertEqual(startCount, 0)
    }

    @MainActor
    func testModifierComboStillWorksWithoutCapsLockOrigin() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(commandOptionComboHotkey(), for: .toggle)

        var startCount = 0
        service.onDictationStart = { _ in
            startCount += 1
        }

        let comboEvent = try makeFlagsChangedEvent(keyCode: 0x3D, modifierFlags: [.command, .option])

        XCTAssertTrue(service.processEventForTesting(comboEvent, source: .monitor))
        XCTAssertEqual(startCount, 1)
    }

    @MainActor
    func testKeyWithModifiersStillWorksWithoutCapsLockOrigin() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(commandOptionAHotkey(), for: .toggle)

        var startCount = 0
        service.onDictationStart = { _ in
            startCount += 1
        }

        let keyDown = try makeKeyboardEvent(keyCode: 0x00, keyDown: true, flags: [.maskCommand, .maskAlternate])

        XCTAssertTrue(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertEqual(startCount, 1)
    }

    @MainActor
    func testBareKeyHotkeyRemainsAllowedAfterCapsLockOrigin() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(bareSpaceHotkey(), for: .toggle)

        var startCount = 0
        service.onDictationStart = { _ in
            startCount += 1
        }

        let capsLockEvent = try makeFlagsChangedEvent(keyCode: 0x39, modifierFlags: [.capsLock])
        let keyDown = try makeKeyboardEvent(keyCode: 0x31, keyDown: true, flags: [])

        XCTAssertFalse(service.processEventForTesting(capsLockEvent, source: .monitor))
        XCTAssertTrue(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertEqual(startCount, 1)
    }

    @MainActor
    func testMonitorFallbackStartsPushToTalkOnFnPress() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(fnHotkey(), for: .pushToTalk)

        var startCount = 0
        var stopCount = 0
        service.onDictationStart = { _ in startCount += 1 }
        service.onDictationStop = { stopCount += 1 }

        let keyDown = try makeFnEvent(isDown: true)
        let keyUp = try makeFnEvent(isDown: false)

        XCTAssertTrue(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 0)

        XCTAssertTrue(service.processEventForTesting(keyUp, source: .monitor))
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 1)
    }

    @MainActor
    func testMonitorFallbackStartsHybridOnFnPress() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(fnHotkey(), for: .hybrid)

        var startCount = 0
        var stopCount = 0
        service.onDictationStart = { _ in startCount += 1 }
        service.onDictationStop = { stopCount += 1 }

        let keyDown = try makeFnEvent(isDown: true)
        let keyUp = try makeFnEvent(isDown: false)

        XCTAssertTrue(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 0)

        XCTAssertTrue(service.processEventForTesting(keyUp, source: .monitor))
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 0)
        XCTAssertEqual(service.currentMode, .toggle)
    }

    @MainActor
    func testMonitorFallbackStartsHybridLongPressAndStopsAfterRelease() async throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(fnHotkey(), for: .hybrid)

        var startCount = 0
        var stopCount = 0
        service.onDictationStart = { _ in startCount += 1 }
        service.onDictationStop = { stopCount += 1 }

        let keyDown = try makeFnEvent(isDown: true)
        let keyUp = try makeFnEvent(isDown: false)

        XCTAssertTrue(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertEqual(startCount, 1)

        try await Task.sleep(nanoseconds: 1_150_000_000)

        XCTAssertTrue(service.processEventForTesting(keyUp, source: .monitor))
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(startCount, 1)
        XCTAssertNil(service.currentMode)
    }

    @MainActor
    func testHybridModifierHoldDoesNotStartBeforeDelay() async throws {
        let service = HotkeyService()
        service.suspendMonitoring()
        service.hybridModifierHoldActivationDelay = 0.05

        service.setHotkeyForTesting(controlModifierHotkey(), for: .hybrid)

        var currentFlags = NSEvent.ModifierFlags.control
        service.modifierFlagsStateProvider = { currentFlags }

        var startCount = 0
        service.onDictationStart = { _ in startCount += 1 }

        let keyDown = try makeControlModifierEvent(isDown: true)
        let keyUp = try makeControlModifierEvent(isDown: false)

        XCTAssertFalse(service.processEventForTesting(keyDown, source: .monitor))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(startCount, 0)
        XCTAssertNil(service.currentMode)

        currentFlags = []
        XCTAssertFalse(service.processEventForTesting(keyUp, source: .monitor))
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(startCount, 0)
        XCTAssertNil(service.currentMode)
    }

    @MainActor
    func testHybridModifierShortTapDoesNotToggleDictation() async throws {
        let service = HotkeyService()
        service.suspendMonitoring()
        service.hybridModifierHoldActivationDelay = 0.02

        service.setHotkeyForTesting(controlModifierHotkey(), for: .hybrid)

        var currentFlags = NSEvent.ModifierFlags.control
        service.modifierFlagsStateProvider = { currentFlags }

        var startCount = 0
        var stopCount = 0
        service.onDictationStart = { _ in startCount += 1 }
        service.onDictationStop = { stopCount += 1 }

        let keyDown = try makeControlModifierEvent(isDown: true)
        let keyUp = try makeControlModifierEvent(isDown: false)

        XCTAssertFalse(service.processEventForTesting(keyDown, source: .monitor))
        currentFlags = []
        XCTAssertFalse(service.processEventForTesting(keyUp, source: .monitor))
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(startCount, 0)
        XCTAssertEqual(stopCount, 0)
        XCTAssertNil(service.currentMode)
    }

    @MainActor
    func testHybridRightOptionSingleTapStillTogglesDictation() async throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(rightOptionModifierHotkey(), for: .hybrid)

        var startCount = 0
        var stopCount = 0
        service.onDictationStart = { _ in startCount += 1 }
        service.onDictationStop = { stopCount += 1 }

        let keyDown = try makeRightOptionModifierEvent(isDown: true)
        let keyUp = try makeRightOptionModifierEvent(isDown: false)

        XCTAssertTrue(service.processEventForTesting(keyDown, source: .eventTap))
        await Task.yield()
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 0)
        XCTAssertEqual(service.currentMode, .pushToTalk)

        XCTAssertTrue(service.processEventForTesting(keyUp, source: .eventTap))
        await Task.yield()
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 0)
        XCTAssertEqual(service.currentMode, .toggle)
    }

    @MainActor
    func testHybridModifierShortcutCancelsPendingHold() async throws {
        let service = HotkeyService()
        service.suspendMonitoring()
        service.hybridModifierHoldActivationDelay = 0.02

        service.setHotkeyForTesting(controlModifierHotkey(), for: .hybrid)

        var currentFlags = NSEvent.ModifierFlags.control
        service.modifierFlagsStateProvider = { currentFlags }

        var startCount = 0
        service.onDictationStart = { _ in startCount += 1 }

        let keyDown = try makeControlModifierEvent(isDown: true)
        let shortcutKeyDown = try makeKeyboardEvent(keyCode: 0x30, keyDown: true, flags: [.maskControl])
        let keyUp = try makeControlModifierEvent(isDown: false)

        XCTAssertFalse(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertFalse(service.processEventForTesting(shortcutKeyDown, source: .monitor))

        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(startCount, 0)
        XCTAssertNil(service.currentMode)

        currentFlags = []
        XCTAssertFalse(service.processEventForTesting(keyUp, source: .monitor))
    }

    @MainActor
    func testEscapeCancelsPendingHybridModifierHold() async throws {
        let service = HotkeyService()
        service.suspendMonitoring()
        service.hybridModifierHoldActivationDelay = 0.02

        service.setHotkeyForTesting(controlModifierHotkey(), for: .hybrid)

        var currentFlags = NSEvent.ModifierFlags.control
        service.modifierFlagsStateProvider = { currentFlags }

        var startCount = 0
        var cancelCount = 0
        service.onDictationStart = { _ in startCount += 1 }
        service.onCancelPressed = { cancelCount += 1 }

        let keyDown = try makeControlModifierEvent(isDown: true)
        let escape = try makeKeyboardEvent(keyCode: 0x35, keyDown: true, flags: [.maskControl])
        let keyUp = try makeControlModifierEvent(isDown: false)

        XCTAssertFalse(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertFalse(service.processEventForTesting(escape, source: .monitor))

        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(startCount, 0)
        XCTAssertNil(service.currentMode)

        currentFlags = []
        XCTAssertFalse(service.processEventForTesting(keyUp, source: .monitor))
    }

    @MainActor
    func testHybridModifierHoldStartsAfterDelayAndShortReleaseTogglesDictation() async throws {
        let service = HotkeyService()
        service.suspendMonitoring()
        service.hybridModifierHoldActivationDelay = 0.02

        service.setHotkeyForTesting(controlModifierHotkey(), for: .hybrid)

        var currentFlags = NSEvent.ModifierFlags.control
        service.modifierFlagsStateProvider = { currentFlags }

        var startCount = 0
        var stopCount = 0
        let started = expectation(description: "hybrid modifier hold starts after delay")
        service.onDictationStart = { _ in
            startCount += 1
            started.fulfill()
        }
        service.onDictationStop = { stopCount += 1 }

        let keyDown = try makeControlModifierEvent(isDown: true)
        let keyUp = try makeControlModifierEvent(isDown: false)

        XCTAssertFalse(service.processEventForTesting(keyDown, source: .monitor))
        await fulfillment(of: [started], timeout: 1.0)
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 0)
        XCTAssertEqual(service.currentMode, .pushToTalk)

        currentFlags = []
        XCTAssertTrue(service.processEventForTesting(keyUp, source: .monitor))
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 0)
        XCTAssertEqual(service.currentMode, .toggle)
    }

    @MainActor
    func testHybridModifierLongHoldStopsAfterRelease() async throws {
        let service = HotkeyService()
        service.suspendMonitoring()
        service.hybridModifierHoldActivationDelay = 0.02

        service.setHotkeyForTesting(controlModifierHotkey(), for: .hybrid)

        var currentFlags = NSEvent.ModifierFlags.control
        service.modifierFlagsStateProvider = { currentFlags }

        var startCount = 0
        var stopCount = 0
        let started = expectation(description: "hybrid modifier hold starts after delay")
        service.onDictationStart = { _ in
            startCount += 1
            started.fulfill()
        }
        service.onDictationStop = { stopCount += 1 }

        let keyDown = try makeControlModifierEvent(isDown: true)
        let keyUp = try makeControlModifierEvent(isDown: false)

        XCTAssertFalse(service.processEventForTesting(keyDown, source: .monitor))
        await fulfillment(of: [started], timeout: 1.0)
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 0)
        XCTAssertEqual(service.currentMode, .pushToTalk)

        try await Task.sleep(for: .milliseconds(1_050))

        currentFlags = []
        XCTAssertTrue(service.processEventForTesting(keyUp, source: .monitor))
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 1)
        XCTAssertNil(service.currentMode)
    }

    @MainActor
    func testHybridModifierDoubleTapStillTogglesDictation() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(controlModifierHotkey(isDoubleTap: true), for: .hybrid)

        var startCount = 0
        var stopCount = 0
        service.onDictationStart = { _ in startCount += 1 }
        service.onDictationStop = { stopCount += 1 }

        let keyDown = try makeControlModifierEvent(isDown: true)
        let keyUp = try makeControlModifierEvent(isDown: false)

        XCTAssertTrue(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertTrue(service.processEventForTesting(keyUp, source: .monitor))
        XCTAssertEqual(startCount, 0)

        XCTAssertTrue(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(service.currentMode, .pushToTalk)

        XCTAssertTrue(service.processEventForTesting(keyUp, source: .monitor))
        XCTAssertEqual(stopCount, 0)
        XCTAssertEqual(service.currentMode, .toggle)
    }

    @MainActor
    func testMonitorFallbackToggleFnStillWorksOnRelease() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(fnHotkey(), for: .toggle)

        var startCount = 0
        service.onDictationStart = { _ in startCount += 1 }

        let keyDown = try makeFnEvent(isDown: true)
        let keyUp = try makeFnEvent(isDown: false)

        XCTAssertFalse(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertEqual(startCount, 0)

        XCTAssertTrue(service.processEventForTesting(keyUp, source: .monitor))
        XCTAssertEqual(startCount, 1)
    }

    @MainActor
    func testRecentTranscriptionsHotkeyInvokesDedicatedCallbackOnKeyDown() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(spaceHotkey(), for: .recentTranscriptions)

        var callbackCount = 0
        var startCount = 0
        service.onRecentTranscriptionsToggle = { callbackCount += 1 }
        service.onDictationStart = { _ in startCount += 1 }

        let keyDown = try makeKeyboardEvent(keyCode: 0x31, keyDown: true)

        XCTAssertTrue(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertEqual(callbackCount, 1)
        XCTAssertEqual(startCount, 0)
        XCTAssertNil(service.currentMode)
    }

    @MainActor
    func testRecentTranscriptionsHotkeyDoesNotStopActiveDictation() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(spaceHotkey(), for: .toggle)
        service.setHotkeyForTesting(commandOptionAHotkey(), for: .recentTranscriptions)

        var startCount = 0
        var stopCount = 0
        var callbackCount = 0
        service.onDictationStart = { _ in startCount += 1 }
        service.onDictationStop = { stopCount += 1 }
        service.onRecentTranscriptionsToggle = { callbackCount += 1 }

        let toggleDown = try makeKeyboardEvent(keyCode: 0x31, keyDown: true)
        let recentDown = try makeKeyboardEvent(keyCode: 0x00, keyDown: true, flags: [.maskCommand, .maskAlternate])

        XCTAssertTrue(service.processEventForTesting(toggleDown, source: .monitor))
        XCTAssertEqual(startCount, 1)

        XCTAssertTrue(service.processEventForTesting(recentDown, source: .monitor))
        XCTAssertEqual(callbackCount, 1)
        XCTAssertEqual(stopCount, 0)
        XCTAssertEqual(service.currentMode, .toggle)
    }

    @MainActor
    func testCopyLastTranscriptionHotkeyInvokesDedicatedCallbackOnKeyDown() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(commandShiftCHotkey(), for: .copyLastTranscription)

        var callbackCount = 0
        var startCount = 0
        service.onCopyLastTranscription = { callbackCount += 1 }
        service.onDictationStart = { _ in startCount += 1 }

        let keyDown = try makeKeyboardEvent(keyCode: 0x08, keyDown: true, flags: [.maskCommand, .maskShift])

        XCTAssertTrue(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertEqual(callbackCount, 1)
        XCTAssertEqual(startCount, 0)
        XCTAssertNil(service.currentMode)
    }

    @MainActor
    func testCopyLastTranscriptionHotkeyDoesNotStopActiveDictation() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(spaceHotkey(), for: .toggle)
        service.setHotkeyForTesting(commandShiftCHotkey(), for: .copyLastTranscription)

        var startCount = 0
        var stopCount = 0
        var callbackCount = 0
        service.onDictationStart = { _ in startCount += 1 }
        service.onDictationStop = { stopCount += 1 }
        service.onCopyLastTranscription = { callbackCount += 1 }

        let toggleDown = try makeKeyboardEvent(keyCode: 0x31, keyDown: true)
        let copyDown = try makeKeyboardEvent(keyCode: 0x08, keyDown: true, flags: [.maskCommand, .maskShift])

        XCTAssertTrue(service.processEventForTesting(toggleDown, source: .monitor))
        XCTAssertEqual(startCount, 1)

        XCTAssertTrue(service.processEventForTesting(copyDown, source: .monitor))
        XCTAssertEqual(callbackCount, 1)
        XCTAssertEqual(stopCount, 0)
        XCTAssertEqual(service.currentMode, .toggle)
    }

    @MainActor
    func testRecorderToggleHotkeyInvokesDedicatedCallbackOnKeyDown() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(commandOptionAHotkey(), for: .recorderToggle)

        var callbackCount = 0
        var startCount = 0
        service.onRecorderToggle = { callbackCount += 1 }
        service.onDictationStart = { _ in startCount += 1 }

        let keyDown = try makeKeyboardEvent(keyCode: 0x00, keyDown: true, flags: [.maskCommand, .maskAlternate])

        XCTAssertTrue(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertEqual(callbackCount, 1)
        XCTAssertEqual(startCount, 0)
        XCTAssertNil(service.currentMode)
    }

    @MainActor
    func testPausedDictationHotkeysKeepRecorderToggleActive() throws {
        try withCleanDictationHotkeysPausedDefault {
            let service = HotkeyService()
            service.suspendMonitoring()
            service.dictationHotkeysPaused = true

            service.setHotkeyForTesting(commandOptionAHotkey(), for: .recorderToggle)

            var callbackCount = 0
            var startCount = 0
            service.onRecorderToggle = { callbackCount += 1 }
            service.onDictationStart = { _ in startCount += 1 }

            let keyDown = try makeKeyboardEvent(keyCode: 0x00, keyDown: true, flags: [.maskCommand, .maskAlternate])

            XCTAssertTrue(service.processEventForTesting(keyDown, source: .monitor))
            XCTAssertEqual(callbackCount, 1)
            XCTAssertEqual(startCount, 0)
            XCTAssertNil(service.currentMode)
        }
    }

    @MainActor
    func testRecorderToggleHotkeyDoesNotStopActiveDictation() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(spaceHotkey(), for: .toggle)
        service.setHotkeyForTesting(commandOptionAHotkey(), for: .recorderToggle)

        var startCount = 0
        var stopCount = 0
        var callbackCount = 0
        service.onDictationStart = { _ in startCount += 1 }
        service.onDictationStop = { stopCount += 1 }
        service.onRecorderToggle = { callbackCount += 1 }

        let toggleDown = try makeKeyboardEvent(keyCode: 0x31, keyDown: true)
        let recorderDown = try makeKeyboardEvent(keyCode: 0x00, keyDown: true, flags: [.maskCommand, .maskAlternate])

        XCTAssertTrue(service.processEventForTesting(toggleDown, source: .monitor))
        XCTAssertEqual(startCount, 1)

        XCTAssertTrue(service.processEventForTesting(recorderDown, source: .monitor))
        XCTAssertEqual(callbackCount, 1)
        XCTAssertEqual(stopCount, 0)
        XCTAssertEqual(service.currentMode, .toggle)
    }

    @MainActor
    func testMenuShortcutDescriptorSupportsPrintableKeyboardShortcut() {
        let descriptor = HotkeyService.menuShortcutDescriptor(for: commandShiftCHotkey())

        XCTAssertEqual(descriptor?.keyEquivalent, "c")
        XCTAssertEqual(descriptor?.modifiers, [.command, .shift])
    }

    @MainActor
    func testMenuShortcutDescriptorSupportsFunctionKeyShortcut() {
        let hotkey = UnifiedHotkey(
            keyCode: 0x64,
            modifierFlags: NSEvent.ModifierFlags.function.rawValue,
            isFn: false
        )

        let descriptor = HotkeyService.menuShortcutDescriptor(for: hotkey)

        XCTAssertEqual(descriptor?.keyEquivalent, Character(UnicodeScalar(NSF8FunctionKey)!))
        XCTAssertEqual(descriptor?.modifiers, [.function])
    }

    @MainActor
    func testMenuShortcutDescriptorSkipsUnsupportedModifierOnlyShortcut() {
        let descriptor = HotkeyService.menuShortcutDescriptor(for: fnHotkey())

        XCTAssertNil(descriptor)
    }

    @MainActor
    func testKeyWithModifiersRejectsExtraModifiers() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeyForTesting(commandOptionAHotkey(), for: .toggle)

        var startCount = 0
        service.onDictationStart = { _ in startCount += 1 }

        let keyDown = try makeKeyboardEvent(
            keyCode: 0x00,
            keyDown: true,
            flags: [.maskCommand, .maskAlternate, .maskShift]
        )

        XCTAssertFalse(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertEqual(startCount, 0)
    }

    @MainActor
    func testProfileModifierComboRejectsExtraModifiers() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        let profileId = UUID()
        service.registerProfileHotkeys([(id: profileId, hotkey: controlShiftComboHotkey())])

        var startedProfileId: UUID?
        service.onProfileDictationStart = { profileId, _ in startedProfileId = profileId }

        let extraModifierDown = try makeFlagsChangedEvent(
            keyCode: 0x38,
            modifierFlags: [.command, .control, .shift]
        )

        XCTAssertFalse(service.processEventForTesting(extraModifierDown, source: .monitor))
        XCTAssertNil(startedProfileId)
    }

    @MainActor
    func testProfileHotkeysAreIgnoredForLegacyRuntime() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        let profileId = UUID()
        service.registerProfileHotkeys([(id: profileId, hotkey: spaceHotkey())])

        var startedProfileId: UUID?
        service.onProfileDictationStart = { profileId, _ in startedProfileId = profileId }

        let keyDown = try makeKeyboardEvent(keyCode: 0x31, keyDown: true)

        XCTAssertFalse(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertNil(startedProfileId)
        XCTAssertNil(service.currentMode)
    }

    @MainActor
    func testWorkflowHotkeyInvokesDedicatedWorkflowCallback() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        let workflowId = UUID()
        service.registerWorkflowHotkeys([(id: workflowId, hotkey: spaceHotkey(), behavior: .startDictation)])

        var startedWorkflowId: UUID?
        service.onWorkflowDictationStart = { workflowId, _ in startedWorkflowId = workflowId }

        let keyDown = try makeKeyboardEvent(keyCode: 0x31, keyDown: true)
        let keyUp = try makeKeyboardEvent(keyCode: 0x31, keyDown: false)

        XCTAssertTrue(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertEqual(startedWorkflowId, workflowId)
        XCTAssertEqual(service.currentMode, .pushToTalk)
        XCTAssertEqual(service.activeWorkflowId, workflowId)

        XCTAssertTrue(service.processEventForTesting(keyUp, source: .monitor))
        XCTAssertEqual(service.currentMode, .toggle)
        XCTAssertEqual(service.activeWorkflowId, workflowId)
    }

    @MainActor
    func testPausedDictationHotkeysIgnoreWorkflowDictationHotkey() throws {
        try withCleanDictationHotkeysPausedDefault {
            let service = HotkeyService()
            service.suspendMonitoring()
            service.dictationHotkeysPaused = true

            let workflowId = UUID()
            service.registerWorkflowHotkeys([(id: workflowId, hotkey: spaceHotkey(), behavior: .startDictation)])

            var startedWorkflowId: UUID?
            service.onWorkflowDictationStart = { workflowId, _ in startedWorkflowId = workflowId }

            let keyDown = try makeKeyboardEvent(keyCode: 0x31, keyDown: true)

            XCTAssertFalse(service.processEventForTesting(keyDown, source: .monitor))
            XCTAssertNil(startedWorkflowId)
            XCTAssertNil(service.currentMode)
            XCTAssertNil(service.activeWorkflowId)
        }
    }

    @MainActor
    func testWorkflowHotkeyTextProcessingCallbackDoesNotStartDictation() async throws {
        let service = HotkeyService()
        service.suspendMonitoring()
        service.workflowTextProcessingModifierPollInterval = 0.001
        service.workflowTextProcessingModifierReleaseTimeout = 0.25
        service.workflowTextProcessingPostReleaseDelay = 0.001
        service.modifierFlagsStateProvider = { [] }

        let workflowId = UUID()
        service.registerWorkflowHotkeys([(id: workflowId, hotkey: spaceHotkey(), behavior: .processSelectedText)])

        var textWorkflowId: UUID?
        var startedWorkflowId: UUID?
        let textProcessingCallback = expectation(description: "workflow text processing callback")
        service.onWorkflowTextProcessing = {
            textWorkflowId = $0
            textProcessingCallback.fulfill()
        }
        service.onWorkflowDictationStart = { workflowId, _ in startedWorkflowId = workflowId }

        let keyDown = try makeKeyboardEvent(keyCode: 0x31, keyDown: true)
        let keyUp = try makeKeyboardEvent(keyCode: 0x31, keyDown: false)

        XCTAssertTrue(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertNil(textWorkflowId)
        XCTAssertNil(startedWorkflowId)
        XCTAssertNil(service.currentMode)
        XCTAssertEqual(service.activeWorkflowId, workflowId)

        XCTAssertTrue(service.processEventForTesting(keyUp, source: .monitor))
        await fulfillment(of: [textProcessingCallback], timeout: 1.0)
        XCTAssertEqual(textWorkflowId, workflowId)
        XCTAssertNil(service.currentMode)
        XCTAssertNil(service.activeWorkflowId)
    }

    @MainActor
    func testPausedDictationHotkeysKeepWorkflowTextProcessingActive() async throws {
        let defaults = UserDefaults.standard
        let key = UserDefaultsKeys.dictationHotkeysPaused
        let original = defaults.object(forKey: key)
        defaults.removeObject(forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let service = HotkeyService()
        service.suspendMonitoring()
        service.dictationHotkeysPaused = true
        service.workflowTextProcessingModifierPollInterval = 0.001
        service.workflowTextProcessingModifierReleaseTimeout = 0.25
        service.workflowTextProcessingPostReleaseDelay = 0.001
        service.modifierFlagsStateProvider = { [] }

        let workflowId = UUID()
        service.registerWorkflowHotkeys([(id: workflowId, hotkey: spaceHotkey(), behavior: .processSelectedText)])

        var textWorkflowId: UUID?
        var startedWorkflowId: UUID?
        let textProcessingCallback = expectation(description: "workflow text processing callback")
        service.onWorkflowTextProcessing = {
            textWorkflowId = $0
            textProcessingCallback.fulfill()
        }
        service.onWorkflowDictationStart = { workflowId, _ in startedWorkflowId = workflowId }

        let keyDown = try makeKeyboardEvent(keyCode: 0x31, keyDown: true)
        let keyUp = try makeKeyboardEvent(keyCode: 0x31, keyDown: false)

        XCTAssertTrue(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertTrue(service.processEventForTesting(keyUp, source: .monitor))
        await fulfillment(of: [textProcessingCallback], timeout: 1.0)
        XCTAssertEqual(textWorkflowId, workflowId)
        XCTAssertNil(startedWorkflowId)
        XCTAssertNil(service.currentMode)
        XCTAssertNil(service.activeWorkflowId)
    }

    @MainActor
    func testWorkflowHotkeyTextProcessingStopsActiveDictationWithoutStartingTextWorkflow() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        let dictationWorkflowId = UUID()
        let textWorkflowId = UUID()
        service.registerWorkflowHotkeys([
            (id: dictationWorkflowId, hotkey: spaceHotkey(), behavior: .startDictation),
            (id: textWorkflowId, hotkey: commandOptionAHotkey(), behavior: .processSelectedText),
        ])

        var startedWorkflowId: UUID?
        var stopCount = 0
        var textProcessingCount = 0
        service.onWorkflowDictationStart = { workflowId, _ in startedWorkflowId = workflowId }
        service.onDictationStop = { stopCount += 1 }
        service.onWorkflowTextProcessing = { _ in textProcessingCount += 1 }

        let dictationKeyDown = try makeKeyboardEvent(keyCode: 0x31, keyDown: true)
        let textWorkflowKeyDown = try makeKeyboardEvent(
            keyCode: 0x00,
            keyDown: true,
            flags: [.maskCommand, .maskAlternate]
        )

        XCTAssertTrue(service.processEventForTesting(dictationKeyDown, source: .monitor))
        XCTAssertEqual(startedWorkflowId, dictationWorkflowId)
        XCTAssertEqual(service.currentMode, .pushToTalk)
        XCTAssertEqual(service.activeWorkflowId, dictationWorkflowId)

        XCTAssertTrue(service.processEventForTesting(textWorkflowKeyDown, source: .monitor))
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(textProcessingCount, 0)
        XCTAssertNil(service.currentMode)
        XCTAssertNil(service.activeWorkflowId)
    }

    @MainActor
    func testWorkflowHotkeyTextProcessingIgnoresKeyUpWithoutActiveKeyDown() async throws {
        let service = HotkeyService()
        service.suspendMonitoring()
        service.workflowTextProcessingModifierPollInterval = 0.001
        service.workflowTextProcessingModifierReleaseTimeout = 0.05
        service.workflowTextProcessingPostReleaseDelay = 0.001
        service.modifierFlagsStateProvider = { [] }

        let workflowId = UUID()
        service.registerWorkflowHotkeys([(id: workflowId, hotkey: spaceHotkey(), behavior: .processSelectedText)])

        var callbackCount = 0
        service.onWorkflowTextProcessing = { _ in callbackCount += 1 }

        let keyUp = try makeKeyboardEvent(keyCode: 0x31, keyDown: false)

        XCTAssertFalse(service.processEventForTesting(keyUp, source: .monitor))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(callbackCount, 0)
        XCTAssertNil(service.activeWorkflowId)
    }

    @MainActor
    func testWorkflowHotkeyTextProcessingWaitsForPhysicalKeyUpAfterModifierRelease() async throws {
        let service = HotkeyService()
        service.suspendMonitoring()
        service.workflowTextProcessingModifierPollInterval = 0.001
        service.workflowTextProcessingModifierReleaseTimeout = 0.25
        service.workflowTextProcessingPostReleaseDelay = 0.001
        service.modifierFlagsStateProvider = { [] }

        let workflowId = UUID()
        service.registerWorkflowHotkeys([(
            id: workflowId,
            hotkey: commandOptionAHotkey(),
            behavior: .processSelectedText
        )])

        var textWorkflowId: UUID?
        let textProcessingCallback = expectation(description: "workflow text processing callback")
        service.onWorkflowTextProcessing = {
            textWorkflowId = $0
            textProcessingCallback.fulfill()
        }

        let keyDown = try makeKeyboardEvent(
            keyCode: 0x00,
            keyDown: true,
            flags: [.maskCommand, .maskAlternate]
        )
        let optionReleaseWhileKeyHeld = try makeFlagsChangedEvent(
            keyCode: 0x3A,
            modifierFlags: [.command]
        )
        let physicalKeyUp = try makeKeyboardEvent(keyCode: 0x00, keyDown: false, flags: [])

        XCTAssertTrue(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertTrue(service.processEventForTesting(optionReleaseWhileKeyHeld, source: .monitor))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(textWorkflowId)
        XCTAssertEqual(service.activeWorkflowId, workflowId)

        XCTAssertTrue(service.processEventForTesting(physicalKeyUp, source: .monitor))
        await fulfillment(of: [textProcessingCallback], timeout: 1.0)
        XCTAssertEqual(textWorkflowId, workflowId)
        XCTAssertNil(service.activeWorkflowId)
    }

    @MainActor
    func testWorkflowHotkeyTextProcessingWaitsForShortcutModifiersToRelease() async throws {
        let service = HotkeyService()
        service.suspendMonitoring()
        service.workflowTextProcessingModifierPollInterval = 0.001
        service.workflowTextProcessingModifierReleaseTimeout = 0.25
        service.workflowTextProcessingPostReleaseDelay = 0.001

        let workflowId = UUID()
        service.registerWorkflowHotkeys([(id: workflowId, hotkey: spaceHotkey(), behavior: .processSelectedText)])

        var currentFlags = NSEvent.ModifierFlags([.control, .option, .shift, .command])
        service.modifierFlagsStateProvider = { currentFlags }

        let callbackAfterRelease = expectation(description: "workflow callback waits for modifier release")
        var textWorkflowId: UUID?
        service.onWorkflowTextProcessing = {
            textWorkflowId = $0
            callbackAfterRelease.fulfill()
        }

        let keyDown = try makeKeyboardEvent(keyCode: 0x31, keyDown: true)
        let keyUp = try makeKeyboardEvent(keyCode: 0x31, keyDown: false)

        XCTAssertTrue(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertTrue(service.processEventForTesting(keyUp, source: .monitor))
        XCTAssertNil(textWorkflowId)

        currentFlags = []
        await fulfillment(of: [callbackAfterRelease], timeout: 1.0)
        XCTAssertEqual(textWorkflowId, workflowId)
    }

    @MainActor
    func testWorkflowHotkeyTextProcessingWaitsForStrayModifiersAfterBareKeyHotkey() async throws {
        let service = HotkeyService()
        service.suspendMonitoring()
        service.workflowTextProcessingModifierPollInterval = 0.001
        service.workflowTextProcessingModifierReleaseTimeout = 0.25
        service.workflowTextProcessingPostReleaseDelay = 0.001

        let workflowId = UUID()
        let bareSpaceHotkey = UnifiedHotkey(keyCode: 0x31, modifierFlags: 0, isFn: false)
        service.registerWorkflowHotkeys([(id: workflowId, hotkey: bareSpaceHotkey, behavior: .processSelectedText)])

        var currentFlags = NSEvent.ModifierFlags([.control, .option, .shift, .command])
        service.modifierFlagsStateProvider = { currentFlags }

        let callbackAfterRelease = expectation(description: "workflow callback waits for stray modifier release")
        var textWorkflowId: UUID?
        service.onWorkflowTextProcessing = {
            textWorkflowId = $0
            callbackAfterRelease.fulfill()
        }

        let keyDown = try makeKeyboardEvent(keyCode: 0x31, keyDown: true, flags: [])
        let keyUp = try makeKeyboardEvent(keyCode: 0x31, keyDown: false, flags: [])

        XCTAssertTrue(service.processEventForTesting(keyDown, source: .monitor))
        XCTAssertTrue(service.processEventForTesting(keyUp, source: .monitor))
        XCTAssertNil(textWorkflowId)

        currentFlags = []
        await fulfillment(of: [callbackAfterRelease], timeout: 1.0)
        XCTAssertEqual(textWorkflowId, workflowId)
    }

    @MainActor
    func testWorkflowCanRegisterMultipleHotkeysForSameWorkflow() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        let workflowId = UUID()
        service.registerWorkflowHotkeys([
            (id: workflowId, hotkey: spaceHotkey(), behavior: .startDictation),
            (id: workflowId, hotkey: alternateSpaceHotkey(), behavior: .startDictation)
        ])

        var startedWorkflowIds: [UUID] = []
        service.onWorkflowDictationStart = { workflowId, _ in startedWorkflowIds.append(workflowId) }

        let firstDown = try makeKeyboardEvent(
            keyCode: 0x31,
            keyDown: true,
            flags: [.maskCommand, .maskAlternate, .maskShift, .maskControl]
        )
        let secondDown = try makeKeyboardEvent(
            keyCode: 0x31,
            keyDown: true,
            flags: [.maskCommand, .maskAlternate]
        )

        XCTAssertTrue(service.processEventForTesting(firstDown, source: .monitor))
        service.cancelDictation()
        XCTAssertTrue(service.processEventForTesting(secondDown, source: .monitor))
        XCTAssertEqual(startedWorkflowIds, [workflowId, workflowId])
    }

    @MainActor
    func testWorkflowModifierComboRejectsExtraModifiers() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        let workflowId = UUID()
        service.registerWorkflowHotkeys([
            (id: workflowId, hotkey: controlShiftComboHotkey(), behavior: .startDictation)
        ])

        var startedWorkflowId: UUID?
        service.onWorkflowDictationStart = { workflowId, _ in startedWorkflowId = workflowId }

        let extraModifierDown = try makeFlagsChangedEvent(
            keyCode: 0x38,
            modifierFlags: [.command, .control, .shift]
        )

        XCTAssertFalse(service.processEventForTesting(extraModifierDown, source: .monitor))
        XCTAssertNil(startedWorkflowId)
    }

    @MainActor
    func testGlobalSlotCanTriggerFromMultipleHotkeys() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeysForTesting([spaceHotkey(), commandOptionAHotkey()], for: .toggle)

        var startCount = 0
        service.onDictationStart = { _ in startCount += 1 }

        let firstDown = try makeKeyboardEvent(keyCode: 0x31, keyDown: true)
        let secondDown = try makeKeyboardEvent(
            keyCode: 0x00,
            keyDown: true,
            flags: [.maskCommand, .maskAlternate]
        )

        XCTAssertTrue(service.processEventForTesting(firstDown, source: .monitor))
        service.cancelDictation()
        XCTAssertTrue(service.processEventForTesting(secondDown, source: .monitor))
        XCTAssertEqual(startCount, 2)
    }

    @MainActor
    func testLoadHotkeysMigratesLegacySingularUserDefaults() throws {
        try withCleanHotkeyDefaults {
            let defaults = UserDefaults.standard
            let legacyHotkey = commandShiftCHotkey()
            defaults.set(try JSONEncoder().encode(legacyHotkey), forKey: HotkeySlotType.copyLastTranscription.defaultsKey)

            let service = HotkeyService()
            service.loadHotkeysForTesting()

            XCTAssertEqual(service.hotkeys(for: .copyLastTranscription), [legacyHotkey])

            let pluralData = try XCTUnwrap(defaults.data(forKey: HotkeySlotType.copyLastTranscription.hotkeysDefaultsKey))
            XCTAssertEqual(try JSONDecoder().decode([UnifiedHotkey].self, from: pluralData), [legacyHotkey])

            let legacyData = try XCTUnwrap(defaults.data(forKey: HotkeySlotType.copyLastTranscription.defaultsKey))
            XCTAssertEqual(try JSONDecoder().decode(UnifiedHotkey.self, from: legacyData), legacyHotkey)
        }
    }

    @MainActor
    func testReplacingPushToTalkHotkeyPersistsPluralAndLegacyDefaults() throws {
        try withCleanHotkeyDefaults {
            let defaults = UserDefaults.standard
            let oldHotkey = controlSpaceHotkey()
            let newHotkey = commandOptionAHotkey()

            let service = HotkeyService()
            service.suspendMonitoring()
            service.updateHotkey(oldHotkey, for: .pushToTalk)
            service.replaceHotkey(oldHotkey, with: newHotkey, for: .pushToTalk)
            service.suspendMonitoring()

            let pluralData = try XCTUnwrap(defaults.data(forKey: HotkeySlotType.pushToTalk.hotkeysDefaultsKey))
            XCTAssertEqual(try JSONDecoder().decode([UnifiedHotkey].self, from: pluralData), [newHotkey])

            let legacyData = try XCTUnwrap(defaults.data(forKey: HotkeySlotType.pushToTalk.defaultsKey))
            XCTAssertEqual(try JSONDecoder().decode(UnifiedHotkey.self, from: legacyData), newHotkey)

            let restoredService = HotkeyService()
            restoredService.loadHotkeysForTesting()
            restoredService.suspendMonitoring()
            XCTAssertEqual(restoredService.hotkeys(for: .pushToTalk), [newHotkey])

            var startCount = 0
            var stopCount = 0
            restoredService.onDictationStart = { _ in startCount += 1 }
            restoredService.onDictationStop = { stopCount += 1 }

            let oldKeyDown = try makeKeyboardEvent(keyCode: 0x31, keyDown: true, flags: [.maskControl])
            XCTAssertFalse(restoredService.processEventForTesting(oldKeyDown, source: .monitor))
            XCTAssertEqual(startCount, 0)

            let newKeyDown = try makeKeyboardEvent(keyCode: 0x00, keyDown: true, flags: [.maskCommand, .maskAlternate])
            let newKeyUp = try makeKeyboardEvent(keyCode: 0x00, keyDown: false, flags: [.maskCommand, .maskAlternate])
            XCTAssertTrue(restoredService.processEventForTesting(newKeyDown, source: .monitor))
            XCTAssertTrue(restoredService.processEventForTesting(newKeyUp, source: .monitor))
            XCTAssertEqual(startCount, 1)
            XCTAssertEqual(stopCount, 1)
        }
    }

    @MainActor
    func testClearingGlobalSlotRemovesPluralAndLegacyPersistence() throws {
        try withCleanHotkeyDefaults {
            let defaults = UserDefaults.standard
            let service = HotkeyService()
            service.suspendMonitoring()

            service.updateHotkey(spaceHotkey(), for: .toggle)
            service.appendHotkey(commandOptionAHotkey(), for: .toggle)

            XCTAssertNotNil(defaults.data(forKey: HotkeySlotType.toggle.defaultsKey))
            XCTAssertNotNil(defaults.data(forKey: HotkeySlotType.toggle.hotkeysDefaultsKey))

            service.clearHotkey(for: .toggle)
            service.suspendMonitoring()

            XCTAssertNil(defaults.data(forKey: HotkeySlotType.toggle.defaultsKey))
            XCTAssertNil(defaults.data(forKey: HotkeySlotType.toggle.hotkeysDefaultsKey))
            XCTAssertTrue(service.hotkeys(for: .toggle).isEmpty)
        }
    }

    @MainActor
    func testRemovingConflictingGlobalHotkeyPreservesOtherBindingsInSlot() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeysForTesting([spaceHotkey(), commandOptionAHotkey()], for: .toggle)

        service.removeConflictingHotkey(spaceHotkey(), for: .toggle)
        service.suspendMonitoring()

        XCTAssertEqual(service.hotkeys(for: .toggle), [commandOptionAHotkey()])
    }

    @MainActor
    func testWorkflowConflictCheckDetectsAnyGlobalSlotBinding() throws {
        let service = HotkeyService()
        service.suspendMonitoring()

        service.setHotkeysForTesting([spaceHotkey(), commandOptionAHotkey()], for: .toggle)

        XCTAssertEqual(service.isHotkeyAssignedToGlobalSlot(commandOptionAHotkey()), .toggle)
    }

    private func withCleanHotkeyDefaults(_ body: () throws -> Void) throws {
        let defaults = UserDefaults.standard
        let keys = HotkeySlotType.allCases.flatMap { [$0.defaultsKey, $0.hotkeysDefaultsKey] }
        let originals = keys.reduce(into: [String: Any]()) { result, key in
            if let value = defaults.object(forKey: key) {
                result[key] = value
            }
        }
        keys.forEach { defaults.removeObject(forKey: $0) }
        defer {
            keys.forEach { key in
                if let value = originals[key] {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        try body()
    }

    private func withCleanDictationHotkeysPausedDefault(_ body: () throws -> Void) throws {
        let defaults = UserDefaults.standard
        let key = UserDefaultsKeys.dictationHotkeysPaused
        let original = defaults.object(forKey: key)
        defaults.removeObject(forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        try body()
    }

    @MainActor
    private func spaceHotkey() -> UnifiedHotkey {
        UnifiedHotkey(
            keyCode: 0x31,
            modifierFlags: NSEvent.ModifierFlags([.control, .option, .shift, .command]).rawValue,
            isFn: false
        )
    }

    @MainActor
    private func alternateSpaceHotkey() -> UnifiedHotkey {
        UnifiedHotkey(
            keyCode: 0x31,
            modifierFlags: NSEvent.ModifierFlags([.option, .command]).rawValue,
            isFn: false
        )
    }

    @MainActor
    private func controlSpaceHotkey() -> UnifiedHotkey {
        UnifiedHotkey(
            keyCode: 0x31,
            modifierFlags: NSEvent.ModifierFlags.control.rawValue,
            isFn: false
        )
    }

    @MainActor
    private func controlShiftComboHotkey() -> UnifiedHotkey {
        UnifiedHotkey(
            keyCode: UnifiedHotkey.modifierComboKeyCode,
            modifierFlags: NSEvent.ModifierFlags([.control, .shift]).rawValue,
            isFn: false
        )
    }

    @MainActor
    private func commandOptionComboHotkey() -> UnifiedHotkey {
        UnifiedHotkey(
            keyCode: UnifiedHotkey.modifierComboKeyCode,
            modifierFlags: NSEvent.ModifierFlags([.command, .option]).rawValue,
            isFn: false
        )
    }

    private func rightCommandRightOptionComboHotkey() throws -> UnifiedHotkey {
        try decodedCommandOptionComboHotkey(modifierKeyCodes: [0x36, 0x3D])
    }

    private func leftCommandLeftOptionComboHotkey() throws -> UnifiedHotkey {
        try decodedCommandOptionComboHotkey(modifierKeyCodes: [0x37, 0x3A])
    }

    private func legacyCommandOptionComboHotkey() throws -> UnifiedHotkey {
        try decodedCommandOptionComboHotkey(modifierKeyCodes: nil)
    }

    private func decodedCommandOptionComboHotkey(modifierKeyCodes: [UInt16]?) throws -> UnifiedHotkey {
        try decodedModifierComboHotkey(
            modifierFlags: [.command, .option],
            modifierKeyCodes: modifierKeyCodes
        )
    }

    private func decodedModifierComboHotkey(
        modifierFlags: NSEvent.ModifierFlags,
        modifierKeyCodes: [UInt16]?
    ) throws -> UnifiedHotkey {
        var payload: [String: Any] = [
            "keyCode": Int(UnifiedHotkey.modifierComboKeyCode),
            "modifierFlags": Int(modifierFlags.rawValue),
            "isFn": false,
            "isDoubleTap": false,
        ]
        if let modifierKeyCodes {
            payload["modifierKeyCodes"] = modifierKeyCodes.map(Int.init)
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(UnifiedHotkey.self, from: data)
    }

    @MainActor
    private func commandOptionAHotkey() -> UnifiedHotkey {
        UnifiedHotkey(
            keyCode: 0x00,
            modifierFlags: NSEvent.ModifierFlags([.command, .option]).rawValue,
            isFn: false
        )
    }

    @MainActor
    private func makeCarbonWorkflowTextProcessingService(
        workflowId: UUID = UUID(),
        hotkey: UnifiedHotkey? = nil,
        keyStateProvider: @escaping (UInt16) -> Bool
    ) -> (service: HotkeyService, workflowId: UUID, hotkey: UnifiedHotkey) {
        let service = HotkeyService()
        service.suspendMonitoring()
        service.workflowTextProcessingModifierPollInterval = 0.001
        service.workflowTextProcessingModifierReleaseTimeout = 0.25
        service.workflowTextProcessingPostReleaseDelay = 0.001
        service.modifierFlagsStateProvider = { [] }
        service.keyStateProvider = keyStateProvider

        let hotkey = hotkey ?? commandOptionAHotkey()
        service.registerWorkflowHotkeys([(id: workflowId, hotkey: hotkey, behavior: .processSelectedText)])
        return (service, workflowId, hotkey)
    }

    @MainActor
    private func commandShiftCHotkey() -> UnifiedHotkey {
        UnifiedHotkey(
            keyCode: 0x08,
            modifierFlags: NSEvent.ModifierFlags([.command, .shift]).rawValue,
            isFn: false
        )
    }

    @MainActor
    private func fnF14Hotkey() -> UnifiedHotkey {
        UnifiedHotkey(
            keyCode: 0x6B,
            modifierFlags: NSEvent.ModifierFlags.function.rawValue,
            isFn: false
        )
    }

    @MainActor
    private func bareSpaceHotkey() -> UnifiedHotkey {
        UnifiedHotkey(
            keyCode: 0x31,
            modifierFlags: 0,
            isFn: false
        )
    }

    @MainActor
    private func fnHotkey() -> UnifiedHotkey {
        UnifiedHotkey(
            keyCode: 0x00,
            modifierFlags: 0,
            isFn: true
        )
    }

    @MainActor
    private func controlModifierHotkey(isDoubleTap: Bool = false) -> UnifiedHotkey {
        UnifiedHotkey(
            keyCode: 0x3B,
            modifierFlags: 0,
            isFn: false,
            isDoubleTap: isDoubleTap
        )
    }

    @MainActor
    private func rightOptionModifierHotkey() -> UnifiedHotkey {
        UnifiedHotkey(
            keyCode: 0x3D,
            modifierFlags: 0,
            isFn: false
        )
    }

    private func makeKeyboardEvent(
        keyCode: UInt16,
        keyDown: Bool,
        flags: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
    ) throws -> NSEvent {
        let event = try XCTUnwrap(
            CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: keyDown)
        )
        event.flags = flags
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }

    private func makeOtherMouseEvent(buttonNumber: UInt32, isDown: Bool) throws -> NSEvent {
        let eventType: CGEventType = isDown ? .otherMouseDown : .otherMouseUp
        let button = try XCTUnwrap(CGMouseButton(rawValue: buttonNumber))
        let event = try XCTUnwrap(
            CGEvent(
                mouseEventSource: nil,
                mouseType: eventType,
                mouseCursorPosition: .zero,
                mouseButton: button
            )
        )
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }

    private func eventMask(for type: CGEventType) -> CGEventMask {
        CGEventMask(1) << type.rawValue
    }

    private func makeFlagsChangedEvent(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .flagsChanged,
                location: .zero,
                modifierFlags: modifierFlags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: keyCode
            )
        )
    }

    private func makeControlModifierEvent(isDown: Bool) throws -> NSEvent {
        try makeFlagsChangedEvent(
            keyCode: 0x3B,
            modifierFlags: isDown ? [.control] : []
        )
    }

    private func makeRightOptionModifierEvent(isDown: Bool) throws -> NSEvent {
        try makeFlagsChangedEvent(
            keyCode: 0x3D,
            modifierFlags: isDown ? [.option] : []
        )
    }

    private func flags(
        generic: NSEvent.ModifierFlags,
        deviceKeyCodes: [UInt16]
    ) -> NSEvent.ModifierFlags {
        let deviceRawValue = deviceKeyCodes.reduce(UInt(0)) { partial, keyCode in
            partial | deviceModifierMask(for: keyCode)
        }
        return NSEvent.ModifierFlags(rawValue: generic.rawValue | deviceRawValue)
    }

    private func deviceModifierMask(for keyCode: UInt16) -> UInt {
        switch keyCode {
        case 0x37: return 0x00000008
        case 0x36: return 0x00000010
        case 0x38: return 0x00000002
        case 0x3C: return 0x00000004
        case 0x3A: return 0x00000020
        case 0x3D: return 0x00000040
        case 0x3B: return 0x00000001
        case 0x3E: return 0x00002000
        default: return 0
        }
    }

    private func makeFnEvent(isDown: Bool) throws -> NSEvent {
        try makeFlagsChangedEvent(
            keyCode: 0x3F,
            modifierFlags: isDown ? [.function] : []
        )
    }
}
