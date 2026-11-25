import XCTest
@testable import TypeWhisper

final class HistoryTextComparisonTests: XCTestCase {
    private func marked(_ text: String, _ ranges: [Range<String.Index>]) -> [String] {
        ranges.map { String(text[$0]) }
    }

    func testIdenticalTextsHaveNoMarks() {
        let comparison = HistoryTextComparison(current: "Same text.", other: "Same text.")
        XCTAssertEqual(comparison.outcome, .identical)
        XCTAssertTrue(comparison.currentRanges.isEmpty)
        XCTAssertTrue(comparison.otherRanges.isEmpty)
    }

    func testSentenceBrokenMidwayMarksPunctuationAndCapitalization() {
        let current = "I think we should. Ship it tomorrow."
        let other = "I think we should ship it tomorrow."
        let comparison = HistoryTextComparison(current: current, other: other)
        XCTAssertEqual(comparison.outcome, .changed(count: 1))
        XCTAssertEqual(marked(current, comparison.currentRanges), [". Ship"])
        XCTAssertEqual(marked(other, comparison.otherRanges), ["ship"])
    }

    func testSeparatePlacesAreCountedAndOnlyChangedTokensAreMarked() {
        let current = "The quick brown fox, jumps over the dog"
        let other = "The quick red fox jumps over the lazy dog."
        let comparison = HistoryTextComparison(current: current, other: other)
        XCTAssertEqual(comparison.outcome, .changed(count: 4))
        XCTAssertEqual(marked(current, comparison.currentRanges), ["brown", ","])
        XCTAssertEqual(marked(other, comparison.otherRanges), ["red", "lazy", "."])
    }

    func testSpacesAndLineBreaksAloneAreNotMarked() {
        let comparison = HistoryTextComparison(current: "One two\n\nthree", other: "One  two three")
        XCTAssertEqual(comparison.outcome, .whitespaceOnly)
        XCTAssertEqual(comparison.changeCount, 0)
        XCTAssertTrue(comparison.currentRanges.isEmpty)
        XCTAssertTrue(comparison.otherRanges.isEmpty)
    }

    func testTextWithoutSpacesIsComparedCharacterByCharacter() {
        let current = "今日は晴れです。"
        let other = "今日は雨です。"
        let comparison = HistoryTextComparison(current: current, other: other)
        XCTAssertEqual(comparison.outcome, .changed(count: 1))
        XCTAssertEqual(marked(current, comparison.currentRanges), ["晴れ"])
        XCTAssertEqual(marked(other, comparison.otherRanges), ["雨"])
    }

    func testAddedAndRemovedTextAtTheEdges() {
        let added = HistoryTextComparison(current: "", other: "New text")
        XCTAssertEqual(added.outcome, .changed(count: 1))
        XCTAssertEqual(marked("New text", added.otherRanges), ["New text"])
        let removed = HistoryTextComparison(current: "Hello there, world", other: "world")
        XCTAssertEqual(removed.outcome, .changed(count: 1))
        XCTAssertEqual(marked("Hello there, world", removed.currentRanges), ["Hello there,"])
        XCTAssertTrue(removed.otherRanges.isEmpty)
    }

    func testTooManyEditsMarkNothing() {
        let comparison = HistoryTextComparison(current: "one two three", other: "four five six", editLimit: 5)
        XCTAssertEqual(comparison.outcome, .tooManyChanges)
        XCTAssertTrue(comparison.currentRanges.isEmpty)
        XCTAssertTrue(comparison.otherRanges.isEmpty)
        XCTAssertEqual(HistoryTextComparison(current: "one two three", other: "four five six", editLimit: 6).outcome,
                       .changed(count: 1))
    }

    /// The edit script is a shortest one, and the tokens it keeps are equal in both texts.
    func testEditScriptIsMinimalAndConsistentForRandomInputs() throws {
        var generator = SeededGenerator(seed: 0x5EED)
        for _ in 0..<400 {
            let a = (0..<Int.random(in: 0...14, using: &generator)).map { _ in Int32.random(in: 0...3, using: &generator) }
            let b = (0..<Int.random(in: 0...14, using: &generator)).map { _ in Int32.random(in: 0...3, using: &generator) }
            let script = try XCTUnwrap(HistoryTextComparison.editScript(a, b, editLimit: 100))
            let removed = Set(script.removed)
            let added = Set(script.added)
            let keptA = a.indices.filter { !removed.contains($0) }.map { a[$0] }
            let keptB = b.indices.filter { !added.contains($0) }.map { b[$0] }
            XCTAssertEqual(keptA, keptB, "a: \(a) b: \(b)")
            XCTAssertEqual(keptA.count, longestCommonSubsequence(a, b), "a: \(a) b: \(b)")
            XCTAssertEqual(script.removed, script.removed.sorted())
            XCTAssertEqual(script.added, script.added.sorted())
        }
    }

    func testLongTranscriptWithScatteredChangesIsMarkedCompletely() {
        let words = (0..<6_000).map { "word\($0)" }
        let current = words.joined(separator: " ")
        let other = words.enumerated().map { $0.offset.isMultiple(of: 20) ? "Changed" : $0.element }
            .joined(separator: " ")
        let comparison = HistoryTextComparison(current: current, other: other)
        XCTAssertEqual(comparison.outcome, .changed(count: 300))
        XCTAssertEqual(comparison.otherRanges.count, 300)
        XCTAssertTrue(marked(other, comparison.otherRanges).allSatisfy { $0 == "Changed" })
    }

    private func longestCommonSubsequence(_ a: [Int32], _ b: [Int32]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 1...a.count {
            for j in 1...b.count {
                table[i][j] = a[i - 1] == b[j - 1] ? table[i - 1][j - 1] + 1 : max(table[i - 1][j], table[i][j - 1])
            }
        }
        return table[a.count][b.count]
    }
}

/// SplitMix64, so a failing random case can be reproduced.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
