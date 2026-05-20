import Foundation
import TypeWhisperPluginSDK

enum MemPalaceMCPError: LocalizedError {
    case missingAPIKey
    case http(Int, String?)
    case rpc(Int, String)
    case decoding(String)
    case missingContent
    case toolError(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Missing MemPalace API key"
        case .http(let status, let detail):
            if let detail, !detail.isEmpty { return "HTTP \(status): \(detail)" }
            return "HTTP \(status)"
        case .rpc(let code, let message):
            return "MemPalace error \(code): \(message)"
        case .decoding(let reason):
            return "Decoding failed: \(reason)"
        case .missingContent:
            return "Tool response missing content field"
        case .toolError(let detail):
            return "MemPalace tool error: \(detail)"
        }
    }
}

// MARK: - Response models for MemPalace tool outputs

// Sidecar wraps tool returns inconsistently. The wire shapes below match
// apps/sidecar/sidecar.py dispatch, not the bare tool_* return values.

// add_drawer: sidecar wraps as {"added": true, "drawer_id": "...", "result": "<str>"}.
// On tool error the inner result string contains the error; success is implied by
// non-nil drawer_id.
struct MemPalaceAddDrawerResult: Decodable {
    let added: Bool?
    let drawer_id: String?
    let result: String?
}

// delete_drawer: sidecar passes the tool result through verbatim → {success, drawer_id?, error?}
struct MemPalaceDeleteDrawerResult: Decodable {
    let success: Bool
    let drawer_id: String?
    let error: String?
}

// update_drawer: sidecar wraps as {"updated": true, "result": <tool_dict>}
struct MemPalaceUpdateDrawerResult: Decodable {
    let updated: Bool?
    let result: UpdateInner?

    struct UpdateInner: Decodable {
        let success: Bool?
        let drawer_id: String?
        let error: String?
    }
}

struct MemPalaceSearchHit: Decodable {
    let text: String?
    let wing: String?
    let room: String?
    let source_file: String?
    let similarity: Double?
    let distance: Double?
}

// search: sidecar wraps as {"results": <tool_search_dict>} where tool_search dict
// is {query, filters, total_before_filter, results: [hits], error?}.
struct MemPalaceSearchResult: Decodable {
    let results: SearchInner?

    struct SearchInner: Decodable {
        let query: String?
        let results: [MemPalaceSearchHit]?
        let error: String?
    }

    var hits: [MemPalaceSearchHit] { results?.results ?? [] }
    var errorMessage: String? { results?.error }
}

// list_wings: {"wings": {"wings": {name: count, ...}}}
struct MemPalaceListWingsResult: Decodable {
    let wings: WingsInner?

    struct WingsInner: Decodable {
        let wings: [String: Int]?
    }
}

// list_rooms: {"rooms": {"wing": "...", "rooms": {name: count, ...}}}
struct MemPalaceListRoomsResult: Decodable {
    let rooms: RoomsInner?

    struct RoomsInner: Decodable {
        let wing: String?
        let rooms: [String: Int]?
    }
}

// get_drawer: {"drawer": {"drawer_id": ..., "content": ..., "wing": ..., "room": ..., "metadata": {...}}}
//             OR {"drawer": {"error": "Drawer not found: ..."}}
struct MemPalaceGetDrawerResult: Decodable {
    let drawer: DrawerInner?

    struct DrawerInner: Decodable {
        let drawer_id: String?
        let content: String?
        let wing: String?
        let room: String?
        let error: String?
    }

    var notFound: Bool {
        if let err = drawer?.error, err.lowercased().contains("not found") {
            return true
        }
        return false
    }

    var exists: Bool {
        drawer?.drawer_id != nil && drawer?.error == nil
    }
}

// MARK: - HTTP abstraction
//
// Why not `PluginHTTPClient` from the SDK: that helper logs
// `request.url?.absoluteString` to the OS log before and after every request.
// Since the MemPalace API key is embedded in the URL path
// (`/mcp/<api-key>`), routing through the shared SDK helper would leak the
// credential to the OS log. We use a plugin-owned `URLSession` instead.
//
// Trade-off: we forego the SDK's connection warming. To partially recover,
// we keep one ephemeral session per client instance and reuse it across
// requests, and we mirror a minimal transient-error retry-once policy.

