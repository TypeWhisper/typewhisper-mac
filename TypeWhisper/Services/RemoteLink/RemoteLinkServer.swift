import CryptoKit
import Foundation
import Network
import os
import SystemConfiguration

struct RemoteLinkDevice: Codable, Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    let pairedAt: Date
    var lastSeenAt: Date?
}

struct RemoteLinkPairingRequest: Equatable, Sendable {
    let deviceID: String
    let deviceName: String
    let code: String
}

/// Paired devices live in UserDefaults, their keys in the Keychain.
final class RemoteLinkDeviceStore: @unchecked Sendable {
    static let keychainServicePrefix = "remote-link-device."

    private let defaults: UserDefaults
    private let lock = NSLock()
    private let loadKey: @Sendable (String) -> String?
    private let saveKey: @Sendable (String, String) throws -> Void
    private let deleteKey: @Sendable (String) -> Void

    init(
        defaults: UserDefaults = .standard,
        loadKey: @escaping @Sendable (String) -> String? = { deviceID in
            KeychainService.load(service: RemoteLinkDeviceStore.keychainServicePrefix + deviceID)
        },
        saveKey: @escaping @Sendable (String, String) throws -> Void = { deviceID, key in
            try KeychainService.save(key: key, service: RemoteLinkDeviceStore.keychainServicePrefix + deviceID)
        },
        deleteKey: @escaping @Sendable (String) -> Void = { deviceID in
            try? KeychainService.delete(service: RemoteLinkDeviceStore.keychainServicePrefix + deviceID)
        }
    ) {
        self.defaults = defaults
        self.loadKey = loadKey
        self.saveKey = saveKey
        self.deleteKey = deleteKey
    }

    /// Stable identifier of this Mac, advertised in the Bonjour TXT record.
    var serverID: String {
        lock.withLock {
            if let existing = defaults.string(forKey: UserDefaultsKeys.remoteLinkServerID) {
                return existing
            }
            let created = UUID().uuidString
            defaults.set(created, forKey: UserDefaultsKeys.remoteLinkServerID)
            return created
        }
    }

    func devices() -> [RemoteLinkDevice] {
        lock.withLock { storedDevices() }
    }

    func pairingKey(for deviceID: String) -> SymmetricKey? {
        guard devices().contains(where: { $0.id == deviceID }),
              let encoded = loadKey(deviceID),
              let data = Data(base64Encoded: encoded),
              data.count == 32 else {
            return nil
        }
        return SymmetricKey(data: data)
    }

    func addDevice(_ device: RemoteLinkDevice, key: SymmetricKey) throws {
        try saveKey(device.id, key.withUnsafeBytes { Data($0) }.base64EncodedString())
        lock.withLock {
            var devices = storedDevices().filter { $0.id != device.id }
            devices.append(device)
            store(devices)
        }
    }

    func removeDevice(id: String) {
        lock.withLock {
            store(storedDevices().filter { $0.id != id })
        }
        deleteKey(id)
    }

    func markSeen(id: String, at date: Date = Date()) {
        lock.withLock {
            var devices = storedDevices()
            guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
            devices[index].lastSeenAt = date
            store(devices)
        }
    }

    private func storedDevices() -> [RemoteLinkDevice] {
        guard let data = defaults.data(forKey: UserDefaultsKeys.remoteLinkDevices),
              let devices = try? JSONDecoder().decode([RemoteLinkDevice].self, from: data) else {
            return []
        }
        return devices
    }

    private func store(_ devices: [RemoteLinkDevice]) {
        defaults.set(try? JSONEncoder().encode(devices), forKey: UserDefaultsKeys.remoteLinkDevices)
    }
}

/// Serves paired iPhones and iPads on the local network. Requests arrive as
/// HTTP inside an encrypted Remote Link channel and reach a small allowlist
/// of API routes; the loopback API and its token are not involved.
final class RemoteLinkServer: @unchecked Sendable {
    enum State: Equatable, Sendable {
        case stopped
        case ready
        case failed(String)
    }

    typealias PairingApprover = @Sendable (RemoteLinkPairingRequest) async -> Bool

    static let allowedRoutes: Set<String> = [
        "GET /v1/status",
        "GET /v1/models",
        "POST /v1/transcribe",
    ]
    static let maxConnections = 8
    static let pairingTimeout: TimeInterval = 120

    let store: RemoteLinkDeviceStore
    var onStateChange: (@Sendable (State) -> Void)?
    var onDevicesChange: (@Sendable () -> Void)?
    var onPairingFinished: (@Sendable (RemoteLinkDevice?) -> Void)?

