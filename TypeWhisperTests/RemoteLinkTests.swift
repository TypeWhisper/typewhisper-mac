import CryptoKit
import Network
import XCTest
@testable import TypeWhisper

final class RemoteLinkTests: XCTestCase {
    // The iOS repository runs the same known-answer test with the same values.
    func testKnownAnswerVectorsMatchTheSharedProtocol() throws {
        let clientKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x11, count: 32))
        let serverKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x22, count: 32))
        let transcript = RemoteLinkPairingTranscript(
            deviceID: "6F1C2B8E-0000-4000-8000-000000000001",
            serverID: "6F1C2B8E-0000-4000-8000-000000000002",
            clientKey: clientKey.publicKey.rawRepresentation,
            serverKey: serverKey.publicKey.rawRepresentation,
            clientNonce: Data(repeating: 0x33, count: 32),
            serverNonce: Data(repeating: 0x44, count: 32)
        )

        XCTAssertEqual(
            RemoteLinkCrypto.commitment(clientKey: transcript.clientKey, clientNonce: transcript.clientNonce).base64EncodedString(),
            "Txbb2g9KtoE8kWrh9GT96vvEt41cOWfO/aLrp4slaCk="
        )
        XCTAssertEqual(transcript.digest.base64EncodedString(), "AFtNqLTyjBTktbjzb8VN6wCyXC1fdXUz8b+voU/4SZI=")
        XCTAssertEqual(transcript.verificationCode, "636092")

        let clientPairingKey = try transcript.pairingKey(privateKey: clientKey, peerKey: transcript.serverKey)
        let serverPairingKey = try transcript.pairingKey(privateKey: serverKey, peerKey: transcript.clientKey)
        XCTAssertEqual(clientPairingKey, serverPairingKey)
        XCTAssertEqual(
            clientPairingKey.withUnsafeBytes { Data($0) }.base64EncodedString(),
            "VjioQZ2TeImG97OFhI/MJcz3gUurUW1uFRdpOA5lhV8="
        )
        XCTAssertEqual(
            transcript.proof(.serverApproved, key: clientPairingKey).base64EncodedString(),
            "OT1uXquIDY7k3BECGiXgiu37/gzaNiko1yY4lrJiW58="
        )

        let clientEphemeral = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x55, count: 32))
        let serverEphemeral = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x66, count: 32))
        let ephemeralSecret = try RemoteLinkSessionKeys.ephemeralSecret(
            privateKey: clientEphemeral,
            peerKey: serverEphemeral.publicKey.rawRepresentation
        )
        XCTAssertEqual(
            try RemoteLinkSessionKeys.ephemeralSecret(privateKey: serverEphemeral, peerKey: clientEphemeral.publicKey.rawRepresentation),
            ephemeralSecret
        )
        XCTAssertEqual(ephemeralSecret.base64EncodedString(), "VZ7SFxuY+gwPQXt4tcWkPpcZkNdgWGADjZQChNMkUUI=")
        XCTAssertThrowsError(try RemoteLinkSessionKeys.ephemeralSecret(privateKey: clientEphemeral, peerKey: Data(count: 32)))

        let keys = RemoteLinkSessionKeys(
            pairingKey: clientPairingKey,
            ephemeralSecret: ephemeralSecret,
            deviceID: transcript.deviceID,
            serverID: transcript.serverID,
            clientNonce: transcript.clientNonce,
            serverNonce: transcript.serverNonce,
            role: .client
        )
        var sealer = RemoteLinkSealer(key: keys.sending)
        let frames = try sealer.seal(message: Data("GET /v1/status HTTP/1.1\r\n\r\n".utf8))
        XCTAssertEqual(
            frames.map { $0.encoded().base64EncodedString() },
            ["AgAAACzeaJ/MWethTEVqhPqK6hAk4mM9W/yOXat1TrZl08PYhmsBiTWeFSCCbXXJFA=="]
        )
    }

    func testSealedMessagesRoundTripAcrossChunksAndRejectTamperingAndReordering() throws {
        let pairingKey = SymmetricKey(size: .bits256)
        let ephemeralSecret = RemoteLinkCrypto.randomNonce()
        let clientNonce = RemoteLinkCrypto.randomNonce()
        let serverNonce = RemoteLinkCrypto.randomNonce()
        let client = RemoteLinkSessionKeys(pairingKey: pairingKey, ephemeralSecret: ephemeralSecret, deviceID: "d", serverID: "s", clientNonce: clientNonce, serverNonce: serverNonce, role: .client)
        let server = RemoteLinkSessionKeys(pairingKey: pairingKey, ephemeralSecret: ephemeralSecret, deviceID: "d", serverID: "s", clientNonce: clientNonce, serverNonce: serverNonce, role: .server)

        let message = Data((0..<(RemoteLink.maxChunkSize * 2 + 17)).map { UInt8(truncatingIfNeeded: $0) })
        var sealer = RemoteLinkSealer(key: client.sending)
        let frames = try sealer.seal(message: message)
        XCTAssertEqual(frames.count, 3)

        var opener = RemoteLinkOpener(key: server.receiving)
        XCTAssertNil(try opener.open(frames[0]))
        XCTAssertNil(try opener.open(frames[1]))
        XCTAssertEqual(try opener.open(frames[2]), message)

        var reordered = RemoteLinkOpener(key: server.receiving)
        XCTAssertThrowsError(try reordered.open(frames[1])) { error in
            XCTAssertEqual(error as? RemoteLinkError, .authenticationFailed)
        }

        var tamperedPayload = frames[0].payload
        tamperedPayload[tamperedPayload.startIndex + 3] ^= 0x01
        var tampered = RemoteLinkOpener(key: server.receiving)
        XCTAssertThrowsError(try tampered.open(RemoteLinkFrame(kind: .sealed, payload: tamperedPayload)))

        var wrongDirection = RemoteLinkOpener(key: client.receiving)
        XCTAssertThrowsError(try wrongDirection.open(frames[0]))
    }

    func testFrameDecoderHandlesSplitInputAndRejectsInvalidFrames() throws {
        let handshake = try RemoteLinkHandshake(type: .hello, deviceID: "device", nonce: Data([1, 2, 3])).frame()
        let encoded = handshake.encoded()
        var decoder = RemoteLinkFrameDecoder()
        for byte in encoded.dropLast() {
            decoder.append(Data([byte]))
            XCTAssertNil(try decoder.nextFrame())
        }
        decoder.append(encoded.suffix(1))
        XCTAssertEqual(try decoder.nextFrame(), handshake)

        decoder.append(encoded + encoded.prefix(3))
        XCTAssertEqual(try RemoteLinkHandshake(frame: XCTUnwrap(decoder.nextFrame())).deviceID, "device")
        XCTAssertNil(try decoder.nextFrame())

        var unknownKind = RemoteLinkFrameDecoder()
        unknownKind.append(Data([9, 0, 0, 0, 0]))
        XCTAssertThrowsError(try unknownKind.nextFrame())

        var oversized = RemoteLinkFrameDecoder()
        oversized.append(Data([1, 0, 1, 0, 0]))
        XCTAssertThrowsError(try oversized.nextFrame()) { error in
            XCTAssertEqual(error as? RemoteLinkError, .frameTooLarge)
        }
    }

    func testHandshakeTurnsPeerErrorsIntoThrownErrors() {
        XCTAssertThrowsError(try RemoteLinkHandshake.error(.unknownDevice).expecting(.welcome)) { error in
            XCTAssertEqual(error as? RemoteLinkError, .remoteError("unknown-device"))
        }
        XCTAssertThrowsError(try RemoteLinkHandshake(type: .welcome, version: 2).expecting(.welcome)) { error in
            XCTAssertEqual(error as? RemoteLinkError, .unsupportedVersion)
        }
    }

    func testRemoteRequestsReachOnlyAllowlistedRoutesWithoutTheLocalToken() async {
        let router = APIRouter(authenticationProvider: { .required(token: "local-token") })
        router.register("GET", "/v1/models") { _ in .json(["ok": true]) }
        router.register("GET", "/v1/history") { _ in .json(["history": true]) }

        let allowed = await RemoteLinkServer.response(
            for: Data("GET /v1/models HTTP/1.1\r\nHost: 192.168.1.20\r\n\r\n".utf8),
            router: router,
            deviceID: "device"
        )
        let blocked = await RemoteLinkServer.response(
            for: Data("GET /v1/history HTTP/1.1\r\n\r\n".utf8),
            router: router,
            deviceID: "device"
        )
        let malformed = await RemoteLinkServer.response(for: Data("nonsense\r\n\r\n".utf8), router: router, deviceID: "device")
        let viaLoopbackAPI = await router.route(
            HTTPRequest(method: "GET", path: "/v1/models", queryParams: [:], headers: [:], body: Data())
        )

        XCTAssertEqual(allowed.status, 200)
        XCTAssertEqual(blocked.status, 403)
        XCTAssertEqual(malformed.status, 400)
        XCTAssertEqual(viaLoopbackAPI.status, 401)
    }

    func testDeviceStoreKeepsKeysInTheInjectedKeychainAndForgetsRemovedDevices() throws {
        let (store, keychain) = Self.makeStore()
        let key = SymmetricKey(size: .bits256)
        let device = RemoteLinkDevice(id: UUID().uuidString, name: "iPhone", pairedAt: Date(), lastSeenAt: nil)

        XCTAssertEqual(store.serverID, store.serverID)
        try store.addDevice(device, key: key)
        XCTAssertEqual(store.pairingKey(for: device.id), key)
        XCTAssertNotNil(keychain.get()[device.id])

        store.markSeen(id: device.id, at: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(store.devices().first?.lastSeenAt, Date(timeIntervalSince1970: 100))

        store.removeDevice(id: device.id)
        XCTAssertTrue(store.devices().isEmpty)
        XCTAssertNil(store.pairingKey(for: device.id))
        XCTAssertNil(keychain.get()[device.id])
    }

    func testDeviceNamesAreTrimmedAndBounded() {
        XCTAssertEqual(RemoteLinkServer.sanitizedDeviceName(" Marco’s iPhone\n"), "Marco’s iPhone")
        XCTAssertEqual(RemoteLinkServer.sanitizedDeviceName(nil), "iPhone")
        XCTAssertEqual(RemoteLinkServer.sanitizedDeviceName(String(repeating: "a", count: 200)).count, 64)
    }

    func testLoopbackPairingThenSealedRequestsOverRealConnections() async throws {
        let (store, _) = Self.makeStore()
        let router = APIRouter(authenticationProvider: { .required(token: "local-token") })
        router.register("POST", "/v1/transcribe") { request in
            .json(["text": String(decoding: request.body, as: UTF8.self)])
        }
        router.register("GET", "/v1/history") { _ in .json(["history": true]) }

        let server = RemoteLinkServer(router: router, store: store, serverName: { "Test Mac" }, advertises: false)
        let shownCode = RemoteLinkLockedValue<String?>(nil)
        try server.start()
        defer { server.stop() }
        let endpoint = try await Self.endpoint(of: server)

        // Pairing is refused while the Mac has no pairing sheet open.
        let refused = try await Self.pair(endpoint: endpoint, deviceID: UUID().uuidString)
        XCTAssertEqual(refused.error, .remoteError("pairing-closed"))

        server.openPairing { request in
            shownCode.set(request.code)
            return true
        }
        let deviceID = UUID().uuidString
        let paired = try await Self.pair(endpoint: endpoint, deviceID: deviceID)
        let pairingKey = try XCTUnwrap(paired.key)
        XCTAssertEqual(shownCode.get(), paired.code)
        XCTAssertEqual(store.devices().map(\.id), [deviceID])
        XCTAssertEqual(store.devices().first?.name, "Test iPhone")
        server.closePairing()

        let transcribed = try await Self.send(
            "POST /v1/transcribe HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello",
            endpoint: endpoint,
            deviceID: deviceID,
            key: pairingKey
        )
        XCTAssertTrue(transcribed.hasPrefix("HTTP/1.1 200"), transcribed)
        XCTAssertTrue(transcribed.contains("\"text\":\"hello\""), transcribed)
        XCTAssertNotNil(store.devices().first?.lastSeenAt)

        let history = try await Self.send("GET /v1/history HTTP/1.1\r\n\r\n", endpoint: endpoint, deviceID: deviceID, key: pairingKey)
        XCTAssertTrue(history.hasPrefix("HTTP/1.1 403"), history)

        do {
            _ = try await Self.send("GET /v1/history HTTP/1.1\r\n\r\n", endpoint: endpoint, deviceID: UUID().uuidString, key: pairingKey)
            XCTFail("An unknown device must be rejected")
        } catch {
            XCTAssertEqual(error as? RemoteLinkError, .remoteError("unknown-device"))
        }

        do {
            _ = try await Self.send(
                "GET /v1/models HTTP/1.1\r\n\r\n",
                endpoint: endpoint,
                deviceID: deviceID,
                key: SymmetricKey(size: .bits256)
            )
            XCTFail("A wrong key must not produce a response")
        } catch {
            XCTAssertEqual(error as? RemoteLinkError, .remoteError("authentication-failed"))
        }
    }

    func testDeniedPairingStoresNothing() async throws {
        let (store, _) = Self.makeStore()
        let server = RemoteLinkServer(router: APIRouter(), store: store, serverName: { "Test Mac" }, advertises: false)
        try server.start()
        defer { server.stop() }
        let endpoint = try await Self.endpoint(of: server)
        server.openPairing { _ in false }

        let result = try await Self.pair(endpoint: endpoint, deviceID: UUID().uuidString)
        XCTAssertNil(result.key)
        XCTAssertNotNil(result.error)
        XCTAssertTrue(store.devices().isEmpty)
    }

    func testOneHostCannotOccupyEveryConnectionSlot() async throws {
        let (store, _) = Self.makeStore()
        let server = RemoteLinkServer(router: APIRouter(), store: store, serverName: { "Test Mac" }, advertises: false)
        try server.start()
        defer { server.stop() }
        let endpoint = try await Self.endpoint(of: server)

        var idle: [RemoteLinkConnection] = []
        defer { idle.forEach { $0.close() } }
        for _ in 0..<RemoteLinkServer.maxConnectionsPerHost {
            let connection = RemoteLinkConnection(endpoint: endpoint)
            try await connection.start(timeout: 5)
            idle.append(connection)
        }
        // Let the server register the idle connections before the next one arrives.
        try await Task.sleep(for: .milliseconds(200))

        let rejected = RemoteLinkConnection(endpoint: endpoint)
        defer { rejected.close() }
        try await rejected.start(timeout: 5)
        do {
            _ = try await rejected.receiveFrame(timeout: 5)
            XCTFail("The server must refuse a connection beyond the per-host limit")
        } catch {
            XCTAssertNotEqual(error as? RemoteLinkError, .timedOut)
        }
    }

    func testRemovingADeviceClosesItsOpenSession() async throws {
        let (store, _) = Self.makeStore()
        let router = APIRouter()
        router.register("GET", "/v1/status") { _ in .json(["status": "ready"]) }
        let server = RemoteLinkServer(router: router, store: store, serverName: { "Test Mac" }, advertises: false)
        try server.start()
        defer { server.stop() }
        let endpoint = try await Self.endpoint(of: server)
        server.openPairing { _ in true }
        let deviceID = UUID().uuidString
        let paired = try await Self.pair(endpoint: endpoint, deviceID: deviceID)
        let pairingKey = try XCTUnwrap(paired.key)
        server.closePairing()

        let (connection, channel) = try await Self.openSession(endpoint: endpoint, deviceID: deviceID, key: pairingKey)
        defer { connection.close() }
        try await Task.sleep(for: .milliseconds(100))
        server.removeDevice(id: deviceID)

        do {
            try await channel.send(message: Data("GET /v1/status HTTP/1.1\r\n\r\n".utf8))
            _ = try await channel.receiveMessage(timeout: 5)
            XCTFail("A removed device must not get a response on an open session")
        } catch {
            XCTAssertNotEqual(error as? RemoteLinkError, .timedOut)
        }
    }

    func testClosingThePairingSheetAfterApprovalStoresNothing() async throws {
        let (store, _) = Self.makeStore()
        let server = RemoteLinkServer(router: APIRouter(), store: store, serverName: { "Test Mac" }, advertises: false)
        try server.start()
        defer { server.stop() }
        let endpoint = try await Self.endpoint(of: server)
        server.openPairing { _ in
            server.closePairing()
            return true
        }

        let result = try await Self.pair(endpoint: endpoint, deviceID: UUID().uuidString)
        XCTAssertNil(result.key)
        XCTAssertTrue(store.devices().isEmpty)
    }

    func testDisconnectingCancelsTheWorkOnTheMac() async throws {
        let (store, _) = Self.makeStore()
        let router = APIRouter()
        let cancelled = RemoteLinkLockedValue(false)
        router.register("POST", "/v1/llm/process") { _ in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                cancelled.set(true)
            }
            return .json(["text": "late"])
        }
        let server = RemoteLinkServer(router: router, store: store, serverName: { "Test Mac" }, advertises: false)
        try server.start()
        defer { server.stop() }
        let endpoint = try await Self.endpoint(of: server)
        server.openPairing { _ in true }
        let deviceID = UUID().uuidString
        let paired = try await Self.pair(endpoint: endpoint, deviceID: deviceID)
        let pairingKey = try XCTUnwrap(paired.key)
        server.closePairing()

        let (connection, channel) = try await Self.openSession(endpoint: endpoint, deviceID: deviceID, key: pairingKey)
        let body = #"{"system_prompt":"x","text":"hello"}"#
        try await channel.send(message: Data("POST /v1/llm/process HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8))
        try await Task.sleep(for: .milliseconds(200))
        connection.close()

        for _ in 0..<50 where !cancelled.get() {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(cancelled.get(), "Closing the connection must cancel the running request")
    }

    func testDeadlineAndCancellationCloseAWaitingConnection() async throws {
        let (store, _) = Self.makeStore()
        let server = RemoteLinkServer(router: APIRouter(), store: store, serverName: { "Test Mac" }, advertises: false)
        try server.start()
        defer { server.stop() }
        let endpoint = try await Self.endpoint(of: server)

        let expiring = RemoteLinkConnection(endpoint: endpoint)
        defer { expiring.close() }
        try await expiring.start(timeout: 5)
        let started = Date()
        do {
            _ = try await expiring.withDeadline(0.3) { try await expiring.receiveFrame(timeout: nil) }
            XCTFail("The deadline must end the wait")
        } catch {
            XCTAssertEqual(error as? RemoteLinkError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)

        let cancelled = RemoteLinkConnection(endpoint: endpoint)
        defer { cancelled.close() }
        try await cancelled.start(timeout: 5)
        let waiting = Task {
            try await cancelled.withDeadline(30) { try await cancelled.receiveFrame(timeout: nil) }
        }
        try await Task.sleep(for: .milliseconds(100))
        waiting.cancel()
        do {
            _ = try await waiting.value
            XCTFail("Cancellation must end the wait")
        } catch {
            XCTAssertTrue(error is CancellationError, String(describing: error))
        }
    }

    func testReplacedAndStoppedListenersReportNoState() async throws {
        let (store, _) = Self.makeStore()
        let server = RemoteLinkServer(router: APIRouter(), store: store, serverName: { "Test Mac" }, advertises: false)
        let states = RemoteLinkLockedValue<[RemoteLinkServer.State]>([])
        server.onStateChange = { state in states.set(states.get() + [state]) }
        try server.start()
        try server.start()
        defer { server.stop() }
        _ = try await Self.endpoint(of: server)
        for _ in 0..<100 where states.get().isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(300))
        // The cancelled first listener must not report `.stopped`.
        XCTAssertEqual(states.get(), [.ready])
        XCTAssertTrue(server.isListening)

        server.stop()
        XCTAssertFalse(server.isListening)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(states.get(), [.ready])
    }

    @MainActor
    func testPremiumChangeWhileStartingKeepsTheListener() async throws {
        let (store, _) = Self.makeStore()
        let server = RemoteLinkServer(router: APIRouter(), store: store, serverName: { "Test Mac" }, advertises: false)
        let defaults = UserDefaults(suiteName: "RemoteLinkTests-\(UUID().uuidString)")!
        defaults.set(true, forKey: UserDefaultsKeys.remoteLinkEnabled)
        let viewModel = RemoteLinkViewModel(server: server, defaults: defaults, premiumAccess: { true })
        defer { viewModel.stop() }

        viewModel.startIfEnabled()
        // Wait without yielding the main actor, so the view model has not
        // seen `.ready` yet, like a premium update that arrives at launch.
        let deadline = Date().addingTimeInterval(5)
        while (server.port ?? 0) == 0, Date() < deadline {
            usleep(10_000)
        }
        let port = try XCTUnwrap(server.port)
        XCTAssertFalse(viewModel.isRunning)
        viewModel.premiumAccessChanged()

        for _ in 0..<100 where !viewModel.isRunning {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(viewModel.isRunning)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(viewModel.isRunning)
        XCTAssertEqual(server.port, port, "The listener must not be restarted")
    }

    // MARK: - Helpers

    private static func openSession(
        endpoint: NWEndpoint,
        deviceID: String,
        key: SymmetricKey
    ) async throws -> (RemoteLinkConnection, RemoteLinkChannel) {
        let connection = RemoteLinkConnection(endpoint: endpoint)
        try await connection.start(timeout: 5)
        let clientNonce = RemoteLinkCrypto.randomNonce()
        let ephemeralKey = Curve25519.KeyAgreement.PrivateKey()
        try await connection.send(RemoteLinkHandshake(
            type: .hello,
            deviceID: deviceID,
            nonce: clientNonce,
            key: ephemeralKey.publicKey.rawRepresentation
        ))
        let welcome = try await connection.receiveHandshake(timeout: 5).expecting(.welcome)
        let keys = RemoteLinkSessionKeys(
            pairingKey: key,
            ephemeralSecret: try RemoteLinkSessionKeys.ephemeralSecret(privateKey: ephemeralKey, peerKey: try XCTUnwrap(welcome.key)),
            deviceID: deviceID,
            serverID: try XCTUnwrap(welcome.serverID),
            clientNonce: clientNonce,
            serverNonce: try XCTUnwrap(welcome.nonce),
            role: .client
        )
        return (connection, RemoteLinkChannel(connection: connection, keys: keys))
    }

    private static func makeStore() -> (RemoteLinkDeviceStore, RemoteLinkLockedValue<[String: String]>) {
        let keychain = RemoteLinkLockedValue<[String: String]>([:])
        let defaults = UserDefaults(suiteName: "RemoteLinkTests-\(UUID().uuidString)")!
        let store = RemoteLinkDeviceStore(
            defaults: defaults,
            loadKey: { keychain.get()[$0] },
            saveKey: { id, key in
                var values = keychain.get()
                values[id] = key
                keychain.set(values)
            },
            deleteKey: { id in
                var values = keychain.get()
                values[id] = nil
                keychain.set(values)
            }
        )
        return (store, keychain)
    }

    private static func endpoint(of server: RemoteLinkServer) async throws -> NWEndpoint {
        for _ in 0..<100 {
            if let port = server.port, port != 0 {
                return .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw RemoteLinkError.timedOut
    }

    private struct PairingResult {
        var key: SymmetricKey?
        var code: String?
        var error: RemoteLinkError?
    }

    private static func pair(endpoint: NWEndpoint, deviceID: String) async throws -> PairingResult {
        let connection = RemoteLinkConnection(endpoint: endpoint)
        defer { connection.close() }
        try await connection.start(timeout: 5)

        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let clientKey = privateKey.publicKey.rawRepresentation
        let clientNonce = RemoteLinkCrypto.randomNonce()
        try await connection.send(RemoteLinkHandshake(
            type: .pairRequest,
            deviceID: deviceID,
            name: "Test iPhone",
            commitment: RemoteLinkCrypto.commitment(clientKey: clientKey, clientNonce: clientNonce)
        ))

        do {
            let challenge = try await connection.receiveHandshake(timeout: 5).expecting(.pairChallenge)
            try await connection.send(RemoteLinkHandshake(type: .pairReveal, nonce: clientNonce, key: clientKey))
            let transcript = RemoteLinkPairingTranscript(
                deviceID: deviceID,
                serverID: try XCTUnwrap(challenge.serverID),
                clientKey: clientKey,
                serverKey: try XCTUnwrap(challenge.key),
                clientNonce: clientNonce,
                serverNonce: try XCTUnwrap(challenge.nonce)
            )
            let key = try transcript.pairingKey(privateKey: privateKey, peerKey: transcript.serverKey)
            try await connection.send(RemoteLinkHandshake(type: .pairConfirm, proof: transcript.proof(.clientConfirmed, key: key)))
            let approved = try await connection.receiveHandshake(timeout: 5).expecting(.pairApproved)
            XCTAssertTrue(transcript.isValidProof(try XCTUnwrap(approved.proof), label: .serverApproved, key: key))
            return PairingResult(key: key, code: transcript.verificationCode)
        } catch let error as RemoteLinkError {
            return PairingResult(error: error)
        }
    }

    private static func send(_ request: String, endpoint: NWEndpoint, deviceID: String, key: SymmetricKey) async throws -> String {
        let connection = RemoteLinkConnection(endpoint: endpoint)
        defer { connection.close() }
        try await connection.start(timeout: 5)

        let clientNonce = RemoteLinkCrypto.randomNonce()
        let ephemeralKey = Curve25519.KeyAgreement.PrivateKey()
        try await connection.send(RemoteLinkHandshake(
            type: .hello,
            deviceID: deviceID,
            nonce: clientNonce,
            key: ephemeralKey.publicKey.rawRepresentation
        ))
        let welcome = try await connection.receiveHandshake(timeout: 5).expecting(.welcome)
        let keys = RemoteLinkSessionKeys(
            pairingKey: key,
            ephemeralSecret: try RemoteLinkSessionKeys.ephemeralSecret(privateKey: ephemeralKey, peerKey: try XCTUnwrap(welcome.key)),
            deviceID: deviceID,
            serverID: try XCTUnwrap(welcome.serverID),
            clientNonce: clientNonce,
            serverNonce: try XCTUnwrap(welcome.nonce),
            role: .client
        )
        let channel = RemoteLinkChannel(connection: connection, keys: keys)
        try await channel.send(message: Data(request.utf8))
        return String(decoding: try await channel.receiveMessage(timeout: 5), as: UTF8.self)
    }
}
