import Foundation
import TypeWhisperPluginSDK
import XCTest
@testable import TypeWhisper

/// How the LLM requests of one piece of work reach its `LLMUsageLedger`: one
/// entry per provider and model, summed over fallback attempts, retries and
/// workflow segments.
@MainActor
final class LLMUsageRecordingTests: XCTestCase {
    private var directories: [URL] = []
    private var defaultsSuites: [String] = []

    override func tearDown() async throws {
        directories.forEach(TestSupport.remove)
        directories = []
        defaultsSuites.forEach { UserDefaults().removePersistentDomain(forName: $0) }
        defaultsSuites = []
        try await super.tearDown()
    }

    // MARK: - Prompt processing

    func testProviderRequestIsRecordedWithTheTokensItReported() async throws {
        let provider = UsageReportingProvider(id: "usage-llm", name: "Usage LLM")
        provider.enqueue(.text("Cleaned.", usage: PluginLLMUsage(inputTokens: 40, outputTokens: 8)))
        let service = try makeService(providers: [provider])
        let ledger = LLMUsageLedger()

        let result = try await LLMUsageLedger.$current.withValue(ledger) {
            try await service.process(prompt: "Clean up.", text: "cleaned", providerOverride: "usage-llm")
        }

        XCTAssertEqual(result, "Cleaned.")
        XCTAssertEqual(ledger.usage?.entries, [
            HistoryLLMUsage.Entry(
                providerId: "usage-llm", providerName: "Usage LLM", model: "model-a",
                requestCount: 1, inputTokens: 40, outputTokens: 8
            ),
        ])
    }

    func testProviderWithoutUsageIsRecordedWithoutTokenCounts() async throws {
        let provider = UsageReportingProvider(id: "silent-llm", name: "Silent LLM")
        provider.enqueue(.text("Cleaned.", usage: nil))
        let service = try makeService(providers: [provider])
        let ledger = LLMUsageLedger()

        _ = try await LLMUsageLedger.$current.withValue(ledger) {
            try await service.process(
                prompt: "Clean up.", text: "cleaned", providerOverride: "silent-llm", cloudModelOverride: "model-b"
            )
        }

        XCTAssertEqual(ledger.usage?.entries, [
            HistoryLLMUsage.Entry(providerId: "silent-llm", providerName: "Silent LLM", model: "model-b", requestCount: 1),
        ])
        XCTAssertFalse(try XCTUnwrap(ledger.usage).hasTokenCounts)
    }

    func testFallbackAttemptsCountWhenTheyUsedTokens() async throws {
        let truncating = UsageReportingProvider(id: "truncating-llm", name: "Truncating LLM")
        truncating.enqueue(.failure(usage: PluginLLMUsage(inputTokens: 30, outputTokens: 4_096)))
        let unreachable = UsageReportingProvider(id: "unreachable-llm", name: "Unreachable LLM")
        unreachable.enqueue(.failure(usage: nil))
        let answering = UsageReportingProvider(id: "answering-llm", name: "Answering LLM")
        answering.enqueue(.text("Cleaned.", usage: PluginLLMUsage(inputTokens: 30, outputTokens: 6, model: "model-a-2026")))
        let service = try makeService(
            providers: [truncating, unreachable, answering],
            fallbacks: ["truncating-llm", "unreachable-llm", "answering-llm"]
        )
        let ledger = LLMUsageLedger()

        let result = try await LLMUsageLedger.$current.withValue(ledger) {
            try await service.process(prompt: "Clean up.", text: "cleaned")
        }

        XCTAssertEqual(result, "Cleaned.")
        XCTAssertEqual(unreachable.processCount, 1)
        XCTAssertEqual(ledger.usage?.entries, [
            HistoryLLMUsage.Entry(
                providerId: "truncating-llm", providerName: "Truncating LLM", model: "model-a",
                requestCount: 1, inputTokens: 30, outputTokens: 4_096
            ),
            HistoryLLMUsage.Entry(
                providerId: "answering-llm", providerName: "Answering LLM", model: "model-a-2026",
                requestCount: 1, inputTokens: 30, outputTokens: 6
            ),
        ])
        XCTAssertEqual(ledger.usage?.inputTokens, 60)
        XCTAssertEqual(ledger.usage?.outputTokens, 4_102)
    }

