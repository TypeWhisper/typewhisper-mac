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

    func testParakeetRecommendationPrefersV3Model() {
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
        let state = SetupWizardRecommendationAvailability.resolve(
            manifestId: "com.typewhisper.parakeet",
            isInstalled: false,
            isReady: false,
            registryPlugin: nil,
            installState: nil,
            fetchState: .loaded,
            architecture: "x86_64"
        )

        XCTAssertEqual(state, .unavailable(.appleSiliconOnly))
    }

    func testParakeetOnIntelDoesNotShowLoadingWhileRegistryIsLoading() {
        let state = SetupWizardRecommendationAvailability.resolve(
            manifestId: "com.typewhisper.parakeet",
            isInstalled: false,
            isReady: false,
            registryPlugin: nil,
            installState: nil,
            fetchState: .loading,
            architecture: "x86_64"
        )

        XCTAssertEqual(state, .unavailable(.appleSiliconOnly))
    }

    func testParakeetOnIntelDoesNotShowInstallState() {
        let state = SetupWizardRecommendationAvailability.resolve(
            manifestId: "com.typewhisper.parakeet",
            isInstalled: false,
            isReady: false,
            registryPlugin: nil,
            installState: .downloading(0.42),
            fetchState: .loaded,
            architecture: "x86_64"
        )

        XCTAssertEqual(state, .unavailable(.appleSiliconOnly))
    }

    func testCompatibleRegistryEntryCanBeInstalled() {
        let state = SetupWizardRecommendationAvailability.resolve(
            manifestId: "com.typewhisper.groq",
            isInstalled: false,
            isReady: false,
            registryPlugin: makeRegistryPlugin(id: "com.typewhisper.groq"),
            installState: nil,
            fetchState: .loaded,
            architecture: "x86_64"
        )

        XCTAssertEqual(state, .installAvailable)
    }

    func testInstallStateTakesPrecedenceForCompatibleArchitecture() {
        let state = SetupWizardRecommendationAvailability.resolve(
            manifestId: "com.typewhisper.parakeet",
            isInstalled: false,
            isReady: false,
            registryPlugin: nil,
            installState: .downloading(0.42),
            fetchState: .loaded,
            architecture: "arm64"
        )

        XCTAssertEqual(state, .installState(.downloading(0.42)))
    }

    func testReadyStateTakesPrecedenceForCompatibleArchitecture() {
        let state = SetupWizardRecommendationAvailability.resolve(
            manifestId: "com.typewhisper.parakeet",
            isInstalled: true,
            isReady: true,
            registryPlugin: nil,
            installState: nil,
            fetchState: .loaded,
            architecture: "arm64"
        )

        XCTAssertEqual(state, .ready)
    }

    func testInstalledStateTakesPrecedenceForCompatibleArchitecture() {
        let state = SetupWizardRecommendationAvailability.resolve(
            manifestId: "com.typewhisper.parakeet",
            isInstalled: true,
            isReady: false,
            registryPlugin: nil,
            installState: nil,
            fetchState: .loaded,
            architecture: "arm64"
        )

        XCTAssertEqual(state, .setupRequired)
    }

    func testErrorInstallStateTakesPrecedenceForCompatibleArchitecture() {
        let state = SetupWizardRecommendationAvailability.resolve(
            manifestId: "com.typewhisper.parakeet",
            isInstalled: false,
            isReady: false,
            registryPlugin: nil,
            installState: .error("Download failed"),
            fetchState: .loaded,
            architecture: "arm64"
        )

        XCTAssertEqual(state, .installState(.error("Download failed")))
    }

    private func makeRegistryPlugin(id: String) -> RegistryPlugin {
        RegistryPlugin(
            id: id,
            source: .official,
            name: "Compatible Plugin",
            version: "1.0.0",
            minHostVersion: "1.0.0",
            sdkCompatibilityVersion: "v1",
            minOSVersion: "14.0",
            supportedArchitectures: nil,
            author: "TypeWhisper",
            description: "Compatible transcription engine",
            category: "transcription",
            categories: ["transcription"],
            size: 1,
            downloadURL: "https://example.com/plugin.zip",
            iconSystemName: nil,
            requiresAPIKey: nil,
            hosting: nil,
            descriptions: nil,
            downloadCount: nil
        )
    }
}
