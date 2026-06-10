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

    func testEnglishCompoundOrdinalNormalizesToDigits() {
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "twenty eighth", language: "en"), "28th")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "thirty first", language: "en"), "31st")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "forty second", language: "en"), "42nd")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "twenty third", language: "en"), "23rd")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "twenty-third", language: "en"), "23rd")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "one hundred first", language: "en"), "101st")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "one hundred twenty first", language: "en"), "121st")
    }

    func testEnglishStandaloneOrdinalNormalizesToDigits() {
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "eighth", language: "en"), "8th")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "twelfth", language: "en"), "12th")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "twentieth", language: "en"), "20th")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "thirtieth", language: "en"), "30th")
    }

    func testEnglishOrdinalSuffixSelection() {
        // st/nd/rd come from compounds; the th-exception (11–13) from teen ordinals.
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "twenty first", language: "en"), "21st")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "twenty second", language: "en"), "22nd")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "twenty third", language: "en"), "23rd")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "fourth", language: "en"), "4th")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "eleventh", language: "en"), "11th")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "twelfth", language: "en"), "12th")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "thirteenth", language: "en"), "13th")
    }

    func testEnglishBareFirstSecondThirdAreLeftUnchanged() {
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "first", language: "en"), "first")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "second", language: "en"), "second")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "third", language: "en"), "third")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "first, let's start", language: "en"), "first, let's start")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "wait a second", language: "en"), "wait a second")
    }

    func testEnglishOrdinalWithinSentenceNormalizesToDigits() {
        XCTAssertEqual(
            NumberWordNormalizer.normalize(text: "the thirty first of May", language: "en"),
            "the 31st of May"
        )
        XCTAssertEqual(
            NumberWordNormalizer.normalize(text: "every twenty fourth hour", language: "en"),
            "every 24th hour"
        )
    }

    func testEnglishOrdinalDigitOutputIsIdempotent() {
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "28th", language: "en"), "28th")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "the 31st of May", language: "en"), "the 31st of May")
    }

    func testEnglishDigitSequenceJoinsBareSingleDigits() {
        // A run of four or more bare single digits is read as one sequence
        // (phone numbers, PINs, codes, digit-by-digit years) instead of the
        // spaced individual digits the cardinal path would emit.
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "one nine eight four", language: "en"), "1984")
        XCTAssertEqual(
            NumberWordNormalizer.normalize(text: "my pin is one two three four", language: "en"),
            "my pin is 1234"
        )
        XCTAssertEqual(
            NumberWordNormalizer.normalize(text: "call five five five one two one two now", language: "en"),
            "call 5551212 now"
        )
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "one two three four dogs", language: "en"), "1234 dogs")
    }

    func testEnglishDigitSequenceReadsOhAsZeroWhenFlanked() {
        XCTAssertEqual(
            NumberWordNormalizer.normalize(text: "five five five oh one two three", language: "en"),
            "5550123"
        )
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "four oh oh two", language: "en"), "4002")
        // A leading zero is preserved because the run is emitted as written.
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "zero one two three", language: "en"), "0123")
    }

    func testEnglishShortDigitRunsStaySplit() {
        // Below the four-digit threshold, dictated counting must not collapse.
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "one two three", language: "en"), "1 2 3")
        // "oh" is only zero when flanked by digits inside a qualifying run;
        // a short run leaves it as an interjection.
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "four oh two", language: "en"), "4 oh 2")
    }

    func testEnglishDigitSequenceDoesNotDisturbCardinalsOrOrdinals() {
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "one hundred", language: "en"), "100")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "two thousand", language: "en"), "2000")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "twenty third", language: "en"), "23rd")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "two point five", language: "en"), "2.5")
    }

    func testEnglishDigitSequenceOutputIsIdempotent() {
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "1984", language: "en"), "1984")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "5550123", language: "en"), "5550123")
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

    func testDutchNumbersNormalizeToDigits() {
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "ik heb twee vragen", language: "nl"), "ik heb 2 vragen")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "drieëntwintig bestanden", language: "nl"), "23 bestanden")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "twee en twintig bestanden", language: "nl"), "22 bestanden")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "duizend tweehonderd vierendertig", language: "nl"), "1234")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "driehonderdvijfendertig", language: "nl"), "335")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "min twee komma vijf", language: "nl"), "-2,5")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "minus een komma vijf", language: "nl"), "-1,5")
    }

    func testDutchArticleOneIsPreservedOutsideClearNumberConstructs() {
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "ik heb een probleem", language: "nl"), "ik heb een probleem")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "een miljoen regels", language: "nl"), "1000000 regels")
        XCTAssertEqual(NumberWordNormalizer.normalize(text: "een komma vijf seconden", language: "nl"), "1,5 seconden")
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
