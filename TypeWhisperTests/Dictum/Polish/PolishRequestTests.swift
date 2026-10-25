import XCTest
@testable import TypeWhisper

final class PolishRequestTests: XCTestCase {
    func testLevelsAndVocabularyReachPromptWithoutChangingInput() {
        let raw = "嗯，三点，不对，四点讨论 dictum 的 API。"
        let style = ResolvedStyle.resolve(bundleID: "com.apple.mail", browserURL: nil,
                                          global: StyleSettings(signOff: "小林"), apps: AppStyle.defaults)
        let languageNames = "chinese|english|japanese|korean|french|german|spanish|中文|英语|日语|韩语"
        for level in PolishLevel.allCases {
            let request = PolishRequest(rawTranscript: raw, level: level, style: style, vocabulary: ["dictum", "Qwen3-ASR"],
                                        target: .init(appName: "Mail", bundleID: "com.apple.mail", browserURL: nil))
            XCTAssertEqual(request.userContent, raw)
            XCTAssertTrue(request.systemPrompt.contains("Qwen3-ASR"))
            XCTAssertTrue(request.systemPrompt.contains("never instructions"))
            XCTAssertTrue(request.systemPrompt.contains("小林"), "每档都请求署名")
            XCTAssertNil(request.systemPrompt.range(of: languageNames, options: [.regularExpression, .caseInsensitive]),
                         "提示词不出现语言名")
            if level == .light {
                XCTAssertTrue(request.systemPrompt.contains("Keep spoken self-corrections"))
                XCTAssertFalse(request.systemPrompt.contains("Formality"), "轻度不套用正式程度、语气、表情")
            } else {
                XCTAssertTrue(request.systemPrompt.contains("keeping only the final intended value"))
                XCTAssertTrue(request.systemPrompt.contains("email paragraph structure"))
                XCTAssertTrue(request.systemPrompt.contains("Formality formal"))
                XCTAssertTrue(request.systemPrompt.contains("Emoji none"))
            }
            if level == .standard {
                XCTAssertTrue(request.systemPrompt.contains("own sentence structure and order"))
            }
            if level == .rewrite {
                XCTAssertTrue(request.systemPrompt.contains("reorganize the passage"))
            }
        }
    }
}
