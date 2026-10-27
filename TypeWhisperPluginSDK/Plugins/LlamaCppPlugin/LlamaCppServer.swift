import Darwin
import Foundation
import os

/// How `llama-server` is started for one model.
struct LlamaCppServerLaunchOptions: Equatable, Sendable {
    /// Name the server reports for the loaded model; requests address it by this alias.
    static let modelAlias = "typewhisper-local"
    static let defaultContextSize = 8192

    var modelURL: URL
    /// Multimodal projector (`mmproj`), for example the audio encoder of a speech model.
    var projectorURL: URL?
    var contextSize = defaultContextSize
    var threads = LlamaCppServerLaunchOptions.recommendedThreadCount

    static var recommendedThreadCount: Int {
        max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
    }

    func arguments(port: UInt16) -> [String] {
        var arguments = [
            "--model", modelURL.path,
            "--alias", Self.modelAlias,
            "--host", "127.0.0.1",
            "--port", String(port),
            "--ctx-size", String(contextSize),
            // One request at a time: TypeWhisper serializes local inference anyway, and
            // every extra slot reserves its own context memory.
            "--parallel", "1",
            "--n-gpu-layers", "999",
            "--threads", String(threads),
            "--jinja",
            // Text cleanup must not think first; templates that always reason are trimmed
            // by `LlamaCppPlugin.finalPromptOutput`.
            "--reasoning", "off",
            // Keep memory predictable: no host-memory prompt cache beyond the slot itself.
            "--cache-ram", "0",
            "--no-ui",
            "--no-slots",
            "--offline",
        ]
        if let projectorURL {
            arguments += ["--mmproj", projectorURL.path]
        }
        return arguments
    }

    /// Inherited variables such as `LLAMA_ARG_CTX_SIZE` would silently override the
    /// arguments above, so the server starts without any `LLAMA_` variable but its key.
    static func environment(
        apiKey: String,
        inheriting inherited: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = inherited.filter { !$0.key.hasPrefix("LLAMA_") }
        environment["LLAMA_API_KEY"] = apiKey
        return environment
    }
}

/// Runs `llama-server` on a random loopback port with a random API key, supervised by a
/// small shell watchdog that stops the server when TypeWhisper exits or crashes.
final class LlamaCppServer: @unchecked Sendable {
    struct Session: Sendable {
        let baseURL: URL
        let apiKey: String
        let modelURL: URL
    }

    private struct State {
        var process: Process?
        var session: Session?
        var outputTail = ""
        var isStopping = false
    }

    private static let startupTimeout: TimeInterval = 300
    private static let shutdownTimeout: TimeInterval = 10
    private static let portBindingAttemptLimit = 3
    private static let outputTailLimit = 12_000
    private static let logger = Logger(subsystem: LlamaCppPlugin.pluginId, category: "llama-server")
    private static let supervisorScript = """
        parent_pid="$1"
        shift
        "$@" &
        child_pid=$!

        terminate_child() {
          trap - TERM INT
          if kill -0 "$child_pid" 2>/dev/null; then
            kill -TERM "$child_pid" 2>/dev/null || true
            attempt=0
            while kill -0 "$child_pid" 2>/dev/null && [ "$attempt" -lt 100 ]; do
              sleep 0.05
              attempt=$((attempt + 1))
            done
            if kill -0 "$child_pid" 2>/dev/null; then
              kill -KILL "$child_pid" 2>/dev/null || true
            fi
          fi
          wait "$child_pid" 2>/dev/null || true
        }

        trap 'terminate_child; exit 143' TERM INT
        while kill -0 "$parent_pid" 2>/dev/null && kill -0 "$child_pid" 2>/dev/null; do
          sleep 0.25
        done

        if ! kill -0 "$parent_pid" 2>/dev/null; then
          terminate_child
          exit 0
        fi

        wait "$child_pid"
        status=$?
        trap - TERM INT
        exit "$status"
        """

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Called on an arbitrary queue when a ready server exits without `stop()`.
    var onUnexpectedExit: (@Sendable (String) -> Void)?