protocol MemPalaceMCPHTTP: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

final class NonLoggingMemPalaceMCPHTTP: MemPalaceMCPHTTP, @unchecked Sendable {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    func invalidate() {
        session.finishTasksAndInvalidate()
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            // Retry once on transient network errors (network blip, DNS
            // hiccup). Permanent errors (auth, bad request) fall through on
            // the second try just like the first.
            if let urlError = error as? URLError, urlError.isTransient {
                return try await session.data(for: request)
            }
            throw error
        }
    }
}

private extension URLError {
    var isTransient: Bool {
        switch code {
        case .timedOut, .cannotConnectToHost, .networkConnectionLost,
             .notConnectedToInternet, .dnsLookupFailed, .resourceUnavailable:
            return true
        default:
            return false
        }
    }
}

// MARK: - MCP client (JSON-RPC 2.0 over /mcp/{api-key})

final class MemPalaceMCPClient {
    private let endpoint: URL
    private let http: MemPalaceMCPHTTP
    private let idGenerator: AtomicCounter

    init(baseURL: URL, apiKey: String, http: MemPalaceMCPHTTP = NonLoggingMemPalaceMCPHTTP()) {
        // /mcp/{token} — API-key in URL path. Aggressively percent-encode the
        // key: alphanumerics only, so '#', '@', '?', '/' etc. are escaped and
        // never re-interpreted as URL syntax.
        let trimmedBase = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let safeKeyCharset = CharacterSet.alphanumerics
        let encodedKey = apiKey.addingPercentEncoding(withAllowedCharacters: safeKeyCharset) ?? apiKey
        self.endpoint = URL(string: "\(trimmedBase)/mcp/\(encodedKey)")
            ?? URL(string: "\(trimmedBase)/mcp/invalid")!
        self.http = http
        self.idGenerator = AtomicCounter()
    }

    /// Invalidate the underlying URLSession so retained-but-replaced clients
    /// release their resources promptly. Called by the plugin when it rebuilds
    /// the client after a config or API key change.
    func invalidate() {
        if let session = http as? NonLoggingMemPalaceMCPHTTP {
            session.invalidate()
        }
    }

    // MARK: - Public API matching MemPalace tools

    func addDrawer(content: String, wing: String, room: String, sourceFile: String?) async throws -> String {
        var args: [String: Any] = [
            "content": content,
            "wing": wing,
            "room": room,
        ]
        if let sourceFile { args["source_file"] = sourceFile }
        let result: MemPalaceAddDrawerResult = try await callTool("mempalace_add_drawer", arguments: args)
        guard let drawerId = result.drawer_id, !drawerId.isEmpty else {
            // sidecar puts error detail into `result` field as Python str()
            throw MemPalaceMCPError.toolError(result.result ?? "add_drawer returned no drawer_id")
        }
        return drawerId
    }

    func deleteDrawer(_ drawerId: String) async throws {
        let result: MemPalaceDeleteDrawerResult = try await callTool(
            "mempalace_delete_drawer",
            arguments: ["drawer_id": drawerId]
        )
        // success=false with "not found" is acceptable for our co-tenancy/cleanup flows.
        if !result.success, let err = result.error, !err.lowercased().contains("not found") {
            throw MemPalaceMCPError.toolError(err)
        }
    }

    func updateDrawer(_ drawerId: String, content: String) async throws {
        let result: MemPalaceUpdateDrawerResult = try await callTool(
            "mempalace_update_drawer",
            arguments: ["drawer_id": drawerId, "content": content]
        )
        // Sidecar shape: {"updated": true, "result": {success, drawer_id, error?}}.
        if let inner = result.result, inner.success == false, let err = inner.error {
            throw MemPalaceMCPError.toolError(err)
        }
        if result.updated != true && result.result?.success != true {
            throw MemPalaceMCPError.toolError("update_drawer failed")
        }
    }

