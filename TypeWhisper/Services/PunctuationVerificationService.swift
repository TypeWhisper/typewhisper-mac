import Foundation

final class PunctuationVerificationService {
    private let rulesLoader: PunctuationRulesLoader

    init(rulesLoader: PunctuationRulesLoader) {
        self.rulesLoader = rulesLoader
    }

    func scenarios(for languageCode: String?) -> [PunctuationVerificationScenario] {
        rulesLoader.ruleSet(for: languageCode)?.verificationScenarios ?? []
    }
}
