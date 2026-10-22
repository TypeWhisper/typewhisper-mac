import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

final class SetupWizardRecommendationAvailabilityTests: XCTestCase {
    func testAppleSpeechFallbackPrefersExactLocaleModel() {
        let modelId = SetupWizardAppleSpeechFallback.preferredModelId(
            from: [
                PluginModelInfo(id: "speechanalyzer-en_US", displayName: "English"),
                PluginModelInfo(id: "speechanalyzer-de_DE", displayName: "German")
            ],
            localeIdentifier: "de_DE",
            languageCode: "de"
        )

        XCTAssertEqual(modelId, "speechanalyzer-de_DE")
    }

    func testAppleSpeechFallbackMatchesLocaleSeparatorVariant() {
        let modelId = SetupWizardAppleSpeechFallback.preferredModelId(
            from: [
                PluginModelInfo(id: "speechanalyzer-de-DE", displayName: "German"),
                PluginModelInfo(id: "speechanalyzer-en_US", displayName: "English")
            ],
            localeIdentifier: "de_DE",
            languageCode: "de"
        )

        XCTAssertEqual(modelId, "speechanalyzer-de-DE")
    }

    func testAppleSpeechFallbackUsesLanguageModelWhenExactLocaleIsMissing() {
        let modelId = SetupWizardAppleSpeechFallback.preferredModelId(
            from: [
                PluginModelInfo(id: "speechanalyzer-en_US", displayName: "English"),
                PluginModelInfo(id: "speechanalyzer-de_CH", displayName: "German Switzerland")
            ],
            localeIdentifier: "de_DE",
            languageCode: "de"
        )

        XCTAssertEqual(modelId, "speechanalyzer-de_CH")
    }

    func testAppleSpeechFallbackUsesFirstModelWhenLocaleCannotMatch() {
        let modelId = SetupWizardAppleSpeechFallback.preferredModelId(
            from: [
                PluginModelInfo(id: "speechanalyzer-fr_FR", displayName: "French"),
                PluginModelInfo(id: "speechanalyzer-en_US", displayName: "English")
            ],
            localeIdentifier: "de_DE",
            languageCode: "de"
        )

        XCTAssertEqual(modelId, "speechanalyzer-fr_FR")
    }

    func testAppleSpeechFallbackReturnsNilForEmptyModelCatalog() {
        let modelId = SetupWizardAppleSpeechFallback.preferredModelId(
            from: [],
            localeIdentifier: "de_DE",
            languageCode: "de"
        )

        XCTAssertNil(modelId)
    }

    func testEngineSelectionUsesAppleSpeechWhenNoEngineAndQwen3IsUnavailable() {
        let providerId = SetupWizardEngineSelection.preferredProviderId(
            selectedProviderId: nil,
            selectedEngineReady: false,
            qwen3Ready: false,
            appleSpeechAvailable: true
        )

        XCTAssertEqual(providerId, SetupWizardAppleSpeechFallback.providerId)
    }

    func testEngineSelectionKeepsReadySelectedEngine() {
        let providerId = SetupWizardEngineSelection.preferredProviderId(
            selectedProviderId: "groq",
            selectedEngineReady: true,
            qwen3Ready: true,
            appleSpeechAvailable: true
        )

        XCTAssertEqual(providerId, "groq")
    }

    func testEngineSelectionPrefersReadyQwen3OverReadyAppleSpeechFallback() {
        let providerId = SetupWizardEngineSelection.preferredProviderId(
            selectedProviderId: SetupWizardAppleSpeechFallback.providerId,
            selectedEngineReady: true,
            qwen3Ready: true,
            appleSpeechAvailable: true
        )

        XCTAssertEqual(providerId, SetupWizardQwen3Recommendation.providerId)
    }

    func testEngineSelectionPrefersQwen3BeforeAppleSpeech() {
        let providerId = SetupWizardEngineSelection.preferredProviderId(
            selectedProviderId: nil,
            selectedEngineReady: false,
            qwen3Ready: true,
            appleSpeechAvailable: true
        )

        XCTAssertEqual(providerId, SetupWizardQwen3Recommendation.providerId)
    }

