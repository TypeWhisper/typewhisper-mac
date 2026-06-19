import Foundation

enum PunctuationStrategy: String, Codable, CaseIterable, Identifiable {
    case nativeOnly
    case automatic
    case fallbackOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nativeOnly:
            return String(localized: "Native")
        case .automatic:
            return String(localized: "Automatic")
        case .fallbackOnly:
            return String(localized: "Fallback")
        }
    }

    var description: String {
        switch self {
        case .nativeOnly:
            return String(localized: "Use the engine output unchanged.")
        case .automatic:
            return String(localized: "Prefer native punctuation and only fix visible spoken commands.")
        case .fallbackOnly:
            return String(localized: "Always apply spoken punctuation fallback rules.")
        }
    }
}

enum PunctuationVerificationState: String, Codable {
    case unknown
    case vendorHint
    case userVerifiedGood
    case userVerifiedBad

    var statusText: String {
        switch self {
        case .unknown:
            return String(localized: "Unverified")
        case .vendorHint:
            return String(localized: "Suggested default")
        case .userVerifiedGood:
            return String(localized: "Verified: native works")
        case .userVerifiedBad:
            return String(localized: "Verified: fallback needed")
        }
    }
}

struct DictationPunctuationProfile: Codable, Identifiable, Hashable {
    let engineId: String
    let modelId: String?
    let languageCode: String
    var defaultStrategy: PunctuationStrategy
    var userOverride: PunctuationStrategy?
    var verificationState: PunctuationVerificationState
    var lastVerifiedAt: Date?

    var id: String {
        Self.makeID(engineId: engineId, modelId: modelId, languageCode: languageCode)
    }

    var effectiveStrategy: PunctuationStrategy {
        userOverride ?? defaultStrategy
    }

    static func makeID(engineId: String, modelId: String?, languageCode: String) -> String {
        "\(engineId)::\(modelId ?? "__default__")::\(languageCode)"
    }
}

enum PunctuationLanguageNormalizer {
    static func normalize(_ languageCode: String?) -> String? {
        guard let rawLanguageCode = languageCode?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawLanguageCode.isEmpty else {
            return nil
        }

        let separatorSplit = rawLanguageCode.split(whereSeparator: { $0 == "-" || $0 == "_" })
        guard let primary = separatorSplit.first else { return nil }
        let normalized = String(primary).lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}
