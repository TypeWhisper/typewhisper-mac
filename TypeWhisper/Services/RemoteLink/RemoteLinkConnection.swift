import Foundation
import Network

// TypeWhisper for macOS and iOS ship identical copies of this file.

/// Frame transport over one `NWConnection`. Each method may be awaited by one
/// task at a time; receive state stays on the connection's private queue.
final class RemoteLinkConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.typewhisper.remote-link.connection")
    private var decoder = RemoteLinkFrameDecoder()

    init(connection: NWConnection) {
        self.connection = connection
    }

    convenience init(endpoint: NWEndpoint) {
        self.init(connection: NWConnection(to: endpoint, using: .tcp))
    }

    var remoteEndpoint: NWEndpoint {
        connection.endpoint
    }

    /// Starts the connection and waits until it is ready. A connection that
    /// keeps waiting, for example because local network access is denied,
    /// fails with the last reported reason once the timeout expires.
    func start(timeout: TimeInterval) async throws {
        let waitingReason = RemoteLinkLockedValue<String?>(nil)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = RemoteLinkResumeOnce(continuation)
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    once.resume(with: .success(()))
                case .waiting(let error):
                    waitingReason.set(error.localizedDescription)
                case .failed(let error):
                    once.resume(with: .failure(RemoteLinkError.connectionFailed(error.localizedDescription)))
                    self?.close()
                case .cancelled:
                    once.resume(with: .failure(RemoteLinkError.connectionClosed))
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                let error = waitingReason.get().map(RemoteLinkError.connectionFailed) ?? .timedOut
                if once.resume(with: .failure(error)) {
                    self?.close()
                }
            }
        }
    }

    func send(_ frames: [RemoteLinkFrame]) async throws {
        for frame in frames {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: frame.encoded(), completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: RemoteLinkError.connectionFailed(error.localizedDescription))
                    } else {
                        continuation.resume()
                    }
                })
            }
        }
    }

    func send(_ handshake: RemoteLinkHandshake) async throws {
        try await send([handshake.frame()])
    }

    func receiveFrame(timeout: TimeInterval?) async throws -> RemoteLinkFrame {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RemoteLinkFrame, Error>) in
            let once = RemoteLinkResumeOnce(continuation)
            queue.async { self.pump(once) }
            if let timeout {
                queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    if once.resume(with: .failure(RemoteLinkError.timedOut)) {
                        self?.close()
                    }
                }
            }
        }
    }

    func receiveHandshake(timeout: TimeInterval?) async throws -> RemoteLinkHandshake {
        try RemoteLinkHandshake(frame: try await receiveFrame(timeout: timeout))
    }

    func close() {
        connection.cancel()
    }

    /// Runs `operation` and closes the connection when the deadline passes or
    /// the calling task is cancelled, so pending sends and receives fail at
    /// once instead of waiting for their own timeouts.
    func withDeadline<T: Sendable>(
        _ timeout: TimeInterval,
        _ operation: () async throws -> T
    ) async throws -> T {
        let expired = RemoteLinkLockedValue(false)
        let timer = DispatchWorkItem { [weak self] in
            expired.set(true)
            self?.close()
        }
        queue.asyncAfter(deadline: .now() + timeout, execute: timer)
        defer { timer.cancel() }
        do {
            return try await withTaskCancellationHandler {
                try await operation()
            } onCancel: { [weak self] in
                self?.close()
            }
        } catch {
            if expired.get() { throw RemoteLinkError.timedOut }
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private func pump(_ once: RemoteLinkResumeOnce<RemoteLinkFrame>) {
        if deliverBufferedFrame(to: once) { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else {
                once.resume(with: .failure(RemoteLinkError.connectionClosed))
                return
            }
            if let data, !data.isEmpty {
                self.decoder.append(data)
            }
            if self.deliverBufferedFrame(to: once) { return }
            if let error {
                once.resume(with: .failure(RemoteLinkError.connectionFailed(error.localizedDescription)))
            } else if isComplete {
                once.resume(with: .failure(RemoteLinkError.connectionClosed))
            } else if !once.isResumed {
                self.pump(once)
            }
        }
    }

    private func deliverBufferedFrame(to once: RemoteLinkResumeOnce<RemoteLinkFrame>) -> Bool {
        do {
            guard let frame = try decoder.nextFrame() else { return false }
            once.resume(with: .success(frame))
        } catch {
            once.resume(with: .failure(error))
            close()
        }
        return true
    }
}

/// Encrypted message exchange on top of a connection whose handshake is done.
actor RemoteLinkChannel {
    private let connection: RemoteLinkConnection
    private var sealer: RemoteLinkSealer
    private var opener: RemoteLinkOpener

    init(connection: RemoteLinkConnection, keys: RemoteLinkSessionKeys) {
        self.connection = connection
        sealer = RemoteLinkSealer(key: keys.sending)
        opener = RemoteLinkOpener(key: keys.receiving)
    }

    func send(message: Data) async throws {
        let frames = try sealer.seal(message: message)
        try await connection.send(frames)
    }

    func receiveMessage(timeout: TimeInterval?) async throws -> Data {
        while true {
            let frame = try await connection.receiveFrame(timeout: timeout)
            if frame.kind == .handshake {
                // A peer that cannot open our frames reports it in plain text.
                throw RemoteLinkError.remoteError((try? RemoteLinkHandshake(frame: frame).code) ?? "unknown")
            }
            if let message = try opener.open(frame) {
                return message
            }
        }
    }

    func close() {
        connection.close()
    }
}

final class RemoteLinkResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    var isResumed: Bool {
        lock.withLock { continuation == nil }
    }

    @discardableResult
    func resume(with result: Result<Value, Error>) -> Bool {
        let pending = lock.withLock {
            let pending = continuation
            continuation = nil
            return pending
        }
        guard let pending else { return false }
        pending.resume(with: result)
        return true
    }
}

final class RemoteLinkLockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.withLock { value }
    }

    func set(_ newValue: Value) {
        lock.withLock { value = newValue }
    }
}
