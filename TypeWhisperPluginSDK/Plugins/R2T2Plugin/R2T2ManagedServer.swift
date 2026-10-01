import CryptoKit
import Darwin
import Foundation
import os
import TypeWhisperPluginSDK

// MARK: - Pinned Assets

/// A Confucius4-R2T2 GGUF pinned to a Hugging Face revision and checksum.
struct R2T2ModelDefinition: Sendable, Equatable, Identifiable {
    let id: String
    let displayName: String
    let repositoryId: String
    let revision: String
    let fileName: String
    let fileSize: Int64
    let sha256: String

    /// License files shipped next to the weights; the NetEase Youdao license requires keeping them with every copy.
    static let licenseFileNames = ["LICENSE", "LICENSE_zh", "NOTICE"]

    var repositoryURL: URL { URL(string: "https://huggingface.co/\(repositoryId)")! }

    func fileURL(_ name: String) -> URL {
        URL(string: "https://huggingface.co/\(repositoryId)/resolve/\(revision)/\(name)")!
    }

    static let q4km = R2T2ModelDefinition(
        id: "r2t2-q4_k_m",
        displayName: "Q4_K_M",
        repositoryId: "Nairod785/Confucius4-R2T2-Q4_K_M-GGUF",
        revision: "b1ea19256fb77a8d8ab7b091dc75378e15952605",
        fileName: "r2t2-q4_k_m.gguf",
        fileSize: 1_186_939_968,
        sha256: "d740d6636f2ea2f3736800c3c88a6e22ecb6c0f26c567fe22b0572ae9c2c4ec8"
    )
    static let q8 = R2T2ModelDefinition(
        id: "r2t2-q8_0",
        displayName: "Q8_0",
        repositoryId: "davidxifeng/Confucius4-R2T2-gguf",
        revision: "a8e6b385d7df7eae9519363e07034a209004797a",
        fileName: "r2t2-q8_0.gguf",
        fileSize: 2_477_512_064,
        sha256: "19f5ccd624484bcb5d44301437de41560b0ecc40c430e8850dfeefefbe82ccf5"
    )
    static let f16 = R2T2ModelDefinition(
        id: "r2t2-f16",
        displayName: "F16",
        repositoryId: "davidxifeng/Confucius4-R2T2-gguf",
        revision: "a8e6b385d7df7eae9519363e07034a209004797a",
        fileName: "r2t2-f16.gguf",
        fileSize: 4_092_155_264,
        sha256: "d1b531ceaf5640d98352d3a9180238d99d36d393e160afd4692031077e7bae2c"
    )

    static let all = [q4km, q8, f16]
    static let recommended = q8

    static func model(for id: String?) -> R2T2ModelDefinition? {
        all.first { $0.id == id }
    }
}

/// The audio.cpp release whose `audiocpp_server` runs the managed server.
enum R2T2Runtime {
    static let version = "v0.9.0"
    static let archiveName = "audio-v0.9.0-bin-macos-arm64-metal.tar.gz"
    static let archiveSize = Int64(29_162_796)
    static let archiveSHA256 = "7cea9219d5f06475011c5d225d71d988cecef633ff7d098ee8a4c7b08583b1b4"
    static let archiveURL = URL(string: "https://github.com/0xShug0/audio.cpp/releases/download/\(version)/\(archiveName)")!
    static let releaseURL = URL(string: "https://github.com/0xShug0/audio.cpp/releases/tag/\(version)")!
}

enum R2T2ManagedError: LocalizedError {
    case unsupportedArchitecture
    case httpStatus(Int, String)
    case verificationFailed(String)
    case insufficientDiskSpace(needed: Int64, available: Int64)
    case extractionFailed(String)
    case serverExited(String)
    case serverStartupTimedOut(String)
    case portReservationFailed
    case modelNotInstalled

