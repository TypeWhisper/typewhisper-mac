import XCTest
@testable import TypeWhisper

final class PromptWizardInferenceServiceTests: XCTestCase {
    func testInferenceMapsTranslatePresetToAlternatingPair() throws {
        let preset = try XCTUnwrap(PromptAction.presets.first { $0.icon == "globe" })

        let draft = PromptWizardInferenceService.infer(from: preset)

        XCTAssertEqual(draft.goal, .translate)
        XCTAssertEqual(draft.translationMode, .alternatingPair(primaryLanguage: "en", secondaryLanguage: "de"))
        XCTAssertEqual(draft.icon, "globe")
    }

    func testInferenceMapsJSONPromptToExtractGoal() {
        let action = PromptAction(
            name: "JSON",
            prompt: "Extract structured data from the following text and format it as valid, well-indented JSON. Use descriptive keys and appropriate data types. Only return the JSON, nothing else.",
            icon: "curlybraces"
        )

        let draft = PromptWizardInferenceService.infer(from: action)

        XCTAssertEqual(draft.goal, .extract)
        XCTAssertEqual(draft.extractFormat, .json)
        XCTAssertEqual(draft.icon, "curlybraces")
    }

    func testInferenceMapsReplyPromptToneAndLanguageMode() {
        let action = PromptAction(
            name: "Reply",
            prompt: "Write a concise, friendly reply to the following message. Respond in the same language as the input text. Only return the reply.",
            icon: "arrowshape.turn.up.left"
        )

        let draft = PromptWizardInferenceService.infer(from: action)

        XCTAssertEqual(draft.goal, .replyEmail)
        XCTAssertEqual(draft.replyMode, .reply)
        XCTAssertEqual(draft.tone, .friendly)
        XCTAssertEqual(draft.responseLength, .short)
        XCTAssertEqual(draft.languageMode, .sameAsInput)
    }
}
