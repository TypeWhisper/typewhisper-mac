import Foundation

public struct PluginRuntimeMemorySnapshot: Sendable, Equatable, Codable {
    public static let sharedMLXRuntimeIdentifier = "shared-mlx-runtime"

    public let runtimeIdentifier: String
    public let activeMemoryBytes: Int
    public let cacheMemoryBytes: Int
    public let peakMemoryBytes: Int

    public init(
        runtimeIdentifier: String = Self.sharedMLXRuntimeIdentifier,
        activeMemoryBytes: Int,
        cacheMemoryBytes: Int,
        peakMemoryBytes: Int
    ) {
        self.runtimeIdentifier = runtimeIdentifier
        self.activeMemoryBytes = activeMemoryBytes
        self.cacheMemoryBytes = cacheMemoryBytes
        self.peakMemoryBytes = peakMemoryBytes
    }
}

public protocol PluginRuntimeMemoryDiagnosticsReporting: TypeWhisperPlugin {
    var runtimeMemorySnapshot: PluginRuntimeMemorySnapshot? { get }
}

public actor PluginLocalInferenceGate {
    public static let shared = PluginLocalInferenceGate()

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var isLocked = false
    private var isClosed = false
    private var waiters: [Waiter] = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func withLock<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    /// 等正在运行的操作结束，并拒绝排队中和之后的操作。
    public func close() async {
        isClosed = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.continuation.resume(returning: false)
        }
        guard isLocked else { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    private func acquire() async throws {
        guard !isClosed else { throw CancellationError() }
        if !isLocked {
            isLocked = true
            return
        }

        let waiterID = UUID()
        let didAcquire = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || isClosed {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: waiterID)
            }
        }
        guard didAcquire else {
            throw CancellationError()
        }
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    private func release() {
        if isClosed {
            isLocked = false
            let idle = idleWaiters
            idleWaiters.removeAll()
            for continuation in idle {
                continuation.resume()
            }
        } else if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }
}
