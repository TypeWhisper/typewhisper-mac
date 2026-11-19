import TypeWhisperPluginSDK
import XCTest
@testable import LanguageDetectionPlugin

final class LanguageDetectionPluginTests: XCTestCase {
    func testBundledModelAnswersWithOneOfTheCandidates() async throws {
        // Two seconds of a quiet tone: the answer is meaningless, but the model must load from
        // the plugin bundle and pick a candidate as the host passed it.
        let samples = (0 ..< 32_000).map { Float(sin(Double($0) * 0.05) * 0.1) }

        let result = try await EarModel().identify(samples: samples, among: ["de-DE", "en"], speechSecond: nil)
        let pairResult = try XCTUnwrap(result)
        XCTAssertTrue(["de-DE", "en"].contains(pairResult.language))
        XCTAssertGreaterThanOrEqual(pairResult.confidence, 0.5)

        let unknown = try await LanguageDetectionPlugin().identifySpokenLanguage(samples: samples, among: ["en", "tlh"])
        XCTAssertNil(unknown, "One known candidate leaves the choice to the host")
    }

    func testAudioWithoutSpeechLeavesTheChoiceToTheHost() async throws {
        // Ring-back tone, clicks and room noise, as before a call: the model would hear English
        // in it with a margin near 1 (issue #1970).
        var generator = SystemRandomNumberGenerator()
        let samples = (0 ..< 40 * 16_000).map { index -> Float in
            let seconds = Double(index) / 16_000
            let ring = seconds.truncatingRemainder(dividingBy: 5) < 1.5 ? sin(2 * .pi * 425 * seconds) * 0.2 : 0
            let click: Double = index % 16_000 < 80 ? 0.5 : 0
            return Float(ring + click + Double.random(in: -0.003 ... 0.003, using: &generator))
        }
        let plugin = LanguageDetectionPlugin()

        let speechStart = try SpeechOnset.firstSpeech(in: samples, request: SpeechOnset.makeRequest())
        XCTAssertNil(speechStart)
        let result = try await plugin.identifySpokenLanguage(samples: samples, among: ["nl", "en"])
        XCTAssertNil(result, "Without speech the host uses the first selected language")
        let silence = try await plugin.identifySpokenLanguage(samples: [Float](repeating: 0, count: 8_000), among: ["nl", "en"])
        XCTAssertNil(silence, "A second call reuses the classifier request")
    }

    func testWindowStartsShortlyBeforeTheLoudSoundWhereSpeechStarts() {
        var samples = [Float](repeating: 0, count: 10 * 16_000)
        // A loud click at 0.2 s, then sound from 3.5 s on.
        for index in 3_200 ..< 3_520 { samples[index] = 0.9 }
        for index in 56_000 ..< samples.count { samples[index] = index.isMultiple(of: 2) ? 0.1 : -0.1 }

        XCTAssertEqual(EarScoring.speechWindow(samples).count, samples.count - 1_600, "From 0.1 s before the click")
        let window = EarScoring.speechWindow(samples, speechSecond: 48_000 ..< 64_000)
        XCTAssertEqual(window.count, samples.count - 54_400, "From 0.1 s before the sound in the speech second")
        XCTAssertEqual(EarScoring.speechWindow(samples, speechSecond: samples.count ..< samples.count).count, 0)
    }

    func testQuietSpeechKeepsTheWindowAgainstLouderSoundsElsewhere() {
        var samples = [Float](repeating: 0, count: 100 * 16_000)
        // Speech at about -46 dB from 3 to 8 s, clicks at 1 s and 90 s more than 35 dB louder.
        for index in 48_000 ..< 128_000 { samples[index] = index.isMultiple(of: 2) ? 0.005 : -0.005 }
        for click in [16_000, 1_440_000] {
            for index in click ..< click + 320 { samples[index] = 0.9 }
        }

        let window = EarScoring.speechWindow(samples, speechSecond: 48_000 ..< 64_000)
        XCTAssertEqual(
            window, Array(samples[46_400 ..< 46_400 + EarScoring.windowSamples]),
            "From 0.1 s before the speech, not before the click at 90 s"
        )
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
