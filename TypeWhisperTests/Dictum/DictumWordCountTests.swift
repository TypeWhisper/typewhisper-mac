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

    func testIdeographWithVariationSelectorCountsAsOneCharacter() {
        XCTAssertEqual(DictumWordCount.count("葛\u{E0100}a"), 2)
        XCTAssertEqual(DictumWordCount.count("葛\u{E0100}葛\u{E0100}"), 2)
    }

    func testApostropheBetweenLettersStaysInsideWord() {
        XCTAssertEqual(DictumWordCount.count("don't"), 1)
        XCTAssertEqual(DictumWordCount.count("don\u{2019}t stop"), 2)
        XCTAssertEqual(DictumWordCount.count("'hello'"), 1)
        XCTAssertEqual(DictumWordCount.count("rock 'n' roll"), 3)
    }

    func testPeriodAndCommaBetweenDigitsStayInsideNumber() {
        XCTAssertEqual(DictumWordCount.count("3.5"), 1)
        XCTAssertEqual(DictumWordCount.count("1,000"), 1)
        XCTAssertEqual(DictumWordCount.count("1,000,000.50"), 1)
        XCTAssertEqual(DictumWordCount.count("version 2.0."), 2)
        XCTAssertEqual(DictumWordCount.count("3. 5"), 2)
        XCTAssertEqual(DictumWordCount.count("a.b"), 2)
        XCTAssertEqual(DictumWordCount.count("Hello, world"), 2)
        XCTAssertEqual(DictumWordCount.count("中文3.5版"), 4)
    }

    func testKatakanaMiddleDotCountsNothing() {
        XCTAssertEqual(DictumWordCount.count("ジョン・スミス"), 6)
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
