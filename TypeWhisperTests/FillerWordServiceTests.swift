import XCTest
@testable import TypeWhisper

final class FillerWordServiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var service: FillerWordService!

    override func setUp() {
        super.setUp()
        suiteName = "FillerWordServiceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: UserDefaultsKeys.removeFillerWordsEnabled)
        service = FillerWordService(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        service = nil
        super.tearDown()
    }

    func testBaseFillers() {
        assert("um hello", equals: "hello")
        assert("hello um", equals: "hello")
        assert("uh I think", equals: "I think")
        assert("umm okay", equals: "okay")
        assert("hm interesting", equals: "interesting")
        assert("Um hello", equals: "hello")
        assert("UH WHAT", equals: "WHAT")
    }

    func testBackToBackFillers() {
        assert("um uh hello?", equals: "hello?")
        assert("uh um test", equals: "test")
        assert("um uh hi", equals: "hi")
        assert("um um um", equals: "")
    }

    func testPunctuationSafety() {
        assert("hello um.", equals: "hello.")
        assert("great! uh next", equals: "great! next")
    }

    func testWordBoundarySafety() {
        assert("umbrella", equals: "umbrella")
        assert("humor", equals: "humor")
        assert("summer", equals: "summer")
        assert("ahem", equals: "ahem")
    }

    func testSpacingLocality() {
        assert("This was umm great", equals: "This was great")
        assert("hello  world", equals: "hello  world")
        assert("\n\num hello", equals: "\n\nhello")
    }

    func testCustomFillers() {
        defaults.set("bro, dude", forKey: UserDefaultsKeys.removeFillerWordsCustomList)
        assert("bro what are you doing dude", equals: "what are you doing")
        assert("broccoli", equals: "broccoli")
        assert("bro", equals: "")
    }

    func testFeatureDisabledLeavesTextUnchanged() {
        defaults.set(false, forKey: UserDefaultsKeys.removeFillerWordsEnabled)
        let input = "um hello"
        XCTAssertEqual(service.removeFillerWordsIfEnabled(from: input), input)
    }

    private func assert(_ input: String, equals expected: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(service.removeFillerWordsIfEnabled(from: input), expected, file: file, line: line)
    }
}
