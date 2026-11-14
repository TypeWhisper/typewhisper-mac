import XCTest
@testable import TypeWhisper

final class SOVTranscribePluginTests: XCTestCase {
    func testModelIsOfferedOnlyWithAtLeast32GBOfMemory() {
        XCTAssertTrue(SOVTranscribePlugin.offeredModels(forMemoryGB: 16).isEmpty)
        XCTAssertTrue(SOVTranscribePlugin.offeredModels(forMemoryGB: 24).isEmpty)
        XCTAssertEqual(SOVTranscribePlugin.offeredModels(forMemoryGB: 32).map(\.id), ["sov-transcribe-1-4bit"])
        XCTAssertEqual(SOVTranscribePlugin.offeredModels(forMemoryGB: 64).map(\.id), ["sov-transcribe-1-4bit"])
    }

    func testModelIsPinnedToOneCommit() {
        let model = SOVTranscribePlugin.availableModels[0]
        XCTAssertEqual(model.repoId, "nativ-community/SOV-Transcribe-1-4bit")
        XCTAssertEqual(model.revision, "8a2f46d85735e55c0b6d1c8d882c570ed20d4d5c")
    }

    func testInstructionNamesTheLanguageOrAsksForAnyLanguage() {
        XCTAssertEqual(
            SOVTranscribePlugin.instruction(forLanguage: "de"),
            "Transcribe the German audio into text, ensuring all punctuation marks are included."
        )
        XCTAssertEqual(
            SOVTranscribePlugin.instruction(forLanguage: "pt-BR"),
            "Transcribe the Portuguese audio into text, ensuring all punctuation marks are included."
        )
        XCTAssertEqual(
            SOVTranscribePlugin.instruction(forLanguage: "NL"),
            "Transcribe the Dutch audio into text, ensuring all punctuation marks are included."
        )
        let automatic = "Transcribe the audio verbatim in the language's standard writing system, using punctuation and capitalization. Output only the transcript."
        XCTAssertEqual(SOVTranscribePlugin.instruction(forLanguage: nil), automatic)
        XCTAssertEqual(SOVTranscribePlugin.instruction(forLanguage: "auto"), automatic)
        XCTAssertEqual(SOVTranscribePlugin.instruction(forLanguage: "ja"), automatic)
        XCTAssertEqual(SOVTranscribePlugin.supportedLanguageCodes.count, 7)
    }

    func testTokenBudgetFollowsTheAudioLength() {
        XCTAssertEqual(SOVTranscribePlugin.maxTokens(forAudioDuration: 0), 1_024)
        XCTAssertEqual(SOVTranscribePlugin.maxTokens(forAudioDuration: 5), 1_024)
        XCTAssertEqual(SOVTranscribePlugin.maxTokens(forAudioDuration: 300), 3_000)
        XCTAssertEqual(SOVTranscribePlugin.maxTokens(forAudioDuration: 1_800), 18_000)
        XCTAssertEqual(SOVTranscribePlugin.maxTokens(forAudioDuration: 7_200), 18_000)
        XCTAssertEqual(SOVTranscribePlugin.maximumChunkSampleCount, 1_800 * 16_000)
    }

    func testDictionaryTermsBecomeHotwords() {
        XCTAssertEqual(SOVTranscribePlugin.hotwords(fromPrompt: "TypeWhisper, MLX , Salesforce"), ["TypeWhisper", "MLX", "Salesforce"])
        XCTAssertNil(SOVTranscribePlugin.hotwords(fromPrompt: nil))
        XCTAssertNil(SOVTranscribePlugin.hotwords(fromPrompt: " , "))
    }
}
