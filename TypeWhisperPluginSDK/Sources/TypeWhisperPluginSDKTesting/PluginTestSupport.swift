@_spi(Testing) import TypeWhisperPluginSDK
import Foundation

public final class PluginTestEventBus: EventBusProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [UUID: @Sendable (TypeWhisperEvent) async -> Void] = [:]

    public init() {}

    @discardableResult
    public func subscribe(handler: @escaping @Sendable (TypeWhisperEvent) async -> Void) -> UUID {
        let id = UUID()
        lock.withLock {
            handlers[id] = handler
        }
        return id
    }

    public func unsubscribe(id: UUID) {
        _ = lock.withLock {
            handlers.removeValue(forKey: id)
        }
    }

    public func emit(_ event: TypeWhisperEvent) async {
        let subscribers = lock.withLock {
            Array(handlers.values)
        }

        for handler in subscribers {
            await handler(event)
        }
    }

    public var subscriberCount: Int {
        lock.withLock { handlers.count }
    }
}

public final class PluginTestHostServices: HostServices, HostModelLifecyclePolicyProviding, @unchecked Sendable {
    private struct AnySendable: @unchecked Sendable {
        let value: Any
    }

    private struct State {
        var defaults: [String: AnySendable]
        var secrets: [String: String]
        var capabilitiesChangedCount = 0
        var streamingDisplayActiveValues: [Bool] = []
    }

    private let lock = NSLock()
    private var state: State

    public let pluginDataDirectory: URL
    public let eventBus: EventBusProtocol
    public var activeAppBundleId: String?
    public var activeAppName: String?
    public var availableRuleNames: [String]
    public var availableWorkflows: [PluginWorkflowInfo]
    public var shouldRestoreLoadedModelsPassively: Bool

    public init(
        defaults: [String: Any] = [:],
        secrets: [String: String] = [:],
        eventBus: EventBusProtocol? = nil,
        pluginDataDirectory: URL? = nil,
        activeAppBundleId: String? = nil,
        activeAppName: String? = nil,
        availableRuleNames: [String] = [],
        availableWorkflows: [PluginWorkflowInfo] = [],
        shouldRestoreLoadedModelsPassively: Bool = true
    ) throws {
        self.state = State(
            defaults: defaults.mapValues(AnySendable.init(value:)),
            secrets: secrets
        )
        self.eventBus = eventBus ?? PluginTestEventBus()
        self.activeAppBundleId = activeAppBundleId
        self.activeAppName = activeAppName
        self.availableRuleNames = availableRuleNames
        self.availableWorkflows = availableWorkflows
        self.shouldRestoreLoadedModelsPassively = shouldRestoreLoadedModelsPassively

        if let pluginDataDirectory {
            self.pluginDataDirectory = pluginDataDirectory
        } else {
            self.pluginDataDirectory = try Self.makeTemporaryDirectory(prefix: "PluginTestHostServices")
        }

        try FileManager.default.createDirectory(
            at: self.pluginDataDirectory,
            withIntermediateDirectories: true
        )
    }

    deinit {
        cleanup()
    }

    public func cleanup() {
        try? FileManager.default.removeItem(at: pluginDataDirectory)
    }

    public func storeSecret(key: String, value: String) throws {
        lock.withLock {
            state.secrets[key] = value
        }
    }

    public func loadSecret(key: String) -> String? {
        lock.withLock {
            state.secrets[key]
        }
    }

    public func userDefault(forKey key: String) -> Any? {
        lock.withLock {
            state.defaults[key]?.value
        }
    }

    public func setUserDefault(_ value: Any?, forKey key: String) {
        lock.withLock {
            state.defaults[key] = value.map(AnySendable.init(value:))
        }
    }

    public func notifyCapabilitiesChanged() {
        lock.withLock {
            state.capabilitiesChangedCount += 1
        }
    }

    public func setStreamingDisplayActive(_ active: Bool) {
        lock.withLock {
            state.streamingDisplayActiveValues.append(active)
        }
    }

    public var capabilitiesChangedCount: Int {
        lock.withLock { state.capabilitiesChangedCount }
    }

    public var streamingDisplayActiveValues: [Bool] {
        lock.withLock { state.streamingDisplayActiveValues }
    }

    private static func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

@_spi(Testing) public enum PluginHTTPClientTestOutcome {
    case success(Data, URLResponse)
    case failure(Error)
}

@_spi(Testing) public final class PluginHTTPClientSessionStore: @unchecked Sendable {
    private let lock = NSLock()
    private var sessionsStorage: [PluginHTTPClientMockSession] = []

    public init() {}

    public func makeSession(outcomes: [PluginHTTPClientTestOutcome]) -> PluginHTTPClientMockSession {
        let session = PluginHTTPClientMockSession(outcomes: outcomes)
        lock.withLock {
            sessionsStorage.append(session)
        }
        return session
    }

    public var sessions: [PluginHTTPClientMockSession] {
        lock.withLock { sessionsStorage }
    }
}

@_spi(Testing) public final class PluginHTTPClientMockSession: PluginHTTPClientSession, @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [PluginHTTPClientTestOutcome]
    private var requestedPathsStorage: [String] = []
    private var requestedRequestsStorage: [URLRequest] = []
    private var didInvalidateStorage = false

    public init(outcomes: [PluginHTTPClientTestOutcome]) {
        self.outcomes = outcomes
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let outcome = lock.withLock {
            requestedRequestsStorage.append(request)
            requestedPathsStorage.append(request.url?.path ?? "")
            if outcomes.count > 1 {
                return outcomes.removeFirst()
            }
            return outcomes.first ?? .failure(URLError(.badServerResponse))
        }

        switch outcome {
        case .success(let data, let response):
            return (data, response)
        case .failure(let error):
            throw error
        }
    }

    public func finishTasksAndInvalidate() {
        lock.withLock {
            didInvalidateStorage = true
        }
    }

    public var requestedPaths: [String] {
        lock.withLock { requestedPathsStorage }
    }

    public var requestedRequests: [URLRequest] {
        lock.withLock { requestedRequestsStorage }
    }

    public var didInvalidate: Bool {
        lock.withLock { didInvalidateStorage }
    }
}

@_spi(Testing) public enum PluginHTTPClientTestHarness {
    public static func configure(
        _ factory: @escaping (URLSessionConfiguration) -> PluginHTTPClientMockSession
    ) {
        PluginHTTPClient.configureForTesting(factory)
    }

    public static func reset() {
        PluginHTTPClient.resetTestingHooks()
    }
}