    func testEmptyResultRetryCountsBothRequests() async throws {
        let provider = UsageReportingProvider(id: "usage-llm", name: "Usage LLM")
        provider.enqueue(.text("", usage: PluginLLMUsage(inputTokens: 25, outputTokens: 0)))
        provider.enqueue(.text("Cleaned.", usage: PluginLLMUsage(inputTokens: 25, outputTokens: 5)))
        let service = try makeService(providers: [provider])
        let ledger = LLMUsageLedger()

        let result = try await LLMUsageLedger.$current.withValue(ledger) {
            try await service.process(prompt: "Clean up.", text: "cleaned", providerOverride: "usage-llm")
        }

        XCTAssertEqual(result, "Cleaned.")
        XCTAssertEqual(ledger.usage?.entries, [
            HistoryLLMUsage.Entry(
                providerId: "usage-llm", providerName: "Usage LLM", model: "model-a",
                requestCount: 2, inputTokens: 50, outputTokens: 5
            ),
        ])
    }

    func testAppleIntelligenceIsRecordedWithoutTokenCounts() async throws {
        let service = try makeService(providers: [])
        service.testingSetAppleIntelligenceProvider(OnDeviceProvider())
        let ledger = LLMUsageLedger()

        _ = try await LLMUsageLedger.$current.withValue(ledger) {
            try await service.process(
                prompt: "Clean up.", text: "cleaned", providerOverride: PromptProcessingService.appleIntelligenceId
            )
        }

        XCTAssertEqual(ledger.usage?.entries, [
            HistoryLLMUsage.Entry(
                providerId: PromptProcessingService.appleIntelligenceId,
                providerName: "Apple Intelligence",
                requestCount: 1
            ),
        ])
    }

    func testRequestsOutsideALedgerAreNotKept() async throws {
        let provider = UsageReportingProvider(id: "usage-llm", name: "Usage LLM")
        let service = try makeService(providers: [provider])
        let ledger = LLMUsageLedger()

        _ = try await LLMUsageLedger.$current.withValue(ledger) {
            try await service.process(prompt: "Clean up.", text: "inside", providerOverride: "usage-llm")
        }
        _ = try await service.process(prompt: "Clean up.", text: "outside", providerOverride: "usage-llm")

        XCTAssertEqual(provider.processCount, 2)
        XCTAssertEqual(ledger.usage?.requestCount, 1, "A request after the ledger's scope must not be added to it")
        XCTAssertNil(LLMUsageLedger.current)
    }

    // MARK: - Post-processing

    func testPipelineRecordsTheLLMStepAlsoWhenItFallsBackToTheRawText() async throws {
        let provider = UsageReportingProvider(id: "usage-llm", name: "Usage LLM")
        provider.enqueue(.text("Cleaned text.", usage: PluginLLMUsage(inputTokens: 12, outputTokens: 3)))
        provider.enqueue(.failure(usage: PluginLLMUsage(inputTokens: 12, outputTokens: 4_096)))
        let service = try makeService(providers: [provider])
        let pipeline = try makePipeline()
        let handler: (String) async throws -> String = { text in
            try await service.process(prompt: "Clean up.", text: text, providerOverride: "usage-llm")
        }

        let succeeded = LLMUsageLedger()
        let processed = try await LLMUsageLedger.$current.withValue(succeeded) {
            try await pipeline.process(
                text: "cleaned text", context: PostProcessingContext(language: "en"),
                llmHandler: handler, llmStepName: "Workflow", llmFailureFallbackText: "cleaned text"
            )
        }
        XCTAssertEqual(processed.text, "Cleaned text.")
        XCTAssertEqual(succeeded.usage?.inputTokens, 12)
        XCTAssertEqual(succeeded.usage?.outputTokens, 3)

        // The raw text is inserted, but the cut-off reply still used tokens.
        let fellBack = LLMUsageLedger()
        let fallback = try await LLMUsageLedger.$current.withValue(fellBack) {
            try await pipeline.process(
                text: "cleaned text", context: PostProcessingContext(language: "en"),
                llmHandler: handler, llmStepName: "Workflow", llmFailureFallbackText: "cleaned text"
            )
        }
        XCTAssertNotNil(fallback.fallback)
        XCTAssertEqual(fellBack.usage?.entries, [
            HistoryLLMUsage.Entry(
                providerId: "usage-llm", providerName: "Usage LLM", model: "model-a",
                requestCount: 1, inputTokens: 12, outputTokens: 4_096
            ),
        ])
    }

