import Foundation
import MCP
import os
#if canImport(Darwin)
import Darwin
#endif

struct MCPResolvedServer: Sendable {
    let configuration: MCPServerConfiguration
    let executableURL: URL
    let environment: [String: String]
    let secrets: [String]
}

struct MCPToolInvocationResult: Sendable {
    let message: String?
    let url: String?
}

private final class MCPStandardErrorBuffer: @unchecked Sendable {
    private let storage = OSAllocatedUnfairLock<Data>(initialState: Data())

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        storage.withLock { buffer in
            buffer.append(data)
            if buffer.count > MCPClientConstants.maximumStandardErrorBytes {
                buffer.removeFirst(buffer.count - MCPClientConstants.maximumStandardErrorBytes)
            }
        }
    }

    func reset() {
        storage.withLock { $0.removeAll(keepingCapacity: true) }
    }

    func text(redacting secrets: [String]) -> String {
        let data = storage.withLock { $0 }
        // Truncation can split a multi-byte sequence, so lossy decoding is intentional.
        // swiftlint:disable:next optional_data_string_conversion
        let text = String(decoding: data, as: UTF8.self)
        return MCPRedactor.redact(text, secrets: secrets)
    }
}

actor MCPServerSession {
    private let resolvedServer: MCPResolvedServer
    private let connectionTimeout: Duration
    private let toolCallTimeout: Duration
    private var process: Process?
    private var client: Client?
    private var transport: StdioTransport?
    private var connectionTask: Task<Void, Error>?
    private var refreshTask: Task<Void, Error>?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var cachedTools: [MCPToolDescriptor] = []
    private var catalogIsStale = true
    private var callIsActive = false
    private var callWaiters: [CheckedContinuation<Void, Never>] = []
    private let standardError = MCPStandardErrorBuffer()
    private let logger = Logger(subsystem: "com.typewhisper.mcp-client", category: "MCPServerSession")

    init(
        resolvedServer: MCPResolvedServer,
        connectionTimeout: Duration = .seconds(20),
        toolCallTimeout: Duration = .seconds(60)
    ) {
        self.resolvedServer = resolvedServer
        self.connectionTimeout = connectionTimeout
        self.toolCallTimeout = toolCallTimeout
    }

    func tools() async throws -> [MCPToolDescriptor] {
        try await ensureConnected()
        if catalogIsStale {
            try await refreshToolsWithTimeout()
        }
        return cachedTools
    }

    func call(
        toolName: String,
        expectedSchemaFingerprint: String,
        arguments: [String: MCPJSONValue]
    ) async throws -> MCPToolInvocationResult {
        await acquireCallSlot()
        defer { releaseCallSlot() }
        try Task.checkCancellation()

        try await prepareTool(named: toolName, expectedSchemaFingerprint: expectedSchemaFingerprint)

        if process?.isRunning != true {
            try await prepareTool(named: toolName, expectedSchemaFingerprint: expectedSchemaFingerprint)
        }

        guard let client else {
            throw MCPClientError.indeterminateTransportFailure
        }
        let mcpArguments = arguments.mapValues(\.mcpValue)

        let requestContext: RequestContext<CallTool.Result>
        do {
            requestContext = try await client.callTool(name: toolName, arguments: mcpArguments)
        } catch {
            throw sanitizedIndeterminateError(error)
        }

        let result: CallTool.Result
        do {
            result = try await awaitToolResult(requestContext, client: client)
        } catch let error as MCPClientError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw sanitizedIndeterminateError(error)
        }

        if result.isError == true {
            let message = firstText(in: result.content)
                ?? MCPClientLocalization.string("The MCP tool reported an error.")
            throw MCPClientError.toolFailed(sanitize(message))
        }

        return MCPToolInvocationResult(
            message: firstText(in: result.content).map(sanitizeFeedback),
            url: firstResourceLink(in: result.content).flatMap(sanitizedResourceLink)
        )
    }

    func close() async {
        connectionTask?.cancel()
        refreshTask?.cancel()
        connectionTask = nil
        refreshTask = nil
        await closeResources()
    }

    private func closeResources() async {
        if let client {
            await client.disconnect()
        } else if let transport {
            await transport.disconnect()
        }

        errorPipe?.fileHandleForReading.readabilityHandler = nil
        inputPipe?.fileHandleForWriting.closeFile()
        outputPipe?.fileHandleForReading.closeFile()
        errorPipe?.fileHandleForReading.closeFile()

        if let process, process.isRunning {
            let deadline = ContinuousClock.now + .seconds(2)
            while process.isRunning, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if process.isRunning {
                process.terminate()
            }
        }

        self.client = nil
        self.transport = nil
        self.process = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        cachedTools = []
        catalogIsStale = true
    }

    private func ensureConnected() async throws {
        if let connectionTask {
            try await awaitSharedTask(connectionTask)
            return
        }

        if let process, process.isRunning, client != nil {
            return
        }

        let task = Task { try await self.connectFresh() }
        connectionTask = task
        do {
            try await awaitSharedTask(task)
            connectionTask = nil
        } catch {
            connectionTask = nil
            throw error
        }
    }

    private func connectFresh() async throws {
        await closeResources()
        try Task.checkCancellation()

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = resolvedServer.executableURL
        process.arguments = resolvedServer.configuration.arguments
        process.environment = resolvedServer.environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        #if canImport(Darwin)
        _ = fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        #endif

        standardError.reset()
        errorPipe.fileHandleForReading.readabilityHandler = { [standardError] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                standardError.append(data)
            }
        }

        do {
            try process.run()
        } catch {
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw MCPClientError.invalidConfiguration(
                MCPClientLocalization.string(
                    "Could not launch MCP server ‘%@’: %@",
                    resolvedServer.configuration.name,
                    sanitize(error.localizedDescription)
                )
            )
        }

        process.terminationHandler = { [weak self] terminatedProcess in
            let processIdentifier = terminatedProcess.processIdentifier
            Task {
                await self?.processDidTerminate(processIdentifier: processIdentifier)
            }
        }

        let transport = StdioTransport(
            input: .init(rawValue: outputPipe.fileHandleForReading.fileDescriptor),
            output: .init(rawValue: inputPipe.fileHandleForWriting.fileDescriptor)
        )
        let clientVersion = Bundle(for: MCPClientPlugin.self)
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let client = Client(name: "TypeWhisper", version: clientVersion, title: "TypeWhisper MCP Client")

        self.process = process
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        self.transport = transport
        self.client = client

        do {
            try await withTaskCancellationHandler {
                try await withTimeout(
                    connectionTimeout,
                    operationName: MCPClientLocalization.string("MCP connection"),
                    onTimeout: { await client.disconnect() }
                ) {
                    _ = try await client.connect(transport: transport)
                }
            } onCancel: {
                Task { await client.disconnect() }
            }
            await client.onNotification(ToolListChangedNotification.self) { [weak self] _ in
                await self?.markCatalogStale()
            }
            try await refreshToolsWithTimeout()
        } catch {
            let detail = standardError.text(redacting: resolvedServer.secrets)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            await closeResources()
            if detail.isEmpty {
                throw error
            }
            throw MCPClientError.invalidConfiguration(
                MCPClientLocalization.string(
                    "Could not connect to MCP server ‘%@’: %@. stderr: %@",
                    resolvedServer.configuration.name,
                    sanitize(error.localizedDescription),
                    sanitize(detail)
                )
            )
        }
    }

    private func refreshTools() async throws {
        guard let client else {
            throw MCPClientError.invalidConfiguration(MCPClientLocalization.string("The MCP client is not connected."))
        }

        var allTools: [Tool] = []
        var cursor: String?
        repeat {
            let page = try await client.listTools(cursor: cursor)
            allTools.append(contentsOf: page.tools)
            cursor = page.nextCursor
        } while cursor != nil

        cachedTools = try allTools.map(MCPToolDescriptor.init)
        catalogIsStale = false
    }

    private func refreshToolsWithTimeout() async throws {
        if let refreshTask {
            try await awaitSharedTask(refreshTask)
            return
        }
        guard let client else {
            throw MCPClientError.invalidConfiguration(MCPClientLocalization.string("The MCP client is not connected."))
        }

        let task = Task { try await self.performRefreshToolsWithTimeout(client: client) }
        refreshTask = task
        do {
            try await awaitSharedTask(task)
            refreshTask = nil
        } catch {
            refreshTask = nil
            throw error
        }
    }

    private func performRefreshToolsWithTimeout(client: Client) async throws {
        try await withTaskCancellationHandler {
            try await withTimeout(
                connectionTimeout,
                operationName: MCPClientLocalization.string("MCP tool discovery"),
                onTimeout: { await client.disconnect() }
            ) {
                try await self.refreshTools()
            }
        } onCancel: {
            Task { await client.disconnect() }
        }
    }

    private func markCatalogStale() {
        catalogIsStale = true
    }

    private func prepareTool(named toolName: String, expectedSchemaFingerprint: String) async throws {
        try await ensureConnected()
        if catalogIsStale {
            try await refreshToolsWithTimeout()
        }
        guard let tool = cachedTools.first(where: { $0.name == toolName }) else {
            throw MCPClientError.toolNotFound(toolName)
        }
        guard tool.schemaFingerprint == expectedSchemaFingerprint else {
            throw MCPClientError.toolSchemaChanged(toolName)
        }
    }

    private func processDidTerminate(processIdentifier: Int32) async {
        guard process?.processIdentifier == processIdentifier else { return }
        catalogIsStale = true
        if let client {
            await client.disconnect()
        } else if let transport {
            await transport.disconnect()
        }
    }

    private func acquireCallSlot() async {
        if !callIsActive {
            callIsActive = true
            return
        }
        await withCheckedContinuation { continuation in
            callWaiters.append(continuation)
        }
    }

    private func releaseCallSlot() {
        if callWaiters.isEmpty {
            callIsActive = false
        } else {
            callWaiters.removeFirst().resume()
        }
    }

    private func awaitToolResult(
        _ context: RequestContext<CallTool.Result>,
        client: Client
    ) async throws -> CallTool.Result {
        let activeProcess = process
        return try await withTaskCancellationHandler {
            try await withTimeout(
                toolCallTimeout,
                operationName: MCPClientLocalization.string("MCP tool call"),
                onTimeout: {
                    if activeProcess?.isRunning == true {
                        try? await client.cancelRequest(context.requestID, reason: "TypeWhisper tool-call timeout")
                    }
                    await client.disconnect()
                }
            ) {
                try await context.value
            }
        } onCancel: {
            Task {
                if activeProcess?.isRunning == true {
                    try? await client.cancelRequest(context.requestID, reason: "TypeWhisper action cancelled")
                }
                await client.disconnect()
            }
        }
    }

    private func withTimeout<T: Sendable>(
        _ duration: Duration,
        operationName: String,
        onTimeout: @escaping @Sendable () async -> Void,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                Task { await onTimeout() }
                throw MCPClientError.timedOut(operationName)
            }
            guard let result = try await group.next() else {
                throw MCPClientError.timedOut(operationName)
            }
            group.cancelAll()
            return result
        }
    }

    private func sanitizedIndeterminateError(_ error: Error) -> MCPClientError {
        logger.error("MCP transport failure: \(self.sanitize(error.localizedDescription), privacy: .public)")
        return .indeterminateTransportFailure
    }

    private func awaitSharedTask(_ task: Task<Void, Error>) async throws {
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func sanitize(_ text: String) -> String {
        MCPRedactor.redact(text, secrets: resolvedServer.secrets)
    }

    private func sanitizeFeedback(_ text: String) -> String {
        let sanitized = sanitize(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard sanitized.count > MCPClientConstants.maximumFeedbackLength else { return sanitized }
        return String(sanitized.prefix(MCPClientConstants.maximumFeedbackLength)) + "…"
    }

    private func firstText(in content: [Tool.Content]) -> String? {
        for item in content {
            if case .text(let text, _, _) = item {
                return text
            }
        }
        return nil
    }

    private func firstResourceLink(in content: [Tool.Content]) -> String? {
        for item in content {
            if case .resourceLink(let uri, _, _, _, _, _) = item {
                return uri
            }
        }
        return nil
    }

    private func sanitizedResourceLink(_ link: String) -> String? {
        resolvedServer.secrets.contains(where: { !$0.isEmpty && link.contains($0) }) ? nil : link
    }
}

actor MCPClientRuntime {
    private struct Entry {
        let revision: Int
        let session: MCPServerSession
    }

    private var sessions: [UUID: Entry] = [:]

    func tools(for server: MCPResolvedServer) async throws -> [MCPToolDescriptor] {
        try await session(for: server).tools()
    }

    func call(
        server: MCPResolvedServer,
        toolName: String,
        expectedSchemaFingerprint: String,
        arguments: [String: MCPJSONValue]
    ) async throws -> MCPToolInvocationResult {
        try await session(for: server).call(
            toolName: toolName,
            expectedSchemaFingerprint: expectedSchemaFingerprint,
            arguments: arguments
        )
    }

    func invalidate(serverID: UUID) async {
        guard let entry = sessions.removeValue(forKey: serverID) else { return }
        await entry.session.close()
    }

    func closeAll() async {
        let current = sessions.values.map(\.session)
        sessions = [:]
        for session in current {
            await session.close()
        }
    }

    private func session(for server: MCPResolvedServer) async -> MCPServerSession {
        if let entry = sessions[server.configuration.id], entry.revision == server.configuration.revision {
            return entry.session
        }

        let old = sessions.removeValue(forKey: server.configuration.id)
        let session = MCPServerSession(resolvedServer: server)
        sessions[server.configuration.id] = Entry(revision: server.configuration.revision, session: session)
        if let old {
            await old.session.close()
        }
        return session
    }
}

private extension MCPJSONValue {
    var mcpValue: MCP.Value {
        switch self {
        case .null: .null
        case .bool(let value): .bool(value)
        case .integer(let value): .int(value)
        case .number(let value): .double(value)
        case .string(let value): .string(value)
        case .array(let value): .array(value.map(\.mcpValue))
        case .object(let value): .object(value.mapValues(\.mcpValue))
        }
    }
}

private extension MCPToolDescriptor {
    init(_ tool: Tool) throws {
        let schemaData = try JSONEncoder().encode(tool.inputSchema)
        self.init(
            name: tool.name,
            title: tool.title ?? tool.annotations.title,
            description: tool.description,
            inputSchema: try JSONDecoder().decode(MCPJSONValue.self, from: schemaData),
            destructiveHint: tool.annotations.destructiveHint,
            readOnlyHint: tool.annotations.readOnlyHint
        )
    }
}
