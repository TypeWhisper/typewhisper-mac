import CryptoKit
import Foundation
import TypeWhisperPluginSDK

enum MCPClientConstants {
    static let configurationDefaultsKey = "configuration-v1"
    static let maximumBatchSize = 100
    static let maximumFeedbackLength = 200
    static let maximumStandardErrorBytes = 64 * 1024
}

enum MCPClientLocalization {
    private static let bundle = Bundle(for: MCPClientPlugin.self)

    static func string(_ key: String, _ arguments: CVarArg...) -> String {
        let format = NSLocalizedString(key, bundle: bundle, comment: "")
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: .current, arguments: arguments)
    }
}

enum MCPClientError: LocalizedError, Equatable {
    case executableNotFound(String)
    case executableNotExecutable(String)
    case relativeExecutableUnsupported(String)
    case serverNotFound
    case actionNotFound
    case toolNotFound(String)
    case toolSchemaChanged(String)
    case invalidConfiguration(String)
    case invalidInput(String)
    case batchTooLarge(Int)
    case toolFailed(String)
    case timedOut(String)
    case indeterminateTransportFailure

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let command):
            return MCPClientLocalization.string("Executable not found: %@", command)
        case .executableNotExecutable(let path):
            return MCPClientLocalization.string("File is not executable: %@", path)
        case .relativeExecutableUnsupported(let command):
            return MCPClientLocalization.string("Use an absolute path or a bare executable name instead of: %@", command)
        case .serverNotFound:
            return MCPClientLocalization.string("The configured MCP server no longer exists.")
        case .actionNotFound:
            return MCPClientLocalization.string("The configured MCP action no longer exists.")
        case .toolNotFound(let tool):
            return MCPClientLocalization.string("The MCP tool ‘%@’ is no longer available. Refresh the action configuration.", tool)
        case .toolSchemaChanged(let tool):
            return MCPClientLocalization.string("The input schema for ‘%@’ changed. Refresh the action configuration.", tool)
        case .invalidConfiguration(let message), .invalidInput(let message):
            return message
        case .batchTooLarge(let count):
            return MCPClientLocalization.string(
                "The batch contains %lld items. MCP Client supports at most %lld.",
                Int64(count),
                Int64(MCPClientConstants.maximumBatchSize)
            )
        case .toolFailed(let message):
            return message
        case .timedOut(let operation):
            return MCPClientLocalization.string("%@ timed out. The request was not retried.", operation)
        case .indeterminateTransportFailure:
            return MCPClientLocalization.string("The MCP connection was lost after the request may have been sent. The request was not retried.")
        }
    }
}

