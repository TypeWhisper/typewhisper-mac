import XCTest
@testable import TypeWhisper

final class TextDiffServiceTests: XCTestCase {
    func testWordDiffPreservesRepeatedWordTieBreaking() {
        let service = TextDiffService()
        XCTAssertEqual(service.computeWordDiff(original: "a b", processed: "b a"), [
            .removed("a"), .unchanged("b"), .added("a"),
        ])
        XCTAssertEqual(service.computeWordDiff(original: "a a", processed: "a"), [
            .removed("a"), .unchanged("a"),
        ])
        XCTAssertEqual(service.computeWordDiff(original: "a", processed: "a a"), [
            .added("a"), .unchanged("a"),
        ])
    }

    func testWordDiffHandlesEmptyInputsUnicodeAndAnUnchangedSuffix() {
        let service = TextDiffService()
        XCTAssertEqual(service.computeWordDiff(original: "", processed: ""), [])
        XCTAssertEqual(service.computeWordDiff(original: "", processed: "🌍 世界"), [.added("🌍"), .added("世界")])
        XCTAssertEqual(service.computeWordDiff(original: "🌍", processed: ""), [.removed("🌍")])
        XCTAssertEqual(service.computeWordDiff(original: "old\t🌍\n世界", processed: "new 🌍 世界"), [
            .removed("old"), .added("new"), .unchanged("🌍"), .unchanged("世界"),
        ])
        let text = Array(repeating: "word", count: 10_000).joined(separator: " ")
        XCTAssertEqual(service.computeWordDiff(original: text, processed: text), Array(repeating: .unchanged("word"), count: 10_000))
    }

    func testBoundedWordDiffMatchesUnboundedDiffAndRejectsOversizedTables() {
        let service = TextDiffService()
        XCTAssertEqual(
            TextDiffService.wordDiff(
                original: "the quick brown fox",
                processed: "the slow brown fox jumps",
                maxComparisonCells: 20
            ),
            service.computeWordDiff(original: "the quick brown fox", processed: "the slow brown fox jumps")
        )
        // The shared suffix is excluded before the bound is checked.
        XCTAssertEqual(
            TextDiffService.wordDiff(original: "a b c", processed: "x b c", maxComparisonCells: 1),
            [.removed("a"), .added("x"), .unchanged("b"), .unchanged("c")]
        )
        XCTAssertNil(TextDiffService.wordDiff(original: "a b c", processed: "x y z", maxComparisonCells: 8))
        XCTAssertNotNil(TextDiffService.wordDiff(original: "a b c", processed: "x y z", maxComparisonCells: 9))
        XCTAssertEqual(TextDiffService.wordDiff(original: "", processed: "new", maxComparisonCells: 0), [.added("new")])
    }

