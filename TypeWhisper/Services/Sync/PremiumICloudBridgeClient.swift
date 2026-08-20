import Foundation

protocol PremiumICloudBridging: Sendable {
    var isAvailable: Bool { get }
    var localFolderURL: URL? { get }

    func synchronize() async throws
    func deleteRemotePackage() async throws
}

private final class PremiumICloudBridgeReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func finish(with result: Result<Void, Error>) {
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

    func synchronize() async throws {
        try await perform { proxy, reply in
            proxy.synchronize(reply: reply)
        }
    }

    func deleteRemotePackage() async throws {
        try await perform { proxy, reply in
            proxy.deleteRemotePackage(reply: reply)
        }
    }

    private func perform(
        _ operation: @escaping (
            PremiumICloudBridgeXPCProtocol,
            @escaping (String?) -> Void
        ) -> Void
    ) async throws {
        guard isAvailable else {
            throw PremiumICloudBridgeError.serviceUnavailable
        }
        try await withCheckedThrowingContinuation { continuation in
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
            operation(proxy) { message in
                if let message {
                    gate.finish(with: .failure(
                        PremiumICloudBridgeError.operationFailed(message)
                    ))
                } else {
                    gate.finish(with: .success(()))
                }
                connection.invalidate()
            }
        }
    }
}
