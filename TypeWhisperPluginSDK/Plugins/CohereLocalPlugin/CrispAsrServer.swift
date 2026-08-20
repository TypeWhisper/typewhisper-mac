import Darwin
import Foundation
import TypeWhisperPluginSDK
import os

final class CrispAsrServer: @unchecked Sendable {
    private struct State {
        var process: Process?
        var baseURL: String?
        var apiKey: String?
        var modelId: String?
        var outputTail = ""
    }

    private static let startupTimeout: TimeInterval = 300
    private static let shutdownTimeout: TimeInterval = 10
    private static let portBindingAttemptLimit = 3
    private static let logger = Logger(
        subsystem: CohereLocalPlugin.pluginId,
        category: "CrispASR"
    )
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

    var isRunning: Bool {
        state.withLock { state in
            state.process.map { !$0.isRunning ? false : true } == true
                && state.baseURL != nil
        }
    }

    func start(assets: CohereLocalModelAssets) async throws {
        for attempt in 1...Self.portBindingAttemptLimit {
            do {
                try await startOnce(assets: assets)
                return
            } catch {
                guard attempt < Self.portBindingAttemptLimit,
                      Self.isPortBindingFailure(error) else {
                    throw error
                }
                Self.logger.warning(
                    "CrispASR loopback port was claimed before startup; retrying with a new port"
                )
            }
        }
    }

    private func startOnce(assets: CohereLocalModelAssets) async throws {
        stop()

        let port = try Self.reserveLoopbackPort()
        let apiKey = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let baseURL = "http://127.0.0.1:\(port)"
        let runtimeArguments = [
            "--server",
            "--backend", "cohere",
            "--model", assets.modelFileURL.path,
            "--host", "127.0.0.1",
            "--port", String(port),
            "--language", "en",
            "--vad",
            "--vad-model", assets.vadModelURL.path,
            "--strict-pipeline",
            "--require-vad",
            "--threads", String(Self.recommendedThreadCount),
            "--gpu-backend", "metal",
        ]

        var environment = ProcessInfo.processInfo.environment
        environment["CRISPASR_API_KEYS"] = apiKey
        environment["CRISPASR_CACHE_DIR"] = assets.cacheDirectory.path
        let process = Self.makeSupervisedProcess(
            executableURL: assets.runtimeExecutableURL,
            arguments: runtimeArguments,
            currentDirectoryURL: assets.runtimeDirectory,
            environment: environment
        )

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.captureOutput(text)
        }

        do {
            try FileManager.default.createDirectory(
                at: assets.cacheDirectory,
                withIntermediateDirectories: true
            )
            try process.run()
            state.withLock { state in
                state.process = process
                state.baseURL = baseURL
                state.apiKey = apiKey
                state.modelId = assets.model.id
                state.outputTail = ""
            }
            try await waitUntilReady(
                process: process,
                baseURL: baseURL
            )
            Self.logger.info(
                "CrispASR \(CohereLocalModelAssets.crispAsrVersion, privacy: .public) is ready on loopback with Metal"
            )
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            stop()
            throw error
        }
    }

    static func isPortBindingFailure(_ error: Error) -> Bool {
        guard case CohereLocalPluginError.runtimeExited(let output) = error else {
            return false
        }
        let normalized = output.lowercased()
        return normalized.contains("address already in use")
            || normalized.contains("failed to bind")
            || normalized.contains("bind() failed")
    }

    func transcribe(
        audio: AudioData,
        language: String
    ) async throws -> PluginTranscriptionResult {
        let context = state.withLock { state in
            (
                process: state.process,
                baseURL: state.baseURL,
                apiKey: state.apiKey,
                modelId: state.modelId
            )
        }
        guard let process = context.process,
              process.isRunning,
              let baseURL = context.baseURL,
              let apiKey = context.apiKey,
              let modelId = context.modelId else {
            throw CohereLocalPluginError.modelNotLoaded
        }

        let helper = PluginOpenAITranscriptionHelper(
            baseURL: baseURL,
            responseFormat: "verbose_json"
        )
        return try await helper.transcribe(
            audio: audio,
            apiKey: apiKey,
            modelName: modelId,
            language: language,
            translate: false,
            prompt: nil,
            requestTimeout: 600
        )
    }

    func stop() {
        let process = state.withLock { state -> Process? in
            let process = state.process
            state.process = nil
            state.baseURL = nil
            state.apiKey = nil
            state.modelId = nil
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

    private func waitUntilReady(
        process: Process,
        baseURL: String
    ) async throws {
        try PluginHTTPClient.ensureNetworkAccessIsAllowed()
        guard let healthURL = URL(string: "\(baseURL)/health") else {
            throw CohereLocalPluginError.invalidLocalServerURL
        }

        let deadline = Date().addingTimeInterval(Self.startupTimeout)
        while Date() < deadline {
            try Task.checkCancellation()
            guard process.isRunning else {
                throw CohereLocalPluginError.runtimeExited(outputTail)
            }

            var request = URLRequest(url: healthURL)
            request.timeoutInterval = 2
            if let (_, response) = try? await URLSession.shared.data(for: request),
               let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 200 {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CohereLocalPluginError.runtimeStartupTimedOut(outputTail)
    }

    private var outputTail: String {
        state.withLock { $0.outputTail }
    }

    private func captureOutput(_ text: String) {
        state.withLock { state in
            state.outputTail.append(text)
            if state.outputTail.count > 12_000 {
                state.outputTail.removeFirst(state.outputTail.count - 12_000)
            }
        }
        for line in text.split(whereSeparator: \.isNewline) {
            Self.logger.debug("\(String(line), privacy: .public)")
        }
    }

    private static var recommendedThreadCount: Int {
        max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
    }

    static func makeSupervisedProcess(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL?,
        environment: [String: String],
        parentProcessIdentifier: pid_t = getpid()
    ) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.currentDirectoryURL = currentDirectoryURL
        process.arguments = [
            "-c",
            supervisorScript,
            "typewhisper-crispasr-supervisor",
            String(parentProcessIdentifier),
            executableURL.path,
        ] + arguments
        process.environment = environment
        return process
    }

    private static func reserveLoopbackPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw CohereLocalPluginError.localPortReservationFailed
        }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(
                    descriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindResult == 0 else {
            throw CohereLocalPluginError.localPortReservationFailed
        }

        var boundAddress = sockaddr_in()
        var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(descriptor, socketAddress, &boundAddressLength)
            }
        }
        guard nameResult == 0 else {
            throw CohereLocalPluginError.localPortReservationFailed
        }
        return UInt16(bigEndian: boundAddress.sin_port)
    }
}
