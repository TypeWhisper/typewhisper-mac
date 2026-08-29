import Darwin
import Foundation
import os

struct WebLinkProcessRequest: Sendable, Equatable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let workingDirectory: URL
}

struct WebLinkProcessResult: Sendable, Equatable {
    let exitCode: Int32
    let diagnosticOutput: String
}

enum WebLinkProcessError: LocalizedError {
    case couldNotStart(String)

    var errorDescription: String? {
        switch self {
        case .couldNotStart(let message):
            "Could not start the helper tool: \(message)"
        }
    }
}

protocol WebLinkProcessRunning: Sendable {
    func run(_ request: WebLinkProcessRequest) async throws -> WebLinkProcessResult
}

struct WebLinkProcessRunner: WebLinkProcessRunning, Sendable {
    private static let maximumDiagnosticBytes = 64 * 1024

    func run(_ request: WebLinkProcessRequest) async throws -> WebLinkProcessResult {
        let logURL = request.workingDirectory.appendingPathComponent("process.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle: FileHandle
        do {
            logHandle = try FileHandle(forWritingTo: logURL)
        } catch {
            throw WebLinkProcessError.couldNotStart(error.localizedDescription)
        }

        let process = Process()
        process.executableURL = request.executableURL
        process.arguments = request.arguments
        process.environment = request.environment
        process.currentDirectoryURL = request.workingDirectory
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.standardInput = FileHandle.nullDevice

        let controller = WebLinkProcessController(process: process)
        return try await withTaskCancellationHandler {
            do {
                try process.run()
            } catch {
                try? logHandle.close()
                throw WebLinkProcessError.couldNotStart(error.localizedDescription)
            }

            controller.didLaunch()
            let box = UncheckedProcessBox(process)
            await Task.detached(priority: .utility) {
                box.process.waitUntilExit()
            }.value
            try? logHandle.close()

            guard !Task.isCancelled else {
                throw CancellationError()
            }

            let diagnostics = Self.readDiagnostics(from: logURL)
            return WebLinkProcessResult(
                exitCode: process.terminationStatus,
                diagnosticOutput: diagnostics
            )
        } onCancel: {
            controller.terminate()
        }
    }

    private static func readDiagnostics(from url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(maximumDiagnosticBytes)
            ? size - UInt64(maximumDiagnosticBytes)
            : 0
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class UncheckedProcessBox: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }
}

private final class WebLinkProcessController: @unchecked Sendable {
    private struct State {
        var process: Process?
        var didLaunch = false
        var cancelled = false
    }

    private let state: OSAllocatedUnfairLock<State>

    init(process: Process) {
        state = OSAllocatedUnfairLock(initialState: State(process: process))
    }

    func didLaunch() {
        let shouldTerminate = state.withLock { state in
            state.didLaunch = true
            return state.cancelled
        }
        if shouldTerminate {
            terminate()
        }
    }

    func terminate() {
        let process = state.withLock { state -> Process? in
            state.cancelled = true
            return state.didLaunch ? state.process : nil
        }
        guard let process, process.isRunning else { return }
        process.terminate()
    }
}
