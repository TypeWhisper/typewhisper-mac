import Foundation

public struct PluginRuntimeMemorySnapshot: Sendable, Equatable, Codable {
    public let activeMemoryBytes: Int
    public let cacheMemoryBytes: Int
    public let peakMemoryBytes: Int

    public init(activeMemoryBytes: Int, cacheMemoryBytes: Int, peakMemoryBytes: Int) {
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

    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func withLock<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