    func testChunkedWorkflowSumsEverySegmentRequest() async throws {
        let provider = UsageReportingProvider(id: "usage-llm", name: "Usage LLM")
        let service = try makeService(providers: [provider])
        let text = [Self.firstSentence, Self.secondSentence, Self.thirdSentence].joined(separator: " ")
        let ledger = LLMUsageLedger()

        let outcome = try await LLMUsageLedger.$current.withValue(ledger) {
            try await WorkflowSegmentedPostProcessor(policy: Self.smallPolicy).process(
                text: text,
                incrementalSession: nil,
                incrementalRequest: nil,
                segmentProcessor: { segment in
                    try await service.process(prompt: "Clean up.", text: segment, providerOverride: "usage-llm")
                },
                wholeTextProcessor: {
                    try await service.process(prompt: "Clean up.", text: text, providerOverride: "usage-llm")
                }
            )
        }

        XCTAssertEqual(outcome.report.mode, .chunked)
        let segments = outcome.report.segmentCount
        XCTAssertGreaterThan(segments, 1)
        XCTAssertEqual(provider.processCount, segments)
        XCTAssertEqual(ledger.usage?.entries.count, 1)
        XCTAssertEqual(ledger.usage?.requestCount, segments)
        // The fake reports one input token per character and one output token per request.
        XCTAssertEqual(ledger.usage?.outputTokens, segments)
        XCTAssertEqual(ledger.usage?.inputTokens, provider.receivedTexts.reduce(0) { $0 + $1.count })
    }

    func testIncrementalSegmentsCountInTheSessionLedgerAndCarryOverToItsReplacement() async throws {
        let provider = UsageReportingProvider(id: "usage-llm", name: "Usage LLM")
        let service = try makeService(providers: [provider])
        // The service records a request before it returns, so a finished
        // segment is already in the ledger when the processor signals.
        let (processedSegments, segmentProcessed) = AsyncStream<Void>.makeStream()
        let processor: WorkflowSegmentProcessor = { segment in
            let output = try await service.process(prompt: "Clean up.", text: segment, providerOverride: "usage-llm")
            segmentProcessed.yield()
            return output
        }
        let first = WorkflowIncrementalPostProcessingSession(
            request: Self.request, policy: Self.smallPolicy, prepareInput: { $0 }, processor: processor
        )
        first.ingest(confirmedText: Self.firstSentence + " " + Self.secondSentence)
        XCTAssertEqual(first.committedSegmentCount, 1)
        for await _ in processedSegments { break }
        XCTAssertEqual(first.usage.usage?.requestCount, 1)

        // Restarting the session during the same recording keeps counting.
        first.cancel()
        let replacement = WorkflowIncrementalPostProcessingSession(
            request: Self.request, policy: Self.smallPolicy, prepareInput: { $0 }, processor: processor,
            usage: first.usage
        )
        let confirmed = [Self.firstSentence, Self.secondSentence, Self.thirdSentence].joined(separator: " ")
        replacement.ingest(confirmedText: confirmed)
        let finalInput = confirmed + " " + Self.tailSentence
        guard case .processed = try await replacement.finish(finalInput: finalInput, request: Self.request) else {
            return XCTFail("Expected the incremental results to be reused")
        }

        XCTAssertTrue(replacement.usage === first.usage)
        XCTAssertEqual(replacement.usage.usage?.requestCount, provider.processCount)
        XCTAssertEqual(replacement.usage.usage?.inputTokens, provider.receivedTexts.reduce(0) { $0 + $1.count })

        // The dictation's own ledger takes them over at stop.
        let dictation = LLMUsageLedger()
        dictation.merge(replacement.usage)
        XCTAssertEqual(dictation.usage, replacement.usage.usage)
    }

    // MARK: - Helpers

    private static let smallPolicy = WorkflowSegmentationPolicy(
        targetSegmentLength: 40,
        minimumSegmentLength: 10,
        minimumSplitLength: 60,
        maximumConcurrentRequests: 2,
        incrementalStabilityMargin: 10
    )

    private static let request = WorkflowLLMRequest(
        systemPrompt: "Clean up the dictated text.",
        providerId: "usage-llm",
        cloudModel: nil,
        temperatureDirective: .inheritProviderSetting,
        effortId: nil
    )

