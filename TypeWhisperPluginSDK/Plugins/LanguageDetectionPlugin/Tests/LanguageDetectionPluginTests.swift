import TypeWhisperPluginSDK
import XCTest
@testable import LanguageDetectionPlugin

final class LanguageDetectionPluginTests: XCTestCase {
    func testBundledModelAnswersWithOneOfTheCandidates() async throws {
        let plugin = LanguageDetectionPlugin()
        // Two seconds of a quiet tone: the answer is meaningless, but the model must load from
        // the plugin bundle and pick a candidate as the host passed it.
        let samples = (0 ..< 32_000).map { Float(sin(Double($0) * 0.05) * 0.1) }

        let result = try await plugin.identifySpokenLanguage(samples: samples, among: ["de-DE", "en"])
        let pairResult = try XCTUnwrap(result)
        XCTAssertTrue(["de-DE", "en"].contains(pairResult.language))
        XCTAssertGreaterThanOrEqual(pairResult.confidence, 0.5)

        let unknown = try await plugin.identifySpokenLanguage(samples: samples, among: ["en", "tlh"])
        XCTAssertNil(unknown, "One known candidate leaves the choice to the host")
    }

    func testWhisperGuessOnlyJoinsWhenItKnowsEveryCandidate() {
        let labels = EarLabels(languages: ["de", "en", "zu"], whisperLanguages: ["de", "en"], whisperWeight: 1)
        let own: [Float] = [log(0.4), log(0.3), log(0.3)]
        let whisper: [Float] = [log(0.1), log(0.9), 0]

        let germanOrEnglish = EarScoring.pick(columns: [("de", 0), ("en", 1)], own: own, whisper: whisper, labels: labels)
        XCTAssertEqual(germanOrEnglish.language, "en")

        let germanOrZulu = EarScoring.pick(columns: [("de", 0), ("zu", 2)], own: own, whisper: whisper, labels: labels)
        XCTAssertEqual(germanOrZulu.language, "de", "Whisper knows no Zulu, so only the own guess counts")
    }

    func testHongKongChineseIsCantoneseWithWhispersChineseScore() {
        let labels = EarLabels(languages: ["en", "yue", "zh"], whisperLanguages: ["en", "zh"], whisperWeight: 1)
        let columns = EarScoring.columns(for: ["zh-TW", "zh-HK", "en"], labels: labels.languages)
        XCTAssertEqual(columns.map(\.code), ["zh-TW", "zh-HK", "en"])
        XCTAssertEqual(columns.map(\.index), [2, 1, 0])

        // Whisper hears Cantonese as Chinese: its Chinese score lifts both Chinese candidates
        // over English, and the own guess picks Cantonese.
        let own: [Float] = [log(0.4), log(0.35), log(0.25)]
        let whisper: [Float] = [log(0.1), 0, log(0.9)]
        XCTAssertEqual(EarScoring.pick(columns: columns, own: own, whisper: whisper, labels: labels).language, "zh-HK")
        XCTAssertEqual(
            EarScoring.pick(columns: [("zh-HK", 1), ("en", 0)], own: own, whisper: whisper, labels: labels).language,
            "zh-HK",
            "Without the stand-in Whisper would drop out and English would win"
        )
    }

    func testCandidatesMapToModelLanguages() {
        let columns = EarScoring.columns(for: ["de-AT", "de", "nb", "pt_BR", "xx"], labels: ["de", "no", "pt"])
        XCTAssertEqual(columns.map(\.code), ["de-AT", "nb", "pt_BR"])
        XCTAssertEqual(columns.map(\.index), [0, 1, 2])
    }
}
