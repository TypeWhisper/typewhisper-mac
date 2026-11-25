import Foundation

protocol PremiumICloudBridging: Sendable {
    var isAvailable: Bool { get }
    var localFolderURL: URL? { get }

    /// Mirrors the local sync package and the iCloud container.
    @discardableResult
    func synchronize() async throws -> PremiumICloudBridgeReport
    func deleteRemotePackage() async throws
    func removeDevice(_ deviceID: String) async throws
}

enum PremiumICloudBridgeFactory {
    static func makeDefault() -> any PremiumICloudBridging {
        #if APPSTORE
        AppStoreICloudMirror()
        #else
        PremiumICloudBridgeClient()
        #endif
    }
}

private final class PremiumICloudBridgeReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PremiumICloudBridgeReport, Error>?

    init(continuation: CheckedContinuation<PremiumICloudBridgeReport, Error>) {
        self.continuation = continuation
    }

    func finish(with result: Result<PremiumICloudBridgeReport, Error>) {
        let pendingContinuation = lock.withLock {
            let pendingContinuation = continuation
            self.continuation = nil
            return pendingContinuation
        }
        pendingContinuation?.resume(with: result)
    }
}

final class PremiumICloudBridgeClient: PremiumICloudBridging, @unchecked Sendable {
    let isAvailable: Bool
    let localFolderURL: URL?

    private let serviceName: String

    init(
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        serviceName: String? = nil
    ) {
        self.serviceName = serviceName
            ?? PremiumICloudBridgeConstants.serviceBundleIdentifier(
                infoDictionary: bundle.infoDictionary
            )
        localFolderURL = PremiumICloudBridgeConstants.localRootURL(
            bundle: bundle,
            fileManager: fileManager
        )
        isAvailable = localFolderURL != nil && fileManager.fileExists(
            atPath: PremiumICloudBridgeConstants.embeddedServiceURL(bundle: bundle).path
        )
    }

    @discardableResult
    func synchronize() async throws -> PremiumICloudBridgeReport {
        try await perform { proxy, reply in
            proxy.synchronize(reply: reply)
        }
    }

    func deleteRemotePackage() async throws {
        try await perform { proxy, reply in
            proxy.deleteRemotePackage(reply: reply)
        }
    }

    func removeDevice(_ deviceID: String) async throws {
        try await perform { proxy, reply in
            proxy.removeDevice(deviceID, reply: reply)
        }
    }

    @discardableResult
    private func perform(
        _ operation: @escaping (
            PremiumICloudBridgeXPCProtocol,
            @escaping (Data) -> Void
        ) -> Void
    ) async throws -> PremiumICloudBridgeReport {
        guard isAvailable else {
            throw PremiumICloudBridgeError.serviceUnavailable
        }
        return try await withCheckedThrowingContinuation { continuation in
            let gate = PremiumICloudBridgeReplyGate(continuation: continuation)
            let connection = NSXPCConnection(serviceName: serviceName)
            connection.remoteObjectInterface = NSXPCInterface(
                with: PremiumICloudBridgeXPCProtocol.self
            )
            connection.interruptionHandler = {
                gate.finish(with: .failure(PremiumICloudBridgeError.serviceUnavailable))
            }
            connection.invalidationHandler = {
                gate.finish(with: .failure(PremiumICloudBridgeError.serviceUnavailable))
            }
            connection.resume()

            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                gate.finish(with: .failure(error))
                connection.invalidate()
            }) as? PremiumICloudBridgeXPCProtocol else {
                gate.finish(with: .failure(PremiumICloudBridgeError.serviceUnavailable))
                connection.invalidate()
                return
            }
            operation(proxy) { data in
                let reply = PremiumICloudBridgeReply.decoded(from: data)
                if let failure = reply.failure {
                    gate.finish(with: .failure(failure))
                } else {
                    gate.finish(with: .success(reply.report))
                }
                connection.invalidate()
            }
        }
    }
}
