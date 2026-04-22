import Foundation

@MainActor
final class DictationPunctuationProfileStore: ObservableObject {
    @Published private(set) var profiles: [DictationPunctuationProfile] = []

    private let defaults: UserDefaults
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = UserDefaultsKeys.dictationPunctuationProfiles
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        loadProfiles()
    }

    func profile(engineId: String, modelId: String?, languageCode: String) -> DictationPunctuationProfile? {
        guard let normalizedLanguage = PunctuationLanguageNormalizer.normalize(languageCode) else {
            return nil
        }

        return profiles.first {
            $0.engineId == engineId &&
            $0.modelId == modelId &&
            $0.languageCode == normalizedLanguage
        }
    }

    func upsert(_ profile: DictationPunctuationProfile) {
        var updatedProfile = profile
        updatedProfile = DictationPunctuationProfile(
            engineId: profile.engineId,
            modelId: profile.modelId,
            languageCode: PunctuationLanguageNormalizer.normalize(profile.languageCode) ?? profile.languageCode,
            defaultStrategy: profile.defaultStrategy,
            userOverride: profile.userOverride,
            verificationState: profile.verificationState,
            lastVerifiedAt: profile.lastVerifiedAt
        )

        if let index = profiles.firstIndex(where: { $0.id == updatedProfile.id }) {
            profiles[index] = updatedProfile
        } else {
            profiles.append(updatedProfile)
        }

        persistProfiles()
    }

    func saveUserOverride(
        engineId: String,
        modelId: String?,
        languageCode: String,
        defaultStrategy: PunctuationStrategy,
        strategy: PunctuationStrategy,
        verificationState: PunctuationVerificationState? = nil,
        updateVerificationDate: Bool = false
    ) {
        guard let normalizedLanguage = PunctuationLanguageNormalizer.normalize(languageCode) else { return }
        var profile = profile(engineId: engineId, modelId: modelId, languageCode: normalizedLanguage)
            ?? DictationPunctuationProfile(
                engineId: engineId,
                modelId: modelId,
                languageCode: normalizedLanguage,
                defaultStrategy: defaultStrategy,
                userOverride: nil,
                verificationState: verificationState ?? .unknown,
                lastVerifiedAt: nil
            )

        profile.defaultStrategy = defaultStrategy
        profile.userOverride = strategy

        if let verificationState {
            profile.verificationState = verificationState
        }
        if updateVerificationDate {
            profile.lastVerifiedAt = Date()
        }

        upsert(profile)
    }

    private func loadProfiles() {
        guard let data = defaults.data(forKey: storageKey) else {
            profiles = []
            return
        }

        do {
            profiles = try JSONDecoder().decode([DictationPunctuationProfile].self, from: data)
        } catch {
            profiles = []
        }
    }

    private func persistProfiles() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
