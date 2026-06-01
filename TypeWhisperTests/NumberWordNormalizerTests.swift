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

    func testEnglishAndSeparatorDoesNotMergeIndependentNumbers() {
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "two and three", language: "en"), "2 and 3")
        XCTAssertEqual(
            NumberWordNormalizer.normalize(text: "between two and three minutes", language: "en"),
            "between 2 and 3 minutes"
        )
    }

    func testEnglishHundredAndScaleAndStillNormalize() {
        XCTAssertEqual(
            NumberWordNormalizer.normalize(text: "one hundred and twenty three", language: "en"),
            "123"
        )
        XCTAssertEqual(
            NumberWordNormalizer.normalize(text: "one thousand and five", language: "en"),
            "1005"
        )
    }

    func testGermanNegativeDecimalNormalizesToDigits() {
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "minus zwei komma fünf", language: "de"), "-2,5")
    }

    func testFrenchNumbersNormalizeToDigits() {
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "J'ai deux questions", language: "fr"), "J'ai 2 questions")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "vingt trois fichiers", language: "fr"), "23 fichiers")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "mille deux cent trente quatre", language: "fr"), "1234")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "moins deux virgule cinq", language: "fr"), "-2,5")
    }

    func testFrenchArticleOneIsPreservedOutsideClearNumberConstructs() {
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "j'ai un problème", language: "fr"), "j'ai un problème")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "un million de lignes", language: "fr"), "1000000 de lignes")
    }

    func testSpanishNumbersNormalizeToDigits() {
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "tengo dos preguntas", language: "es"), "tengo 2 preguntas")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "veintitrés archivos", language: "es"), "23 archivos")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "veinte y tres archivos", language: "es"), "23 archivos")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "mil doscientos treinta y cuatro", language: "es"), "1234")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "menos dos coma cinco", language: "es"), "-2,5")
    }

    func testSpanishArticleOneIsPreservedOutsideClearNumberConstructs() {
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "tengo un problema", language: "es"), "tengo un problema")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "un millón de filas", language: "es"), "1000000 de filas")
    }

    func testChineseHanNumbersNormalizeToDigits() {
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "我有二十三个文件", language: "zh"), "我有23个文件")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "一千二百三十四", language: "zh"), "1234")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "负二点五", language: "zh"), "-2.5")
    }

    func testJapaneseHanNumbersNormalizeToDigits() {
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "二十三個のファイル", language: "ja"), "23個のファイル")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "千二百三十四", language: "ja"), "1234")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "負二点五", language: "ja"), "-2.5")
    }

    func testJapaneseSingleKanjiInWordsIsPreserved() {
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "一緒に行く", language: "ja"), "一緒に行く")
    }

    func testUnsupportedLanguageIsNoOp() {
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "twenty three", language: "it"), "twenty three")
    }

    func testAlreadyDigitTextIsNoOp() {
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "I have 23 files", language: "en"), "I have 23 files")
    }

    func testGermanArticleOneIsPreservedOutsideClearNumberConstructs() {
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "ich habe ein Problem", language: "de"), "ich habe ein Problem")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "ein hundert Euro", language: "de"), "100 Euro")
    }
}
