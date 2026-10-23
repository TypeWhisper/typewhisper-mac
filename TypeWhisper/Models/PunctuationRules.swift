import Foundation

struct PunctuationRuleSet: Codable, Hashable {
    let language: String
    let rules: [PunctuationReplacementRule]
    let verificationScenarios: [PunctuationVerificationScenario]
}

struct PunctuationReplacementRule: Codable, Hashable {
    let phrase: String
    let replacement: String
    let category: PunctuationRuleCategory
    /// Set when the replacement must attach to the next (opening) or previous (closing) word.
    /// Needed for characters such as `"` that are the same on both sides of a quote.
    var spacing: PunctuationRuleSpacing? = nil
}

enum PunctuationRuleSpacing: String, Codable, Hashable {
    case opening
    case closing
}

enum PunctuationRuleCategory: String, Codable, Hashable {
    case punctuation
    case brackets
    case quotes
    case structural
}

struct PunctuationVerificationScenario: Codable, Hashable {
    let spoken: String
    let expected: String
}