enum MCPJSONValue: Codable, Equatable, Hashable, Sendable {
    case null
    case bool(Bool)
    case integer(Int)
    case number(Double)
    case string(String)
    case array([MCPJSONValue])
    case object([String: MCPJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([MCPJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: MCPJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    static func parse(_ text: String) throws -> MCPJSONValue {
        guard let data = text.data(using: .utf8) else {
            throw MCPClientError.invalidInput(MCPClientLocalization.string("The input is not valid UTF-8 text."))
        }
        do {
            return try JSONDecoder().decode(MCPJSONValue.self, from: data)
        } catch {
            throw MCPClientError.invalidInput(MCPClientLocalization.string("Expected valid JSON."))
        }
    }

    var objectValue: [String: MCPJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [MCPJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    func value(at path: String) -> MCPJSONValue? {
        guard !path.isEmpty else { return self }
        return path.split(separator: ".").reduce(Optional(self)) { current, component in
            guard let current else { return nil }
            switch current {
            case .object(let object):
                return object[String(component)]
            case .array(let array):
                guard let index = Int(component), array.indices.contains(index) else { return nil }
                return array[index]
            default:
                return nil
            }
        }
    }

    var canonicalData: Data {
        (try? JSONSerialization.data(
            withJSONObject: foundationValue,
            options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        )) ?? Data()
    }

    var canonicalJSONString: String {
        String(data: canonicalData, encoding: .utf8) ?? "null"
    }

    var fingerprint: String {
        SHA256.hash(data: canonicalData).map { String(format: "%02x", $0) }.joined()
    }

    private var foundationValue: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .integer(let value): value
        case .number(let value): value
        case .string(let value): value
        case .array(let value): value.map(\.foundationValue)
        case .object(let value): value.mapValues(\.foundationValue)
        }
    }
}

enum MCPJSONType: String, Codable, CaseIterable, Sendable {
    case string
    case number
    case integer
    case boolean
    case array
    case object
    case null

    func accepts(_ value: MCPJSONValue) -> Bool {
        switch (self, value) {
        case (.string, .string), (.integer, .integer), (.boolean, .bool), (.array, .array),
             (.object, .object), (.null, .null), (.number, .number), (.number, .integer):
            true
        default:
            false
        }
    }
}

struct MCPToolProperty: Identifiable, Equatable, Sendable {
    let name: String
    let type: MCPJSONType?
    let isRequired: Bool
    let schema: MCPJSONValue

    var id: String { name }
}

struct MCPToolDescriptor: Codable, Equatable, Identifiable, Sendable {
    let name: String
    let title: String?
    let description: String?
    let inputSchema: MCPJSONValue
    let destructiveHint: Bool?
    let readOnlyHint: Bool?

    var id: String { name }
    var schemaFingerprint: String { inputSchema.fingerprint }

    var topLevelProperties: [MCPToolProperty] {
        guard case .object(let schema) = inputSchema,
              case .object(let properties)? = schema["properties"] else { return [] }
        let required = Set(schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        return properties.keys.sorted().compactMap { name in
            guard let propertySchema = properties[name] else { return nil }
            let type = propertySchema.objectValue?["type"]?.stringValue.flatMap(MCPJSONType.init(rawValue:))
            return MCPToolProperty(name: name, type: type, isRequired: required.contains(name), schema: propertySchema)
        }
    }

    var hasOneRequiredStringProperty: MCPToolProperty? {
        let required = topLevelProperties.filter(\.isRequired)
        guard required.count == 1, required[0].type == .string else { return nil }
        return required[0]
    }
}

enum MCPServerTransport: String, Codable, CaseIterable, Identifiable, Sendable {
    case stdio
    case streamableHTTP

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stdio:
            MCPClientLocalization.string("stdio")
        case .streamableHTTP:
            MCPClientLocalization.string("Streamable HTTP")
        }
    }
}

enum MCPHTTPAuthentication: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case bearerToken

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none:
            MCPClientLocalization.string("None")
        case .bearerToken:
            MCPClientLocalization.string("Bearer token")
        }
    }
}

struct MCPServerConfiguration: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var transport: MCPServerTransport
    var command: String
    var arguments: [String]
    var environment: [String: String]
    var secretEnvironmentNames: [String]
    var endpoint: String
    var httpAuthentication: MCPHTTPAuthentication
    var launchAcknowledged: Bool
    var revision: Int
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        transport: MCPServerTransport = .stdio,
        command: String = "",
        arguments: [String] = [],
        environment: [String: String] = [:],
        secretEnvironmentNames: [String] = [],
        endpoint: String = "",
        httpAuthentication: MCPHTTPAuthentication = .none,
        launchAcknowledged: Bool = false,
        revision: Int = 1,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.secretEnvironmentNames = secretEnvironmentNames.sorted()
        self.endpoint = endpoint
        self.httpAuthentication = httpAuthentication
        self.launchAcknowledged = launchAcknowledged
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case transport
        case command
        case arguments
        case environment
        case secretEnvironmentNames
        case endpoint
        case httpAuthentication
        case launchAcknowledged
        case revision
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        transport = try container.decodeIfPresent(MCPServerTransport.self, forKey: .transport) ?? .stdio
        command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
        arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        secretEnvironmentNames = try container.decodeIfPresent([String].self, forKey: .secretEnvironmentNames) ?? []
        endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint) ?? ""
        httpAuthentication = try container.decodeIfPresent(MCPHTTPAuthentication.self, forKey: .httpAuthentication) ?? .none
        launchAcknowledged = try container.decodeIfPresent(Bool.self, forKey: .launchAcknowledged) ?? false
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 1
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    static func secretStorageKey(serverID: UUID, environmentName: String) -> String {
        "server.\(serverID.uuidString.lowercased()).environment.\(environmentName)"
    }

    static func bearerTokenStorageKey(serverID: UUID) -> String {
        "server.\(serverID.uuidString.lowercased()).http.bearer-token"
    }
}

