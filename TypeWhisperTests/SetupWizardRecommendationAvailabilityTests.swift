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

    func testEngineSelectionUsesAppleSpeechWhenNoEngineAndParakeetIsUnavailable() {
        let providerId = SetupWizardEngineSelection.preferredProviderId(
            selectedProviderId: nil,
            selectedEngineReady: false,
            parakeetReady: false,
            appleSpeechAvailable: true
        )

        XCTAssertEqual(providerId, SetupWizardAppleSpeechFallback.providerId)
    }

    func testEngineSelectionKeepsReadySelectedEngine() {
        let providerId = SetupWizardEngineSelection.preferredProviderId(
            selectedProviderId: "groq",
            selectedEngineReady: true,
            parakeetReady: true,
            appleSpeechAvailable: true
        )

        XCTAssertEqual(providerId, "groq")
    }

    func testEngineSelectionPrefersReadyParakeetOverReadyAppleSpeechFallback() {
        let providerId = SetupWizardEngineSelection.preferredProviderId(
            selectedProviderId: SetupWizardAppleSpeechFallback.providerId,
            selectedEngineReady: true,
            parakeetReady: true,
            appleSpeechAvailable: true
        )

        XCTAssertEqual(providerId, SetupWizardParakeetRecommendation.providerId)
    }

    func testEngineSelectionPrefersParakeetBeforeAppleSpeech() {
        let providerId = SetupWizardEngineSelection.preferredProviderId(
            selectedProviderId: nil,
            selectedEngineReady: false,
            parakeetReady: true,
            appleSpeechAvailable: true
        )

        XCTAssertEqual(providerId, SetupWizardParakeetRecommendation.providerId)
    }

    func testEngineSelectionReturnsNilWhenNoLocalFallbackIsAvailable() {
        let providerId = SetupWizardEngineSelection.preferredProviderId(
            selectedProviderId: nil,
            selectedEngineReady: false,
            parakeetReady: false,
            appleSpeechAvailable: false
        )

        XCTAssertNil(providerId)
    }

    func testParakeetRecommendationPrefersUltraModel() {
        let modelId = SetupWizardParakeetRecommendation.preferredModelId(
            from: [
                PluginModelInfo(id: "parakeet-tdt-0.6b-v2", displayName: "Parakeet TDT v2"),
                PluginModelInfo(id: "parakeet-tdt-0.6b-v3", displayName: "Parakeet TDT v3"),
                PluginModelInfo(id: "parakeet-ultra", displayName: "Parakeet Ultra")
            ]
        )

        XCTAssertEqual(modelId, "parakeet-ultra")
    }

    func testParakeetRecommendationFallsBackToV3WithoutUltra() {
        let modelId = SetupWizardParakeetRecommendation.preferredModelId(
            from: [
                PluginModelInfo(id: "parakeet-tdt-0.6b-v2", displayName: "Parakeet TDT v2"),
                PluginModelInfo(id: "parakeet-tdt-0.6b-v3", displayName: "Parakeet TDT v3")
            ]
        )

        XCTAssertEqual(modelId, "parakeet-tdt-0.6b-v3")
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

    func testParakeetOnIntelIsUnavailableImmediately() {
        XCTAssertEqual(SetupWizardRecommendationAvailability.resolve(
            manifestId: "com.typewhisper.parakeet", isInstalled: false, isReady: false,
            architecture: "x86_64"
        ), .unavailable(.appleSiliconOnly))
    }

    func testBundledEngineReadyForUse() {
        XCTAssertEqual(SetupWizardRecommendationAvailability.resolve(
            manifestId: "com.typewhisper.parakeet", isInstalled: true, isReady: true,
            architecture: "arm64"
        ), .ready)
    }

    func testBundledEngineRequiresSetup() {
        XCTAssertEqual(SetupWizardRecommendationAvailability.resolve(
            manifestId: "com.typewhisper.parakeet", isInstalled: true, isReady: false,
            architecture: "arm64"
        ), .setupRequired)
    }

    func testMissingEngineIsUnavailable() {
        XCTAssertEqual(SetupWizardRecommendationAvailability.resolve(
            manifestId: "com.typewhisper.parakeet", isInstalled: false, isReady: false,
            architecture: "arm64"
        ), .unavailable(.engineUnavailable))
    }
}
