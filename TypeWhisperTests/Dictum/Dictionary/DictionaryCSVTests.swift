import XCTest
@testable import TypeWhisper

final class DictionaryCSVTests: XCTestCase {
    func testDocumentedWisprFile() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("wispr-flow.csv")
        let result = try DictionaryCSV.parse(Data(contentsOf: url), format: .wisprFlow)
        XCTAssertEqual(result.items.first, .init(original: "Whisper Flow", replacement: "Wispr Flow"))
        XCTAssertEqual(result.items.last?.original, "NA")
        XCTAssertEqual(result.items[2].original, "00123")
    }

    func testQuotedChineseBOMAndDuplicateRows() throws {
        let csv = "\u{feff}\"项目,星河\",星河项目\r\n\"项目,星河\",星河项目\r\n\r\nQwen3,\r\n"
        let result = try DictionaryCSV.parse(Data(csv.utf8), format: .wordFirst)
        XCTAssertEqual(result.items, [.init(original: "星河项目", replacement: "项目,星河"), .init(original: "Qwen3", replacement: nil)])
        XCTAssertEqual(result.duplicates, 1)
    }

    func testWisprRoundTripPreservesText() throws {
        let items = [DictionaryCSVItem(original: "Whisper Flow", replacement: "Wispr Flow"),
                     .init(original: "00123", replacement: nil),
                     .init(original: "NA", replacement: nil),
                     .init(original: "带有\"引号\"", replacement: "正确,名称")]
        let data = try DictionaryCSV.export(items)
        XCTAssertEqual(try DictionaryCSV.parse(data, format: .wisprFlow).items, items)
    }

    func testLimits() {
        XCTAssertThrowsError(try DictionaryCSV.parse(Data(repeating: 65, count: 5_000_001), format: .wordFirst))
        let csv = (0...3000).map { "项目\($0)" }.joined(separator: "\n")
        XCTAssertThrowsError(try DictionaryCSV.parse(Data(csv.utf8), format: .wordFirst))
    }

    func testMixedColumnCountsAndRejectedRows() throws {
        let result = try DictionaryCSV.parse(Data("Qwen3\nWhisper Flow,Wispr Flow\ninvalid,row,extra\n".utf8), format: .wisprFlow)
        XCTAssertEqual(result.items.count, 2)
        XCTAssertEqual(result.rejected.map(\.row), [3])
    }

    func testWisprEmptyFieldsAndMalformedRowDoNotDiscardValidWords() throws {
        let result = try DictionaryCSV.parse(Data("hello,world,\nword,\n ,correction\n\"unfinished\nQwen3\n".utf8), format: .wisprFlow)
        XCTAssertEqual(result.items, [.init(original: "hello", replacement: "world"), .init(original: "word", replacement: nil), .init(original: "correction", replacement: nil), .init(original: "Qwen3", replacement: nil)])
        XCTAssertEqual(result.rejected.map(\.row), [4])
    }
}