enum MCPInvocationMode: String, Codable, CaseIterable, Sendable {
    case single
    case batch
}

enum MCPBindingSource: String, Codable, CaseIterable, Sendable {
    case processedText
    case originalTranscript
    case currentBatchItem
    case jsonProperty
    case activeApplicationName
    case activeApplicationBundleIdentifier
    case activeApplicationURL
    case detectedLanguage
    case literal

    var displayName: String {
        switch self {
        case .processedText: MCPClientLocalization.string("Processed workflow text")
        case .originalTranscript: MCPClientLocalization.string("Original transcript")
        case .currentBatchItem: MCPClientLocalization.string("Current batch item")
        case .jsonProperty: MCPClientLocalization.string("JSON property path")
        case .activeApplicationName: MCPClientLocalization.string("Active application name")
        case .activeApplicationBundleIdentifier: MCPClientLocalization.string("Active application bundle identifier")
        case .activeApplicationURL: MCPClientLocalization.string("Active application URL")
        case .detectedLanguage: MCPClientLocalization.string("Detected language")
        case .literal: MCPClientLocalization.string("Literal value")
        }
    }
}

struct MCPArgumentBinding: Codable, Equatable, Identifiable, Sendable {
    var targetProperty: String
    var expectedType: MCPJSONType?
    var source: MCPBindingSource
    var propertyPath: String?
    var literalValue: MCPJSONValue?

    var id: String { targetProperty }
}

enum MCPRawArgumentsSource: String, Codable, CaseIterable, Sendable {
    case processedText
    case currentBatchItem
    case literalJSON
}

struct MCPActionConfiguration: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var symbolName: String
    var serverID: UUID
    var toolName: String
    var toolInputSchema: MCPJSONValue
    var schemaFingerprint: String
    var toolDestructiveHint: Bool?
    var bindings: [MCPArgumentBinding]
    var invocationMode: MCPInvocationMode
    var usesRawJSONArguments: Bool
    var rawArgumentsSource: MCPRawArgumentsSource
    var rawLiteralJSON: String
    var destructiveAcknowledged: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        symbolName: String = "point.3.connected.trianglepath.dotted",
        serverID: UUID,
        tool: MCPToolDescriptor,
        bindings: [MCPArgumentBinding] = [],
        invocationMode: MCPInvocationMode = .single,
        usesRawJSONArguments: Bool = false,
        rawArgumentsSource: MCPRawArgumentsSource = .processedText,
        rawLiteralJSON: String = "{}",
        destructiveAcknowledged: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.serverID = serverID
        self.toolName = tool.name
        self.toolInputSchema = tool.inputSchema
        self.schemaFingerprint = tool.schemaFingerprint
        self.toolDestructiveHint = tool.destructiveHint
        self.bindings = bindings
        self.invocationMode = invocationMode
        self.usesRawJSONArguments = usesRawJSONArguments
        self.rawArgumentsSource = rawArgumentsSource
        self.rawLiteralJSON = rawLiteralJSON
        self.destructiveAcknowledged = destructiveAcknowledged
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var actionID: String { "mcp-client-action-\(id.uuidString.lowercased())" }
}

struct MCPStoredConfiguration: Codable, Equatable, Sendable {
    var servers: [MCPServerConfiguration] = []
    var actions: [MCPActionConfiguration] = []
}

enum MCPExecutableResolver {
    static func resolve(
        command: String,
        configuredEnvironment: [String: String],
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:),
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:),
        isDirectory: (String) -> Bool = { path in
            var result = ObjCBool(false)
            _ = FileManager.default.fileExists(atPath: path, isDirectory: &result)
            return result.boolValue
        }
    ) throws -> URL {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MCPClientError.invalidConfiguration(MCPClientLocalization.string("Enter an MCP server command."))
        }

        if trimmed.hasPrefix("/") {
            guard fileExists(trimmed) else {
                throw MCPClientError.executableNotFound(trimmed)
            }
            guard isExecutable(trimmed), !isDirectory(trimmed) else {
                throw MCPClientError.executableNotExecutable(trimmed)
            }
            return URL(fileURLWithPath: trimmed)
        }

        if trimmed.contains("/") {
            throw MCPClientError.relativeExecutableUnsupported(trimmed)
        }

        let fallbackPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let pathValues = [configuredEnvironment["PATH"], processEnvironment["PATH"]]
            .compactMap { $0 }
            .flatMap { $0.split(separator: ":").map(String.init) }
        var seen = Set<String>()
        for directory in pathValues + fallbackPaths where seen.insert(directory).inserted {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(trimmed).path
            if isExecutable(candidate), !isDirectory(candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }

        throw MCPClientError.executableNotFound(trimmed)
    }
}

