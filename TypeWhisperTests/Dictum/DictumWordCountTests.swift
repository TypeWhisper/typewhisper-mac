import XCTest
@testable import TypeWhisper

final class DictumWordCountTests: XCTestCase {
    func testChineseCharactersCountIndividually() {
        XCTAssertEqual(DictumWordCount.count("部署到 Kubernetes 集群"), 6)
        XCTAssertEqual(DictumWordCount.count("今天下午三点开会"), 8)
    }

    func testEnglishAndNumbersCountAsWords() {
        XCTAssertEqual(DictumWordCount.count("Hello world"), 2)
        XCTAssertEqual(DictumWordCount.count("abc123"), 1)
        XCTAssertEqual(DictumWordCount.count("2026年10月24日"), 6)
    }

    func testJapaneseCountsKanaAndKanjiIndividually() {
        XCTAssertEqual(DictumWordCount.count("こんにちは世界"), 7)
    }

    func testKoreanCountsSyllablesIndividually() {
        XCTAssertEqual(DictumWordCount.count("안녕하세요"), 5)
    }

    func testPunctuationAndEmojiCountNothing() {
        XCTAssertEqual(DictumWordCount.count("你好，世界！"), 4)
        XCTAssertEqual(DictumWordCount.count("😊"), 0)
        XCTAssertEqual(DictumWordCount.count("…"), 0)
        XCTAssertEqual(DictumWordCount.count(""), 0)
    }
}
