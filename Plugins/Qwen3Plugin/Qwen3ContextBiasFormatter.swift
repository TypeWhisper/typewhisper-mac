import Foundation
import TypeWhisperPluginSDK

enum Qwen3ContextBiasFormatter {
    static func format(prompt: String?) -> String {
        let terms = PluginDictionaryTerms.terms(fromPrompt: prompt)
        guard !terms.isEmpty else { return "" }
        return "Technical terms: \(terms.joined(separator: ", "))."
    }
}