    func testBoundedWordDiffChecksCancellationPeriodicallyAndStopsWhenCancelled() {
        let wordCount = 1_000
        let original = (0..<wordCount).map { "a\($0)" }.joined(separator: " ")
        let processed = (0..<wordCount).map { "b\($0)" }.joined(separator: " ")
        let cellCount = wordCount * wordCount

        var checks = 0
        let segments = TextDiffService.wordDiff(
            original: original,
            processed: processed,
            maxComparisonCells: .max,
            checkCancellation: { checks += 1 }
        )
        XCTAssertEqual(segments?.count, 2 * wordCount)
        XCTAssertGreaterThanOrEqual(checks, cellCount / TextDiffService.cancellationCheckInterval)

        checks = 0
        XCTAssertThrowsError(
            try TextDiffService.wordDiff(
                original: original,
                processed: processed,
                maxComparisonCells: .max,
                checkCancellation: {
                    checks += 1
                    if checks == 3 { throw CancellationError() }
                }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(checks, 3, "The comparison must stop at the first failed check")
    }

    func testBoundedWordDiffChecksCancellationWithinWideRow() {
        // One word against many forms a single table row, which must not run unchecked.
        let wordCount = 300_000
        let processed = (0..<wordCount).map { "b\($0)" }.joined(separator: " ")

        var checks = 0
        let segments = TextDiffService.wordDiff(
            original: "a",
            processed: processed,
            maxComparisonCells: .max,
            checkCancellation: { checks += 1 }
        )
        XCTAssertEqual(segments?.count, wordCount + 1)
        XCTAssertEqual(checks, 1 + wordCount / TextDiffService.cancellationCheckInterval)

        checks = 0
        XCTAssertThrowsError(
            try TextDiffService.wordDiff(
                original: "a",
                processed: processed,
                maxComparisonCells: .max,
                checkCancellation: {
                    checks += 1
                    if checks == 3 { throw CancellationError() }
                }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(checks, 3)
    }

    func testExtractCorrectionsFindsLocalizedWordReplacement() {
        let service = TextDiffService()

        let suggestions = service.extractCorrections(
            original: "teh quick brown fox",
            edited: "the quick brown fox"
        )

        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.original, "teh")
        XCTAssertEqual(suggestions.first?.replacement, "the")
    }

    func testExtractCorrectionsSkipsLargeRewrites() {
        let service = TextDiffService()

        let suggestions = service.extractCorrections(
            original: "one two three",
            edited: "completely different rewrite here"
        )

        XCTAssertTrue(suggestions.isEmpty)
    }

    func testHighConfidenceExtractionFindsSingleLocalTokenReplacement() {
        let service = TextDiffService()

        let suggestions = service.extractHighConfidenceCorrections(
            original: "please use teh word",
            edited: "please use the word"
        )

        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.original, "teh")
        XCTAssertEqual(suggestions.first?.replacement, "the")
    }

    func testExtractionSkipsNumberToNumberEdits() {
        let service = TextDiffService()

        XCTAssertTrue(service.extractHighConfidenceCorrections(
            original: "accuracy was 90% today",
            edited: "accuracy was 95% today"
        ).isEmpty)
        XCTAssertTrue(service.extractCorrections(
            original: "accuracy was 90% today",
            edited: "accuracy was 95% today"
        ).isEmpty)

        let suggestions = service.extractHighConfidenceCorrections(
            original: "deploy to Kates now",
            edited: "deploy to K8s now"
        )
        XCTAssertEqual(suggestions.first?.original, "Kates")
        XCTAssertEqual(suggestions.first?.replacement, "K8s")
    }

    func testHighConfidenceExtractionSkipsAmbiguousAndLowSignalEdits() {
        let service = TextDiffService()

        XCTAssertTrue(service.extractHighConfidenceCorrections(
            original: "teh langauge",
            edited: "the language"
        ).isEmpty)

        XCTAssertTrue(service.extractHighConfidenceCorrections(
            original: "remove this sentence",
            edited: "write new copy"
        ).isEmpty)

        XCTAssertTrue(service.extractHighConfidenceCorrections(
            original: "remove this sentence",
            edited: ""
        ).isEmpty)

        XCTAssertTrue(service.extractHighConfidenceCorrections(
            original: "teh quick fox",
            edited: "the very quick fox"
        ).isEmpty)

        XCTAssertTrue(service.extractHighConfidenceCorrections(
            original: "TypeWhisper",
            edited: "typewhisper"
        ).isEmpty)

        XCTAssertTrue(service.extractHighConfidenceCorrections(
            original: "hello.",
            edited: "hello!"
        ).isEmpty)

        XCTAssertTrue(service.extractHighConfidenceCorrections(
            original: "teh teh",
            edited: "the them"
        ).isEmpty)

        XCTAssertTrue(service.extractHighConfidenceCorrections(
            original: "one two three four",
            edited: "1 2 3 4"
        ).isEmpty)
    }

    func testHighConfidenceExtractionSegmentsChineseWithoutSpacesByWord() {
        let service = TextDiffService()

        let suggestions = service.extractHighConfidenceCorrections(
            original: "周四下午三点，讨论新河项目，请准备会议记录。",
            edited: "周四下午三点，讨论星河项目，请准备会议记录。"
        )

        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.original, "新河")
        XCTAssertEqual(suggestions.first?.replacement, "星河")
    }

    func testHighConfidenceExtractionLearnsAChineseMishearingSplitIntoSeveralTokens() {
        let service = TextDiffService()

        let suggestions = service.extractHighConfidenceCorrections(
            original: "我想用迪克腾做听写，请帮我打开设置",
            edited: "我想用dictum做听写，请帮我打开设置"
        )

        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.original, "迪克腾")
        XCTAssertEqual(suggestions.first?.replacement, "dictum")
    }

    func testHighConfidenceExtractionSkipsChineseEditsAcrossSeveralClauses() {
        let service = TextDiffService()

        XCTAssertTrue(service.extractHighConfidenceCorrections(
            original: "周四下午三点，讨论新河项目，请准备会议记录。",
            edited: "周五上午九点，讨论星河项目，请准备会议记录。"
        ).isEmpty)
        XCTAssertTrue(service.extractHighConfidenceCorrections(
            original: "周四下午三点，讨论新河项目，请准备会议记录。",
            edited: "周四下午三点，请准备会议记录。"
        ).isEmpty)
    }

