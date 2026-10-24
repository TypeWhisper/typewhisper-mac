import TypeWhisperPluginSDK
import XCTest
@testable import TypeWhisper

@MainActor
final class TranslationPipelineTests: XCTestCase {
    private struct Failure: Error, LocalizedError { var errorDescription: String? { "所有供应商都失败了" } }

    private var appSupport: URL!
    private var pipeline: PostProcessingPipeline!
    private var suite = ""

    override func setUp() async throws {
        try await super.setUp()
        appSupport = try TestSupport.makeTemporaryDirectory(prefix: "dictum-translation-pipeline")
        suite = "dictum-translation-pipeline-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        pipeline = PostProcessingPipeline(
            snippetService: SnippetService(appSupportDirectory: appSupport),
            dictionaryService: DictionaryService(appSupportDirectory: appSupport),
            appFormatterService: nil,
            punctuationStrategyResolver: PunctuationStrategyResolver(
                profileStore: DictationPunctuationProfileStore(defaults: defaults, storageKey: suite))
        )
    }

    override func tearDown() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        TestSupport.remove(appSupport)
        super.tearDown()
    }

    private func handler(pair: TranslationPair?, chain: ChainDouble, bundleID: String = "com.tinyspeck.slackmacgap") -> TranslationHandler.Handler? {
        TranslationHandler.make(
            pair: pair, processor: chain,
            style: ResolvedStyle.resolve(bundleID: bundleID, browserURL: nil, global: StyleSettings(), apps: AppStyle.defaults),
            level: .standard, vocabulary: ["dictum"],
            app: .init(appName: "Slack", bundleID: bundleID, browserURL: nil)
        )
    }

    private func run(_ text: String, through handler: TranslationHandler.Handler?) async throws -> PostProcessingResult {
        try await pipeline.process(
            text: text, context: PostProcessingContext(bundleIdentifier: "com.tinyspeck.slackmacgap", language: "zh"),
            llmHandler: handler, llmStepName: handler == nil ? nil : "Translation", llmFailureFallbackText: text
        )
    }

    func testTranslationSessionCallsTheModelChainWithThePair() async throws {
        let chain = ChainDouble(result: .success("I'm downstairs."))
        let result = try await run("嗯，我到楼下了", through: handler(pair: .init(spoken: "zh-Hans", target: "en"), chain: chain))
        XCTAssertEqual(result.text, "I'm downstairs.")
        XCTAssertNil(result.fallback)
        XCTAssertEqual(result.appliedSteps.last, "Translation")
        XCTAssertEqual(chain.texts, ["嗯，我到楼下了"])
        XCTAssertTrue(chain.prompts[0].contains("English (en)"))
        XCTAssertTrue(chain.prompts[0].contains("Chinese, Simplified (zh-Hans)"))
        XCTAssertTrue(chain.prompts[0].contains("casual formality"), "语气来自聊天应用的风格")
        XCTAssertTrue(chain.prompts[0].contains("dictum"))
    }

    func testAnotherPairChangesThePromptNotTheRoute() async throws {
        let chain = ChainDouble(result: .success("下に着きました。"))
        _ = try await run("I'm downstairs.", through: handler(pair: .init(spoken: "en", target: "ja"), chain: chain))
        XCTAssertTrue(chain.prompts[0].contains("Japanese (ja)"))
        XCTAssertTrue(chain.prompts[0].contains("English (en)"))
        XCTAssertFalse(chain.prompts[0].contains("Chinese"))
    }

    func testFailureInsertsTheOriginalAndReportsTheFallback() async throws {
        let chain = ChainDouble(result: .failure(Failure()))
        let result = try await run("嗯，我到楼下了", through: handler(pair: .init(spoken: "zh-Hans", target: "en"), chain: chain))
        XCTAssertEqual(result.text, "嗯，我到楼下了")
        XCTAssertEqual(result.fallback?.failedStep, "Translation")
        XCTAssertEqual(chain.texts.count, 1)
    }

    func testWithoutAModelThereIsNoHandlerAndTheOriginalPassesThrough() async throws {
        let chain = ChainDouble(result: .success("never used"))
        chain.hasReadyModel = false
        let built = handler(pair: .init(spoken: "zh-Hans", target: "en"), chain: chain)
        XCTAssertNil(built)
        let result = try await run("我到楼下了", through: built)
        XCTAssertEqual(result.text, "我到楼下了")
        XCTAssertNil(result.fallback)
        XCTAssertTrue(chain.texts.isEmpty)
    }

    func testMissingPairProducesNoHandler() {
        XCTAssertNil(handler(pair: nil, chain: ChainDouble(result: .success(""))))
    }

    // MARK: - 语音条状态

    func testVoiceBarShowsTranslationStates() {
        var input = VoiceBarState.Input()
        input.activity = .recording
        input.translation = true
        input.confirmedText = "我到楼下了"
        XCTAssertEqual(VoiceBarState.derive(input), .translating)
        input.targetMenuOpen = true
        XCTAssertEqual(VoiceBarState.derive(input), .targetMenu)
        input.activity = .processing
        XCTAssertEqual(VoiceBarState.derive(input), .polishing(translating: true))
        input = VoiceBarState.Input()
        input.outcome = .translationFailed
        XCTAssertEqual(VoiceBarState.derive(input), .translationFailed)
        input.outcome = .noAI
        XCTAssertEqual(VoiceBarState.derive(input), .noAI)
        input.outcome = .inserted(7)
        XCTAssertEqual(VoiceBarState.derive(input), .inserted(count: 7))
    }

    func testInsertedTranslationIsCountedWithTheSharedWordCount() {
        XCTAssertEqual(DictumWordCount.count("下に着きました。"), 7)
        XCTAssertEqual(DictumWordCount.count("I'm downstairs."), 2)
    }
}
