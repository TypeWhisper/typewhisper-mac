import Foundation
import os

// MARK: - LLM Usage

/// Token counts an LLM provider reported for one request.
///
/// The counts come from the provider's response. Leave a count nil when the
/// response does not include it; never estimate one.
public struct PluginLLMUsage: Sendable, Equatable {
    /// Every prompt token the provider processed for the request, cached ones included.
    public let inputTokens: Int?
    /// Every token the provider generated, reasoning or thinking tokens included.
    public let outputTokens: Int?
    /// The model that answered when the response names it, for example a dated
    /// snapshot or the model a router picked. Nil means the requested model.
    public let model: String?

    /// Negative counts and empty model names are dropped.
    public init(inputTokens: Int?, outputTokens: Int?, model: String? = nil) {
        self.inputTokens = inputTokens.flatMap { $0 >= 0 ? $0 : nil }
        self.outputTokens = outputTokens.flatMap { $0 >= 0 ? $0 : nil }
        let trimmedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = trimmedModel?.isEmpty == false ? trimmedModel : nil
    }

    /// Whether the report carries at least one token count.
    public var hasTokenCounts: Bool {
        inputTokens != nil || outputTokens != nil
    }
}

public extension PluginLLMUsage {
    /// Usage from an OpenAI-compatible response body: chat completions
    /// (`usage.prompt_tokens`, `usage.completion_tokens`) or the Responses API
    /// (`usage.input_tokens`, `usage.output_tokens`), with the top-level `model`.
    /// Returns nil when the body has no token counts.
    static func openAICompatible(from response: [String: Any]) -> PluginLLMUsage? {
        guard let usage = response["usage"] as? [String: Any] else { return nil }
        let input = tokenCount(usage["prompt_tokens"]) ?? tokenCount(usage["input_tokens"])
        var output = tokenCount(usage["completion_tokens"]) ?? tokenCount(usage["output_tokens"])
        // Some endpoints, such as Gemini's OpenAI-compatible one, leave reasoning
        // tokens out of the completion count but include them in the total.
        if let input, let total = tokenCount(usage["total_tokens"]), total - input > (output ?? 0) {
            output = total - input
        }
        let report = PluginLLMUsage(
            inputTokens: input,
            outputTokens: output,
            model: response["model"] as? String
        )
        return report.hasTokenCounts ? report : nil
    }

    /// Usage from the raw bytes of an OpenAI-compatible response body. Returns
    /// nil when the body is not a JSON object or has no token counts.
    static func openAICompatible(from responseData: Data) -> PluginLLMUsage? {
        guard let response = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any] else {
            return nil
        }
        return openAICompatible(from: response)
    }

    /// Usage from an Anthropic Messages response body. Input counts the
    /// uncached prompt plus the tokens written to and read from the prompt
    /// cache; output is `usage.output_tokens`. Returns nil without token counts.
    static func anthropicMessages(from response: [String: Any]) -> PluginLLMUsage? {
        guard let usage = response["usage"] as? [String: Any] else { return nil }
        let inputParts = [
            tokenCount(usage["input_tokens"]),
            tokenCount(usage["cache_creation_input_tokens"]),
            tokenCount(usage["cache_read_input_tokens"]),
        ].compactMap { $0 }
        let report = PluginLLMUsage(
            inputTokens: inputParts.isEmpty ? nil : inputParts.reduce(0, +),
            outputTokens: tokenCount(usage["output_tokens"]),
            model: response["model"] as? String
        )
        return report.hasTokenCounts ? report : nil
    }

    /// A non-negative whole token count from a JSON value, or nil.
    static func tokenCount(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= 0, double < 9.0e15, double.rounded() == double else { return nil }
        return number.intValue
    }
}

/// Receives the usage reports of the LLM requests made while it is installed.
public final class PluginLLMUsageCollector: Sendable {
    private let state = OSAllocatedUnfairLock<[PluginLLMUsage]>(initialState: [])

    public init() {}

    /// Every report in the order it arrived.
    public var reports: [PluginLLMUsage] {
        state.withLock { $0 }
    }

    /// Adds a report. Reports accumulate: each one stands for a separate request.
    public func record(_ usage: PluginLLMUsage) {
        state.withLock { $0.append(usage) }
    }
}

/// Optional usage reporting for LLM providers.
///
/// The `LLMProviderPlugin` methods keep returning plain text. A provider
/// reports the token counts of each response from inside any `process` call,
/// once per request it sent, and the host reads them when it asked for them.
/// Without a host collector the report does nothing, so providers call it
/// unconditionally. The collector is task-local: report from the task that
/// runs `process`, not from a detached task. A provider whose response has
/// no usage reports nothing.
///
/// `PluginOpenAIChatHelper.process` reports usage on its own.
///
/// Requires TypeWhisper 1.8.0 or later; declare `"minHostVersion": "1.8.0"`
/// when you call it.
public enum PluginLLMUsageReporting {
    @TaskLocal public static var collector: PluginLLMUsageCollector?

    /// Reports the usage of one request. Reports without token counts are ignored.
    public static func report(_ usage: PluginLLMUsage?) {
        guard let usage, usage.hasTokenCounts else { return }
        collector?.record(usage)
    }
}