    var session: Session? {
        state.withLock { state in
            guard let process = state.process, process.isRunning else { return nil }
            return state.session
        }
    }

    var outputTail: String {
        state.withLock { $0.outputTail }
    }

    func start(executableURL: URL, options: LlamaCppServerLaunchOptions) async throws {
        for attempt in 1...Self.portBindingAttemptLimit {
            do {
                try await startOnce(executableURL: executableURL, options: options)
                return
            } catch {
                guard attempt < Self.portBindingAttemptLimit, Self.isPortBindingFailure(error) else {
                    throw error
                }
                Self.logger.warning("llama-server port was claimed before startup; retrying with a new port")
            }
        }
    }

    private func startOnce(executableURL: URL, options: LlamaCppServerLaunchOptions) async throws {
        stop()

        let port = try Self.reserveLoopbackPort()
        let apiKey = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let baseURL = URL(string: "http://127.0.0.1:\(port)")!
        let process = Self.makeSupervisedProcess(
            executableURL: executableURL,
            arguments: options.arguments(port: port),
            environment: LlamaCppServerLaunchOptions.environment(apiKey: apiKey)
        )
        process.currentDirectoryURL = executableURL.deletingLastPathComponent()

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.captureOutput(text)
        }
        process.terminationHandler = { [weak self] exitedProcess in
            self?.handleTermination(of: exitedProcess)
        }

        do {
            state.withLock { state in
                state.outputTail = ""
                state.isStopping = false
            }
            try process.run()
            state.withLock { state in
                state.process = process
            }
            try await waitUntilReady(process: process, baseURL: baseURL)
            state.withLock { state in
                state.session = Session(baseURL: baseURL, apiKey: apiKey, modelURL: options.modelURL)
            }
            Self.logger.info("llama-server \(LlamaCppRuntimeRelease.pinned.build, privacy: .public) is ready on loopback")
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            // A newer start may already own the server; only stop the process started here.
            stop(onlyIf: process)
            if process.isRunning {
                process.terminate()
            }
            throw error
        }
    }

    func stop() {
        stop(onlyIf: nil)
    }

    private func stop(onlyIf expectedProcess: Process?) {
        let process = state.withLock { state -> Process? in
            if let expectedProcess, state.process !== expectedProcess {
                return nil
            }
            let process = state.process
            state.process = nil
            state.session = nil
            state.isStopping = true
            return process
        }
        guard let process else { return }
        if let pipe = process.standardOutput as? Pipe {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        guard process.isRunning else { return }

        process.terminate()
        let deadline = Date().addingTimeInterval(Self.shutdownTimeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private func handleTermination(of process: Process) {
        let tail: String? = state.withLock { state in
            guard state.process === process, !state.isStopping else { return nil }
            let wasReady = state.session != nil
            state.process = nil
            state.session = nil
            return wasReady ? state.outputTail : nil
        }
        guard let tail else { return }
        Self.logger.error("llama-server exited unexpectedly with status \(process.terminationStatus)")
        onUnexpectedExit?(tail)
    }

    private func waitUntilReady(process: Process, baseURL: URL) async throws {
        let healthURL = baseURL.appending(path: "health")
        let session = LlamaCppChatClient.makeLoopbackSession()
        defer { session.invalidateAndCancel() }
        let deadline = Date().addingTimeInterval(Self.startupTimeout)
        while Date() < deadline {
            try Task.checkCancellation()
            guard process.isRunning else {
                throw LlamaCppPluginError.serverExited(outputTail)
            }
            var request = URLRequest(url: healthURL)
            request.timeoutInterval = 2
            // 503 while the model loads, 200 once it is ready.
            if let (_, response) = try? await session.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw LlamaCppPluginError.serverStartupTimedOut(outputTail)
    }

    private func captureOutput(_ text: String) {
        state.withLock { state in
            state.outputTail.append(text)
            if state.outputTail.count > Self.outputTailLimit {
                state.outputTail.removeFirst(state.outputTail.count - Self.outputTailLimit)
            }
        }
        for line in text.split(whereSeparator: \.isNewline) {
            Self.logger.debug("\(String(line), privacy: .public)")
        }
    }

    static func isPortBindingFailure(_ error: Error) -> Bool {
        guard case LlamaCppPluginError.serverExited(let output) = error else { return false }
        let normalized = output.lowercased()
        return normalized.contains("address already in use")
            || normalized.contains("couldn't bind")
            || normalized.contains("failed to bind")
    }

    static func makeSupervisedProcess(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        parentProcessIdentifier: pid_t = getpid()
    ) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            supervisorScript,
            "typewhisper-llama-server-supervisor",
            String(parentProcessIdentifier),
            executableURL.path,
        ] + arguments
        process.environment = environment
        return process
    }

    private static func reserveLoopbackPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw LlamaCppPluginError.localPortReservationFailed }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw LlamaCppPluginError.localPortReservationFailed }

        var boundAddress = sockaddr_in()
        var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(descriptor, socketAddress, &boundAddressLength)
            }
        }
        guard nameResult == 0 else { throw LlamaCppPluginError.localPortReservationFailed }
        return UInt16(bigEndian: boundAddress.sin_port)
    }
}

