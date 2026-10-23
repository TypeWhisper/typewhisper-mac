import Foundation
import TypeWhisperPluginSDK

enum Qwen3ContextBiasFormatter {
    static let budget = DictionaryTermsBudget(maxTerms: 64, maxCharsPerTerm: 64, maxWordsPerTerm: 8, maxTotalChars: 1024)
    static let baseInstruction = "Transcribe only words that are spoken in the audio. Do not append acknowledgements, continuations, or filler words after speech ends."

    static func format(prompt: String?) -> String {
        let terms = PluginDictionaryTerms.clippedTerms(from: PluginDictionaryTerms.terms(fromPrompt: prompt), budget: budget)
        guard !terms.isEmpty else { return baseInstruction }
        return "\(baseInstruction)\nTechnical terms: \(terms.joined(separator: ", "))."
    }
}
