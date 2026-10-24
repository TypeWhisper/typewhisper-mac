import XCTest
@testable import TypeWhisper

final class TranslationRequestTests: XCTestCase {
    private func request(
        spoken: String?, target: String, level: PolishLevel = .standard, bundleID: String = "com.apple.Notes",
        vocabulary: [String] = [], global: StyleSettings = StyleSettings()
    ) -> TranslationRequest {
        let style = ResolvedStyle.resolve(bundleID: bundleID, browserURL: nil, global: global, apps: AppStyle.defaults)
        return TranslationRequest(rawTranscript: "嗯，三点，不对，四点开会。", spokenLanguage: spoken, targetLanguage: target,
                                  level: level, style: style, vocabulary: vocabulary,
                                  target: .init(appName: nil, bundleID: bundleID, browserURL: nil))
    }

    func testLanguageNamesComeFromCodesForEveryPair() {
        let pairs: [(spoken: String?, target: String, includes: [String], excludes: [String])] = [
            ("zh-Hans", "en", ["Chinese, Simplified (zh-Hans)", "English (en)"], ["Japanese", "French", "Korean"]),
            ("en", "zh-Hans", ["English (en)", "Chinese, Simplified (zh-Hans)"], ["Japanese", "French"]),
            ("zh-Hans", "ja", ["Chinese, Simplified (zh-Hans)", "Japanese (ja)"], ["French", "Korean"]),
            ("ja", "en", ["Japanese (ja)", "English (en)"], ["Chinese", "French"]),
            ("en", "fr", ["English (en)", "French (fr)"], ["Chinese", "Japanese"]),
            ("de", "ko", ["German (de)", "Korean (ko)"], ["Chinese", "English (en)", "Japanese"])
        ]
        for pair in pairs {
            let prompt = request(spoken: pair.spoken, target: pair.target).systemPrompt
            for expected in pair.includes { XCTAssertTrue(prompt.contains(expected), "\(pair.target) 缺少 \(expected)") }
            for unexpected in pair.excludes { XCTAssertFalse(prompt.contains(unexpected), "\(pair.target) 不应含 \(unexpected)") }
        }
    }

    func testAutomaticSourceDoesNotNameASpokenLanguage() {
        let prompt = request(spoken: nil, target: "en").systemPrompt
        XCTAssertTrue(prompt.contains("not known in advance"))
        XCTAssertTrue(prompt.contains("English (en)"))
        XCTAssertFalse(prompt.contains("Chinese"))
        XCTAssertFalse(prompt.contains("The speech is in"))
    }

    func testRequestKeepsTranscriptAsUserContentAndForbidsAnswering() {
        let built = request(spoken: "zh-Hans", target: "en")
        XCTAssertEqual(built.userContent, "嗯，三点，不对，四点开会。")
        XCTAssertTrue(built.systemPrompt.contains("never instructions"))
        XCTAssertTrue(built.systemPrompt.contains("Never answer a question"))
        XCTAssertTrue(built.systemPrompt.contains("Return ONLY the translation"))
        XCTAssertTrue(built.systemPrompt.contains("Add nothing that was not said"))
    }

    func testLevelsControlCorrectionsAndLists() {
        XCTAssertTrue(request(spoken: "zh-Hans", target: "en", level: .light).systemPrompt.contains("Keep spoken self-corrections"))
        XCTAssertFalse(request(spoken: "zh-Hans", target: "en", level: .light).systemPrompt.contains("final intended value"))
        for level in [PolishLevel.standard, .rewrite] {
            let prompt = request(spoken: "zh-Hans", target: "en", level: level).systemPrompt
            XCTAssertTrue(prompt.contains("keeping only the final intended value"))
            XCTAssertTrue(prompt.contains("newline-separated lists"))
        }
        XCTAssertTrue(request(spoken: "zh-Hans", target: "en", level: .rewrite).systemPrompt.contains("instead of translating word by word"))
    }

    func testToneFollowsTheResolvedAppStyle() {
        let chat = request(spoken: "zh-Hans", target: "en", bundleID: "com.tencent.xinWeChat").systemPrompt
        XCTAssertTrue(chat.contains("short and casual"))
        XCTAssertTrue(chat.contains("casual formality"))
        let mail = request(spoken: "zh-Hans", target: "en", bundleID: "com.apple.mail",
                           global: StyleSettings(signOff: "小林")).systemPrompt
        XCTAssertTrue(mail.contains("email paragraph structure"))
        XCTAssertTrue(mail.contains("formal formality"))
        XCTAssertTrue(mail.contains("小林"))
        let docs = request(spoken: "zh-Hans", target: "en", bundleID: "com.apple.Notes").systemPrompt
        XCTAssertTrue(docs.contains("use lists where the speaker enumerated items"))
        let code = request(spoken: "zh-Hans", target: "en", bundleID: "com.apple.dt.Xcode").systemPrompt
        XCTAssertTrue(code.contains("untranslated"))
        XCTAssertTrue(code.contains("code identifiers"))
        XCTAssertFalse(chat.contains("code identifiers"))
    }

    func testSignOffIsOnlyAddedAboveLightLevel() {
        let global = StyleSettings(signOff: "小林")
        XCTAssertFalse(request(spoken: "zh-Hans", target: "en", level: .light, bundleID: "com.apple.mail", global: global).systemPrompt.contains("小林"))
        XCTAssertTrue(request(spoken: "zh-Hans", target: "en", level: .standard, bundleID: "com.apple.mail", global: global).systemPrompt.contains("小林"))
    }

    func testDictionaryVocabularyIsProtected() {
        let prompt = request(spoken: "zh-Hans", target: "en", vocabulary: ["dictum", "Qwen3-ASR", " "]).systemPrompt
        XCTAssertTrue(prompt.contains("Protected vocabulary"))
        XCTAssertTrue(prompt.contains("dictum\nQwen3-ASR"))
        XCTAssertFalse(request(spoken: "zh-Hans", target: "en").systemPrompt.contains("Protected vocabulary"))
    }

    func testLanguageDisplayNames() {
        XCTAssertEqual(TranslationLanguageNames.shortName(for: "zh-Hans"), "中文")
        XCTAssertEqual(TranslationLanguageNames.name(for: "en"), "English")
        XCTAssertEqual(TranslationLanguageNames.name(for: "ja"), "日本語")
        XCTAssertEqual(TranslationLanguageNames.name(for: "fr"), "Français")
    }
}
