import Foundation
import os
import SwiftUI
import TypeWhisperPluginSDK

struct MCPActivityEntry: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case success
        case failure
    }

    let id: UUID
    let date: Date
    let serverName: String
    let actionName: String?
    let status: Status
    let summary: String

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        serverName: String,
        actionName: String?,
        status: Status,
        summary: String
    ) {
        self.id = id
        self.date = date
        self.serverName = serverName
        self.actionName = actionName
        self.status = status
        self.summary = summary
    }
}

@objc(MCPClientPlugin)
final class MCPClientPlugin: NSObject, AdditionalActionPluginsProviding, PluginSettingsWindowLayoutProviding, @unchecked Sendable {
    static let pluginId = "com.typewhisper.mcp-client"
    static let pluginName = "MCP Client"

    private struct State {
        var host: HostServices?
        var configuration = MCPStoredConfiguration()
        var configurationLoadFailed = false
        var activity: [MCPActivityEntry] = []
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())
    private let runtime = MCPClientRuntime()

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        let configuration: MCPStoredConfiguration
        let configurationLoadFailed: Bool
        if let data = host.userDefault(forKey: MCPClientConstants.configurationDefaultsKey) as? Data {
            do {
                configuration = try JSONDecoder().decode(MCPStoredConfiguration.self, from: data)
                configurationLoadFailed = false
            } catch {
                configuration = MCPStoredConfiguration()
                configurationLoadFailed = true
            }
        } else {
            configuration = MCPStoredConfiguration()
            configurationLoadFailed = false
        }
        state.withLock {
            $0.host = host
            $0.configuration = configuration
            $0.configurationLoadFailed = configurationLoadFailed
        }
    }

    func deactivate() {
        state.withLock { $0.host = nil }
        let runtime = runtime
        Task {
            await runtime.closeAll()
        }
    }

    var additionalActionPlugins: [any ActionPlugin] {
        let actions = state.withLock { $0.configuration.actions }
        return actions.map { MCPConfiguredAction(configuration: $0, owner: self) }
    }

    @MainActor
    var settingsView: AnyView? {
        AnyView(MCPClientSettingsView(plugin: self))
    }

    var settingsViewManagesScrolling: Bool { true }
    var preferredSettingsWindowSize: CGSize? { CGSize(width: 860, height: 620) }
    var minimumSettingsWindowSize: CGSize? { CGSize(width: 720, height: 500) }

    var servers: [MCPServerConfiguration] {
        state.withLock { $0.configuration.servers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
    }

    var actions: [MCPActionConfiguration] {
        state.withLock { $0.configuration.actions.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
    }

    var activity: [MCPActivityEntry] {
        state.withLock { $0.activity }
    }

    var configurationLoadFailed: Bool {
        state.withLock { $0.configurationLoadFailed }
    }

    func secretValue(serverID: UUID, name: String) -> String {
        let host = state.withLock { $0.host }
        return host?.loadSecret(key: MCPServerConfiguration.secretStorageKey(serverID: serverID, environmentName: name)) ?? ""
    }

    func bearerTokenValue(serverID: UUID) -> String {
        let host = state.withLock { $0.host }
        return host?.loadSecret(key: MCPServerConfiguration.bearerTokenStorageKey(serverID: serverID)) ?? ""
    }

    func resolvedExecutable(for server: MCPServerConfiguration, secretValues: [String: String] = [:]) throws -> URL {
        var configuredEnvironment = server.environment
        for name in server.secretEnvironmentNames {
            let value = secretValues[name] ?? secretValue(serverID: server.id, name: name)
            if !value.isEmpty {
                configuredEnvironment[name] = value
            }
        }
        return try MCPExecutableResolver.resolve(
            command: server.command,
            configuredEnvironment: configuredEnvironment
        )
    }

    func resolvedEndpoint(for server: MCPServerConfiguration) throws -> URL {
        try MCPHTTPEndpointResolver.resolve(server.endpoint)
    }

    func saveServer(
        _ draft: MCPServerConfiguration,
        secretValues: [String: String],
        bearerToken: String? = nil
    ) throws {
        try ensureConfigurationWritable()
        guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPClientError.invalidConfiguration(MCPClientLocalization.string("Enter a server name."))
        }
        guard draft.launchAcknowledged else {
            let message = draft.transport == .stdio
                ? MCPClientLocalization.string("Acknowledge that TypeWhisper may launch this executable with your user permissions.")
                : MCPClientLocalization.string("Acknowledge that TypeWhisper may connect to this MCP server and send configured workflow data.")
            throw MCPClientError.invalidConfiguration(message)
        }

        let host = state.withLock { $0.host }
        guard let host else {
            throw MCPClientError.invalidConfiguration(MCPClientLocalization.string("MCP Client is not active."))
        }
        let oldServer = state.withLock { current in
            current.configuration.servers.first { $0.id == draft.id }
        }
        let oldSecretNames = Set(oldServer?.secretEnvironmentNames ?? [])
        let newSecretNames = draft.transport == .stdio ? Set(draft.secretEnvironmentNames) : []

        switch draft.transport {
        case .stdio:
            _ = try resolvedExecutable(for: draft, secretValues: secretValues)
        case .streamableHTTP:
            _ = try resolvedEndpoint(for: draft)
            if draft.httpAuthentication == .bearerToken {
                let effectiveToken = bearerToken
                    ?? host.loadSecret(key: MCPServerConfiguration.bearerTokenStorageKey(serverID: draft.id))
                    ?? ""
                guard !effectiveToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw MCPClientError.invalidConfiguration(MCPClientLocalization.string("Enter a bearer token."))
                }
            }
        }

        for name in oldSecretNames.subtracting(newSecretNames) {
            try host.storeSecret(
                key: MCPServerConfiguration.secretStorageKey(serverID: draft.id, environmentName: name),
                value: ""
            )
        }
        for name in newSecretNames {
            if let value = secretValues[name] {
                try host.storeSecret(
                    key: MCPServerConfiguration.secretStorageKey(serverID: draft.id, environmentName: name),
                    value: value
                )
            }
        }

        let bearerTokenKey = MCPServerConfiguration.bearerTokenStorageKey(serverID: draft.id)
        if draft.transport == .streamableHTTP, draft.httpAuthentication == .bearerToken {
            if let bearerToken {
                try host.storeSecret(key: bearerTokenKey, value: bearerToken)
            }
        } else {
            try host.storeSecret(key: bearerTokenKey, value: "")
        }

        var normalizedServer = draft
        normalizedServer.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch draft.transport {
        case .stdio:
            normalizedServer.command = draft.command.trimmingCharacters(in: .whitespacesAndNewlines)
            normalizedServer.environment = draft.environment.filter { !newSecretNames.contains($0.key) }
            normalizedServer.secretEnvironmentNames = newSecretNames.sorted()
            normalizedServer.endpoint = ""
            normalizedServer.httpAuthentication = .none
        case .streamableHTTP:
            normalizedServer.command = ""
            normalizedServer.arguments = []
            normalizedServer.environment = [:]
            normalizedServer.secretEnvironmentNames = []
            normalizedServer.endpoint = draft.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        normalizedServer.updatedAt = Date()
        let normalizedDraft = normalizedServer

        let saved = state.withLock { current -> MCPServerConfiguration in
            let currentServer = current.configuration.servers.first { $0.id == draft.id }
            var saved = normalizedDraft
            saved.createdAt = currentServer?.createdAt ?? draft.createdAt
            saved.revision = (currentServer?.revision ?? 0) + 1
            current.configuration.servers.removeAll { $0.id == saved.id }
            current.configuration.servers.append(saved)
            return saved
        }
        persistConfiguration(using: host)
        host.notifyCapabilitiesChanged()

        let runtime = runtime
        Task { await runtime.invalidate(serverID: saved.id) }
    }

    func removeServer(id: UUID) {
        guard !configurationLoadFailed else { return }
        let snapshot = state.withLock { current -> (HostServices?, MCPServerConfiguration?) in
            let server = current.configuration.servers.first { $0.id == id }
            current.configuration.servers.removeAll { $0.id == id }
            current.configuration.actions.removeAll { $0.serverID == id }
            return (current.host, server)
        }

        if let host = snapshot.0 {
            for name in snapshot.1?.secretEnvironmentNames ?? [] {
                try? host.storeSecret(
                    key: MCPServerConfiguration.secretStorageKey(serverID: id, environmentName: name),
                    value: ""
                )
            }
            try? host.storeSecret(
                key: MCPServerConfiguration.bearerTokenStorageKey(serverID: id),
                value: ""
            )
            persistConfiguration(using: host)
            host.notifyCapabilitiesChanged()
        }
        let runtime = runtime
        Task { await runtime.invalidate(serverID: id) }
    }

    func discoverTools(serverID: UUID) async throws -> [MCPToolDescriptor] {
        let server = try resolvedServer(id: serverID)
        do {
            let tools = try await runtime.tools(for: server)
            recordActivity(
                serverName: server.configuration.name,
                actionName: nil,
                status: .success,
                summary: MCPClientLocalization.string("Loaded %lld MCP tools.", Int64(tools.count))
            )
            return tools
        } catch {
            let message = sanitize(error.localizedDescription, secrets: server.secrets)
            recordActivity(
                serverName: server.configuration.name,
                actionName: nil,
                status: .failure,
                summary: message
            )
            throw MCPClientError.invalidConfiguration(message)
        }
    }

    func discoverTools(
        server draft: MCPServerConfiguration,
        secretValues: [String: String],
        bearerToken: String? = nil
    ) async throws -> [MCPToolDescriptor] {
        guard draft.launchAcknowledged else {
            let message = draft.transport == .stdio
                ? MCPClientLocalization.string("Acknowledge that TypeWhisper may launch this executable with your user permissions.")
                : MCPClientLocalization.string("Acknowledge that TypeWhisper may connect to this MCP server and send configured workflow data.")
            throw MCPClientError.invalidConfiguration(message)
        }
        let host = state.withLock { $0.host }
        guard let host else {
            throw MCPClientError.invalidConfiguration(MCPClientLocalization.string("MCP Client is not active."))
        }
        let server = try resolvedServer(
            configuration: draft,
            secretValues: secretValues,
            bearerToken: bearerToken,
            host: host
        )
        let session = MCPServerSession(resolvedServer: server)
        do {
            let tools = try await session.tools()
            await session.close()
            recordActivity(
                serverName: draft.name,
                actionName: nil,
                status: .success,
                summary: MCPClientLocalization.string("Loaded %lld MCP tools.", Int64(tools.count))
            )
            return tools
        } catch is CancellationError {
            await session.close()
            throw CancellationError()
        } catch {
            await session.close()
            let message = sanitize(error.localizedDescription, secrets: server.secrets)
            recordActivity(serverName: draft.name, actionName: nil, status: .failure, summary: message)
            throw MCPClientError.invalidConfiguration(message)
        }
    }

    func saveAction(_ draft: MCPActionConfiguration) throws {
        try ensureConfigurationWritable()
        guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPClientError.invalidConfiguration(MCPClientLocalization.string("Enter an action name."))
        }
        let serverExists = state.withLock { $0.configuration.servers.contains { $0.id == draft.serverID } }
        guard serverExists else { throw MCPClientError.serverNotFound }
        guard !draft.toolName.isEmpty else {
            throw MCPClientError.invalidConfiguration(MCPClientLocalization.string("Select an MCP tool."))
        }
        if draft.toolDestructiveHint == true && !draft.destructiveAcknowledged {
            throw MCPClientError.invalidConfiguration(
                MCPClientLocalization.string("Acknowledge automatic execution of this destructive tool before saving.")
            )
        }

        if draft.usesRawJSONArguments {
            if draft.invocationMode == .batch, draft.rawArgumentsSource != .currentBatchItem {
                throw MCPClientError.invalidConfiguration(
                    MCPClientLocalization.string("Batch raw JSON arguments must use the current batch item.")
                )
            }
        } else {
            let descriptor = MCPToolDescriptor(
                name: draft.toolName,
                title: nil,
                description: nil,
                inputSchema: draft.toolInputSchema,
                destructiveHint: draft.toolDestructiveHint,
                readOnlyHint: nil
            )
            let properties = Dictionary(uniqueKeysWithValues: descriptor.topLevelProperties.map { ($0.name, $0) })
            for binding in draft.bindings {
                guard let property = properties[binding.targetProperty],
                      property.type == binding.expectedType else {
                    throw MCPClientError.invalidConfiguration(
                        MCPClientLocalization.string("Refresh incompatible argument bindings before saving.")
                    )
                }
            }
            let required = descriptor.topLevelProperties.filter(\.isRequired)
            let boundNames = Set(draft.bindings.map(\.targetProperty))
            let missing = required.filter { !boundNames.contains($0.name) }.map(\.name)
            if !missing.isEmpty {
                throw MCPClientError.invalidConfiguration(
                    MCPClientLocalization.string("Add bindings for required arguments: %@.", missing.joined(separator: ", "))
                )
            }
        }

        let host = state.withLock { $0.host }
        guard let host else {
            throw MCPClientError.invalidConfiguration(MCPClientLocalization.string("MCP Client is not active."))
        }

        let oldCreatedAt = state.withLock { current in
            current.configuration.actions.first { $0.id == draft.id }?.createdAt
        }
        var updatedAction = draft
        updatedAction.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        updatedAction.createdAt = oldCreatedAt ?? draft.createdAt
        updatedAction.updatedAt = Date()
        let saved = updatedAction
        state.withLock { current in
            current.configuration.actions.removeAll { $0.id == saved.id }
            current.configuration.actions.append(saved)
        }
        persistConfiguration(using: host)
        host.notifyCapabilitiesChanged()
    }

    func removeAction(id: UUID) {
        guard !configurationLoadFailed else { return }
        let host = state.withLock { current -> HostServices? in
            current.configuration.actions.removeAll { $0.id == id }
            return current.host
        }
        if let host {
            persistConfiguration(using: host)
            host.notifyCapabilitiesChanged()
        }
    }

    func execute(actionID: UUID, input: String, context: ActionContext) async throws -> ActionResult {
        let snapshot = state.withLock { current -> (MCPActionConfiguration?, MCPServerConfiguration?, HostServices?) in
            let action = current.configuration.actions.first { $0.id == actionID }
            let server = action.flatMap { action in current.configuration.servers.first { $0.id == action.serverID } }
            return (action, server, current.host)
        }
        guard let action = snapshot.0 else { throw MCPClientError.actionNotFound }
        guard snapshot.1 != nil else { throw MCPClientError.serverNotFound }

        let serverConfiguration = snapshot.1!
        let fallbackSecrets = secretValues(for: serverConfiguration, host: snapshot.2)
        let server: MCPResolvedServer
        let tools: [MCPToolDescriptor]
        do {
            server = try resolvedServer(id: action.serverID)
            tools = try await runtime.tools(for: server)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return failureResult(
                error,
                action: action,
                serverName: serverConfiguration.name,
                secrets: fallbackSecrets
            )
        }
        guard let tool = tools.first(where: { $0.name == action.toolName }) else {
            return failureResult(MCPClientError.toolNotFound(action.toolName), action: action, server: server)
        }
        guard tool.schemaFingerprint == action.schemaFingerprint else {
            return failureResult(MCPClientError.toolSchemaChanged(action.toolName), action: action, server: server)
        }

        let invocations: [[String: MCPJSONValue]]
        do {
            invocations = try MCPArgumentMapper.invocations(input: input, context: context, action: action)
        } catch {
            return failureResult(error, action: action, server: server)
        }

        if action.invocationMode == .single {
            do {
                let result = try await runtime.call(
                    server: server,
                    toolName: action.toolName,
                    expectedSchemaFingerprint: action.schemaFingerprint,
                    arguments: invocations[0]
                )
                let message = result.message.flatMap { $0.isEmpty ? nil : $0 }
                    ?? MCPClientLocalization.string("MCP action completed.")
                recordActivity(
                    serverName: server.configuration.name,
                    actionName: action.name,
                    status: .success,
                    summary: MCPClientLocalization.string("MCP action completed.")
                )
                return ActionResult(
                    success: true,
                    message: message,
                    url: result.url,
                    icon: "checkmark.circle.fill",
                    displayDuration: 4
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return failureResult(error, action: action, server: server)
            }
        }

        var failedItems: [Int] = []
        var completed = 0
        for (index, arguments) in invocations.enumerated() {
            do {
                _ = try await runtime.call(
                    server: server,
                    toolName: action.toolName,
                    expectedSchemaFingerprint: action.schemaFingerprint,
                    arguments: arguments
                )
                completed += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failedItems.append(index + 1)
                if shouldAbortBatch(after: error) {
                    break
                }
            }
        }

        if failedItems.isEmpty {
            let summary = MCPClientLocalization.string("%lld actions completed.", Int64(completed))
            recordActivity(serverName: server.configuration.name, actionName: action.name, status: .success, summary: summary)
            return ActionResult(success: true, message: summary, icon: "checkmark.circle.fill", displayDuration: 4)
        }

        let failedIndices = failedItems.map(String.init).joined(separator: ", ")
        let summary = MCPClientLocalization.string(
            "%lld of %lld actions completed; failed items: %@.",
            Int64(completed),
            Int64(invocations.count),
            failedIndices
        )
        recordActivity(
            serverName: server.configuration.name,
            actionName: action.name,
            status: .failure,
            summary: summary
        )
        return ActionResult(success: false, message: summary, icon: "exclamationmark.triangle.fill", displayDuration: 6)
    }

    static func defaultBindings(for tool: MCPToolDescriptor, mode: MCPInvocationMode) -> [MCPArgumentBinding] {
        guard let property = tool.hasOneRequiredStringProperty else { return [] }
        return [
            MCPArgumentBinding(
                targetProperty: property.name,
                expectedType: .string,
                source: mode == .single ? .processedText : .currentBatchItem,
                propertyPath: nil,
                literalValue: nil
            )
        ]
    }

    static func compatibleBindings(
        from action: MCPActionConfiguration,
        for tool: MCPToolDescriptor
    ) -> [MCPArgumentBinding] {
        let properties = Dictionary(uniqueKeysWithValues: tool.topLevelProperties.map { ($0.name, $0) })
        return action.bindings.filter { binding in
            guard let property = properties[binding.targetProperty] else { return false }
            return property.type == binding.expectedType
        }
    }

    private func resolvedServer(id: UUID) throws -> MCPResolvedServer {
        let snapshot = state.withLock { current -> (MCPServerConfiguration?, HostServices?) in
            (current.configuration.servers.first { $0.id == id }, current.host)
        }
        guard let server = snapshot.0 else { throw MCPClientError.serverNotFound }
        guard let host = snapshot.1 else {
            throw MCPClientError.invalidConfiguration(MCPClientLocalization.string("MCP Client is not active."))
        }

        return try resolvedServer(configuration: server, secretValues: nil, bearerToken: nil, host: host)
    }

    private func resolvedServer(
        configuration server: MCPServerConfiguration,
        secretValues: [String: String]?,
        bearerToken: String?,
        host: HostServices
    ) throws -> MCPResolvedServer {
        if server.transport == .streamableHTTP {
            let endpoint = try MCPHTTPEndpointResolver.resolve(server.endpoint)
            let token: String?
            switch server.httpAuthentication {
            case .none:
                token = nil
            case .bearerToken:
                let value = bearerToken
                    ?? host.loadSecret(key: MCPServerConfiguration.bearerTokenStorageKey(serverID: server.id))
                    ?? ""
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw MCPClientError.invalidConfiguration(MCPClientLocalization.string("Enter a bearer token."))
                }
                token = value
            }
            return MCPResolvedServer(configuration: server, endpoint: endpoint, bearerToken: token)
        }

        let inherited = ProcessInfo.processInfo.environment
        let inheritedKeys = ["PATH", "HOME", "USER", "SHELL", "TMPDIR", "LANG"]
        var environment = Dictionary(uniqueKeysWithValues: inheritedKeys.compactMap { key in
            inherited[key].map { (key, $0) }
        })
        environment.merge(server.environment) { _, configured in configured }
        var secrets: [String] = []
        for name in server.secretEnvironmentNames {
            let value = secretValues?[name] ?? host.loadSecret(
                key: MCPServerConfiguration.secretStorageKey(serverID: server.id, environmentName: name)
            ) ?? ""
            if !value.isEmpty {
                environment[name] = value
                secrets.append(value)
            }
        }

        let executable = try MCPExecutableResolver.resolve(
            command: server.command,
            configuredEnvironment: environment
        )
        return MCPResolvedServer(
            configuration: server,
            executableURL: executable,
            environment: environment,
            secrets: secrets
        )
    }

    private func persistConfiguration(using host: HostServices) {
        let snapshot = state.withLock { ($0.configuration, $0.configurationLoadFailed) }
        guard !snapshot.1 else { return }
        let configuration = snapshot.0
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        host.setUserDefault(data, forKey: MCPClientConstants.configurationDefaultsKey)
    }

    private func failureResult(
        _ error: Error,
        action: MCPActionConfiguration,
        server: MCPResolvedServer
    ) -> ActionResult {
        failureResult(
            error,
            action: action,
            serverName: server.configuration.name,
            secrets: server.secrets
        )
    }

    private func failureResult(
        _ error: Error,
        action: MCPActionConfiguration,
        serverName: String,
        secrets: [String]
    ) -> ActionResult {
        let message = sanitize(error.localizedDescription, secrets: secrets)
        recordActivity(
            serverName: serverName,
            actionName: action.name,
            status: .failure,
            summary: MCPClientLocalization.string("MCP action failed.")
        )
        return ActionResult(
            success: false,
            message: message,
            icon: "exclamationmark.triangle.fill",
            displayDuration: 6
        )
    }

    private func sanitize(_ text: String, secrets: [String]) -> String {
        MCPRedactor.redact(text, secrets: secrets)
    }

    private func ensureConfigurationWritable() throws {
        guard !configurationLoadFailed else {
            throw MCPClientError.invalidConfiguration(
                MCPClientLocalization.string(
                    "The stored MCP configuration could not be loaded. It was left unchanged to prevent data loss."
                )
            )
        }
    }

    private func secretValues(for server: MCPServerConfiguration, host: HostServices?) -> [String] {
        guard let host else { return [] }
        var secrets = server.secretEnvironmentNames.compactMap { name in
            host.loadSecret(
                key: MCPServerConfiguration.secretStorageKey(serverID: server.id, environmentName: name)
            )
        }.filter { !$0.isEmpty }
        if server.transport == .streamableHTTP,
           server.httpAuthentication == .bearerToken,
           let bearerToken = host.loadSecret(key: MCPServerConfiguration.bearerTokenStorageKey(serverID: server.id)),
           !bearerToken.isEmpty {
            secrets.append(bearerToken)
        }
        return secrets
    }

    private func shouldAbortBatch(after error: Error) -> Bool {
        guard let error = error as? MCPClientError else { return true }
        if case .toolFailed = error {
            return false
        }
        return true
    }

    private func recordActivity(
        serverName: String,
        actionName: String?,
        status: MCPActivityEntry.Status,
        summary: String
    ) {
        state.withLock { current in
            current.activity.insert(
                MCPActivityEntry(
                    serverName: serverName,
                    actionName: actionName,
                    status: status,
                    summary: summary
                ),
                at: 0
            )
            if current.activity.count > 20 {
                current.activity.removeLast(current.activity.count - 20)
            }
        }
    }
}

private final class MCPConfiguredAction: NSObject, ActionPlugin, @unchecked Sendable {
    static let pluginId = MCPClientPlugin.pluginId
    static let pluginName = MCPClientPlugin.pluginName

    private let configuration: MCPActionConfiguration?
    private weak var owner: MCPClientPlugin?

    var actionName: String { configuration?.name ?? MCPClientLocalization.string("MCP Action") }
    var actionId: String { configuration?.actionID ?? "mcp-client-action-unconfigured" }
    var actionIcon: String { configuration?.symbolName ?? "point.3.connected.trianglepath.dotted" }

    required override init() {
        configuration = nil
        owner = nil
        super.init()
    }

    init(configuration: MCPActionConfiguration, owner: MCPClientPlugin) {
        self.configuration = configuration
        self.owner = owner
        super.init()
    }

    func activate(host: HostServices) {}
    func deactivate() {}

    func execute(input: String, context: ActionContext) async throws -> ActionResult {
        guard let configuration, let owner else { throw MCPClientError.actionNotFound }
        return try await owner.execute(actionID: configuration.id, input: input, context: context)
    }
}
