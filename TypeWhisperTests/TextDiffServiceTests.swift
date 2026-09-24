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
}
