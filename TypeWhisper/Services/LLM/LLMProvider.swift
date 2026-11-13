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
    /// Starts loading the model so a request shortly afterwards does not wait for it.
    func prewarm()
    /// Answers a prompt as it is. `process` instead wraps its text as dictated
    /// text that must not be answered.
    func answer(instructions: String, prompt: String) async throws -> String
    /// The tokens a request takes and the tokens the model's context holds.
    /// Nil where the system cannot count them.
    func inputTokens(instructions: String, prompt: String) async -> (count: Int, contextSize: Int)?
}

extension LLMProvider {
    func prewarm() {}

    func answer(instructions: String, prompt: String) async throws -> String {
        try await process(systemPrompt: instructions, userText: prompt)
    }

    func inputTokens(instructions: String, prompt: String) async -> (count: Int, contextSize: Int)? { nil }
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
