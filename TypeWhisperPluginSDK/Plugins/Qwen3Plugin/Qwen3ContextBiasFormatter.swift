import Foundation
import TypeWhisperPluginSDK

enum Qwen3ContextBiasFormatter {
    static let baseInstruction = "Transcribe only words that are spoken in the audio. Do not append acknowledgements, continuations, or filler words after speech ends."

    static func format(prompt: String?) -> String {
        let terms = PluginDictionaryTerms.terms(fromPrompt: prompt)
        guard !terms.isEmpty else { return baseInstruction }
        return "\(baseInstruction)\nTechnical terms: \(terms.joined(separator: ", "))."
    }
}