    func search(text: String, wing: String?, limit: Int) async throws -> [MemPalaceSearchHit] {
        var args: [String: Any] = ["query": text, "limit": limit]
        if let wing, !wing.isEmpty { args["wing"] = wing }
        let result: MemPalaceSearchResult = try await callTool(
            "mempalace_search",
            arguments: args
        )
        if let err = result.errorMessage { throw MemPalaceMCPError.toolError(err) }
        return result.hits
    }

    func listWings() async throws -> [String] {
        let result: MemPalaceListWingsResult = try await callTool(
            "mempalace_list_wings",
            arguments: [:]
        )
        let dict = result.wings?.wings ?? [:]
        return Array(dict.keys).sorted()
    }

    func listRooms(wing: String) async throws -> [String] {
        let result: MemPalaceListRoomsResult = try await callTool(
            "mempalace_list_rooms",
            arguments: ["wing": wing]
        )
        let dict = result.rooms?.rooms ?? [:]
        return Array(dict.keys).sorted()
    }

    func ping() async throws {
        let _: EmptyDecodable = try await callTool("mempalace_status", arguments: [:])
    }

    /// Returns true if the drawer exists on the server, false if MemPalace
    /// reports "not found". Throws on other errors (network, auth).
    func drawerExists(_ drawerId: String) async throws -> Bool {
        let result: MemPalaceGetDrawerResult = try await callTool(
            "mempalace_get_drawer",
            arguments: ["drawer_id": drawerId]
        )
        if result.notFound { return false }
        return result.exists
    }

    // MARK: - Internals

    private struct EmptyDecodable: Decodable {}

    private func callTool<T: Decodable>(_ name: String, arguments: [String: Any]) async throws -> T {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": idGenerator.next(),
            "method": "tools/call",
            "params": [
                "name": name,
                "arguments": arguments,
            ],
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = body
        request.timeoutInterval = 20

        let (data, response) = try await http.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MemPalaceMCPError.http(0, "no HTTP response")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let detail = String(data: data, encoding: .utf8)
            throw MemPalaceMCPError.http(httpResponse.statusCode, detail)
        }

        let envelope = try decodeEnvelope(data)
        if let rpcError = envelope.error {
            throw MemPalaceMCPError.rpc(rpcError.code, rpcError.message)
        }
        return try extractToolResult(envelope.result)
    }

    private func decodeEnvelope(_ data: Data) throws -> JSONRPCEnvelope {
        do {
            return try JSONDecoder().decode(JSONRPCEnvelope.self, from: data)
        } catch {
            throw MemPalaceMCPError.decoding("envelope: \(error)")
        }
    }

    private func extractToolResult<T: Decodable>(_ result: JSONRPCResult?) throws -> T {
        // EmptyDecodable accepts any shape — short-circuit if no content needed.
        if T.self == EmptyDecodable.self {
            return EmptyDecodable() as! T
        }
        guard let result else {
            throw MemPalaceMCPError.missingContent
        }
        // MCP tool results: { content: [{ type: "text", text: "<JSON>" }], isError: bool }
        if let content = result.content, let first = content.first, first.type == "text", let text = first.text {
            guard let json = text.data(using: .utf8) else {
                throw MemPalaceMCPError.decoding("content text not UTF-8")
            }
            do {
                return try JSONDecoder().decode(T.self, from: json)
            } catch {
                throw MemPalaceMCPError.decoding("tool result JSON: \(error)")
            }
        }
        // Some MemPalace methods (e.g. list_vaults) return content shape but ours expect dict result.
        throw MemPalaceMCPError.missingContent
    }
}

// MARK: - JSON-RPC envelope

private struct JSONRPCEnvelope: Decodable {
    let jsonrpc: String?
    let id: Int?
    let result: JSONRPCResult?
    let error: JSONRPCError?
}

private struct JSONRPCResult: Decodable {
    let content: [JSONRPCContent]?
    let isError: Bool?
}

private struct JSONRPCContent: Decodable {
    let type: String?
    let text: String?
}

private struct JSONRPCError: Decodable {
    let code: Int
    let message: String
}

// MARK: - Thread-safe counter for JSON-RPC ids

final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int = 0
    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}
