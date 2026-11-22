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

    /// A stored device with its key.
    typealias Pairing = (device: RemoteLinkDevice, key: SymmetricKey)

    private let defaults: UserDefaults
    private let lock = NSLock()
    /// Serializes every write including its Keychain operation, so a
    /// rollback cannot interleave with an addition or a removal. Taken
    /// before `lock`, never inside it.
    private let writeLock = NSLock()
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

    /// Stores the device and returns the pairing it replaced, read in the
    /// same step, so a pairing that fails afterwards can put it back.
    @discardableResult
    func addDevice(_ device: RemoteLinkDevice, key: SymmetricKey) throws -> Pairing? {
        try writeLock.withLock {
            let replaced = storedPairing(for: device.id)
            try addDeviceLocked(device, key: key)
            return replaced
        }
    }

    func removeDevice(id: String) {
        writeLock.withLock { removeDeviceLocked(id: id) }
    }

    /// Undoes `addDevice` with `addedKey` while that write is still the
    /// stored one: puts back the pairing it replaced, or forgets the device.
    /// Runs as one write, so a newer pairing or a removal that came after
    /// the failed attempt stays as it is and is never undone.
    func rollBack(deviceID: String, addedKey: SymmetricKey, replaced: Pairing?) {
        writeLock.withLock {
            guard pairingKey(for: deviceID) == addedKey else { return }
            if let replaced, (try? addDeviceLocked(replaced.device, key: replaced.key)) != nil {
                return
            }
            removeDeviceLocked(id: deviceID)
        }
    }

    /// Call with `writeLock` held.
    private func addDeviceLocked(_ device: RemoteLinkDevice, key: SymmetricKey) throws {
        let previousKey = loadKey(device.id)
        do {
            try saveKey(device.id, key.withUnsafeBytes { Data($0) }.base64EncodedString())
        } catch {
            // `KeychainService.save` deletes the old item before it adds the
            // new one, so a failed save can leave the device without a key.
            // The previous key is put back; if the Keychain keeps failing,
            // the device is no longer listed, since it cannot connect anyway.
            if let previousKey, (try? saveKey(device.id, previousKey)) == nil {
                lock.withLock {
                    store(storedDevices().filter { $0.id != device.id })
                }
                deleteKey(device.id)
            }
            throw error
        }
        lock.withLock {
            var devices = storedDevices().filter { $0.id != device.id }
            devices.append(device)
            store(devices)
        }
    }

    /// Call with `writeLock` held.
    private func removeDeviceLocked(id: String) {
        lock.withLock {
            store(storedDevices().filter { $0.id != id })
        }
        deleteKey(id)
    }

    private func storedPairing(for deviceID: String) -> Pairing? {
        guard let device = devices().first(where: { $0.id == deviceID }),
              let key = pairingKey(for: deviceID) else {
            return nil
        }
        return (device, key)
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

/// Serves paired phones and tablets on the local network. Requests arrive as
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
    /// Secret attempts need no user decision and run beside the single
    /// slot of a code request, at most this many at once.
    static let maxSecretPairingAttempts = 2
    /// The methods this Mac offers while pairing is open. Advertised in the
    /// TXT record, which is unauthenticated, so it only words the device's list.
    static let offeredPairingMethods: [RemoteLinkPairingMethod] = [.secret, .compare]

    /// How long the secret of a QR code stays valid. The pairing sheet then
    /// shows a new one.
    var pairingSecretLifetime: TimeInterval = 300
    /// Time a secret attempt has for `pair-reveal` and then for `pair-confirm`.
    var secretPairingStepTimeout: TimeInterval = 10
    /// How long a host stays shut out of pairing after a failed secret
    /// attempt. A wrong proof does not burn the secret, so a network peer
    /// cannot invalidate the QR code the user is about to scan; it is
    /// locked out instead.
    var pairingFailureLockout: TimeInterval = 60

    let store: RemoteLinkDeviceStore
    /// Also passes the listener's generation. A consumer that handles the
    /// state on another queue checks it again there with `isCurrentListener`
    /// or `isActiveListener`, because the listener can be replaced or stopped
    /// in between.
    var onStateChange: (@Sendable (State, Int) -> Void)?
    var onDevicesChange: (@Sendable () -> Void)?
    /// True once Bonjour registered the service. macOS holds the registration
    /// back until the user allows local network access. Also passes the
    /// listener's generation, like `onStateChange`.
    var onAdvertisingChange: (@Sendable (Bool, Int) -> Void)?
    var onPairingFinished: (@Sendable (RemoteLinkDevice?) -> Void)?
    /// The QR code to show changed: a new secret, or none any more. Read
    /// `pairingInvitation` for the current one.
    var onPairingInvitationChange: (@Sendable () -> Void)?

    private let router: APIRouter
    private let serverName: @Sendable () -> String
    private let advertises: Bool
    private let queue = DispatchQueue(label: "com.typewhisper.remote-link.server")
    private let lock = NSLock()
    private let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "RemoteLink")
    private var listener: NWListener?
    /// Changes on every start, so a replaced listener cannot report its
    /// state over the current one.
    private var listenerGeneration = 0
    private typealias ActiveConnection = (connection: RemoteLinkConnection, host: String, task: Task<Void, Never>)
    private var activeConnections: [UUID: ActiveConnection] = [:]
    /// Device behind each authenticated session, so removing a device closes it.
    private var sessionDevices: [UUID: String] = [:]
    private var pairingApprover: PairingApprover?
    private var isPairingInProgress = false
    /// Changes whenever pairing opens or closes; a pairing that started under
    /// an older generation must not store its device.
    private var pairingGeneration = 0
    /// Changes only when the pairing sheet opens or closes, unlike
    /// `pairingGeneration`, so work of a closed sheet can tell it is stale.
    private var pairingSession = 0
    private var pairingConnection: RemoteLinkConnection?
    /// The one-time secret of the QR code. Memory only: never logged, never
    /// written to disk or to the TXT record.
    private var pairingSecret: PairingSecret?
    private var pairingSecretGeneration = 0
    /// Running secret attempts, so closing pairing can abort them.
    private var secretAttempts: [UUID: RemoteLinkConnection] = [:]
    /// Hosts whose secret attempt failed, with the end of their lockout.
    private var lockedOutPairingHosts: [String: Date] = [:]
    /// Devices whose pairing is being stored and answered. A second pairing
    /// of the same device in that time could roll back to the first one's
    /// key instead of the original, so it is answered with pairing-busy.
    private var devicesBeingStored: Set<String> = []

    private struct PairingSecret {
        let value: Data
        let expiresAt: Date
        let generation: Int

        var isLive: Bool { expiresAt > Date() }
    }

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

    /// True from `start()` until `stop()`, also while the listener is still
    /// getting ready.
    var isListening: Bool {
        lock.withLock { listener != nil }
    }

    /// True if no newer listener started since the one with this generation.
    func isCurrentListener(_ generation: Int) -> Bool {
        lock.withLock { listenerGeneration == generation }
    }

    /// True if the listener with this generation is the current one and was
    /// not stopped.
    func isActiveListener(_ generation: Int) -> Bool {
        lock.withLock { listenerGeneration == generation && listener != nil }
    }

    static func computerName() -> String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    }

    func start() throws {
        // The new generation comes first, so the listener stopped here cannot
        // report while its replacement is created.
        let generation = lock.withLock {
            listenerGeneration += 1
            return listenerGeneration
        }
        stop()
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let listener = try NWListener(using: parameters)
        listener.service = makeService(pairing: lock.withLock { pairingApprover != nil })
        // A start that began later owns the server; this listener never starts.
        let installed = lock.withLock {
            guard listenerGeneration == generation else { return false }
            self.listener = listener
            return true
        }
        guard installed else { return }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, isCurrentListener(generation) else { return }
            switch state {
            case .ready:
                onStateChange?(.ready, generation)
            case .failed(let error):
                onStateChange?(.failed(error.localizedDescription), generation)
                stop(generation: generation)
            case .cancelled:
                onStateChange?(.stopped, generation)
            default:
                break
            }
        }
        listener.serviceRegistrationUpdateHandler = { [weak self] change in
            guard let self, isCurrentListener(generation) else { return }
            switch change {
            case .add:
                onAdvertisingChange?(true, generation)
            case .remove:
                onAdvertisingChange?(false, generation)
            @unknown default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        stop(generation: nil)
    }

    /// With a generation, stops only if that listener is still the current
    /// one, so a failed listener cannot stop the one that replaced it.
    private func stop(generation: Int?) {
        let (listener, connections): (NWListener?, [ActiveConnection]) = lock.withLock {
            guard generation == nil || generation == listenerGeneration else { return (nil, []) }
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
    /// the code of a code request to the user and returns their decision.
    /// Also creates the secret for the QR code (`pairingInvitation`), which
    /// pairs without asking the approver. Opening pairing anew lifts the
    /// lockouts of hosts whose secret attempt failed.
    func openPairing(approver: @escaping PairingApprover) {
        let listener = lock.withLock {
            pairingApprover = approver
            pairingGeneration += 1
            pairingSession += 1
            lockedOutPairingHosts.removeAll()
            renewPairingSecretLocked()
            return self.listener
        }
        listener?.service = makeService(pairing: true)
        onPairingInvitationChange?()
    }

    /// What the QR code in the pairing sheet carries, while pairing is open
    /// and the secret is neither used nor expired.
    var pairingInvitation: RemoteLinkPairingInvitation? {
        let secret: Data? = lock.withLock {
            guard pairingApprover != nil, let pairingSecret, pairingSecret.isLive else { return nil }
            return pairingSecret.value
        }
        guard let secret else { return nil }
        return RemoteLinkPairingInvitation(serverID: store.serverID, secret: secret, name: serverName())
    }

    /// Stops accepting pairing requests and aborts one that is in progress,
    /// even if the user already approved it.
    func closePairing() {
        let (listener, connection, attempts) = lock.withLock {
            pairingApprover = nil
            pairingGeneration += 1
            pairingSession += 1
            pairingSecret = nil
            let current = (self.listener, pairingConnection, Array(secretAttempts.values))
            pairingConnection = nil
            return current
        }
        connection?.close()
        attempts.forEach { $0.close() }
        listener?.service = makeService(pairing: false)
        onPairingInvitationChange?()
    }

    /// Creates a new secret and schedules its renewal at expiry, so an open
    /// pairing sheet always shows a valid QR code. Call with `lock` held.
    private func renewPairingSecretLocked() {
        pairingSecretGeneration += 1
        let generation = pairingSecretGeneration
        let lifetime = pairingSecretLifetime
        pairingSecret = PairingSecret(
            value: RemoteLinkPairingInvitation.randomSecret(),
            expiresAt: Date().addingTimeInterval(lifetime),
            generation: generation
        )
        queue.asyncAfter(deadline: .now() + lifetime) { [weak self] in
            self?.pairingSecretExpired(generation: generation)
        }
    }

    private func pairingSecretExpired(generation: Int) {
        // A secret that was used, replaced or dropped with the sheet stays gone.
        let renewed = lock.withLock {
            guard pairingApprover != nil, pairingSecret?.generation == generation else { return false }
            renewPairingSecretLocked()
            return true
        }
        if renewed {
            onPairingInvitationChange?()
        }
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
        return NWListener.Service(type: RemoteLink.bonjourType, txtRecord: txtRecord(pairing: pairing))
    }

    /// Never carries the pairing secret, only that pairing is open and how.
    func txtRecord(pairing: Bool) -> NWTXTRecord {
        var txt = NWTXTRecord()
        txt[RemoteLink.txtVersionKey] = String(RemoteLink.protocolVersion)
        txt[RemoteLink.txtServerIDKey] = store.serverID
        if pairing {
            txt[RemoteLink.txtPairingKey] = "1"
            txt[RemoteLink.txtPairingMethodsKey] = Self.offeredPairingMethods.map(\.rawValue).joined(separator: ",")
        }
        return txt
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
                try await servePairing(request: first, connection: connection, id: id)
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

    private enum SecretAttemptClaim {
        case claimed(secret: PairingSecret, generation: Int, session: Int, host: String)
        case noSecret
        case lockedOut
        case busy
    }

    private func servePairing(request: RemoteLinkHandshake, connection: RemoteLinkConnection, id: UUID) async throws {
        guard let deviceID = request.deviceID,
              UUID(uuidString: deviceID) != nil,
              let commitment = request.commitment,
              commitment.count == 32 else {
            throw RemoteLinkError.malformedHandshake
        }

        // Method choice: a request that offers the secret gets it while the
        // QR code is valid. One that offers nothing else gets no code
        // request in the sheet. Everything else, also old clients without
        // `methods`, compares the code as before.
        let methods = request.methods ?? []
        if methods.contains(RemoteLinkPairingMethod.secret.rawValue) {
            switch claimSecretAttempt(id: id, connection: connection) {
            case .claimed(let secret, let generation, let session, let host):
                try await serveSecretPairing(
                    request: request,
                    deviceID: deviceID,
                    commitment: commitment,
                    secret: secret,
                    generation: generation,
                    session: session,
                    host: host,
                    connection: connection,
                    id: id
                )
                return
            case .lockedOut:
                try await connection.send(.error(.pairingFailed))
                return
            case .busy:
                try await connection.send(.error(.pairingBusy))
                return
            case .noSecret:
                if methods.allSatisfy({ $0 == RemoteLinkPairingMethod.secret.rawValue }) {
                    try await connection.send(.error(.pairingFailed))
                    return
                }
            }
        }

        let claimed: (approver: PairingApprover, generation: Int)? = lock.withLock {
            guard let pairingApprover, !isPairingInProgress, !isLockedOutLocked(id: id) else { return nil }
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

        guard beginStoringPairing(of: deviceID) else {
            try? await connection.send(.error(.pairingBusy))
            return
        }
        defer { endStoringPairing(of: deviceID) }

        let device = RemoteLinkDevice(id: deviceID, name: deviceName, pairedAt: Date(), lastSeenAt: nil)
        let replaced = try store.addDevice(device, key: pairingKey)
        do {
            try await connection.send(RemoteLinkHandshake(
                type: .pairApproved,
                proof: transcript.proof(.serverApproved, key: pairingKey)
            ))
        } catch {
            // The device never learns that pairing succeeded, so it keeps no
            // new key either; a pairing it had before stays valid.
            store.rollBack(deviceID: deviceID, addedKey: pairingKey, replaced: replaced)
            throw error
        }
        pairedDevice = device
        onDevicesChange?()
    }

    // MARK: - Pairing with the QR secret

    private func claimSecretAttempt(id: UUID, connection: RemoteLinkConnection) -> SecretAttemptClaim {
        lock.withLock {
            guard let host = activeConnections[id]?.host,
                  pairingApprover != nil,
                  let pairingSecret,
                  pairingSecret.isLive else {
                return .noSecret
            }
            guard !isLockedOutLocked(id: id) else { return .lockedOut }
            guard secretAttempts.count < Self.maxSecretPairingAttempts else { return .busy }
            secretAttempts[id] = connection
            return .claimed(secret: pairingSecret, generation: pairingGeneration, session: pairingSession, host: host)
        }
    }

    /// True if the connection's host is still locked out of pairing. Call
    /// with `lock` held.
    private func isLockedOutLocked(id: UUID) -> Bool {
        guard let host = activeConnections[id]?.host, let lockedUntil = lockedOutPairingHosts[host] else { return false }
        guard lockedUntil > Date() else {
            lockedOutPairingHosts[host] = nil
            return false
        }
        return true
    }

    /// Pairs a device that scanned the QR code. No approver and no slot:
    /// the proofs decide. A failed attempt keeps the secret and locks the
    /// host out of pairing for `pairingFailureLockout`.
    private func serveSecretPairing(
        request: RemoteLinkHandshake,
        deviceID: String,
        commitment: Data,
        secret: PairingSecret,
        generation: Int,
        session: Int,
        host: String,
        connection: RemoteLinkConnection,
        id: UUID
    ) async throws {
        defer {
            lock.withLock { secretAttempts[id] = nil }
        }

        let deviceName = Self.sanitizedDeviceName(request.name)
        let serverID = store.serverID
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let serverNonce = RemoteLinkCrypto.randomNonce()
        let transcript: RemoteLinkPairingTranscript
        let pairingKey: SymmetricKey
        do {
            try await connection.send(RemoteLinkHandshake(
                type: .pairChallenge,
                serverID: serverID,
                name: serverName(),
                nonce: serverNonce,
                key: privateKey.publicKey.rawRepresentation,
                method: RemoteLinkPairingMethod.secret.rawValue
            ))

            let reveal = try await connection.receiveHandshake(timeout: secretPairingStepTimeout).expecting(.pairReveal)
            guard let clientKey = reveal.key,
                  let clientNonce = reveal.nonce,
                  clientNonce.count == RemoteLink.nonceSize,
                  RemoteLinkCrypto.commitment(clientKey: clientKey, clientNonce: clientNonce) == commitment else {
                lockOutSecretAttempt(host: host, session: session)
                try? await connection.send(.error(.pairingFailed))
                throw RemoteLinkError.commitmentMismatch
            }

            transcript = RemoteLinkPairingTranscript(
                deviceID: deviceID,
                serverID: serverID,
                clientKey: clientKey,
                serverKey: privateKey.publicKey.rawRepresentation,
                clientNonce: clientNonce,
                serverNonce: serverNonce
            )
            pairingKey = try transcript.pairingKey(privateKey: privateKey, peerKey: clientKey)

            let confirm = try await connection.receiveHandshake(timeout: secretPairingStepTimeout).expecting(.pairConfirm)
            // Both checks are constant time (`HMAC.isValidAuthenticationCode`).
            guard let proof = confirm.proof,
                  transcript.isValidProof(proof, label: .clientConfirmed, key: pairingKey),
                  let secretProof = confirm.secretProof,
                  transcript.isValidSecretProof(secretProof, role: .client, secret: secret.value) else {
                // Locked out before the answer goes out, so a retry cannot
                // arrive first.
                lockOutSecretAttempt(host: host, session: session)
                try? await connection.send(.error(.pairingFailed))
                throw RemoteLinkError.authenticationFailed
            }
        } catch {
            // A timeout or a dropped connection counts as a failed attempt too.
            lockOutSecretAttempt(host: host, session: session)
            throw error
        }
        // From here on the device has proved the secret, so nothing that
        // follows locks it out.

        // Before the secret is burnt, so a busy device keeps a usable QR code.
        guard beginStoringPairing(of: deviceID) else {
            try? await connection.send(.error(.pairingBusy))
            return
        }
        defer { endStoringPairing(of: deviceID) }

        // Burns the secret, so only one device pairs with it. The new
        // generation also keeps a code request that is still waiting from
        // storing its device.
        let burnt: ActiveConnection?? = lock.withLock {
            guard pairingApprover != nil,
                  pairingGeneration == generation,
                  pairingSecret?.generation == secret.generation,
                  secret.isLive else {
                return nil
            }
            pairingSecret = nil
            pairingGeneration += 1
            let pending = pairingConnection.flatMap { pending in
                activeConnections.values.first { $0.connection === pending }
            }
            return .some(pending)
        }
        guard let pendingCodeRequest = burnt else {
            try? await connection.send(.error(.pairingFailed))
            return
        }
        onPairingInvitationChange?()

        let device = RemoteLinkDevice(id: deviceID, name: deviceName, pairedAt: Date(), lastSeenAt: nil)
        do {
            let replaced = try store.addDevice(device, key: pairingKey)
            do {
                try await connection.send(RemoteLinkHandshake(
                    type: .pairApproved,
                    proof: transcript.proof(.serverApproved, key: pairingKey),
                    secretProof: transcript.secretProof(.server, secret: secret.value)
                ))
            } catch {
                // The device never learns that pairing succeeded, so it keeps
                // no new key either; a pairing it had before stays valid.
                store.rollBack(deviceID: deviceID, addedKey: pairingKey, replaced: replaced)
                throw error
            }
        } catch {
            // The used secret stays invalid, since the device may have seen
            // the approval; the sheet that is still open gets a new QR code.
            renewPairingSecretAfterFailure(session: session)
            throw error
        }
        onDevicesChange?()
        onPairingFinished?(device)

        // A code request that waits in the sheet is declined, and its wait
        // for the user's decision ends.
        if let pending = pendingCodeRequest {
            try? await pending.connection.send(RemoteLinkHandshake(type: .pairDenied))
            pending.connection.close()
            pending.task.cancel()
        }
    }

    /// Claims the device ID from storing its pairing until the approval was
    /// sent or rolled back.
    private func beginStoringPairing(of deviceID: String) -> Bool {
        lock.withLock { devicesBeingStored.insert(deviceID).inserted }
    }

    private func endStoringPairing(of deviceID: String) {
        lock.withLock { _ = devicesBeingStored.remove(deviceID) }
    }

    /// Locks the host out, but only for the sheet that admitted the attempt.
    /// An attempt that ends because the user closed or reopened the sheet
    /// did not fail, and must not block the phone from the new QR code.
    private func lockOutSecretAttempt(host: String, session: Int) {
        lock.withLock {
            guard pairingApprover != nil, pairingSession == session else { return }
            lockedOutPairingHosts[host] = Date().addingTimeInterval(pairingFailureLockout)
        }
    }

    private func renewPairingSecretAfterFailure(session: Int) {
        let renewed = lock.withLock {
            guard pairingApprover != nil, pairingSession == session, pairingSecret == nil else { return false }
            renewPairingSecretLocked()
            return true
        }
        if renewed {
            onPairingInvitationChange?()
        }
    }

    static func sanitizedDeviceName(_ name: String?) -> String {
        let trimmed = (name ?? "")
            .components(separatedBy: .controlCharacters)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultDeviceName : String(trimmed.prefix(64))
    }

    /// The name of a device that sent none. Phones and tablets of any kind pair.
    static let defaultDeviceName = "Device"
}