    func testEngineSelectionReturnsNilWhenNoLocalFallbackIsAvailable() {
        let providerId = SetupWizardEngineSelection.preferredProviderId(
            selectedProviderId: nil,
            selectedEngineReady: false,
            qwen3Ready: false,
            appleSpeechAvailable: false
        )

        XCTAssertNil(providerId)
    }

    func testQwen3RecommendationPrefers17B6BitModel() {
        let modelId = SetupWizardQwen3Recommendation.preferredModelId(
            from: [
                PluginModelInfo(id: "qwen3-asr-0.6b-6bit", displayName: "Qwen3 0.6B 6-bit"),
                PluginModelInfo(id: "qwen3-asr-1.7b-8bit", displayName: "Qwen3 1.7B 8-bit"),
                PluginModelInfo(id: "qwen3-asr-1.7b-6bit", displayName: "Qwen3 1.7B 6-bit")
            ]
        )

        XCTAssertEqual(modelId, "qwen3-asr-1.7b-6bit")
    }

    func testQwen3RecommendationFallsBackToFirstAvailableModel() {
        let modelId = SetupWizardQwen3Recommendation.preferredModelId(
            from: [
                PluginModelInfo(id: "qwen3-asr-0.6b-6bit", displayName: "Qwen3 0.6B 6-bit"),
                PluginModelInfo(id: "qwen3-asr-1.7b-8bit", displayName: "Qwen3 1.7B 8-bit")
            ]
        )

        XCTAssertEqual(modelId, "qwen3-asr-0.6b-6bit")
    }

    func testRecommendedHybridFnCanBeAppliedWhenTriggerSlotsAreEmpty() {
        let state = SetupWizardDefaultHotkey.resolve(
            existingTriggerHotkeys: [:],
            conflictingSlot: nil
        )

        XCTAssertEqual(
            state,
            SetupWizardDefaultHotkey.Resolution(shouldApply: true, blockedReason: nil)
        )
        XCTAssertEqual(
            SetupWizardDefaultHotkey.recommendedHybridHotkey,
            UnifiedHotkey(keyCode: 0, modifierFlags: 0, isFn: true)
        )
    }

    func testRecommendedHybridFnDoesNotOverrideExistingTriggerHotkey() {
        let state = SetupWizardDefaultHotkey.resolve(
            existingTriggerHotkeys: [
                .pushToTalk: [UnifiedHotkey(keyCode: 0x69, modifierFlags: 0, isFn: false)]
            ],
            conflictingSlot: nil
        )

        XCTAssertEqual(
            state,
            SetupWizardDefaultHotkey.Resolution(
                shouldApply: false,
                blockedReason: .existingTriggerHotkey
            )
        )
    }

    func testRecommendedHybridFnDoesNotOverrideConflictingSlot() {
        let state = SetupWizardDefaultHotkey.resolve(
            existingTriggerHotkeys: [:],
            conflictingSlot: .promptPalette
        )

        XCTAssertEqual(
            state,
            SetupWizardDefaultHotkey.Resolution(
                shouldApply: false,
                blockedReason: .conflictingSlot(.promptPalette)
            )
        )
    }

    func testQwen3OnIntelIsUnavailableImmediately() {
        XCTAssertEqual(SetupWizardRecommendationAvailability.resolve(
            manifestId: "com.typewhisper.qwen3", isInstalled: false, isReady: false,
            architecture: "x86_64"
        ), .unavailable(.appleSiliconOnly))
    }

    func testBundledEngineReadyForUse() {
        XCTAssertEqual(SetupWizardRecommendationAvailability.resolve(
            manifestId: "com.typewhisper.qwen3", isInstalled: true, isReady: true,
            architecture: "arm64"
        ), .ready)
    }

    func testBundledEngineRequiresSetup() {
        XCTAssertEqual(SetupWizardRecommendationAvailability.resolve(
            manifestId: "com.typewhisper.qwen3", isInstalled: true, isReady: false,
            architecture: "arm64"
        ), .setupRequired)
    }

    func testMissingEngineIsUnavailable() {
        XCTAssertEqual(SetupWizardRecommendationAvailability.resolve(
            manifestId: "com.typewhisper.qwen3", isInstalled: false, isReady: false,
            architecture: "arm64"
        ), .unavailable(.engineUnavailable))
    }
}
