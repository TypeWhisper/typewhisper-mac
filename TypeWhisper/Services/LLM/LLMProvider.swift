import Foundation

// MARK: - Provider Type

enum LLMProviderType: String, CaseIterable, Identifiable {
    case appleIntelligence

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleIntelligence: "Apple Intelligence"
        }
    }
}

// MARK: - Provider Protocol

protocol LLMProvider: Sendable {
    func process(systemPrompt: String, userText: String) async throws -> String
    var isAvailable: Bool { get }
}

// MARK: - Errors

enum LLMError: LocalizedError {
    case notAvailable
    case providerError(String)
    case providerNotReady(String)
    case inputTooLong
    case noProviderConfigured
    case noApiKey

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            "LLM provider is not available on this device."
        case .providerError(let message):
            "LLM error: \(message)"
        case .providerNotReady(let message):
            message
        case .inputTooLong:
            "Input text is too long for the selected provider."
        case .noProviderConfigured:
            "No LLM provider configured. Please select a provider in Settings > Prompts."
        case .noApiKey:
            "API key not configured. Please add your API key in Settings > Models."
        }
    }
}