    func testChineseAutoLearningKeepsOnlyTheEditedWord() {
        let service = TextDiffService()

        let word = service.extractHighConfidenceCorrections(
            original: "周四下午三点，讨论新河项目，请准备会议记录。",
            edited: "周四下午三点，讨论星河项目，请准备会议记录。"
        )
        XCTAssertEqual(word.map(\.original), ["新河"])
        XCTAssertEqual(word.map(\.replacement), ["星河"])

        let extended = service.extractHighConfidenceCorrections(
            original: "请准备会议记录",
            edited: "请准备会议纪要和议程"
        )
        XCTAssertFalse(extended.contains { $0.replacement == "纪要和议程" })
        XCTAssertTrue(extended.isEmpty || (extended.map(\.original) == ["记录"] && extended.map(\.replacement) == ["纪要"]))
    }

    func testChineseAutoLearningRejectsPhrasesAndSharedTokens() {
        let service = TextDiffService()

        let phrase = service.extractHighConfidenceCorrections(
            original: "周四下午三点，讨论新河项目，请准备会议记录。",
            edited: "周四下午三点，讨论星河方案，请准备会议记录。"
        )
        XCTAssertFalse(phrase.contains { $0.replacement == "星河方案" || $0.original == "新河项目" })

        XCTAssertTrue(service.extractHighConfidenceCorrections(
            original: "讨论新河项目的进度安排",
            edited: "讨论星河计划的时间安排"
        ).isEmpty)
    }

    func testChineseAutoLearningStillLearnsAMishearingSplitIntoManyTokens() {
        let suggestions = TextDiffService().extractHighConfidenceCorrections(
            original: "我们把服务部署到酷伯尼特斯。",
            edited: "我们把服务部署到Kubernetes。"
        )

        XCTAssertEqual(suggestions.map(\.original), ["酷伯尼特斯"])
        XCTAssertEqual(suggestions.map(\.replacement), ["Kubernetes"])
    }

    func testChineseAutoLearningRejectsMultiTokenContentRewrites() {
        let service = TextDiffService()

        XCTAssertTrue(service.extractHighConfidenceCorrections(
            original: "把会议记录和议程安排整理好",
            edited: "把材料整理好"
        ).isEmpty)
        XCTAssertTrue(service.extractHighConfidenceCorrections(
            original: "生产环境的集群已经扩容",
            edited: "线已经扩容"
        ).isEmpty)
        XCTAssertTrue(service.extractHighConfidenceCorrections(
            original: "市场部的同事会参加评审",
            edited: "小王会参加评审"
        ).isEmpty)
        XCTAssertTrue(service.extractHighConfidenceCorrections(
            original: "我们开会讨论了这个方案",
            edited: "我们聊了这个方案"
        ).isEmpty)
    }

    func testChineseAutoLearningRejectsOtherEditShapes() {
        let service = TextDiffService()
        let original = "周四下午三点，讨论新河项目，请准备会议记录。"

        XCTAssertTrue(service.extractHighConfidenceCorrections(
            original: original,
            edited: "周五下午三点，讨论星河项目，请准备会议纪要。"
        ).isEmpty)
        XCTAssertTrue(service.extractHighConfidenceCorrections(
            original: original,
            edited: "周四下午三点，讨论新河项目，请准备会议记录！"
        ).isEmpty)
        XCTAssertTrue(service.extractHighConfidenceCorrections(
            original: original,
            edited: "周四下午三点，讨论项目，请准备会议记录。"
        ).isEmpty)
        XCTAssertTrue(service.extractHighConfidenceCorrections(
            original: original,
            edited: "周四下午三点，讨论新河大项目，请准备会议记录。"
        ).isEmpty)
        XCTAssertTrue(service.extractHighConfidenceCorrections(
            original: "please open Github today",
            edited: "please open GitHub today"
        ).isEmpty)
    }

    func testChineseNumeralToNumeralEditsAreNeverLearned() {
        let service = TextDiffService()

        XCTAssertTrue(service.extractHighConfidenceCorrections(original: "订三份", edited: "订四份").isEmpty)
        XCTAssertTrue(service.extractCorrections(original: "订 三 份", edited: "订 四 份").isEmpty)
        XCTAssertTrue(service.extractHighConfidenceCorrections(original: "共计二十三人", edited: "共计二十四人").isEmpty)
    }

    func testHighConfidenceExtractionHandlesMixedChineseAndEnglish() {
        let service = TextDiffService()

        let suggestions = service.extractHighConfidenceCorrections(
            original: "把 teh 项目发给星河团队",
            edited: "把 the 项目发给星河团队"
        )

        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.original, "teh")
        XCTAssertEqual(suggestions.first?.replacement, "the")
    }

    func testHighConfidenceExtractionKeepsEnglishBehaviour() {
        let service = TextDiffService()

        let suggestions = service.extractHighConfidenceCorrections(
            original: "please use teh word",
            edited: "please use the word"
        )

        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.original, "teh")
        XCTAssertEqual(suggestions.first?.replacement, "the")
    }
}
