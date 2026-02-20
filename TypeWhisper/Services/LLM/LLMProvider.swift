import Foundation

// MARK: - Cloud Provider Config

/// Configuration for OpenAI-compatible cloud providers.
/// To add a new provider: add a case to LLMProviderType, add its cloudConfig entry, done.
struct CloudProviderConfig: Sendable {
    let baseURL: String
    let chatEndpoint: String
    let defaultModel: String
    let keychainId: String
    let knownModels: [String]
}

// MARK: - Provider Type

enum LLMProviderType: String, CaseIterable, Identifiable {
    case appleIntelligence
    case groq
    case openai
    case gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleIntelligence: "Apple Intelligence"
        case .groq: "Groq"
        case .openai: "OpenAI"
        case .gemini: "Gemini"
        }
    }

    var isCloudProvider: Bool { cloudConfig != nil }

    /// LLM-only providers that have no corresponding EngineType (not used for transcription).
    static var llmOnlyCases: [LLMProviderType] {
        allCases.filter { $0.isCloudProvider && EngineType(rawValue: $0.rawValue) == nil }
    }

    /// Cloud provider configuration. Returns nil for non-cloud providers (Apple Intelligence).
    var cloudConfig: CloudProviderConfig? {
        switch self {
        case .appleIntelligence:
            nil
        case .groq:
            CloudProviderConfig(
                baseURL: "https://api.groq.com/openai",
                chatEndpoint: "/v1/chat/completions",
                defaultModel: "llama-3.3-70b-versatile",
                keychainId: "groq",
                knownModels: [
                    "llama-3.3-70b-versatile",
                    "llama-3.1-8b-instant",
                    "openai/gpt-oss-120b",
                    "openai/gpt-oss-20b",
                ]
            )
        case .openai:
            CloudProviderConfig(
                baseURL: "https://api.openai.com",
                chatEndpoint: "/v1/chat/completions",
                defaultModel: "gpt-4.1-nano",
                keychainId: "openai",
                knownModels: [
                    "gpt-5",
                    "gpt-5-mini",
                    "gpt-5-nano",
                    "gpt-4.1",
                    "gpt-4.1-mini",
                    "gpt-4.1-nano",
                    "o4-mini",
                ]
            )
        case .gemini:
            CloudProviderConfig(
                baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
                chatEndpoint: "/chat/completions",
                defaultModel: "gemini-2.5-flash",
                keychainId: "gemini",
                knownModels: [
                    "gemini-3.1-pro-preview",
                    "gemini-3-flash-preview",
                    "gemini-2.5-pro",
                    "gemini-2.5-flash",
                    "gemini-2.5-flash-lite",
                ]
            )
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
    case inputTooLong
    case noProviderConfigured
    case noApiKey

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            "LLM provider is not available on this device."
        case .providerError(let message):
            "LLM error: \(message)"
        case .inputTooLong:
            "Input text is too long for the selected provider."
        case .noProviderConfigured:
            "No LLM provider configured. Please select a provider in Settings > Prompts."
        case .noApiKey:
            "API key not configured. Please add your API key in Settings > Models."
        }
    }
}