    var errorDescription: String? {
        switch self {
        case .unsupportedArchitecture:
            return "The built-in server needs a Mac with Apple silicon."
        case .httpStatus(let status, let name):
            return "Downloading \(name) failed with HTTP \(status)."
        case .verificationFailed(let name):
            return "\(name) did not match its expected size or checksum and was removed."
        case .insufficientDiskSpace(let needed, let available):
            let format = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            return "Not enough disk space: \(format(needed)) needed, \(format(available)) available."
        case .extractionFailed(let message):
            return "Unpacking audio.cpp failed: \(message)"
        case .serverExited(let output):
            return "audiocpp_server exited during startup. \(output.suffix(400))"
        case .serverStartupTimedOut(let output):
            return "audiocpp_server did not become ready. \(output.suffix(400))"
        case .portReservationFailed:
            return "Could not reserve a loopback port for audiocpp_server."
        case .modelNotInstalled:
            return "Download a model in the Confucius4-R2T2 settings first."
        }
    }
}

// MARK: - Installation

/// On-disk layout under the plugin data directory:
/// `Runtime/audio.cpp-v0.9.0/audiocpp_server` and `Models/<model id>/<gguf + license files>`.
struct R2T2ManagedAssets: Sendable {
    let pluginDataDirectory: URL

    var runtimeDirectory: URL {
        pluginDataDirectory.appendingPathComponent("Runtime/audio.cpp-\(R2T2Runtime.version)", isDirectory: true)
    }
    var serverExecutableURL: URL { runtimeDirectory.appendingPathComponent("audiocpp_server") }
    var serverConfigURL: URL { pluginDataDirectory.appendingPathComponent("server.json") }

    func modelDirectory(_ model: R2T2ModelDefinition) -> URL {
        pluginDataDirectory.appendingPathComponent("Models/\(model.id)", isDirectory: true)
    }

    func modelFileURL(_ model: R2T2ModelDefinition) -> URL {
        modelDirectory(model).appendingPathComponent(model.fileName)
    }

