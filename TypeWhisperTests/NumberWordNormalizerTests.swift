import XCTest
@testable import TypeWhisper

final class NumberWordNormalizerTests: XCTestCase {
    func testEnglishSimpleNumbersNormalizeToDigits() {
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "I have two questions", language: "en"), "I have 2 questions")
    }

    func testGermanSimpleNumbersNormalizeToDigits() {
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "ich habe zwei Fragen", language: "de"), "ich habe 2 Fragen")
    }

    func testEnglishCompoundNumberNormalizesToDigits() {
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "twenty three files", language: "en"), "23 files")
    }

    func testGermanCompoundNumberNormalizesToDigits() {
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "dreiundzwanzig Dateien", language: "de"), "23 Dateien")
    }

    func testEnglishScaleNumberNormalizesToDigits() {
        XCTAssertEqual(
            NumberWordNormalizer.normalize(text: "one thousand two hundred thirty four", language: "en"),
            "1234"
        )
    }

    func testGermanScaleNumberNormalizesToDigits() {
        XCTAssertEqual(
            NumberWordNormalizer.normalize(text: "eintausendzweihundertvierunddreißig", language: "de"),
            "1234"
        )
    }

    func testEnglishNegativeDecimalNormalizesToDigits() {
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "minus two point five", language: "en"), "-2.5")
    }

    func testGermanNegativeDecimalNormalizesToDigits() {
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "minus zwei komma fünf", language: "de"), "-2,5")
    }

    func testUnsupportedLanguageIsNoOp() {
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "twenty three", language: "fr"), "twenty three")
    }

    func testAlreadyDigitTextIsNoOp() {
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "I have 23 files", language: "en"), "I have 23 files")
    }

    func testGermanArticleOneIsPreservedOutsideClearNumberConstructs() {
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "ich habe ein Problem", language: "de"), "ich habe ein Problem")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "ein hundert Euro", language: "de"), "100 Euro")
    }
}
