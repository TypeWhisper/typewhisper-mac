import Darwin
import Dispatch
import Foundation
import os

struct CLIProcessRequest: Sendable {
    var executableURL: URL
    var arguments: [String]
    var environment: [String: String]
    var workingDirectory: URL
    var standardInput: Data
    var timeout: TimeInterval
    var standardOutputLimit: Int
    var standardErrorLimit: Int
}

struct CLIProcessResult: Sendable, Equatable {
    let exitCode: Int32
    let standardOutput: Data
    let standardError: Data
}

enum CLIProcessError: LocalizedError, Equatable {
    case couldNotStart(String)
    case timedOut
    case cancelled
    case standardOutputTooLarge
    case standardErrorTooLarge
    case inputWriteFailed(String)
    case outputReadFailed(String)
    case waitFailed(String)

    var errorDescription: String? {
        switch self {
        case .couldNotStart(let message): "Could not start the CLI: \(message)"
        case .timedOut: "The CLI request timed out."
        case .cancelled: "The CLI request was cancelled."
        case .standardOutputTooLarge: "The CLI wrote too much standard output."
        case .standardErrorTooLarge: "The CLI wrote too much standard error."
        case .inputWriteFailed(let message): "Could not write CLI input: \(message)"
        case .outputReadFailed(let message): "Could not read CLI output: \(message)"
        case .waitFailed(let message): "Could not wait for the CLI: \(message)"
        }
    }
}

protocol CLIProcessRunning: Sendable {
    func run(_ request: CLIProcessRequest) async throws -> CLIProcessResult
}

struct CLIJSONRPCExchangeRequest: Sendable {
    var process: CLIProcessRequest
    var initializeRequest: Data
    var initializedNotification: Data
    var request: Data
    var initializeResponseID: Int
    var responseID: Int
}

protocol CLIJSONRPCProcessRunning: Sendable {
    func exchange(_ request: CLIJSONRPCExchangeRequest) async throws -> Data
}

struct CLIProcessRunner: CLIProcessRunning, CLIJSONRPCProcessRunning, Sendable {
    private static let blockingQueue = DispatchQueue(
        label: "com.typewhisper.authenticated-cli.process-io",
        qos: .utility,
        attributes: .concurrent
    )

    private enum Event: Sendable {
        case inputFinished
        case standardOutput(Data)
        case standardError(Data)
        case exited(Int32)
        case timedOut
    }

    private enum JSONRPCEvent: Sendable {
        case response(Data)
        case standardError(Data)
        case exited(Int32)
        case timedOut
    }

