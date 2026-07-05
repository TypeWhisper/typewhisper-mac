import XCTest
@testable import TypeWhisper

final class TextDiffServiceTests: XCTestCase {
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
