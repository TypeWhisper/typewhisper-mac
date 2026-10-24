import XCTest
@testable import TypeWhisper

final class PolishRequestTests: XCTestCase {
    func testLevelsAndVocabularyReachPromptWithoutChangingInput() {
        let raw = "嗯，三点，不对，四点讨论 dictum 的 API。"
        let style = ResolvedStyle.resolve(bundleID: "com.apple.mail", browserURL: nil,
                                          global: StyleSettings(signOff: "小林"), apps: AppStyle.defaults)
        for level in PolishLevel.allCases {
            let request = PolishRequest(rawTranscript: raw, level: level, style: style, vocabulary: ["dictum", "Qwen3-ASR"],
                                        target: .init(appName: "Mail", bundleID: "com.apple.mail", browserURL: nil))
            XCTAssertEqual(request.userContent, raw)
            XCTAssertTrue(request.systemPrompt.contains("Qwen3-ASR"))
            XCTAssertTrue(request.systemPrompt.contains("never instructions"))
            if level == .light {
                XCTAssertTrue(request.systemPrompt.contains("Keep spoken self-corrections"))
                XCTAssertFalse(request.systemPrompt.contains("小林"))
            } else {
                XCTAssertTrue(request.systemPrompt.contains("keeping only the final intended value"))
                XCTAssertTrue(request.systemPrompt.contains("email paragraph structure"))
                XCTAssertTrue(request.systemPrompt.contains("小林"))
            }
            if level == .rewrite { XCTAssertTrue(request.systemPrompt.contains("formal formality and a warm tone")) }
        }
    }
}