/// OpenAI-style chat completions against the local `llama-server`.
enum LlamaCppChatClient {
    static let maxOutputTokens = 2048
    static let requestTimeout: TimeInterval = 300

    struct Request: Encodable, Equatable, Sendable {
        struct Message: Encodable, Equatable, Sendable {
            let role: String
            let content: String
        }

        let model: String
        let messages: [Message]
        let temperature: Double
        let maxTokens: Int
        let stream = false
        /// Hybrid reasoning templates (Qwen3, Qwen3.5) must not think for text transformations.
        let chatTemplateKwargs = ["enable_thinking": false]

        enum CodingKeys: String, CodingKey {
            case model, messages, temperature, stream
            case maxTokens = "max_tokens"
            case chatTemplateKwargs = "chat_template_kwargs"
        }
    }

    private struct Response: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }

            let message: Message
        }

        let choices: [Choice]
    }

    private struct ErrorResponse: Decodable {
        struct Detail: Decodable {
            let message: String?
            let type: String?
        }

        let error: Detail
    }

    /// Instructions go into the system turn and the text to transform into the user turn.
    /// Small models leak or execute instructions when both share one message.
    static func makeRequest(systemPrompt: String, userText: String, temperature: Double) -> Request {
        Request(
            model: LlamaCppServerLaunchOptions.modelAlias,
            messages: [
                .init(role: "system", content: systemPrompt),
                .init(role: "user", content: userText),
            ],
            temperature: temperature,
            maxTokens: maxOutputTokens
        )
    }

    static func complete(
        _ body: Request,
        session serverSession: LlamaCppServer.Session,
        urlSession: URLSession? = nil
    ) async throws -> String {
        var request = URLRequest(url: serverSession.baseURL.appending(path: "v1/chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(serverSession.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)

        let session = urlSession ?? makeLoopbackSession()
        defer {
            if urlSession == nil { session.finishTasksAndInvalidate() }
        }
        let (data, response) = try await session.data(for: request)
        return try parse(data: data, statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    static func parse(data: Data, statusCode: Int) throws -> String {
        guard statusCode == 200 else {
            let detail = try? JSONDecoder().decode(ErrorResponse.self, from: data).error
            let message = detail?.message ?? String(data: data, encoding: .utf8) ?? ""
            if detail?.type == "exceed_context_size_error"
                || message.lowercased().contains("exceeds the available context size") {
                throw LlamaCppPluginError.inputTooLong
            }
            throw LlamaCppPluginError.serverRequestFailed(statusCode, message)
        }
        guard let content = try JSONDecoder().decode(Response.self, from: data).choices.first?.message.content else {
            throw LlamaCppPluginError.emptyResponse
        }
        return content
    }

    /// Loopback requests never go through a configured proxy.
    static func makeLoopbackSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }
}
