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
}
