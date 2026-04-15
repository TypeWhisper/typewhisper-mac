import Foundation

final class PunctuationRulesLoader {
    private let bundle: Bundle
    private let dataLoader: ((String) -> Data?)?
    private var cache: [String: PunctuationRuleSet] = [:]

    init(bundle: Bundle = .main, dataLoader: ((String) -> Data?)? = nil) {
        self.bundle = bundle
        self.dataLoader = dataLoader
    }

    func ruleSet(for languageCode: String?) -> PunctuationRuleSet? {
        guard let normalizedLanguage = PunctuationLanguageNormalizer.normalize(languageCode) else {
            return nil
        }

        if let cached = cache[normalizedLanguage] {
            return cached
        }

        guard let data = loadData(for: normalizedLanguage),
              let ruleSet = try? JSONDecoder().decode(PunctuationRuleSet.self, from: data) else {
            return nil
        }

        cache[normalizedLanguage] = ruleSet
        return ruleSet
    }

    private func loadData(for languageCode: String) -> Data? {
        if let dataLoader {
            return dataLoader(languageCode)
        }

        guard let url = bundle.url(forResource: languageCode, withExtension: "json") else {
            return nil
        }

        return try? Data(contentsOf: url)
    }
}