    var isRuntimeInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: serverExecutableURL.path)
    }

    /// Size check only; the checksum is verified once, right after the download.
    func isModelInstalled(_ model: R2T2ModelDefinition) -> Bool {
        Self.fileSize(modelFileURL(model)) == model.fileSize
            && R2T2ModelDefinition.licenseFileNames.allSatisfy {
                Self.fileSize(modelDirectory(model).appendingPathComponent($0)) > 0
            }
    }

    /// Downloads whatever is missing for `model`: the audio.cpp runtime, the license files and the GGUF.
    func install(_ model: R2T2ModelDefinition, progress: @Sendable @escaping (Double) -> Void) async throws {
        #if arch(arm64)
        try await installAssets(model, progress: progress)
        #else
        throw R2T2ManagedError.unsupportedArchitecture
        #endif
    }

    private func installAssets(_ model: R2T2ModelDefinition, progress: @Sendable @escaping (Double) -> Void) async throws {
        try PluginHTTPClient.ensureNetworkAccessIsAllowed()
        let fileManager = FileManager.default
        let directory = modelDirectory(model)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let needsRuntime = !isRuntimeInstalled
        let needsModel = Self.fileSize(modelFileURL(model)) != model.fileSize
        // URLSession stages downloads in the temporary directory on the same volume before they are moved.
        let needed = (needsModel ? model.fileSize : 0) + (needsRuntime ? R2T2Runtime.archiveSize * 5 : 0)
        let available = Self.availableCapacity(at: pluginDataDirectory)
        if needed > 0, available < needed {
            throw R2T2ManagedError.insufficientDiskSpace(needed: needed, available: available)
        }

        if needsRuntime {
            try await installRuntime()
        }
        for name in R2T2ModelDefinition.licenseFileNames {
            let destination = directory.appendingPathComponent(name)
            if Self.fileSize(destination) == 0 {
                try await R2T2Download.file(from: model.fileURL(name), to: destination, name: name)
            }
        }
        progress(0.01)
        if needsModel {
            // Verified at a staging path first: isModelInstalled checks only the size of the final file.
            let staged = modelFileURL(model).appendingPathExtension("partial")
            defer { try? fileManager.removeItem(at: staged) }
            try await R2T2Download.file(from: model.fileURL(model.fileName), to: staged, name: model.fileName) { fraction in
                progress(0.01 + fraction * 0.98)
            }
            try Self.verify(staged, size: model.fileSize, sha256: model.sha256)
            try Task.checkCancellation()
            try? fileManager.removeItem(at: modelFileURL(model))
            try fileManager.moveItem(at: staged, to: modelFileURL(model))
        }
        progress(1)
    }

    func deleteModel(_ model: R2T2ModelDefinition) throws {
        let directory = modelDirectory(model)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func installRuntime() async throws {
        let fileManager = FileManager.default
        let staging = pluginDataDirectory.appendingPathComponent("Runtime/.staging-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let archive = staging.appendingPathComponent(R2T2Runtime.archiveName)
        try await R2T2Download.file(from: R2T2Runtime.archiveURL, to: archive, name: R2T2Runtime.archiveName)
        try Self.verify(archive, size: R2T2Runtime.archiveSize, sha256: R2T2Runtime.archiveSHA256)

        let extracted = staging.appendingPathComponent("audio.cpp", isDirectory: true)
        try fileManager.createDirectory(at: extracted, withIntermediateDirectories: true)
        try await Self.untar(archive, into: extracted)
        let server = extracted.appendingPathComponent("audiocpp_server")
        guard Self.fileSize(server) > 0 else {
            throw R2T2ManagedError.extractionFailed("audiocpp_server is missing from \(R2T2Runtime.archiveName)")
        }
        // The release archive ships its binaries without the executable bit.
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path)

        if fileManager.fileExists(atPath: runtimeDirectory.path) {
            try fileManager.removeItem(at: runtimeDirectory)
        }
        try fileManager.moveItem(at: extracted, to: runtimeDirectory)
        // Runtimes pinned by earlier plugin versions are no longer used.
        let runtimes = runtimeDirectory.deletingLastPathComponent()
        for entry in (try? fileManager.contentsOfDirectory(at: runtimes, includingPropertiesForKeys: nil)) ?? []
        where entry.lastPathComponent.hasPrefix("audio.cpp-") && entry.lastPathComponent != runtimeDirectory.lastPathComponent {
            try? fileManager.removeItem(at: entry)
        }
    }

    private static func untar(_ archive: URL, into directory: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xzf", archive.path, "-C", directory.path]
            let errorPipe = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errorPipe
            process.terminationHandler = { process in
                let message = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: R2T2ManagedError.extractionFailed(message))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Throws CancellationError when the calling task is cancelled while hashing.
    static func verify(_ file: URL, size: Int64, sha256 expected: String) throws {
        guard fileSize(file) == size, try sha256(of: file) == expected else {
            throw R2T2ManagedError.verificationFailed(file.lastPathComponent)
        }
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 4 << 20), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func availableCapacity(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? Int64.max
    }
}

// MARK: - Download

/// Downloads one URL to a destination with byte progress. The file is moved into place only after
/// a 200 response, so an interrupted download never leaves a partial file at `destination`.
private final class R2T2Download: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let name: String
    private let progress: (@Sendable (Double) -> Void)?
    /// Written only on the session's serial delegate queue.
    private var result: Result<Void, Error>?
    /// The waiting caller and the task's outcome, whichever arrives first waits for the other.
    private let pending = OSAllocatedUnfairLock<(continuation: CheckedContinuation<Void, Error>?, outcome: Result<Void, Error>?)>(
        initialState: (nil, nil)
    )

    private init(destination: URL, name: String, progress: (@Sendable (Double) -> Void)?) {
        self.destination = destination
        self.name = name
        self.progress = progress
    }

    static func file(from url: URL, to destination: URL, name: String, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let download = R2T2Download(destination: destination, name: name, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: download, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // The task may already have completed (cancelled before it started), or the caller may be
                // cancelled before the continuation is stored; resume at once in both cases.
                let outcome = download.pending.withLock { pending -> Result<Void, Error>? in
                    if let outcome = pending.outcome { return outcome }
                    if Task.isCancelled { return .failure(CancellationError()) }
                    pending.continuation = continuation
                    return nil
                }
                if let outcome {
                    task.cancel()
                    continuation.resume(with: outcome)
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            result = .failure(R2T2ManagedError.httpStatus(status, name))
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            result = .success(())
        } catch {
            result = .failure(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let outcome: Result<Void, Error> = error.map { .failure($0) } ?? result ?? .failure(R2T2ManagedError.httpStatus(0, name))
        let continuation = pending.withLock { pending -> CheckedContinuation<Void, Error>? in
            pending.outcome = outcome
            defer { pending.continuation = nil }
            return pending.continuation
        }
        continuation?.resume(with: outcome)
    }
}

// MARK: - Server Process

/// Released once, explicitly or when the holder goes away.
final class R2T2ServerLease: @unchecked Sendable {
    private let released = OSAllocatedUnfairLock(initialState: false)
    private let onRelease: @Sendable () -> Void

    init(onRelease: @escaping @Sendable () -> Void) {
        self.onRelease = onRelease
    }

    func release() {
        if !released.withLock({ let was = $0; $0 = true; return was }) { onRelease() }
    }

    deinit {
        release()
    }
}

/// Runs `audiocpp_server` on a random loopback port for the selected model and restarts it when it
/// exits unexpectedly, so a crash never leaves TypeWhisper without its engine.
final class R2T2ManagedServer: @unchecked Sendable {
    static let modelId = "r2t2"

    private struct State {
        var process: Process?
        var baseURL: URL?
        var model: R2T2ModelDefinition?
        var outputTail = ""
        var isReady = false
        var recentExits: [Date] = []
        var starting: (model: R2T2ModelDefinition, task: Task<URL, Error>)?
        /// Bumped by stop(); starts and crash restarts from an older generation do not launch a server.
        var generation = 0
        /// Connections using the current server; a start for another model waits until they end.
        var leases = 0
    }

    private static let logger = Logger(subsystem: "com.scriptease.r2t2", category: "Server")
    private static let startupTimeout: TimeInterval = 60
    /// The supervisor escalates to SIGKILL for the server after about 6 seconds.
    private static let shutdownTimeout: TimeInterval = 10
    private static let maxRestartsPerMinute = 3
    /// Keeps the server a child of TypeWhisper: it is stopped when TypeWhisper exits, even on a crash,
    /// and is killed if it ignores SIGTERM for 5 seconds.
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
        """

    private let assets: R2T2ManagedAssets
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Called on every start, stop and crash so the settings view can refresh.
    var onStatusChange: (@Sendable () -> Void)?
    /// The model a crash restart should use, which may differ from the one that crashed.
    var selectedModel: (@Sendable () -> R2T2ModelDefinition?)?

    init(assets: R2T2ManagedAssets) {
        self.assets = assets
    }

    var baseURL: URL? {
        state.withLock { $0.process?.isRunning == true ? $0.baseURL : nil }
    }

    var runningModel: R2T2ModelDefinition? {
        state.withLock { $0.process?.isRunning == true ? $0.model : nil }
    }

    /// Returns the URL of a ready server for `model`, starting or restarting it when needed.
    /// Returns a ready server for `model` together with a lease that keeps it from being replaced
    /// by a start for another model until the lease is released.
    func acquire(model: R2T2ModelDefinition) async throws -> (URL, R2T2ServerLease) {
        while true {
            let url = try await ensureRunning(model: model)
            let lease = state.withLock { state -> R2T2ServerLease? in
                guard state.isReady, state.process?.isRunning == true, state.baseURL == url else { return nil }
                state.leases += 1
                return R2T2ServerLease(onRelease: { [weak self] in self?.state.withLock { $0.leases -= 1 } })
            }
            if let lease { return (url, lease) }
            try Task.checkCancellation()
        }
    }

    /// Concurrent callers for the same model share one start; a start for another model waits for it.
    /// With `expectedGeneration`, nothing starts once stop() has moved past that generation.
    func ensureRunning(model: R2T2ModelDefinition, expectedGeneration: Int? = nil) async throws -> URL {
        enum Decision { case ready(URL), wait(Task<URL, Error>), stopped }
        let decision = state.withLock { state -> Decision in
            if let expectedGeneration, state.generation != expectedGeneration {
                return .stopped
            }
            if state.isReady, state.process?.isRunning == true, state.model == model, let url = state.baseURL {
                return .ready(url)
            }
            if let starting = state.starting, starting.model == model {
                return .wait(starting.task)
            }
            let previous = state.starting?.task
            let generation = state.generation
            let task = Task {
                _ = try? await previous?.value
                do {
                    return try await self.start(model: model, generation: generation)
                } catch R2T2ManagedError.serverExited(let output) where output.contains("could not bind") {
                    // Another process took the reserved port before the server bound it; try a new one.
                    return try await self.start(model: model, generation: generation)
                }
            }
            state.starting = (model, task)
            return .wait(task)
        }
        switch decision {
        case .stopped:
            throw CancellationError()
        case .ready(let url):
            return url
        case .wait(let task):
            defer { state.withLock { if $0.starting?.task == task { $0.starting = nil } } }
            return try await task.value
        }
    }

    /// Stops the server, an in-flight start and a pending crash restart, without blocking the caller,
    /// which may be the main thread.
    func stop() {
        let starting = state.withLock { state -> Task<URL, Error>? in
            state.generation += 1
            defer { state.starting = nil }
            return state.starting?.task
        }
        starting?.cancel()
        terminate(detachProcess())
    }

    private func terminate(_ process: Process?) {
        guard let process else { return }
        process.terminate()
        escalateInBackground(process)
        onStatusChange?()
    }

    /// SIGKILLs the supervisor only after the full deadline, so it can first escalate for its child.
    private func escalateInBackground(_ process: Process) {
        DispatchQueue.global(qos: .utility).async {
            let deadline = Date().addingTimeInterval(Self.shutdownTimeout)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    /// Stops the server and waits for it to exit, so the next one does not compete for its memory.
    private func stopAndWait() async {
        guard let process = detachProcess() else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(Self.shutdownTimeout)
        while process.isRunning, Date() < deadline {
            if Task.isCancelled {
                // A cancelled start no longer needs to wait, but the supervisor still gets its full deadline.
                escalateInBackground(process)
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        onStatusChange?()
    }

    private func detachProcess() -> Process? {
        let process = state.withLock { state -> Process? in
            let process = state.process
            state.process = nil
            state.baseURL = nil
            state.model = nil
            state.isReady = false
            return process
        }
        return process?.isRunning == true ? process : nil
    }

    private func start(model: R2T2ModelDefinition, generation: Int) async throws -> URL {
        guard assets.isRuntimeInstalled, assets.isModelInstalled(model) else {
            throw R2T2ManagedError.modelNotInstalled
        }
        // Let dictations on the running server finish before it is replaced.
        while state.withLock({ $0.leases > 0 && $0.process?.isRunning == true }) {
            try await Task.sleep(for: .milliseconds(100))
        }
        await stopAndWait()
        let port = try Self.reserveLoopbackPort()
        let config: [String: Any] = [
            "host": "127.0.0.1",
            "port": Int(port),
            "backend": "metal",
            "lazy_load": true,
            "idle_unload_ms": 1_800_000,
            "models": [[
                "id": Self.modelId,
                "family": "confucius4_r2t2",
                "path": assets.modelFileURL(model).path,
                "task": "asr",
                "mode": "streaming",
                "session_options": ["confucius4_r2t2.chunk_size_ms": "320"],
            ]],
        ]
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            .write(to: assets.serverConfigURL, options: .atomic)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.currentDirectoryURL = assets.runtimeDirectory
        process.arguments = ["-c", Self.supervisorScript, "r2t2-supervisor", String(getpid()),
                             assets.serverExecutableURL.path, "--config", assets.serverConfigURL.path, "--no-ui"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.state.withLock { state in
                state.outputTail.append(String(decoding: data, as: UTF8.self))
                if state.outputTail.count > 8_000 { state.outputTail.removeFirst(state.outputTail.count - 8_000) }
            }
        }
        process.terminationHandler = { [weak self] process in
            output.fileHandleForReading.readabilityHandler = nil
            self?.handleExit(of: process)
        }

        let baseURL = URL(string: "http://127.0.0.1:\(port)")!
        // Publishing and launching under the lock means a concurrent stop() either prevents the
        // launch or finds the process and terminates it.
        try state.withLock { state in
            guard state.generation == generation, !Task.isCancelled else { throw CancellationError() }
            try process.run()
            state.process = process
            state.baseURL = baseURL
            state.model = model
            state.outputTail = ""
            state.isReady = false
        }
        do {
            try await waitUntilReady(process: process, baseURL: baseURL)
        } catch {
            // Clean up only this start's process; a later start may already own the state.
            if state.withLock({ $0.process === process }) { terminate(detachProcess()) }
            throw error
        }
        state.withLock { $0.isReady = true }
        Self.logger.info("audiocpp_server \(R2T2Runtime.version, privacy: .public) ready on port \(port) with \(model.fileName, privacy: .public)")
        onStatusChange?()
        return baseURL
    }

    private func handleExit(of process: Process) {
        let restart = state.withLock { state -> (model: R2T2ModelDefinition, generation: Int)? in
            // stop() clears state.process first, so only unexpected exits get here with a match.
            // A failed startup is reported by start() instead of being retried.
            guard state.process === process, state.isReady, let model = state.model else { return nil }
            state.process = nil
            state.baseURL = nil
            state.isReady = false
            let now = Date()
            state.recentExits = state.recentExits.filter { now.timeIntervalSince($0) < 60 } + [now]
            return state.recentExits.count <= Self.maxRestartsPerMinute ? (model, state.generation) : nil
        }
        onStatusChange?()
        guard let restart else { return }
        Self.logger.warning("audiocpp_server exited with status \(process.terminationStatus); restarting")
        Task {
            try? await Task.sleep(for: .seconds(1))
            // Skipped when stop() was called in the meantime; checked inside ensureRunning's decision lock.
            _ = try? await ensureRunning(model: selectedModel?() ?? restart.model, expectedGeneration: restart.generation)
        }
    }

    private func waitUntilReady(process: Process, baseURL: URL) async throws {
        let health = baseURL.appendingPathComponent("health")
        let deadline = Date().addingTimeInterval(Self.startupTimeout)
        while Date() < deadline {
            try Task.checkCancellation()
            guard process.isRunning else {
                throw R2T2ManagedError.serverExited(state.withLock { $0.outputTail })
            }
            var request = URLRequest(url: health)
            request.timeoutInterval = 1
            if let (_, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw R2T2ManagedError.serverStartupTimedOut(state.withLock { $0.outputTail })
    }

    private static func reserveLoopbackPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw R2T2ManagedError.portReservationFailed }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, length) == 0 && getsockname(descriptor, $0, &length) == 0
            }
        }
        guard bound else { throw R2T2ManagedError.portReservationFailed }
        return UInt16(bigEndian: address.sin_port)
    }
}