enum MCPHTTPEndpointResolver {
    private static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]

    static func resolve(_ endpoint: String) throws -> URL {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host,
              !host.isEmpty,
              scheme == "https" || loopbackHosts.contains(host.lowercased()),
              components.user == nil,
              components.password == nil,
              let url = components.url else {
            throw MCPClientError.invalidConfiguration(
                MCPClientLocalization.string("Enter a valid MCP server URL using HTTPS, or HTTP for a local address.")
            )
        }
        return url
    }
}

enum MCPJSONSchemaValidator {
    /// Performs limited prevalidation for `type`, `enum`, `required`, `properties`, and `items`.
    /// Boolean schemas and unsupported JSON Schema keywords remain authoritative on the MCP server.
    static func validate(_ value: MCPJSONValue, against schema: MCPJSONValue, path: String = "arguments") throws {
        guard case .object(let schemaObject) = schema else { return }

        if let typeName = schemaObject["type"]?.stringValue,
           let type = MCPJSONType(rawValue: typeName),
           !type.accepts(value) {
            throw MCPClientError.invalidInput(MCPClientLocalization.string("%@ must be a JSON %@.", path, type.rawValue))
        }

        if case .array(let allowed)? = schemaObject["enum"], !allowed.contains(value) {
            throw MCPClientError.invalidInput(MCPClientLocalization.string("%@ is not one of the values allowed by the tool schema.", path))
        }

        if case .object(let object) = value {
            let required = schemaObject["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            for name in required where object[name] == nil {
                throw MCPClientError.invalidInput(MCPClientLocalization.string("Missing required MCP argument: %@.", name))
            }
            if case .object(let properties)? = schemaObject["properties"] {
                for (name, propertyValue) in object {
                    if let propertySchema = properties[name] {
                        try validate(propertyValue, against: propertySchema, path: "\(path).\(name)")
                    }
                }
            }
        }

        if case .array(let array) = value, let itemSchema = schemaObject["items"] {
            for (index, item) in array.enumerated() {
                try validate(item, against: itemSchema, path: "\(path)[\(index)]")
            }
        }
    }
}

enum MCPArgumentMapper {
    static func invocations(
        input: String,
        context: ActionContext,
        action: MCPActionConfiguration
    ) throws -> [[String: MCPJSONValue]] {
        let items: [MCPJSONValue?]
        switch action.invocationMode {
        case .single:
            items = [nil]
        case .batch:
            let parsed = try MCPJSONValue.parse(input)
            guard let batch = parsed.arrayValue else {
                throw MCPClientError.invalidInput(MCPClientLocalization.string("Batch mode requires the processed workflow text to be a JSON array."))
            }
            guard batch.count <= MCPClientConstants.maximumBatchSize else {
                throw MCPClientError.batchTooLarge(batch.count)
            }
            items = batch.map(Optional.some)
        }

        if action.invocationMode == .batch,
           action.usesRawJSONArguments,
           action.rawArgumentsSource != .currentBatchItem {
            throw MCPClientError.invalidInput(
                MCPClientLocalization.string("Batch raw JSON arguments must use the current batch item.")
            )
        }

        let parsedInput = try? MCPJSONValue.parse(input)
        return try items.map { item in
            let arguments: [String: MCPJSONValue]
            if action.usesRawJSONArguments {
                let raw: MCPJSONValue
                switch action.rawArgumentsSource {
                case .processedText:
                    raw = try MCPJSONValue.parse(input)
                case .currentBatchItem:
                    guard let item else {
                        throw MCPClientError.invalidInput(MCPClientLocalization.string("Current batch item can only be used in batch mode."))
                    }
                    raw = item
                case .literalJSON:
                    raw = try MCPJSONValue.parse(action.rawLiteralJSON)
                }
                guard let object = raw.objectValue else {
                    throw MCPClientError.invalidInput(MCPClientLocalization.string("Raw JSON arguments must resolve to an object."))
                }
                arguments = object
            } else {
                arguments = try mappedArguments(
                    input: input,
                    parsedInput: parsedInput,
                    item: item,
                    context: context,
                    action: action
                )
            }

            let object = MCPJSONValue.object(arguments)
            try MCPJSONSchemaValidator.validate(object, against: action.toolInputSchema)
            return arguments
        }
    }