    private static let firstSentence = "The first sentence is right here and long."
    private static let secondSentence = "Another sentence follows it with more words."
    private static let thirdSentence = "A third one is also part of this text now."
    private static let tailSentence = "Tail words here."

    private func makeService(
        providers: [UsageReportingProvider],
        fallbacks: [String] = []
    ) throws -> PromptProcessingService {
        let directory = try TestSupport.makeTemporaryDirectory()
        directories.append(directory)
        PluginManager.shared = PluginManager(appSupportDirectory: directory)
        PluginManager.shared.loadedPlugins = providers.map { provider in
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.tests.\(provider.id)",
                    name: provider.name,
                    version: "1.0.0",
                    principalClass: "LLMUsageRecordingTestsProvider"
                ),
                instance: provider,
                bundle: Bundle.main,
                sourceURL: directory,
                isEnabled: true
            )
        }

        let suite = "LLMUsageRecordingTests-\(UUID().uuidString)"
        defaultsSuites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        if !fallbacks.isEmpty {
            defaults.set(
                try JSONEncoder().encode(fallbacks.map { LLMFallbackPriorityItem(providerId: $0) }),
                forKey: UserDefaultsKeys.llmFallbackPriorityList
            )
        }
        return PromptProcessingService(userDefaults: defaults)
    }

    private func makePipeline() throws -> PostProcessingPipeline {
        let directory = try TestSupport.makeTemporaryDirectory()
        directories.append(directory)
        let suite = "LLMUsageRecordingTests-punctuation-\(UUID().uuidString)"
        defaultsSuites.append(suite)
        return PostProcessingPipeline(
            snippetService: SnippetService(appSupportDirectory: directory),
            dictionaryService: DictionaryService(appSupportDirectory: directory),
            punctuationStrategyResolver: PunctuationStrategyResolver(
                profileStore: DictationPunctuationProfileStore(
                    defaults: try XCTUnwrap(UserDefaults(suiteName: suite)),
                    storageKey: suite
                )
            )
        )
    }
}

/// Answers from a queue, then echoes the text in upper case. Reports usage
/// like a provider plugin: through the SDK, from the task that runs `process`.
@objc(LLMUsageRecordingTestsProvider)
private final class UsageReportingProvider: NSObject, LLMProviderPlugin, LLMProviderIdentityProviding, @unchecked Sendable {
    static var pluginId: String { "com.typewhisper.tests.usage-llm" }
    static var pluginName: String { "Usage LLM" }

    enum Reply {
        case text(String, usage: PluginLLMUsage?)
        case failure(usage: PluginLLMUsage?)
    }

    struct Failure: LocalizedError {
        var errorDescription: String? { "The provider failed." }
    }

    let id: String
    let name: String
    private let lock = NSLock()
    private var queue: [Reply] = []
    private var texts: [String] = []

    required override init() {
        id = "usage-llm"
        name = "Usage LLM"
        super.init()
    }

    init(id: String, name: String) {
        self.id = id
        self.name = name
        super.init()
    }

    func activate(host: HostServices) {}
    func deactivate() {}

    var providerName: String { name }
    var providerId: String { id }
    var providerDisplayName: String { name }
    var isAvailable: Bool { true }
    var supportedModels: [PluginModelInfo] {
        [PluginModelInfo(id: "model-a", displayName: "Model A"), PluginModelInfo(id: "model-b", displayName: "Model B")]
    }

    var processCount: Int { lock.withLock { texts.count } }
    var receivedTexts: [String] { lock.withLock { texts } }

    func enqueue(_ reply: Reply) {
        lock.withLock { queue.append(reply) }
    }

    func process(systemPrompt: String, userText: String, model: String?) async throws -> String {
        let reply = lock.withLock { () -> Reply in
            texts.append(userText)
            return queue.isEmpty
                ? .text(userText.uppercased(), usage: PluginLLMUsage(inputTokens: userText.count, outputTokens: 1))
                : queue.removeFirst()
        }
        switch reply {
        case .text(let text, let usage):
            PluginLLMUsageReporting.report(usage)
            return text
        case .failure(let usage):
            PluginLLMUsageReporting.report(usage)
            throw Failure()
        }
    }
}

private struct OnDeviceProvider: LLMProvider {
    var isAvailable: Bool { true }

    func process(systemPrompt: String, userText: String) async throws -> String {
        "On device."
    }
}
