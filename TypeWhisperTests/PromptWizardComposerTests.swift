import XCTest
@testable import TypeWhisper

final class PromptWizardComposerTests: XCTestCase {
    func testTranslatePromptBuildsExpectedSystemPrompt() {
        var draft = PromptWizardDraft(goal: .translate)
        draft.translationMode = .alternatingPair(primaryLanguage: "en", secondaryLanguage: "de")
        draft.preserveFormatting = true

        let prompt = PromptWizardComposer.compose(from: draft)

        XCTAssertEqual(
            prompt,
            "Translate the following text to English. If it's already in English, translate it to German. Preserve the original formatting when possible. Only return the translation, nothing else."
        )
    }

    func testExtractPromptBuildsJSONInstruction() {
        var draft = PromptWizardDraft(goal: .extract)
        draft.extractFormat = .json

        let prompt = PromptWizardComposer.compose(from: draft)

        XCTAssertEqual(
            prompt,
            "Extract structured data from the following text and format it as valid, well-indented JSON. Use descriptive keys and appropriate data types. Only return the JSON, nothing else."
        )
    }

    func testReviewNarrativeSummarizesPromptGoal() {
        var draft = PromptWizardDraft(goal: .replyEmail)
        draft.replyMode = .reply
        draft.tone = .friendly
        draft.responseLength = .short
        draft.languageMode = .sameAsInput

        XCTAssertEqual(
            PromptWizardComposer.reviewSummary(for: draft),
            "Write a short, friendly reply in the same language as the input."
        )
    }
}
