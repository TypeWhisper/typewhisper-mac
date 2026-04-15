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
