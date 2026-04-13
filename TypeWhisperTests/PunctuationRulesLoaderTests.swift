import XCTest
@testable import TypeWhisper

final class PunctuationRulesLoaderTests: XCTestCase {
    func testLoaderUsesPrimaryLanguageSubtag() {
        let loader = PunctuationRulesLoader { languageCode in
            guard languageCode == "de" else { return nil }
            return """
            {
              "language": "de",
              "rules": [
                { "phrase": "komma", "replacement": ",", "category": "punctuation" }
              ],
              "verificationScenarios": [
                { "spoken": "hallo komma welt", "expected": "hallo, welt" }
              ]
            }
            """.data(using: .utf8)
        }

        let ruleSet = loader.ruleSet(for: "de-DE")
        XCTAssertEqual(ruleSet?.language, "de")
        XCTAssertEqual(ruleSet?.rules.first?.phrase, "komma")
        XCTAssertEqual(ruleSet?.verificationScenarios.first?.expected, "hallo, welt")
    }
}
