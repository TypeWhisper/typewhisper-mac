import Foundation

/// Sends prompts to the app's language model providers.
///
/// The app applies its managed policies to every request. A module tries the
/// providers in the order of `providers()` and decides itself what to do when
/// one fails.
@MainActor
public protocol LanguageModelAnswering: AnyObject {
    /// The providers a request can try, in order: the provider an organization
    /// enforces, or the user's provider list.
    /// - Throws: `ModuleLanguageModelError.refused` when the enforced provider
    ///   cannot be used.
    func providers() throws -> [ModuleLanguageModelProvider]

    /// The provider's reply to a prompt, answered as it is: the app adds no
    /// memories and does not treat the prompt as dictated text.
    /// - Throws: `ModuleLanguageModelError`, or `CancellationError`.
    func answer(instructions: String, prompt: String, using provider: ModuleLanguageModelProvider) async throws -> String

    /// The tokens a request takes and the tokens the model's context holds.
    /// Nil where the provider cannot count them.
    func inputTokens(
        instructions: String, prompt: String, using provider: ModuleLanguageModelProvider
    ) async -> ModuleTokenCount?

    /// Starts loading the first provider's model when it runs on this Mac, so
    /// a request shortly afterwards does not wait for it.
    func prewarm()

    /// Opens the settings where the user chooses the providers.
    func showSettings()
}

/// One provider with the model and effort a request uses.
public struct ModuleLanguageModelProvider: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        /// The model runs on this Mac.
        case local
        /// The text leaves this Mac.
        case cloud
    }

    /// The provider's identifier.
    public var id: String
    public var name: String
    public var kind: Kind
    /// The plugin that offers the provider. Nil for the system's own model.
    public var pluginId: String?
    public var modelId: String?
    public var effortId: String?

    public init(
        id: String,
        name: String,
        kind: Kind,
        pluginId: String? = nil,
        modelId: String? = nil,
        effortId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.pluginId = pluginId
        self.modelId = modelId
        self.effortId = effortId
    }
}

public struct ModuleTokenCount: Equatable, Sendable {
    public var count: Int
    public var contextSize: Int

    public init(count: Int, contextSize: Int) {
        self.count = count
        self.contextSize = contextSize
    }
}

/// Why a provider gave no answer.
public enum ModuleLanguageModelError: LocalizedError, Equatable, Sendable {
    /// The prompt is longer than the model's context. A shorter one may work.
    case contextExceeded
    /// The provider is missing, unavailable on this Mac or lacks its key.
    case notSetUp(String)
    /// A managed policy does not allow the request. The text says why.
    case refused(String)
    /// The reply was empty.
    case emptyReply
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .contextExceeded: "The input is too long for the model."
        case .notSetUp(let message), .refused(let message), .failed(let message): message
        case .emptyReply: "The model returned an empty reply."
        }
    }
}