    func run(_ request: CLIProcessRequest) async throws -> CLIProcessResult {
        guard request.timeout > 0,
              request.standardOutputLimit >= 0,
              request.standardErrorLimit >= 0
        else {
            throw CLIProcessError.couldNotStart("Invalid process limits.")
        }

        let controller = CLIProcessController()
        return try await withTaskCancellationHandler {
            let process = try spawn(request)
            controller.install(processIdentifier: process.processIdentifier)

            do {
                return try await withThrowingTaskGroup(of: Event.self) { group in
                    group.addTask {
                        try await Self.runBlocking {
                            try Self.write(request.standardInput, to: process.standardInput)
                            return .inputFinished
                        }
                    }
                    group.addTask {
                        try await Self.runBlocking {
                            .standardOutput(try Self.read(
                                from: process.standardOutput,
                                limit: request.standardOutputLimit,
                                limitError: .standardOutputTooLarge
                            ))
                        }
                    }
                    group.addTask {
                        try await Self.runBlocking {
                            .standardError(try Self.read(
                                from: process.standardError,
                                limit: request.standardErrorLimit,
                                limitError: .standardErrorTooLarge
                            ))
                        }
                    }
                    group.addTask {
                        try await Self.runBlocking {
                            let exitCode = try Self.wait(for: process.processIdentifier)
                            controller.markReaped()
                            return .exited(exitCode)
                        }
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(request.timeout))
                        return .timedOut
                    }

                    var inputFinished = false
                    var standardOutput: Data?
                    var standardError: Data?
                    var exitCode: Int32?

                    do {
                        while let event = try await group.next() {
                            try Task.checkCancellation()
                            switch event {
                            case .inputFinished:
                                inputFinished = true
                            case .standardOutput(let data):
                                standardOutput = data
                            case .standardError(let data):
                                standardError = data
                            case .exited(let code):
                                exitCode = code
                            case .timedOut:
                                controller.terminateProcessGroup()
                                group.cancelAll()
                                throw CLIProcessError.timedOut
                            }

                            if inputFinished,
                               let standardOutput,
                               let standardError,
                               let exitCode {
                                group.cancelAll()
                                return CLIProcessResult(
                                    exitCode: exitCode,
                                    standardOutput: standardOutput,
                                    standardError: standardError
                                )
                            }
                        }
                    } catch {
                        controller.terminateProcessGroup()
                        group.cancelAll()
                        throw error
                    }
                    throw CLIProcessError.waitFailed("Process event stream ended unexpectedly.")
                }
            } catch is CancellationError {
                controller.terminateProcessGroup()
                throw CLIProcessError.cancelled
            } catch {
                controller.terminateProcessGroup()
                throw error
            }
        } onCancel: {
            controller.terminateProcessGroup()
        }
    }

    func exchange(_ request: CLIJSONRPCExchangeRequest) async throws -> Data {
        let processRequest = request.process
        guard processRequest.timeout > 0,
              processRequest.standardOutputLimit >= 0,
              processRequest.standardErrorLimit >= 0
        else {
            throw CLIProcessError.couldNotStart("Invalid process limits.")
        }

        let controller = CLIProcessController()
        return try await withTaskCancellationHandler {
            let process = try spawn(processRequest)
            controller.install(processIdentifier: process.processIdentifier)

            do {
                return try await withThrowingTaskGroup(of: JSONRPCEvent.self) { group in
                    group.addTask {
                        try await Self.runBlocking {
                            .response(try Self.exchangeJSONRPC(request, with: process))
                        }
                    }
                    group.addTask {
                        try await Self.runBlocking {
                            .standardError(try Self.read(
                                from: process.standardError,
                                limit: processRequest.standardErrorLimit,
                                limitError: .standardErrorTooLarge
                            ))
                        }
                    }
                    group.addTask {
                        try await Self.runBlocking {
                            let exitCode = try Self.wait(for: process.processIdentifier)
                            controller.markReaped()
                            return .exited(exitCode)
                        }
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(processRequest.timeout))
                        return .timedOut
                    }

                    var response: Data?
                    var standardError: Data?
                    var exitCode: Int32?

                    do {
                        while let event = try await group.next() {
                            try Task.checkCancellation()
                            switch event {
                            case .response(let data):
                                response = data
                                controller.terminateProcessGroup()
                            case .standardError(let data):
                                standardError = data
                            case .exited(let code):
                                exitCode = code
                            case .timedOut:
                                controller.terminateProcessGroup()
                                group.cancelAll()
                                throw CLIProcessError.timedOut
                            }

                            if let response, standardError != nil, exitCode != nil {
                                group.cancelAll()
                                return response
                            }
                        }
                    } catch {
                        controller.terminateProcessGroup()
                        group.cancelAll()
                        throw error
                    }
                    throw CLIProcessError.waitFailed("JSON-RPC process event stream ended unexpectedly.")
                }
            } catch is CancellationError {
                controller.terminateProcessGroup()
                throw CLIProcessError.cancelled
            } catch {
                controller.terminateProcessGroup()
                throw error
            }
        } onCancel: {
            controller.terminateProcessGroup()
        }
    }

    private struct SpawnedProcess: Sendable {
        let processIdentifier: pid_t
        let standardInput: Int32
        let standardOutput: Int32
        let standardError: Int32
    }

    private func spawn(_ request: CLIProcessRequest) throws -> SpawnedProcess {
        var standardInput = try Self.makePipe()
        var standardOutput = try Self.makePipe()
        var standardError = try Self.makePipe()
        var parentDescriptorsTransferred = false
        defer {
            if !parentDescriptorsTransferred {
                Self.closePipe(&standardInput)
                Self.closePipe(&standardOutput)
                Self.closePipe(&standardError)
            }
        }

        var actions: posix_spawn_file_actions_t? = nil
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw CLIProcessError.couldNotStart("Could not initialize spawn file actions.")
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
        }

        var attributes: posix_spawnattr_t? = nil
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw CLIProcessError.couldNotStart("Could not initialize spawn attributes.")
        }
        defer {
            posix_spawnattr_destroy(&attributes)
        }

        try Self.addFileAction(posix_spawn_file_actions_adddup2(&actions, standardInput.read, STDIN_FILENO))
        try Self.addFileAction(posix_spawn_file_actions_adddup2(&actions, standardOutput.write, STDOUT_FILENO))
        try Self.addFileAction(posix_spawn_file_actions_adddup2(&actions, standardError.write, STDERR_FILENO))
        for descriptor in [
            standardInput.read, standardInput.write,
            standardOutput.read, standardOutput.write,
            standardError.read, standardError.write,
        ] where descriptor > STDERR_FILENO {
            try Self.addFileAction(posix_spawn_file_actions_addclose(&actions, descriptor))
        }

        let changeDirectoryResult = request.workingDirectory.path.withCString { path in
            if #available(macOS 26.0, *) {
                posix_spawn_file_actions_addchdir(&actions, path)
            } else {
                posix_spawn_file_actions_addchdir_np(&actions, path)
            }
        }
        try Self.addFileAction(changeDirectoryResult)

        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        guard posix_spawnattr_setflags(&attributes, flags) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0
        else {
            throw CLIProcessError.couldNotStart("Could not create an isolated process group.")
        }

        let arguments = [request.executableURL.path] + request.arguments
        let environment = request.environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        var processIdentifier: pid_t = 0
        let spawnResult = Self.withCStringArray(arguments) { argumentVector in
            Self.withCStringArray(environment) { environmentVector in
                request.executableURL.path.withCString { executablePath in
                    posix_spawn(
                        &processIdentifier,
                        executablePath,
                        &actions,
                        &attributes,
                        argumentVector,
                        environmentVector
                    )
                }
            }
        }
        guard spawnResult == 0 else {
            throw CLIProcessError.couldNotStart(Self.errorMessage(spawnResult))
        }

        Darwin.close(standardInput.read)
        standardInput.read = -1
        Darwin.close(standardOutput.write)
        standardOutput.write = -1
        Darwin.close(standardError.write)
        standardError.write = -1
        parentDescriptorsTransferred = true

        return SpawnedProcess(
            processIdentifier: processIdentifier,
            standardInput: standardInput.write,
            standardOutput: standardOutput.read,
            standardError: standardError.read
        )
    }

    private struct FileDescriptorPipe {
        var read: Int32
        var write: Int32
    }

    private static func makePipe() throws -> FileDescriptorPipe {
        var descriptors = [Int32](repeating: 0, count: 2)
        let result = descriptors.withUnsafeMutableBufferPointer { buffer in
            Darwin.pipe(buffer.baseAddress!)
        }
        guard result == 0 else {
            throw CLIProcessError.couldNotStart(errorMessage(errno))
        }
        return FileDescriptorPipe(read: descriptors[0], write: descriptors[1])
    }

    private static func closePipe(_ pipe: inout FileDescriptorPipe) {
        if pipe.read >= 0 { Darwin.close(pipe.read) }
        if pipe.write >= 0 { Darwin.close(pipe.write) }
        pipe.read = -1
        pipe.write = -1
    }

    private static func addFileAction(_ result: Int32) throws {
        guard result == 0 else {
            throw CLIProcessError.couldNotStart(errorMessage(result))
        }
    }

    private static func withCStringArray<Result>(
        _ strings: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        let pointers = strings.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        var terminatedPointers = pointers + [nil]
        return terminatedPointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }

    private static func runBlocking<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            blockingQueue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func write(_ data: Data, to descriptor: Int32) throws {
        defer { Darwin.close(descriptor) }
        try writeKeepingOpen(data, to: descriptor)
    }

    private static func writeKeepingOpen(_ data: Data, to descriptor: Int32) throws {
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else if count < 0, errno == EPIPE {
                    return
                } else {
                    throw CLIProcessError.inputWriteFailed(errorMessage(errno))
                }
            }
        }
    }

    private static func writeLine(_ data: Data, to descriptor: Int32) throws {
        var line = data
        if line.last != 0x0A {
            line.append(0x0A)
        }
        try writeKeepingOpen(line, to: descriptor)
    }

    private static func exchangeJSONRPC(
        _ request: CLIJSONRPCExchangeRequest,
        with process: SpawnedProcess
    ) throws -> Data {
        defer {
            Darwin.close(process.standardInput)
            Darwin.close(process.standardOutput)
        }

        var reader = JSONLineReader(
            descriptor: process.standardOutput,
            limit: request.process.standardOutputLimit
        )
        try writeLine(request.initializeRequest, to: process.standardInput)
        _ = try reader.readResponse(id: request.initializeResponseID)
        try writeLine(request.initializedNotification, to: process.standardInput)
        try writeLine(request.request, to: process.standardInput)
        return try reader.readResponse(id: request.responseID)
    }

    private struct JSONLineReader {
        let descriptor: Int32
        let limit: Int
        var buffered = Data()
        var bytesRead = 0

        mutating func readResponse(id: Int) throws -> Data {
            while let line = try readLine() {
                guard !line.isEmpty else { continue }
                guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw CLIProcessError.outputReadFailed("The CLI emitted an invalid JSON-RPC line.")
                }
                guard let responseID = object["id"] as? NSNumber,
                      responseID.intValue == id
                else { continue }

                if let error = object["error"], !(error is NSNull) {
                    let description = String(describing: error).prefix(1_024)
                    throw CLIProcessError.outputReadFailed("JSON-RPC request failed: \(description)")
                }
                return line
            }
            throw CLIProcessError.outputReadFailed(
                "The CLI closed its JSON-RPC stream before response \(id)."
            )
        }

        private mutating func readLine() throws -> Data? {
            while true {
                if let newline = buffered.firstIndex(of: 0x0A) {
                    var line = Data(buffered[..<newline])
                    buffered.removeSubrange(...newline)
                    if line.last == 0x0D {
                        line.removeLast()
                    }
                    return line
                }

                var chunk = [UInt8](repeating: 0, count: 8 * 1024)
                let count = chunk.withUnsafeMutableBytes { bytes in
                    Darwin.read(descriptor, bytes.baseAddress!, bytes.count)
                }
                if count == 0 {
                    guard !buffered.isEmpty else { return nil }
                    let line = buffered
                    buffered.removeAll(keepingCapacity: false)
                    return line
                }
                if count < 0, errno == EINTR { continue }
                if count < 0 {
                    throw CLIProcessError.outputReadFailed(errorMessage(errno))
                }
                guard bytesRead + count <= limit else {
                    throw CLIProcessError.standardOutputTooLarge
                }
                bytesRead += count
                buffered.append(contentsOf: chunk.prefix(count))
            }
        }
    }

    private static func read(
        from descriptor: Int32,
        limit: Int,
        limitError: CLIProcessError
    ) throws -> Data {
        defer { Darwin.close(descriptor) }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress!, bytes.count)
            }
            if count == 0 { return result }
            if count < 0, errno == EINTR { continue }
            if count < 0 {
                throw CLIProcessError.outputReadFailed(errorMessage(errno))
            }
            guard result.count + count <= limit else { throw limitError }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    private static func wait(for processIdentifier: pid_t) throws -> Int32 {
        var status: Int32 = 0
        while true {
            let result = Darwin.waitpid(processIdentifier, &status, 0)
            if result == processIdentifier { break }
            if result < 0, errno == EINTR { continue }
            throw CLIProcessError.waitFailed(errorMessage(errno))
        }

        let signal = status & 0x7f
        if signal == 0 {
            return (status >> 8) & 0xff
        }
        return 128 + signal
    }

    private static func errorMessage(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}