    private static func mappedArguments(
        input: String,
        parsedInput: MCPJSONValue?,
        item: MCPJSONValue?,
        context: ActionContext,
        action: MCPActionConfiguration
    ) throws -> [String: MCPJSONValue] {
        var result: [String: MCPJSONValue] = [:]
        for binding in action.bindings {
            let value: MCPJSONValue?
            switch binding.source {
            case .processedText:
                value = .string(input)
            case .originalTranscript:
                value = .string(context.originalText)
            case .currentBatchItem:
                value = item
            case .jsonProperty:
                let root = item ?? parsedInput
                value = binding.propertyPath.flatMap { root?.value(at: $0) }
            case .activeApplicationName:
                value = context.appName.map(MCPJSONValue.string)
            case .activeApplicationBundleIdentifier:
                value = context.bundleIdentifier.map(MCPJSONValue.string)
            case .activeApplicationURL:
                value = context.url.map(MCPJSONValue.string)
            case .detectedLanguage:
                value = context.language.map(MCPJSONValue.string)
            case .literal:
                value = binding.literalValue
            }

            guard let value else { continue }
            if let expectedType = binding.expectedType, !expectedType.accepts(value) {
                throw MCPClientError.invalidInput(
                    MCPClientLocalization.string(
                        "MCP argument ‘%@’ must be a JSON %@.",
                        binding.targetProperty,
                        expectedType.rawValue
                    )
                )
            }
            result[binding.targetProperty] = value
        }
        return result
    }
}

enum MCPArgumentPreview {
    static func arguments(for action: MCPActionConfiguration) -> [String: MCPJSONValue] {
        Dictionary(action.bindings.compactMap { binding in
            let value: MCPJSONValue?
            switch binding.source {
            case .processedText:
                value = placeholder(for: binding.expectedType, text: MCPClientLocalization.string("Sample processed text"))
            case .originalTranscript:
                value = placeholder(for: binding.expectedType, text: MCPClientLocalization.string("Sample original transcript"))
            case .currentBatchItem:
                value = placeholder(for: binding.expectedType, text: MCPClientLocalization.string("Sample batch item"))
            case .jsonProperty:
                value = placeholder(
                    for: binding.expectedType,
                    text: MCPClientLocalization.string("Sample JSON property")
                )
            case .activeApplicationName:
                value = placeholder(for: binding.expectedType, text: "Notes")
            case .activeApplicationBundleIdentifier:
                value = placeholder(for: binding.expectedType, text: "com.apple.Notes")
            case .activeApplicationURL:
                value = placeholder(for: binding.expectedType, text: "https://example.com")
            case .detectedLanguage:
                value = placeholder(for: binding.expectedType, text: "en")
            case .literal:
                value = binding.literalValue
            }
            return value.map { (binding.targetProperty, $0) }
        }, uniquingKeysWith: { _, newer in newer })
    }

    private static func placeholder(for type: MCPJSONType?, text: String) -> MCPJSONValue {
        switch type {
        case .number: .number(1.5)
        case .integer: .integer(1)
        case .boolean: .bool(true)
        case .array: .array([])
        case .object: .object([:])
        case .null: .null
        case .string, nil: .string(text)
        }
    }
}

enum MCPRedactor {
    static func redact(_ text: String, secrets: [String]) -> String {
        secrets
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
            .reduce(text) { partial, secret in
                partial.replacingOccurrences(of: secret, with: "••••")
            }
    }
}
