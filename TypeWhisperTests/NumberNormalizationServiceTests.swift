@testable import TypeWhisper
import XCTest

@MainActor
final class NumberNormalizationServiceTests: XCTestCase {
    private var service: NumberNormalizationService!

    override func setUp() {
        super.setUp()
        // Reset UserDefaults key so prior test runs do not leak isEnabled=false
        UserDefaults.standard.removeObject(forKey: "itnEnabled")
        service = NumberNormalizationService()
        service.isEnabled = true
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "itnEnabled")
        service = nil
        super.tearDown()
    }

    // MARK: - Cardinals

    func testOneHundredAndTwentyThree() {
        let result = service.normalize("one hundred and twenty three")
        XCTAssertEqual(result, "123")
    }

    func testTwoThousandAndFortyFive() {
        // Falls in [1900,2099] so year detection fires — output is "2045" not "2,045"
        let result = service.normalize("two thousand and forty five")
        XCTAssertEqual(result, "2045")
    }

    func testOneBillionTwoHundredMillion() {
        let result = service.normalize("one billion two hundred million")
        XCTAssertEqual(result, "1,200,000,000")
    }

    // MARK: - Decimals

    func testOnePointFive() {
        let result = service.normalize("one point five")
        XCTAssertEqual(result, "1.5")
    }

    func testThreePointOneFour() {
        let result = service.normalize("three point one four")
        XCTAssertEqual(result, "3.14")
    }

    func testMinusFortyDegrees() {
        let result = service.normalize("minus forty degrees")
        XCTAssertEqual(result, "-40 degrees")
    }

    func testNegativeThreePointTwo() {
        let result = service.normalize("negative three point two")
        XCTAssertEqual(result, "-3.2")
    }

    // MARK: - Currency

    func testTwentyThreeDollars() {
        let result = service.normalize("i owe you twenty three dollars")
        XCTAssertEqual(result, "i owe you $23")
    }

    func testOneHundredAndFiftyEuros() {
        let result = service.normalize("that costs one hundred and fifty euros")
        XCTAssertEqual(result, "that costs €150")
    }

    func testNinetyFivePercent() {
        let result = service.normalize("ninety five percent")
        XCTAssertEqual(result, "95%")
    }

    func testDollarAndCents() {
        let result = service.normalize("one dollar and twenty three cents")
        XCTAssertEqual(result, "$1.23")
    }

    // MARK: - Years

    func testTwentyTwentySix() {
        let result = service.normalize("twenty twenty six")
        XCTAssertEqual(result, "2026")
    }

    func testNineteenEightyFour() {
        let result = service.normalize("nineteen eighty four")
        XCTAssertEqual(result, "1984")
    }

    func testTwoThousandAndOne() {
        let result = service.normalize("two thousand and one")
        XCTAssertEqual(result, "2001")
    }

    // MARK: - Time (with disambiguator)

    func testThreeThirtyPm() {
        let result = service.normalize("the meeting is at three thirty pm")
        XCTAssertEqual(result, "the meeting is at 3:30pm")
    }

    func testFiveOhFiveAm() {
        let result = service.normalize("call me at five oh five am")
        XCTAssertEqual(result, "call me at 5:05am")
    }

    func testNineOClock() {
        let result = service.normalize("at nine o'clock")
        XCTAssertEqual(result, "at 9:00")
    }

    func testThreePm() {
        let result = service.normalize("three pm")
        XCTAssertEqual(result, "3pm")
    }

    // MARK: - Gate — should NOT transform

    func testFirstTimeBuyers() {
        let result = service.normalize("first time buyers")
        XCTAssertEqual(result, "first time buyers")
    }

    func testFiftyCentRapper() {
        let result = service.normalize("fifty cent is a rapper")
        XCTAssertEqual(result, "fifty cent is a rapper")
    }

    func testMeetingWentWell() {
        let result = service.normalize("the meeting went well")
        XCTAssertEqual(result, "the meeting went well")
    }

    // MARK: - Hyphenated Year Spans

    func testTwentyTwentySixHyphenated() {
        let result = service.normalize("twenty twenty-six")
        XCTAssertEqual(result, "2026")
    }

    func testNineteenEightyFourHyphenated() {
        let result = service.normalize("nineteen eighty-four")
        XCTAssertEqual(result, "1984")
    }

    // MARK: - Hyphenated Numbers

    func testHyphenatedTwentyThree() {
        let result = service.normalize("he paid twenty-three dollars")
        XCTAssertEqual(result, "he paid $23")
    }

    func testHyphenatedFortyFivePercent() {
        let result = service.normalize("forty-five percent")
        XCTAssertEqual(result, "45%")
    }

    // MARK: - Per Cent (two words)

    func testPerCentTwoWords() {
        let result = service.normalize("ninety five per cent")
        XCTAssertEqual(result, "95%")
    }

    func testPerCentWithTrailingPeriod() {
        let result = service.normalize("he owned ninety five per cent.")
        XCTAssertEqual(result, "he owned 95%.")
    }

    // MARK: - Indian Scale

    func testThirteenLakh() {
        let result = service.normalize("thirteen lakh")
        XCTAssertEqual(result, "13,00,000")
    }

    func testTwoCrore() {
        let result = service.normalize("two crore")
        XCTAssertEqual(result, "2,00,00,000")
    }

    func testOneLakh() {
        let result = service.normalize("one lakh")
        XCTAssertEqual(result, "1,00,000")
    }

    // MARK: - Mixed Digit+Word Merge

    func testDigitPlusWordSpan() {
        let result = service.normalize("i owe you 100 twenty-three dollars")
        XCTAssertEqual(result, "i owe you $123")
    }

    func testDigitPlusWordSpanNoHyphen() {
        let result = service.normalize("i owe you 100 twenty three dollars")
        XCTAssertEqual(result, "i owe you $123")
    }

    // MARK: - Standalone Cents

    func testStandaloneCents() {
        let result = service.normalize("twenty-five cents")
        XCTAssertEqual(result, "$0.25")
    }

    func testStandaloneCentsNoHyphen() {
        let result = service.normalize("thirty cents")
        XCTAssertEqual(result, "$0.30")
    }

    // MARK: - Trailing Punctuation on Currency Words

    func testCurrencyWordTrailingPeriod() {
        let result = service.normalize("that cost twenty dollars.")
        XCTAssertEqual(result, "that cost $20.")
    }

    func testPercentTrailingPeriod() {
        let result = service.normalize("success rate is ninety percent.")
        XCTAssertEqual(result, "success rate is 90%.")
    }

    // MARK: - isEnabled = false

    func testAllInputsReturnUnchangedWhenDisabled() {
        service.isEnabled = false

        let inputs = [
            "one hundred and twenty three",
            "three point one four",
            "twenty twenty six",
            "twenty three dollars",
            "three pm",
            "first time buyers",
            "fifty cent is a rapper",
            "negative ten",
            "two thousand and one",
            "ninety five percent",
        ]

        for input in inputs {
            let result = service.normalize(input)
            XCTAssertEqual(result, input, "Expected no transformation when ITN is disabled for: \(input)")
        }
    }

    // MARK: - Additional edge cases

    func testEmptyString() {
        let result = service.normalize("")
        XCTAssertEqual(result, "")
    }

    func testWhitespaceOnly() {
        let result = service.normalize("   ")
        XCTAssertEqual(result, "   ")
    }

    func testAlreadyDigitText() {
        let result = service.normalize("I have 5 apples")
        XCTAssertEqual(result, "I have 5 apples")
    }

    func testMixedDigitAndWord() {
        // "ten" is a number word; ITN converts it to "10". The digit "3" and "of" are not merged.
        let result = service.normalize("page 3 of ten")
        XCTAssertEqual(result, "page 3 of 10")
    }

    func testPunctuationReattached() {
        // Trailing comma from "three," is preserved on the digit; "dollars" is consumed by currency pass
        let result = service.normalize("that's one hundred and twenty three, dollars")
        XCTAssertEqual(result, "that's $123,")
    }

    func testFortyFiveDollarCents() {
        let result = service.normalize("forty five dollars and thirty cents")
        XCTAssertEqual(result, "$45.30")
    }

    // MARK: - Bug Fix 1: Crore + Lakh Compound Arithmetic

    func testTwoCroreFiftyLakhs() {
        let result = service.normalize("Two crore fifty lakhs")
        XCTAssertEqual(result, "2,50,00,000")
    }

    // MARK: - Bug Fix 2: Digit Multiplier for Crore/Lakh

    func testDigitCroreAndLakh() {
        let result = service.normalize("2 crore 50 lakh")
        XCTAssertEqual(result, "2,50,00,000")
    }

    func testDigitLakhAndDigits() {
        let result = service.normalize("2 lakh 25,000")
        XCTAssertEqual(result, "2,25,000")
    }

    // MARK: - Bug Fix 3: Dollar + Cents With Punctuation

    func testDollarCommaCentsWithPeriod() {
        let result = service.normalize("One dollar, one cent.")
        XCTAssertEqual(result, "$1.01.")
    }

    func testDollarCommaZeroCentsWithPeriod() {
        let result = service.normalize("One hundred dollars, zero cents.")
        XCTAssertEqual(result, "$100.00.")
    }

    // MARK: - Bug Fix 4: Dollar + Cents Without Connector

    func testDollarCentsNoConnector() {
        let result = service.normalize("One hundred dollars fifty cents")
        XCTAssertEqual(result, "$100.50")
    }

    func testDollarAndCentsWithPeriod() {
        let result = service.normalize("One hundred dollars and fifty cents.")
        XCTAssertEqual(result, "$100.50.")
    }

    // MARK: - Bug Fix 5: Percent Conversion After Number Normalization

    func testZeroPointFivePercent() {
        let result = service.normalize("Zero point five percent.")
        XCTAssertEqual(result, "0.5%.")
    }

    func testIndianThousandsPercent() {
        let result = service.normalize("One hundred twenty three thousand percent.")
        XCTAssertEqual(result, "123,000%.")
    }

    // MARK: - Bug Fix 6: Negative Prefix Handling (Post-Normalization)

    func testMinusZeroPointFivePercent() {
        let result = service.normalize("Minus 0.5%")
        XCTAssertEqual(result, "-0.5%")
    }

    func testMinusAlreadyNormalizedNumber() {
        let result = service.normalize("minus 100")
        XCTAssertEqual(result, "-100")
    }

    // MARK: - Bug Fix 7: "o" as Zero in Digit Sequences

    func testFiveOFive() {
        let result = service.normalize("Five o five.")
        XCTAssertEqual(result, "505.")
    }

    func testFiveOhFive() {
        let result = service.normalize("Five oh five.")
        XCTAssertEqual(result, "505.")
    }

    // MARK: - Bug Fix 8: Prevent Number Merge Across Punctuation

    func testFiftyCommaTwentyThree() {
        let result = service.normalize("Fifty, twenty-three.")
        XCTAssertEqual(result, "50, 23.")
    }

    // MARK: - Bug Fix 9: Currency With Indian Numbers

    func testFiveCroreDollars() {
        let result = service.normalize("Five crore dollars.")
        XCTAssertEqual(result, "$5,00,00,000.")
    }

    func testTwoLakhRupees() {
        let result = service.normalize("two lakh rupees")
        XCTAssertEqual(result, "₹2,00,000")
    }

    // MARK: - Bug Fix 10: Percent Requires Preceding Number

    func testStandalonePercentNotConverted() {
        let result = service.normalize("She got percent of the shares twenty.")
        XCTAssertEqual(result, "She got percent of the shares 20.")
    }
}