private final class CLIProcessController: @unchecked Sendable {
    private struct State {
        var processIdentifier: pid_t?
        var terminationRequested = false
        var reaped = false
        var terminationSignalSent = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func install(processIdentifier: pid_t) {
        let terminateImmediately = state.withLock { state -> Bool in
            state.processIdentifier = processIdentifier
            guard state.terminationRequested,
                  !state.reaped,
                  !state.terminationSignalSent
            else { return false }
            state.terminationSignalSent = true
            return true
        }
        if terminateImmediately {
            Self.killProcessAndGroup(processIdentifier)
        }
    }

    func markReaped() {
        let processIdentifier = state.withLock { state -> pid_t? in
            state.reaped = true
            guard !state.terminationSignalSent else { return nil }
            state.terminationSignalSent = true
            return state.processIdentifier
        }
        if let processIdentifier {
            Self.killDescendantProcessGroup(processIdentifier)
        }
    }

    func terminateProcessGroup() {
        let processIdentifier = state.withLock { state -> pid_t? in
            state.terminationRequested = true
            guard !state.reaped, !state.terminationSignalSent else { return nil }
            state.terminationSignalSent = true
            return state.processIdentifier
        }
        if let processIdentifier {
            Self.killProcessAndGroup(processIdentifier)
        }
    }

    private static func killProcessAndGroup(_ processIdentifier: pid_t) {
        guard processIdentifier > 1 else { return }
        _ = Darwin.kill(-processIdentifier, SIGKILL)
        _ = Darwin.kill(processIdentifier, SIGKILL)
    }

    private static func killDescendantProcessGroup(_ processIdentifier: pid_t) {
        guard processIdentifier > 1 else { return }
        _ = Darwin.kill(-processIdentifier, SIGKILL)
    }
}
