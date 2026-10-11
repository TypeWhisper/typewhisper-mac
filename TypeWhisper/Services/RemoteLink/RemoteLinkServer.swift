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
        "GET /v1/llm/models",
        "POST /v1/llm/process",
        "GET /v1/workflows",
        "POST /v1/workflows/run",
    ]
    /// Set by the server on every routed request, so handlers can tell paired
    /// devices apart from local tools. A client-supplied value is overwritten.
    static let remoteDeviceHeader = "x-typewhisper-remote-device"
    static let maxConnections = 8
    static let maxConnectionsPerHost = 3
    static let pairingTimeout: TimeInterval = 120
    static let requestTimeout: TimeInterval = 120
    static let responseTimeout: TimeInterval = 60

    let store: RemoteLinkDeviceStore
    var onStateChange: (@Sendable (State) -> Void)?
    var onDevicesChange: (@Sendable () -> Void)?
    /// True once Bonjour registered the service. macOS holds the registration
    /// back until the user allows local network access.
    var onAdvertisingChange: (@Sendable (Bool) -> Void)?
    var onPairingFinished: (@Sendable (RemoteLinkDevice?) -> Void)?

    private let router: APIRouter
    private let serverName: @Sendable () -> String
    private let advertises: Bool
    private let queue = DispatchQueue(label: "com.typewhisper.remote-link.server")
    private let lock = NSLock()
    private let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "RemoteLink")
    private var listener: NWListener?
    private var activeConnections: [UUID: (connection: RemoteLinkConnection, host: String, task: Task<Void, Never>)] = [:]
    /// Device behind each authenticated session, so removing a device closes it.
    private var sessionDevices: [UUID: String] = [:]
    private var pairingApprover: PairingApprover?
    private var isPairingInProgress = false
    /// Changes whenever pairing opens or closes; a pairing that started under
    /// an older generation must not store its device.
    private var pairingGeneration = 0
    private var pairingConnection: RemoteLinkConnection?

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
        listener.serviceRegistrationUpdateHandler = { [weak self] change in
            switch change {
            case .add:
                self?.onAdvertisingChange?(true)
            case .remove:
                self?.onAdvertisingChange?(false)
            @unknown default:
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
            pairingGeneration += 1
            return self.listener
        }
        listener?.service = makeService(pairing: true)
    }

    /// Stops accepting pairing requests and aborts one that is in progress,
    /// even if the user already approved it.
    func closePairing() {
        let (listener, connection) = lock.withLock {
            pairingApprover = nil
            pairingGeneration += 1
            let current = (self.listener, pairingConnection)
            pairingConnection = nil
            return current
        }
        connection?.close()
        listener?.service = makeService(pairing: false)
    }

    /// Forgets the device and closes its open sessions right away.
    /// Forgets the device, closes its open sessions and cancels the work they
    /// started, for example a running language model request.
    func removeDevice(id: String) {
        store.removeDevice(id: id)
        let sessions = lock.withLock {
            sessionDevices.filter { $0.value == id }.compactMap { activeConnections[$0.key] }
        }
        for session in sessions {
            session.task.cancel()
            session.connection.close()
        }
        onDevicesChange?()
    }

    /// Turns one decrypted request message into the response message body.
    static func response(for message: Data, router: APIRouter, deviceID: String) async -> HTTPResponse {
        let parsed: HTTPRequest
        do {
            parsed = try HTTPRequestParser.parse(message)
        } catch HTTPParseError.bodyTooLarge {
            return .error(status: 413, message: "Payload too large. Maximum request body size is 256 MiB.")
        } catch {
            return .error(status: 400, message: "Malformed request")
        }

        guard allowedRoutes.contains("\(parsed.method) \(parsed.path)") else {
            return .error(status: 403, message: "This endpoint is not available to paired devices")
        }
        var headers = parsed.headers
        headers[remoteDeviceHeader] = deviceID
        let request = HTTPRequest(
            method: parsed.method,
            path: parsed.path,
            queryParams: parsed.queryParams,
            headers: headers,
            body: parsed.body
        )
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

    /// Caps connections overall and per remote host, so one device on the
    /// network cannot occupy every slot before it authenticates.
    private func accept(_ nwConnection: NWConnection) {
        let id = UUID()
        let host = Self.hostKey(for: nwConnection.endpoint)
        let connection = RemoteLinkConnection(connection: nwConnection)
        lock.withLock {
            let fromHost = activeConnections.values.filter { $0.host == host }.count
            guard activeConnections.count < Self.maxConnections,
                  fromHost < Self.maxConnectionsPerHost else {
                nwConnection.cancel()
                return
            }
            let task = Task { [weak self] in
                await self?.serve(connection, id: id)
                connection.close()
                self?.finishConnection(id)
            }
            activeConnections[id] = (connection, host, task)
        }
    }

    static func hostKey(for endpoint: NWEndpoint) -> String {
        if case .hostPort(let host, _) = endpoint {
            return "\(host)"
        }
        return "\(endpoint)"
    }

    private func finishConnection(_ id: UUID) {
        lock.withLock {
            activeConnections[id] = nil
            sessionDevices[id] = nil
        }
    }

    private func serve(_ connection: RemoteLinkConnection, id: UUID) async {
        do {
            try await connection.start(timeout: 10)
            let first = try await connection.receiveHandshake(timeout: 10)
            guard first.version == RemoteLink.protocolVersion else {
                try await connection.send(.error(.unsupportedVersion))
                return
            }
            switch first.type {
            case .hello:
                try await serveSession(hello: first, connection: connection, id: id)
            case .pairRequest:
                try await servePairing(request: first, connection: connection)
            default:
                return
            }
        } catch {
            logger.debug("Remote Link connection ended: \(String(describing: error), privacy: .public)")
        }
    }

    private func serveSession(hello: RemoteLinkHandshake, connection: RemoteLinkConnection, id: UUID) async throws {
        guard let deviceID = hello.deviceID,
              let clientNonce = hello.nonce,
              clientNonce.count == RemoteLink.nonceSize,
              let clientEphemeralKey = hello.key else {
            throw RemoteLinkError.malformedHandshake
        }
        guard let pairingKey = store.pairingKey(for: deviceID) else {
            try await connection.send(.error(.unknownDevice))
            return
        }

        lock.withLock { sessionDevices[id] = deviceID }

        let serverID = store.serverID
        let serverNonce = RemoteLinkCrypto.randomNonce()
        let ephemeralKey = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralSecret = try RemoteLinkSessionKeys.ephemeralSecret(privateKey: ephemeralKey, peerKey: clientEphemeralKey)
        try await connection.send(RemoteLinkHandshake(
            type: .welcome,
            serverID: serverID,
            nonce: serverNonce,
            key: ephemeralKey.publicKey.rawRepresentation
        ))

        let keys = RemoteLinkSessionKeys(
            pairingKey: pairingKey,
            ephemeralSecret: ephemeralSecret,
            deviceID: deviceID,
            serverID: serverID,
            clientNonce: clientNonce,
            serverNonce: serverNonce,
            role: .server
        )
        let channel = RemoteLinkChannel(connection: connection, keys: keys)
        let message: Data
        do {
            // The deadline covers the whole request, so empty chunks cannot
            // keep a session open.
            message = try await connection.withDeadline(Self.requestTimeout) {
                try await channel.receiveMessage(timeout: Self.requestTimeout)
            }
        } catch RemoteLinkError.authenticationFailed {
            try? await connection.send(.error(.authenticationFailed))
            throw RemoteLinkError.authenticationFailed
        }

        // The device may have been removed while its request was arriving.
        guard store.pairingKey(for: deviceID) != nil else {
            throw RemoteLinkError.remoteError(RemoteLinkHandshake.ErrorCode.unknownDevice.rawValue)
        }
        store.markSeen(id: deviceID)
        onDevicesChange?()

        // Routing can take long, for example a language model request. A
        // receive stays pending meanwhile, so a client that disconnects
        // cancels the work instead of letting it run to the end.
        let router = self.router
        let work = Task { await Self.response(for: message, router: router, deviceID: deviceID) }
        let disconnectWatch = Task {
            _ = try? await connection.receiveFrame(timeout: nil)
            work.cancel()
        }
        let response = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        disconnectWatch.cancel()
        try Task.checkCancellation()
        try await connection.withDeadline(Self.responseTimeout) {
            try await channel.send(message: response.serialized())
        }
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

        let claimed: (approver: PairingApprover, generation: Int)? = lock.withLock {
            guard let pairingApprover, !isPairingInProgress else { return nil }
            isPairingInProgress = true
            pairingConnection = connection
            return (pairingApprover, pairingGeneration)
        }
        guard let claimed else {
            let isOpen = lock.withLock { pairingApprover != nil }
            try await connection.send(.error(isOpen ? .pairingBusy : .pairingClosed))
            return
        }
        let (approver, generation) = claimed

        var pairedDevice: RemoteLinkDevice?
        defer {
            lock.withLock {
                isPairingInProgress = false
                if pairingConnection === connection {
                    pairingConnection = nil
                }
            }
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
        // The user may have closed the pairing sheet after approving.
        guard lock.withLock({ pairingApprover != nil && pairingGeneration == generation }) else {
            try? await connection.send(RemoteLinkHandshake(type: .pairDenied))
            return
        }

        let device = RemoteLinkDevice(id: deviceID, name: deviceName, pairedAt: Date(), lastSeenAt: nil)
        try store.addDevice(device, key: pairingKey)
        do {
            try await connection.send(RemoteLinkHandshake(
                type: .pairApproved,
                proof: transcript.proof(.serverApproved, key: pairingKey)
            ))
        } catch {
            // The iPhone never learns that pairing succeeded, so it keeps no key either.
            store.removeDevice(id: deviceID)
            throw error
        }
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
