import Foundation
import TypeWhisperPluginSDK
import TypeWhisperPluginSDKTesting
import XCTest
@testable import MCPClientPlugin

final class MCPClientPluginTests: XCTestCase {
    private let taskTool = MCPToolDescriptor(
        name: "create_task",
        title: "Create task",
        description: "Creates one task",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "title": .object(["type": .string("string")]),
                "priority": .object(["type": .string("integer")]),
            ]),
            "required": .array([.string("title")]),
        ]),
        destructiveHint: false,
        readOnlyHint: false
    )

    func testManifestDeclaresInitialVersionAndHostBoundary() throws {
        let url = Self.pluginRoot.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: url))

        XCTAssertEqual(manifest.id, "com.typewhisper.mcp-client")
        XCTAssertEqual(manifest.version, "0.1.0")
        XCTAssertEqual(manifest.minHostVersion, "1.6.0")
        XCTAssertEqual(manifest.sdkCompatibilityVersion, "v1")
        XCTAssertEqual(manifest.category, "action")

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let descriptions = try XCTUnwrap(object["descriptions"] as? [String: String])
        XCTAssertEqual(descriptions["zh-Hans"], "通过 stdio 将 TypeWhisper 工作流连接到本地 MCP 工具。")
    }

    func testUnreadableStoredConfigurationIsNeverOverwritten() throws {
        let host = try PluginTestHostServices()
        let unreadable = Data("not-json".utf8)
        host.setUserDefault(unreadable, forKey: MCPClientConstants.configurationDefaultsKey)
        let plugin = MCPClientPlugin()
        plugin.activate(host: host)

        XCTAssertTrue(plugin.configurationLoadFailed)
        let server = MCPServerConfiguration(
            name: "Tasks",
            command: "/usr/bin/env",
            launchAcknowledged: true
        )
        XCTAssertThrowsError(try plugin.saveServer(server, secretValues: [:]))
        XCTAssertEqual(
            host.userDefault(forKey: MCPClientConstants.configurationDefaultsKey) as? Data,
            unreadable
        )
    }

    func testSecretValuesStayOutOfStoredConfigurationAndAreClearedWithServer() throws {
        let host = try PluginTestHostServices()
        let plugin = MCPClientPlugin()
        plugin.activate(host: host)

        let server = MCPServerConfiguration(
            name: "Tasks",
            command: "/usr/bin/env",
            secretEnvironmentNames: ["TASK_TOKEN"],
            launchAcknowledged: true
        )
        try plugin.saveServer(server, secretValues: ["TASK_TOKEN": "super-secret-token"])

        let secretKey = MCPServerConfiguration.secretStorageKey(
            serverID: server.id,
            environmentName: "TASK_TOKEN"
        )
        XCTAssertEqual(host.loadSecret(key: secretKey), "super-secret-token")

        let data = try XCTUnwrap(host.userDefault(forKey: MCPClientConstants.configurationDefaultsKey) as? Data)
        let storedText = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(storedText.contains("super-secret-token"))
        let stored = try JSONDecoder().decode(MCPStoredConfiguration.self, from: data)
        XCTAssertEqual(stored.servers.first?.secretEnvironmentNames, ["TASK_TOKEN"])
        XCTAssertTrue(stored.servers.first?.environment.isEmpty == true)

        plugin.removeServer(id: server.id)
        XCTAssertEqual(host.loadSecret(key: secretKey), "")
    }

    func testConfiguredActionsKeepStableIDsAcrossEditsAndNotifyHost() throws {
        let host = try PluginTestHostServices()
        let plugin = MCPClientPlugin()
        plugin.activate(host: host)
        let server = MCPServerConfiguration(name: "Tasks", command: "/usr/bin/env", launchAcknowledged: true)
        try plugin.saveServer(server, secretValues: [:])

        var action = MCPActionConfiguration(
            name: "Meeting tasks",
            serverID: server.id,
            tool: taskTool,
            bindings: MCPClientPlugin.defaultBindings(for: taskTool, mode: .single)
        )
        let stableID = action.actionID
        try plugin.saveAction(action)
        action.name = "Renamed meeting tasks"
        try plugin.saveAction(action)

        XCTAssertEqual(plugin.actions.count, 1)
        XCTAssertEqual(plugin.actions[0].actionID, stableID)
        XCTAssertEqual(plugin.actions[0].name, "Renamed meeting tasks")
        XCTAssertEqual(plugin.additionalActionPlugins.map(\.actionId), [stableID])
        XCTAssertEqual(host.capabilitiesChangedCount, 3)
    }

    func testConcurrentServerSavesAdvanceRevisionAtomically() throws {
        let host = try PluginTestHostServices()
        let plugin = MCPClientPlugin()
        plugin.activate(host: host)
        let server = MCPServerConfiguration(name: "Tasks", command: "/usr/bin/env", launchAcknowledged: true)
        try plugin.saveServer(server, secretValues: [:])

        DispatchQueue.concurrentPerform(iterations: 20) { index in
            var edit = server
            edit.name = "Tasks \(index)"
            try! plugin.saveServer(edit, secretValues: [:])
        }

        XCTAssertEqual(plugin.servers.first?.revision, 21)
    }

    func testExecutableResolutionUsesConfiguredPathBeforeProcessPath() throws {
        var candidates: [String] = []
        let result = try MCPExecutableResolver.resolve(
            command: "todo-mcp",
            configuredEnvironment: ["PATH": "/configured/bin:/second/bin"],
            processEnvironment: ["PATH": "/process/bin"],
            isExecutable: { path in
                candidates.append(path)
                return path == "/second/bin/todo-mcp"
            }
        )

        XCTAssertEqual(result.path, "/second/bin/todo-mcp")
        XCTAssertEqual(candidates, ["/configured/bin/todo-mcp", "/second/bin/todo-mcp"])
    }

    func testExecutableResolutionRejectsRelativePathsWithoutInvokingShell() {
        XCTAssertThrowsError(
            try MCPExecutableResolver.resolve(
                command: "./todo-mcp",
                configuredEnvironment: [:],
                processEnvironment: [:],
                isExecutable: { _ in true }
            )
        ) { error in
            XCTAssertEqual(error as? MCPClientError, .relativeExecutableUnsupported("./todo-mcp"))
        }
    }

    func testAbsoluteExecutableResolutionDistinguishesMissingAndNonExecutableFiles() {
        XCTAssertThrowsError(
            try MCPExecutableResolver.resolve(
                command: "/missing/todo-mcp",
                configuredEnvironment: [:],
                fileExists: { _ in false },
                isExecutable: { _ in false }
            )
        ) { error in
            XCTAssertEqual(error as? MCPClientError, .executableNotFound("/missing/todo-mcp"))
        }

        XCTAssertThrowsError(
            try MCPExecutableResolver.resolve(
                command: "/present/todo-mcp",
                configuredEnvironment: [:],
                fileExists: { _ in true },
                isExecutable: { _ in false }
            )
        ) { error in
            XCTAssertEqual(error as? MCPClientError, .executableNotExecutable("/present/todo-mcp"))
        }

        XCTAssertThrowsError(
            try MCPExecutableResolver.resolve(
                command: "/present/server-directory",
                configuredEnvironment: [:],
                fileExists: { _ in true },
                isExecutable: { _ in true },
                isDirectory: { _ in true }
            )
        ) { error in
            XCTAssertEqual(error as? MCPClientError, .executableNotExecutable("/present/server-directory"))
        }
    }

    func testSchemaFingerprintIsIndependentOfObjectKeyOrder() {
        let first = MCPJSONValue.object([
            "type": .string("object"),
            "properties": .object([
                "title": .object(["type": .string("string")]),
                "done": .object(["type": .string("boolean")]),
            ]),
        ])
        let second = MCPJSONValue.object([
            "properties": .object([
                "done": .object(["type": .string("boolean")]),
                "title": .object(["type": .string("string")]),
            ]),
            "type": .string("object"),
        ])

        XCTAssertEqual(first.fingerprint, second.fingerprint)
        XCTAssertEqual(first.canonicalJSONString, second.canonicalJSONString)
        XCTAssertEqual(MCPJSONValue.string("literal").canonicalJSONString, #""literal""#)
        XCTAssertEqual(MCPJSONValue.integer(3).canonicalJSONString, "3")
    }

    func testCompatibleSchemaRefreshRetainsOnlyMatchingBindings() throws {
        let original = MCPActionConfiguration(
            name: "Meeting tasks",
            serverID: UUID(),
            tool: taskTool,
            bindings: [
                MCPArgumentBinding(
                    targetProperty: "title",
                    expectedType: .string,
                    source: .processedText,
                    propertyPath: nil,
                    literalValue: nil
                ),
                MCPArgumentBinding(
                    targetProperty: "priority",
                    expectedType: .integer,
                    source: .literal,
                    propertyPath: nil,
                    literalValue: .integer(1)
                ),
            ]
        )
        let refreshed = MCPToolDescriptor(
            name: "create_task",
            title: nil,
            description: nil,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "title": .object(["type": .string("string")]),
                    "priority": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("title"), .string("priority")]),
            ]),
            destructiveHint: false,
            readOnlyHint: false
        )

        XCTAssertEqual(
            MCPClientPlugin.compatibleBindings(from: original, for: refreshed).map(\.targetProperty),
            ["title"]
        )

        let host = try PluginTestHostServices()
        let plugin = MCPClientPlugin()
        plugin.activate(host: host)
        let server = MCPServerConfiguration(name: "Tasks", command: "/usr/bin/env", launchAcknowledged: true)
        try plugin.saveServer(server, secretValues: [:])
        var incompatible = MCPActionConfiguration(
            name: "Meeting tasks",
            serverID: server.id,
            tool: refreshed,
            bindings: original.bindings
        )
        incompatible.schemaFingerprint = refreshed.schemaFingerprint
        XCTAssertThrowsError(try plugin.saveAction(incompatible)) { error in
            XCTAssertTrue(error.localizedDescription.contains("incompatible"))
        }
    }

    func testAutomaticStringBindingUsesProcessedTextOrBatchItem() {
        XCTAssertEqual(
            MCPClientPlugin.defaultBindings(for: taskTool, mode: .single).first?.source,
            .processedText
        )
        XCTAssertEqual(
            MCPClientPlugin.defaultBindings(for: taskTool, mode: .batch).first?.source,
            .currentBatchItem
        )
    }

    func testSingleMappingPreservesContextAndTypedLiterals() throws {
        let action = MCPActionConfiguration(
            name: "Create task",
            serverID: UUID(),
            tool: taskTool,
            bindings: [
                MCPArgumentBinding(
                    targetProperty: "title",
                    expectedType: .string,
                    source: .activeApplicationName,
                    propertyPath: nil,
                    literalValue: nil
                ),
                MCPArgumentBinding(
                    targetProperty: "priority",
                    expectedType: .integer,
                    source: .literal,
                    propertyPath: nil,
                    literalValue: .integer(2)
                ),
            ]
        )

        let invocations = try MCPArgumentMapper.invocations(
            input: "ignored",
            context: ActionContext(appName: "Notes", originalText: "original"),
            action: action
        )

        XCTAssertEqual(invocations, [["title": .string("Notes"), "priority": .integer(2)]])
    }

    func testBatchMappingValidatesEveryItemBeforeReturningInvocations() throws {
        let schema = MCPJSONValue.object([
            "type": .string("object"),
            "properties": .object(["title": .object(["type": .string("string")])]),
            "required": .array([.string("title")]),
        ])
        let tool = MCPToolDescriptor(
            name: "create_task",
            title: nil,
            description: nil,
            inputSchema: schema,
            destructiveHint: nil,
            readOnlyHint: nil
        )
        let action = MCPActionConfiguration(
            name: "Tasks",
            serverID: UUID(),
            tool: tool,
            bindings: [
                MCPArgumentBinding(
                    targetProperty: "title",
                    expectedType: .string,
                    source: .jsonProperty,
                    propertyPath: "title",
                    literalValue: nil
                )
            ],
            invocationMode: .batch
        )

        XCTAssertThrowsError(
            try MCPArgumentMapper.invocations(
                input: #"[{"title":"first"},{"wrong":"second"}]"#,
                context: ActionContext(),
                action: action
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("Missing required MCP argument"))
        }
    }

    func testBatchLimitIsEnforcedBeforeCallsCanBegin() {
        let action = MCPActionConfiguration(
            name: "Tasks",
            serverID: UUID(),
            tool: taskTool,
            bindings: MCPClientPlugin.defaultBindings(for: taskTool, mode: .batch),
            invocationMode: .batch
        )
        let input = "[" + Array(repeating: #""task""#, count: 101).joined(separator: ",") + "]"

        XCTAssertThrowsError(
            try MCPArgumentMapper.invocations(input: input, context: ActionContext(), action: action)
        ) { error in
            XCTAssertEqual(error as? MCPClientError, .batchTooLarge(101))
        }
    }

    func testRawArgumentsRequireAnObject() {
        var action = MCPActionConfiguration(name: "Raw", serverID: UUID(), tool: taskTool)
        action.usesRawJSONArguments = true
        action.rawArgumentsSource = .processedText

        XCTAssertThrowsError(
            try MCPArgumentMapper.invocations(input: #"["not","an","object"]"#, context: ActionContext(), action: action)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("must resolve to an object"))
        }
    }

    func testBatchRawArgumentsRequireCurrentBatchItem() throws {
        let action = MCPActionConfiguration(
            name: "Raw batch",
            serverID: UUID(),
            tool: taskTool,
            bindings: [],
            invocationMode: .batch,
            usesRawJSONArguments: true,
            rawArgumentsSource: .literalJSON,
            rawLiteralJSON: #"{"title":"duplicate"}"#
        )

        XCTAssertThrowsError(
            try MCPArgumentMapper.invocations(
                input: #"["first","second"]"#,
                context: ActionContext(),
                action: action
            )
        ) { error in
            XCTAssertEqual(
                error as? MCPClientError,
                .invalidInput("Batch raw JSON arguments must use the current batch item.")
            )
        }

        let host = try PluginTestHostServices()
        let plugin = MCPClientPlugin()
        plugin.activate(host: host)
        let server = MCPServerConfiguration(name: "Tasks", command: "/usr/bin/env", launchAcknowledged: true)
        try plugin.saveServer(server, secretValues: [:])
        var storedAction = action
        storedAction.serverID = server.id
        XCTAssertThrowsError(try plugin.saveAction(storedAction))
    }

    func testRedactorRemovesAllConfiguredSecretValues() {
        XCTAssertEqual(
            MCPRedactor.redact("token=abc123 and abc", secrets: ["abc", "abc123"]),
            "token=•••• and ••••"
        )
    }

    func testStdioContractDiscoversAndCallsToolWithoutRetryingToolErrors() async throws {
        let pythonPath = "/usr/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: pythonPath) else {
            throw XCTSkip("System Python is unavailable")
        }
        let fixture = try XCTUnwrap(
            Bundle.module.url(forResource: "mcp_fixture", withExtension: "py", subdirectory: "Fixtures")
        )
        let counter = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPClientPluginTests-\(UUID().uuidString).count")
        defer { try? FileManager.default.removeItem(at: counter) }

        let configuration = MCPServerConfiguration(
            name: "Fixture",
            command: pythonPath,
            arguments: [fixture.path, counter.path],
            launchAcknowledged: true
        )
        let server = MCPResolvedServer(
            configuration: configuration,
            executableURL: URL(fileURLWithPath: pythonPath),
            environment: ProcessInfo.processInfo.environment,
            secrets: []
        )
        let runtime = MCPClientRuntime()
        addTeardownBlock { await runtime.closeAll() }

        let tools = try await runtime.tools(for: server)
        XCTAssertEqual(tools.map(\.name), ["create_task"])
        XCTAssertEqual(tools.first?.hasOneRequiredStringProperty?.name, "title")

        do {
            _ = try await runtime.call(
                server: server,
                toolName: "create_task",
                expectedSchemaFingerprint: "stale-schema",
                arguments: ["title": .string("must-not-run")]
            )
            XCTFail("Expected a changed-schema error")
        } catch {
            XCTAssertEqual(error as? MCPClientError, .toolSchemaChanged("create_task"))
        }

        let success = try await runtime.call(
            server: server,
            toolName: "create_task",
            expectedSchemaFingerprint: try XCTUnwrap(tools.first).schemaFingerprint,
            arguments: ["title": .string("from-stdio")]
        )
        XCTAssertEqual(success.message, "created:from-stdio")

        do {
            _ = try await runtime.call(
                server: server,
                toolName: "create_task",
                expectedSchemaFingerprint: try XCTUnwrap(tools.first).schemaFingerprint,
                arguments: ["title": .string("fail")]
            )
            XCTFail("Expected the fixture tool error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("created:fail"))
        }

        let callCount = try String(contentsOf: counter, encoding: .utf8)
            .split(separator: "\n").count
        XCTAssertEqual(callCount, 2, "A tool error must not be retried")
    }

    func testDraftDiscoveryDoesNotPersistServerOrSecrets() async throws {
        let fixture = try Self.fixtureResources()
        defer { try? FileManager.default.removeItem(at: fixture.counter) }
        let host = try PluginTestHostServices()
        let plugin = MCPClientPlugin()
        plugin.activate(host: host)
        let server = MCPServerConfiguration(
            name: "Draft",
            command: fixture.pythonPath,
            arguments: [fixture.script.path, fixture.counter.path],
            secretEnvironmentNames: ["TASK_TOKEN"],
            launchAcknowledged: true
        )

        let tools = try await plugin.discoverTools(
            server: server,
            secretValues: ["TASK_TOKEN": "draft-secret"]
        )

        XCTAssertEqual(tools.map(\.name), ["create_task"])
        XCTAssertTrue(plugin.servers.isEmpty)
        XCTAssertNil(host.userDefault(forKey: MCPClientConstants.configurationDefaultsKey))
        XCTAssertNil(
            host.loadSecret(
                key: MCPServerConfiguration.secretStorageKey(
                    serverID: server.id,
                    environmentName: "TASK_TOKEN"
                )
            )
        )
    }

    func testCancellationUsesMCPRequestCancellationAndReturnsPromptly() async throws {
        let fixture = try Self.fixtureResources()
        defer { try? FileManager.default.removeItem(at: fixture.counter) }
        let server = Self.resolvedFixtureServer(fixture)
        let runtime = MCPClientRuntime()
        addTeardownBlock { await runtime.closeAll() }
        let tools = try await runtime.tools(for: server)
        let fingerprint = try XCTUnwrap(tools.first).schemaFingerprint

        let call = Task {
            try await runtime.call(
                server: server,
                toolName: "create_task",
                expectedSchemaFingerprint: fingerprint,
                arguments: ["title": .string("hang")]
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        call.cancel()

        do {
            _ = try await call.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: the SDK cancellation path removes the pending request.
        }
        XCTAssertEqual(try Self.requestCount(at: fixture.counter), 1)
    }

    func testToolCallTimeoutCancelsRequestWithoutRetry() async throws {
        let fixture = try Self.fixtureResources()
        defer { try? FileManager.default.removeItem(at: fixture.counter) }
        let server = Self.resolvedFixtureServer(fixture)
        let session = MCPServerSession(resolvedServer: server, toolCallTimeout: .milliseconds(100))
        let tools = try await session.tools()

        do {
            _ = try await session.call(
                toolName: "create_task",
                expectedSchemaFingerprint: try XCTUnwrap(tools.first).schemaFingerprint,
                arguments: ["title": .string("hang")]
            )
            XCTFail("Expected timeout")
        } catch let error as MCPClientError {
            guard case .timedOut = error else {
                return XCTFail("Expected timedOut, got \(error)")
            }
        }

        XCTAssertEqual(try Self.requestCount(at: fixture.counter), 1)
        await session.close()
    }

    func testConnectionTimeoutClosesHungInitialization() async throws {
        let fixture = try Self.fixtureResources()
        defer { try? FileManager.default.removeItem(at: fixture.counter) }
        let configuration = MCPServerConfiguration(
            name: "Fixture",
            command: fixture.pythonPath,
            arguments: [fixture.script.path, fixture.counter.path, "hang-init"],
            launchAcknowledged: true
        )
        let server = MCPResolvedServer(
            configuration: configuration,
            executableURL: URL(fileURLWithPath: fixture.pythonPath),
            environment: ProcessInfo.processInfo.environment,
            secrets: []
        )
        let session = MCPServerSession(resolvedServer: server, connectionTimeout: .milliseconds(100))

        do {
            _ = try await session.tools()
            XCTFail("Expected connection timeout")
        } catch let error as MCPClientError {
            guard case .timedOut = error else {
                return XCTFail("Expected timedOut, got \(error)")
            }
        }
        await session.close()
    }

    func testCancellingConnectionCancelsSharedTaskAndClosesProcess() async throws {
        let fixture = try Self.fixtureResources()
        defer { try? FileManager.default.removeItem(at: fixture.counter) }
        let configuration = MCPServerConfiguration(
            name: "Fixture",
            command: fixture.pythonPath,
            arguments: [fixture.script.path, fixture.counter.path, "hang-init"],
            launchAcknowledged: true
        )
        let server = MCPResolvedServer(
            configuration: configuration,
            executableURL: URL(fileURLWithPath: fixture.pythonPath),
            environment: ProcessInfo.processInfo.environment,
            secrets: []
        )
        let session = MCPServerSession(resolvedServer: server)
        let task = Task { try await session.tools() }
        try await Task.sleep(for: .milliseconds(100))

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        await session.close()
    }

    func testStandardErrorIsBoundedAndRedactsSecrets() async throws {
        let fixture = try Self.fixtureResources()
        defer { try? FileManager.default.removeItem(at: fixture.counter) }
        let secret = "fixture-super-secret"
        let configuration = MCPServerConfiguration(
            name: "Fixture",
            command: fixture.pythonPath,
            arguments: [fixture.script.path, fixture.counter.path, "fail-init"],
            launchAcknowledged: true
        )
        let server = MCPResolvedServer(
            configuration: configuration,
            executableURL: URL(fileURLWithPath: fixture.pythonPath),
            environment: ProcessInfo.processInfo.environment,
            secrets: [secret]
        )
        let runtime = MCPClientRuntime()
        addTeardownBlock { await runtime.closeAll() }

        do {
            _ = try await runtime.tools(for: server)
            XCTFail("Expected initialization failure")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains(secret))
            XCTAssertTrue(error.localizedDescription.contains("••••"))
            XCTAssertLessThan(error.localizedDescription.utf8.count, 66 * 1024)
        }
    }

    func testKnownProcessExitBeforeWriteReconnectsOnce() async throws {
        let fixture = try Self.fixtureResources()
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPClientPluginTests-\(UUID().uuidString).marker")
        defer {
            if FileManager.default.fileExists(atPath: fixture.counter.path) {
                try? FileManager.default.removeItem(at: fixture.counter)
            }
            if FileManager.default.fileExists(atPath: marker.path) {
                try? FileManager.default.removeItem(at: marker)
            }
        }
        let configuration = MCPServerConfiguration(
            name: "Fixture",
            command: fixture.pythonPath,
            arguments: [fixture.script.path, fixture.counter.path, "exit-after-first-list", marker.path],
            launchAcknowledged: true
        )
        let server = MCPResolvedServer(
            configuration: configuration,
            executableURL: URL(fileURLWithPath: fixture.pythonPath),
            environment: ProcessInfo.processInfo.environment,
            secrets: []
        )
        let runtime = MCPClientRuntime()
        addTeardownBlock { await runtime.closeAll() }

        let tools = try await runtime.tools(for: server)
        try await Task.sleep(for: .milliseconds(250))
        let result = try await runtime.call(
            server: server,
            toolName: "create_task",
            expectedSchemaFingerprint: try XCTUnwrap(tools.first).schemaFingerprint,
            arguments: ["title": .string("after-reconnect")]
        )

        XCTAssertEqual(result.message, "created:after-reconnect")
        XCTAssertEqual(try Self.requestCount(at: fixture.counter), 1)
    }

    func testToolListChangedNotificationRefreshesCatalog() async throws {
        let fixture = try Self.fixtureResources()
        defer { try? FileManager.default.removeItem(at: fixture.counter) }
        let configuration = MCPServerConfiguration(
            name: "Fixture",
            command: fixture.pythonPath,
            arguments: [fixture.script.path, fixture.counter.path, "list-change"],
            launchAcknowledged: true
        )
        let server = MCPResolvedServer(
            configuration: configuration,
            executableURL: URL(fileURLWithPath: fixture.pythonPath),
            environment: ProcessInfo.processInfo.environment,
            secrets: []
        )
        let session = MCPServerSession(resolvedServer: server)

        _ = try await session.tools()
        var refreshed = try await session.tools()
        for _ in 0..<100 where refreshed.first?.description != "Create a fixture task version 2" {
            try await Task.sleep(for: .milliseconds(50))
            refreshed = try await session.tools()
        }

        XCTAssertEqual(refreshed.first?.description, "Create a fixture task version 2")
        XCTAssertEqual(try Self.requestCount(at: fixture.counter), 2)
        await session.close()
    }

    func testConcurrentDiscoverySharesOneConnectionAndCatalogLoad() async throws {
        let fixture = try Self.fixtureResources()
        defer { try? FileManager.default.removeItem(at: fixture.counter) }
        let configuration = MCPServerConfiguration(
            name: "Fixture",
            command: fixture.pythonPath,
            arguments: [fixture.script.path, fixture.counter.path, "count-connection"],
            launchAcknowledged: true
        )
        let server = MCPResolvedServer(
            configuration: configuration,
            executableURL: URL(fileURLWithPath: fixture.pythonPath),
            environment: ProcessInfo.processInfo.environment,
            secrets: []
        )
        let session = MCPServerSession(resolvedServer: server)

        let catalogs = try await withThrowingTaskGroup(of: [MCPToolDescriptor].self) { group in
            for _ in 0..<10 {
                group.addTask { try await session.tools() }
            }
            var results: [[MCPToolDescriptor]] = []
            for try await tools in group {
                results.append(tools)
            }
            return results
        }

        XCTAssertEqual(catalogs.count, 10)
        XCTAssertTrue(catalogs.allSatisfy { $0.map(\.name) == ["create_task"] })
        XCTAssertEqual(try Self.requestCount(at: fixture.counter), 2)
        await session.close()
    }

    func testRevisionReplacementIsVisibleBeforeOldSessionCloses() async throws {
        let fixture = try Self.fixtureResources()
        defer { try? FileManager.default.removeItem(at: fixture.counter) }
        let id = UUID()
        func resolved(revision: Int) -> MCPResolvedServer {
            let configuration = MCPServerConfiguration(
                id: id,
                name: "Fixture",
                command: fixture.pythonPath,
                arguments: [fixture.script.path, fixture.counter.path, "count-connection"],
                launchAcknowledged: true,
                revision: revision
            )
            return MCPResolvedServer(
                configuration: configuration,
                executableURL: URL(fileURLWithPath: fixture.pythonPath),
                environment: ProcessInfo.processInfo.environment,
                secrets: []
            )
        }
        let runtime = MCPClientRuntime()
        addTeardownBlock { await runtime.closeAll() }

        _ = try await runtime.tools(for: resolved(revision: 1))
        async let first = runtime.tools(for: resolved(revision: 2))
        async let second = runtime.tools(for: resolved(revision: 2))
        _ = try await (first, second)

        XCTAssertEqual(try Self.requestCount(at: fixture.counter), 4)
    }

    func testBatchExecutionContinuesAfterToolErrorInOrder() async throws {
        let fixture = try Self.fixtureResources()
        defer { try? FileManager.default.removeItem(at: fixture.counter) }

        let host = try PluginTestHostServices()
        let plugin = MCPClientPlugin()
        plugin.activate(host: host)
        defer { plugin.deactivate() }

        let server = MCPServerConfiguration(
            name: "Fixture",
            command: fixture.pythonPath,
            arguments: [fixture.script.path, fixture.counter.path],
            launchAcknowledged: true
        )
        try plugin.saveServer(server, secretValues: [:])
        let tool = Self.fixtureTool
        let action = MCPActionConfiguration(
            name: "Meeting tasks",
            serverID: server.id,
            tool: tool,
            bindings: MCPClientPlugin.defaultBindings(for: tool, mode: .batch),
            invocationMode: .batch
        )
        try plugin.saveAction(action)

        let result = try await plugin.execute(
            actionID: action.id,
            input: #"["first","fail","third"]"#,
            context: ActionContext()
        )

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.message, "2 of 3 actions completed; failed items: 2.")
        XCTAssertEqual(plugin.activity.first?.summary, "2 of 3 actions completed; failed items: 2.")
        XCTAssertFalse(plugin.activity.first?.summary.contains("fixture tool failure") == true)
        XCTAssertEqual(try Self.requestCount(at: fixture.counter), 3)
    }

    func testConnectionFailureReturnsStructuredActionResultAndActivity() async throws {
        let host = try PluginTestHostServices()
        let plugin = MCPClientPlugin()
        plugin.activate(host: host)
        defer { plugin.deactivate() }
        let server = MCPServerConfiguration(
            name: "Unavailable",
            command: "/usr/bin/false",
            launchAcknowledged: true
        )
        try plugin.saveServer(server, secretValues: [:])
        let action = MCPActionConfiguration(
            name: "Meeting tasks",
            serverID: server.id,
            tool: taskTool,
            bindings: MCPClientPlugin.defaultBindings(for: taskTool, mode: .single)
        )
        try plugin.saveAction(action)

        let result = try await plugin.execute(
            actionID: action.id,
            input: "Create a task",
            context: ActionContext()
        )

        XCTAssertFalse(result.success)
        XCTAssertEqual(plugin.activity.first?.status, .failure)
        XCTAssertEqual(plugin.activity.first?.actionName, action.name)
    }

    func testTransportLossAfterWriteIsNeverReplayed() async throws {
        let fixture = try Self.fixtureResources()
        defer { try? FileManager.default.removeItem(at: fixture.counter) }
        let configuration = MCPServerConfiguration(
            name: "Fixture",
            command: fixture.pythonPath,
            arguments: [fixture.script.path, fixture.counter.path],
            launchAcknowledged: true
        )
        let server = MCPResolvedServer(
            configuration: configuration,
            executableURL: URL(fileURLWithPath: fixture.pythonPath),
            environment: ProcessInfo.processInfo.environment,
            secrets: []
        )
        let runtime = MCPClientRuntime()
        addTeardownBlock { await runtime.closeAll() }

        let tools = try await runtime.tools(for: server)
        do {
            _ = try await runtime.call(
                server: server,
                toolName: "create_task",
                expectedSchemaFingerprint: try XCTUnwrap(tools.first).schemaFingerprint,
                arguments: ["title": .string("crash-after-receive")]
            )
            XCTFail("Expected an indeterminate transport failure")
        } catch {
            XCTAssertEqual(error as? MCPClientError, .indeterminateTransportFailure)
        }
        XCTAssertEqual(try Self.requestCount(at: fixture.counter), 1)
    }

    private static var fixtureTool: MCPToolDescriptor {
        MCPToolDescriptor(
            name: "create_task",
            title: nil,
            description: nil,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["title": .object(["type": .string("string")])]),
                "required": .array([.string("title")]),
            ]),
            destructiveHint: false,
            readOnlyHint: false
        )
    }

    private static func fixtureResources() throws -> (pythonPath: String, script: URL, counter: URL) {
        let pythonPath = "/usr/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: pythonPath) else {
            throw XCTSkip("System Python is unavailable")
        }
        let script = try XCTUnwrap(
            Bundle.module.url(forResource: "mcp_fixture", withExtension: "py", subdirectory: "Fixtures")
        )
        let counter = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPClientPluginTests-\(UUID().uuidString).count")
        return (pythonPath, script, counter)
    }

    private static func resolvedFixtureServer(
        _ fixture: (pythonPath: String, script: URL, counter: URL)
    ) -> MCPResolvedServer {
        let configuration = MCPServerConfiguration(
            name: "Fixture",
            command: fixture.pythonPath,
            arguments: [fixture.script.path, fixture.counter.path],
            launchAcknowledged: true
        )
        return MCPResolvedServer(
            configuration: configuration,
            executableURL: URL(fileURLWithPath: fixture.pythonPath),
            environment: ProcessInfo.processInfo.environment,
            secrets: []
        )
    }

    private static func requestCount(at counter: URL) throws -> Int {
        try String(contentsOf: counter, encoding: .utf8).split(separator: "\n").count
    }

    private static var pluginRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
