import Foundation

/// A provider-defined effort option for an LLM model.
///
/// Effort identifiers are intentionally opaque to the host. Providers may use
/// values such as `low`, `high`, or future model-specific levels without
/// requiring a TypeWhisper release.
public final class PluginLLMEffortInfo: @unchecked Sendable {
    public let id: String
    public let displayName: String
    public let detail: String?

    public init(id: String, displayName: String, detail: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.detail = detail
    }
}

/// Optional extension for LLM providers that support an explicit reasoning or
/// inference effort. Kept separate from `LLMProviderPlugin` so existing plugin
/// binaries continue to work unchanged.
public protocol LLMEffortControllableProvider: LLMProviderPlugin {
    /// Returns the effort values supported by the selected model. An empty list
    /// means the provider does not expose an effort picker for that model.
    func supportedEfforts(for model: String?) -> [PluginLLMEffortInfo]

    /// The provider-recommended effort when the user has not selected one.
    /// This is a transient UI hint and must not be persisted as a user choice.
    func defaultEffortId(for model: String?) -> String?

    /// Processes a request with an optional explicit effort. A nil effort asks
    /// the provider CLI or SDK to keep its own default.
    func process(
        systemPrompt: String,
        userText: String,
        model: String?,
        effort: String?
    ) async throws -> String
}

/// Optional combined extension for providers that support both temperature and
/// effort. The host prefers this overload so neither setting is discarded.
public protocol LLMTemperatureAndEffortControllableProvider:
    LLMEffortControllableProvider,
    LLMTemperatureControllableProvider
{
    func process(
        systemPrompt: String,
        userText: String,
        model: String?,
        temperatureDirective: PluginLLMTemperatureDirective,
        effort: String?
    ) async throws -> String
}