    private let router: APIRouter
    private let serverName: @Sendable () -> String
    private let advertises: Bool
    private let queue = DispatchQueue(label: "com.typewhisper.remote-link.server")
    private let lock = NSLock()
    private let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "RemoteLink")
    private var listener: NWListener?
    private var activeConnections: [UUID: (connection: RemoteLinkConnection, task: Task<Void, Never>)] = [:]
    private var pairingApprover: PairingApprover?
    private var isPairingInProgress = false

    init(
        router: APIRouter,
        store: RemoteLinkDeviceStore = RemoteLinkDeviceStore(),
        serverName: @escaping @Sendable () -> String = RemoteLinkServer.computerName,
        advertises: Bool = true
    ) {
        self.router = router
        self.store = store
        self.serverName = serverName
        self.advertises = advertises
    }

    var port: UInt16? {
        lock.withLock { listener?.port?.rawValue }
    }

    static func computerName() -> String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    }

    func start() throws {
        stop()
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let listener = try NWListener(using: parameters)
        listener.service = makeService(pairing: lock.withLock { pairingApprover != nil })
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onStateChange?(.ready)
            case .failed(let error):
                self?.onStateChange?(.failed(error.localizedDescription))
                self?.stop()
            case .cancelled:
                self?.onStateChange?(.stopped)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        lock.withLock { self.listener = listener }
        listener.start(queue: queue)
    }

    func stop() {
        let (listener, connections) = lock.withLock {
            let current = (self.listener, Array(activeConnections.values))
            self.listener = nil
            activeConnections.removeAll()
            return current
        }
        listener?.cancel()
        for active in connections {
            active.task.cancel()
            active.connection.close()
        }
    }

    /// Accepts pairing requests until `closePairing()`. The approver shows
    /// the code to the user and returns their decision.
    func openPairing(approver: @escaping PairingApprover) {
        let listener = lock.withLock {
            pairingApprover = approver
            return self.listener
        }
        listener?.service = makeService(pairing: true)
    }

    func closePairing() {
        let listener = lock.withLock {
            pairingApprover = nil
            return self.listener
        }
        listener?.service = makeService(pairing: false)
    }

    func removeDevice(id: String) {
        store.removeDevice(id: id)
        onDevicesChange?()
    }

    /// Turns one decrypted request message into the response message body.
    static func response(for message: Data, router: APIRouter) async -> HTTPResponse {
        let request: HTTPRequest
        do {
            request = try HTTPRequestParser.parse(message)
        } catch HTTPParseError.bodyTooLarge {
            return .error(status: 413, message: "Payload too large. Maximum request body size is 256 MiB.")
        } catch {
            return .error(status: 400, message: "Malformed request")
        }

        guard allowedRoutes.contains("\(request.method) \(request.path)") else {
            return .error(status: 403, message: "This endpoint is not available to paired devices")
        }
        return await router.routeTrusted(request)
    }

    // MARK: - Connections

    private func makeService(pairing: Bool) -> NWListener.Service? {
        guard advertises else { return nil }
        var txt = NWTXTRecord()
        txt[RemoteLink.txtVersionKey] = String(RemoteLink.protocolVersion)
        txt[RemoteLink.txtServerIDKey] = store.serverID
        if pairing {
            txt[RemoteLink.txtPairingKey] = "1"
        }
        return NWListener.Service(type: RemoteLink.bonjourType, txtRecord: txt)
    }

    private func accept(_ nwConnection: NWConnection) {
        let id = UUID()
        let connection = RemoteLinkConnection(connection: nwConnection)
        lock.withLock {
            guard activeConnections.count < Self.maxConnections else {
                nwConnection.cancel()
                return
            }
            let task = Task { [weak self] in
                await self?.serve(connection)
                connection.close()
                self?.finishConnection(id)
            }
            activeConnections[id] = (connection, task)
        }
    }

    private func finishConnection(_ id: UUID) {
        _ = lock.withLock { activeConnections.removeValue(forKey: id) }
    }

    private func serve(_ connection: RemoteLinkConnection) async {
        do {
            try await connection.start(timeout: 10)
            let first = try await connection.receiveHandshake(timeout: 10)
            guard first.version == RemoteLink.protocolVersion else {
                try await connection.send(.error(.unsupportedVersion))
                return
            }
            switch first.type {
            case .hello:
                try await serveSession(hello: first, connection: connection)
            case .pairRequest:
                try await servePairing(request: first, connection: connection)
            default:
                return
            }
        } catch {
            logger.debug("Remote Link connection ended: \(String(describing: error), privacy: .public)")
        }
    }

    private func serveSession(hello: RemoteLinkHandshake, connection: RemoteLinkConnection) async throws {
        guard let deviceID = hello.deviceID,
              let clientNonce = hello.nonce,
              clientNonce.count == RemoteLink.nonceSize else {
            throw RemoteLinkError.malformedHandshake
        }
        guard let pairingKey = store.pairingKey(for: deviceID) else {
            try await connection.send(.error(.unknownDevice))
            return
        }

        let serverID = store.serverID
        let serverNonce = RemoteLinkCrypto.randomNonce()
        try await connection.send(RemoteLinkHandshake(type: .welcome, serverID: serverID, nonce: serverNonce))

        let keys = RemoteLinkSessionKeys(
            pairingKey: pairingKey,
            deviceID: deviceID,
            serverID: serverID,
            clientNonce: clientNonce,
            serverNonce: serverNonce,
            role: .server
        )
        let channel = RemoteLinkChannel(connection: connection, keys: keys)
        let message: Data
        do {
            message = try await channel.receiveMessage(timeout: 60)
        } catch RemoteLinkError.authenticationFailed {
            try? await connection.send(.error(.authenticationFailed))
            throw RemoteLinkError.authenticationFailed
        }
        store.markSeen(id: deviceID)
        onDevicesChange?()

        let response = await Self.response(for: message, router: router)
        try await channel.send(message: response.serialized())
    }

    // MARK: - Pairing

    private enum PairingStep: Sendable {
        case approval(Bool)
        case clientConfirmed
    }

    private func servePairing(request: RemoteLinkHandshake, connection: RemoteLinkConnection) async throws {
        guard let deviceID = request.deviceID,
              UUID(uuidString: deviceID) != nil,
              let commitment = request.commitment,
              commitment.count == 32 else {
            throw RemoteLinkError.malformedHandshake
        }

        let approver: PairingApprover? = lock.withLock {
            guard let pairingApprover, !isPairingInProgress else { return nil }
            isPairingInProgress = true
            return pairingApprover
        }
        guard let approver else {
            let isOpen = lock.withLock { pairingApprover != nil }
            try await connection.send(.error(isOpen ? .pairingBusy : .pairingClosed))
            return
        }

        var pairedDevice: RemoteLinkDevice?
        defer {
            lock.withLock { isPairingInProgress = false }
            onPairingFinished?(pairedDevice)
        }

        let deviceName = Self.sanitizedDeviceName(request.name)
        let serverID = store.serverID
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let serverNonce = RemoteLinkCrypto.randomNonce()
        try await connection.send(RemoteLinkHandshake(
            type: .pairChallenge,
            serverID: serverID,
            name: serverName(),
            nonce: serverNonce,
            key: privateKey.publicKey.rawRepresentation
        ))

        let reveal = try await connection.receiveHandshake(timeout: 60).expecting(.pairReveal)
        guard let clientKey = reveal.key,
              let clientNonce = reveal.nonce,
              clientNonce.count == RemoteLink.nonceSize,
              RemoteLinkCrypto.commitment(clientKey: clientKey, clientNonce: clientNonce) == commitment else {
            try? await connection.send(.error(.pairingFailed))
            throw RemoteLinkError.commitmentMismatch
        }

        let transcript = RemoteLinkPairingTranscript(
            deviceID: deviceID,
            serverID: serverID,
            clientKey: clientKey,
            serverKey: privateKey.publicKey.rawRepresentation,
            clientNonce: clientNonce,
            serverNonce: serverNonce
        )
        let pairingKey = try transcript.pairingKey(privateKey: privateKey, peerKey: clientKey)
        let pairingRequest = RemoteLinkPairingRequest(
            deviceID: deviceID,
            deviceName: deviceName,
            code: transcript.verificationCode
        )

        let approved = try await withThrowingTaskGroup(of: PairingStep.self) { group in
            group.addTask {
                .approval(await approver(pairingRequest))
            }
            group.addTask {
                let confirm = try await connection.receiveHandshake(timeout: Self.pairingTimeout).expecting(.pairConfirm)
                guard let proof = confirm.proof,
                      transcript.isValidProof(proof, label: .clientConfirmed, key: pairingKey) else {
                    throw RemoteLinkError.authenticationFailed
                }
                return .clientConfirmed
            }
            group.addTask {
                try await Task.sleep(for: .seconds(Self.pairingTimeout))
                throw RemoteLinkError.timedOut
            }

            var isApproved = false
            var isConfirmed = false
            while let step = try await group.next() {
                switch step {
                case .approval(let decision):
                    guard decision else {
                        try? await connection.send(RemoteLinkHandshake(type: .pairDenied))
                        connection.close()
                        group.cancelAll()
                        return false
                    }
                    isApproved = true
                case .clientConfirmed:
                    isConfirmed = true
                }
                if isApproved && isConfirmed {
                    group.cancelAll()
                    return true
                }
            }
            return false
        }
        guard approved else { return }

        let device = RemoteLinkDevice(id: deviceID, name: deviceName, pairedAt: Date(), lastSeenAt: nil)
        try store.addDevice(device, key: pairingKey)
        try await connection.send(RemoteLinkHandshake(
            type: .pairApproved,
            proof: transcript.proof(.serverApproved, key: pairingKey)
        ))
        pairedDevice = device
        onDevicesChange?()
    }

    static func sanitizedDeviceName(_ name: String?) -> String {
        let trimmed = (name ?? "")
            .components(separatedBy: .controlCharacters)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "iPhone" : String(trimmed.prefix(64))
    }
}
