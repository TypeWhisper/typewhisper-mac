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

    func testLoaderSupportsJapanesePrimaryLanguageSubtag() {
        let loader = PunctuationRulesLoader { languageCode in
            guard languageCode == "ja" else { return nil }
            return """
            {
              "language": "ja",
              "rules": [
                { "phrase": "まる", "replacement": "。", "category": "punctuation" }
              ],
              "verificationScenarios": [
                { "spoken": "確認しましたまる", "expected": "確認しました。" }
              ]
            }
            """.data(using: .utf8)
        }

        let ruleSet = loader.ruleSet(for: "ja-JP")
        XCTAssertEqual(ruleSet?.language, "ja")
        XCTAssertEqual(ruleSet?.rules.first?.phrase, "まる")
        XCTAssertEqual(ruleSet?.verificationScenarios.first?.expected, "確認しました。")
    }
}
