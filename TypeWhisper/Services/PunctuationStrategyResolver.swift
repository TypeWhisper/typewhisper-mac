import Foundation

struct ResolvedPunctuationStrategy {
    let languageCode: String
    let strategy: PunctuationStrategy
    let profile: DictationPunctuationProfile
}

@MainActor
final class PunctuationStrategyResolver {
    private let profileStore: DictationPunctuationProfileStore

    init(profileStore: DictationPunctuationProfileStore) {
        self.profileStore = profileStore
    }

    func resolve(
        engineId: String?,
        modelId: String?,
        configuredLanguage: String?,
        detectedLanguage: String?
    ) -> ResolvedPunctuationStrategy? {
        guard let engineId,
              let languageCode = PunctuationLanguageNormalizer.normalize(configuredLanguage ?? detectedLanguage) else {
            return nil
        }

        let defaultProfile = defaultProfile(engineId: engineId, modelId: modelId, languageCode: languageCode)
        let storedProfile = profileStore.profile(engineId: engineId, modelId: modelId, languageCode: languageCode)

        let mergedProfile: DictationPunctuationProfile
        if let storedProfile {
            mergedProfile = DictationPunctuationProfile(
                engineId: storedProfile.engineId,
                modelId: storedProfile.modelId,
                languageCode: storedProfile.languageCode,
                defaultStrategy: defaultProfile.defaultStrategy,
                userOverride: storedProfile.userOverride,
                verificationState: storedProfile.verificationState,
                lastVerifiedAt: storedProfile.lastVerifiedAt
            )
        } else {
            mergedProfile = defaultProfile
        }

        return ResolvedPunctuationStrategy(
            languageCode: languageCode,
            strategy: mergedProfile.effectiveStrategy,
            profile: mergedProfile
        )
    }

    private func defaultProfile(engineId: String, modelId: String?, languageCode: String) -> DictationPunctuationProfile {
        let verificationState: PunctuationVerificationState

        switch (engineId, languageCode) {
        case ("parakeet", "de"):
            verificationState = .vendorHint
        default:
            verificationState = .unknown
        }

        return DictationPunctuationProfile(
            engineId: engineId,
            modelId: modelId,
            languageCode: languageCode,
            defaultStrategy: .automatic,
            userOverride: nil,
            verificationState: verificationState,
            lastVerifiedAt: nil
        )
    }
}
