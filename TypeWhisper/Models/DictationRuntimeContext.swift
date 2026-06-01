import Foundation

struct DictationRuntimeContext {
    let engineId: String?
    let modelId: String?
    let configuredLanguage: String?
    let configuredLanguageCandidates: [String]
    let detectedLanguage: String?

    init(
        engineId: String?,
        modelId: String?,
        configuredLanguage: String?,
        configuredLanguageCandidates: [String] = [],
        detectedLanguage: String?
    ) {
        self.engineId = engineId
        self.modelId = modelId
        self.configuredLanguage = configuredLanguage
        self.configuredLanguageCandidates = configuredLanguageCandidates
        self.detectedLanguage = detectedLanguage
    }
}
