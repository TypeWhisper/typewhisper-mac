import Combine
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
        XCTAssertEqual(RemoteLinkServer.sanitizedDeviceName(nil), "Device")
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
        server.onStateChange = { state, _ in states.set(states.get() + [state]) }
        try server.start()
        try server.start()
        defer { server.stop() }
        _ = try await Self.endpoint(of: server)
        for _ in 0..<100 where states.get().isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(300))
        // The first listener may still report `.ready` before it is replaced,
        // but the replaced listener must not report `.stopped`.
        XCTAssertFalse(states.get().isEmpty)
        XCTAssertTrue(states.get().allSatisfy { $0 == .ready }, "\(states.get())")
        XCTAssertTrue(server.isListening)
        let readyCount = states.get().count

        server.stop()
        XCTAssertFalse(server.isListening)
        try await Task.sleep(for: .milliseconds(300))
        // A stopped listener may still report that it stopped, never that it is ready.
        XCTAssertEqual(states.get().filter { $0 == .ready }.count, readyCount)
        XCTAssertNotEqual(states.get().last, .ready)
    }

    @MainActor
    func testReadyWaitingForTheMainActorDoesNotReviveAStoppedListener() async throws {
        let (store, _) = Self.makeStore()
        let server = RemoteLinkServer(router: APIRouter(), store: store, serverName: { "Test Mac" }, advertises: false)
        let defaults = UserDefaults(suiteName: "RemoteLinkTests-\(UUID().uuidString)")!
        defaults.set(true, forKey: UserDefaultsKeys.remoteLinkEnabled)
        let viewModel = RemoteLinkViewModel(server: server, defaults: defaults, premiumAccess: { true })
        defer { viewModel.stop() }

        viewModel.startIfEnabled()
        // Keep the main actor busy until the listener is ready, so `.ready`
        // waits in a main-actor task while the user turns the setting off.
        let deadline = Date().addingTimeInterval(5)
        while (server.port ?? 0) == 0, Date() < deadline {
            usleep(10_000)
        }
        usleep(200_000)
        XCTAssertNotNil(server.port)
        XCTAssertFalse(viewModel.isRunning)
        viewModel.setEnabled(false)
        var runningAfterStop: [Bool] = []
        let observation = viewModel.$isRunning.dropFirst().sink { runningAfterStop.append($0) }
        defer { observation.cancel() }

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(runningAfterStop.contains(true), "A stopped listener reported ready: \(runningAfterStop)")
        XCTAssertFalse(viewModel.isRunning)
        XCTAssertFalse(viewModel.isAdvertised)
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

    // MARK: - Pairing with the QR secret

    // The iOS and Android repositories assert the same values.
    func testSecretProofVectorsMatchTheSharedProtocol() throws {
        let transcript = try Self.knownAnswerTranscript()
        let secret = Data(repeating: 0x77, count: 16)

        XCTAssertEqual(transcript.digest.base64EncodedString(), "AFtNqLTyjBTktbjzb8VN6wCyXC1fdXUz8b+voU/4SZI=")
        let clientProof = transcript.secretProof(.client, secret: secret)
        let serverProof = transcript.secretProof(.server, secret: secret)
        XCTAssertEqual(clientProof.base64EncodedString(), "ADM7ZOtqBIICAFXiEa027yURZ2IViV8hr/JhkD3P14I=")
        XCTAssertEqual(serverProof.base64EncodedString(), "mhjbO3qspWdNmMQKzAe5bqV7v0Py5iYUzc0yEuZxnOo=")

        XCTAssertTrue(transcript.isValidSecretProof(clientProof, role: .client, secret: secret))
        XCTAssertTrue(transcript.isValidSecretProof(serverProof, role: .server, secret: secret))
        XCTAssertFalse(transcript.isValidSecretProof(clientProof, role: .server, secret: secret))
        XCTAssertFalse(transcript.isValidSecretProof(clientProof, role: .client, secret: Data(repeating: 0x78, count: 16)))
        XCTAssertFalse(transcript.isValidSecretProof(
            transcript.secretProof(.client, secret: Data(repeating: 0x77, count: 15)),
            role: .client,
            secret: Data(repeating: 0x77, count: 15)
        ))
    }

    func testPairingInvitationPayloadMatchesTheSharedVector() throws {
        let invitation = RemoteLinkPairingInvitation(
            serverID: "6F1C2B8E-0000-4000-8000-000000000002",
            secret: Data(repeating: 0x77, count: 16),
            name: "Studio Mac"
        )
        let payload = "typewhisper-pair:1?id=6F1C2B8E-0000-4000-8000-000000000002&s=d3d3d3d3d3d3d3d3d3d3dw&n=Studio%20Mac"
        XCTAssertEqual(invitation.payload, payload)
        XCTAssertEqual(RemoteLinkPairingInvitation(payload: payload), invitation)

        // Scheme without case, free query order, unknown keys ignored, no name.
        XCTAssertEqual(
            RemoteLinkPairingInvitation(payload: "TypeWhisper-Pair:1?x=1&s=d3d3d3d3d3d3d3d3d3d3dw&id=6F1C2B8E-0000-4000-8000-000000000002"),
            RemoteLinkPairingInvitation(serverID: "6F1C2B8E-0000-4000-8000-000000000002", secret: Data(repeating: 0x77, count: 16))
        )
        XCTAssertEqual(RemoteLinkPairingInvitation.randomSecret().count, RemoteLink.pairingSecretSize)
        XCTAssertNotEqual(RemoteLinkPairingInvitation.randomSecret(), RemoteLinkPairingInvitation.randomSecret())
    }

    func testPairingInvitationRejectsInvalidPayloads() {
        let id = "6F1C2B8E-0000-4000-8000-000000000002"
        let secret = "d3d3d3d3d3d3d3d3d3d3dw"
        let rejected = [
            "typewhisper-pair:2?id=\(id)&s=\(secret)",
            "typewhisper-pair://1?id=\(id)&s=\(secret)",
            "typewhisper-pair:1?id=\(id)&s=\(RemoteLinkPairingInvitation.encodeBase64URL(Data(repeating: 0x77, count: 15)))",
            "typewhisper-pair:1?id=\(id)&s=\(RemoteLinkPairingInvitation.encodeBase64URL(Data(repeating: 0x77, count: 17)))",
            "typewhisper-pair:1?id=\(id)&s=d3d3d3d3d3d3d3d3d3d3d+",
            "typewhisper-pair:1?id=\(id)&s=d3d3d3d3d3d3d3d3d3d3d/",
            "typewhisper-pair:1?id=\(id)&s=d3d3d3d3d3d3d3d3d3d3dw==",
            "typewhisper-pair:1?id=\(id)&s=d3d3d3d3d3d3d3d3d3d3dx",
            "typewhisper-pair:1?s=\(secret)",
            "typewhisper-pair:1?id=&s=\(secret)",
            "typewhisper-pair:1?id=6F1C_2B8E&s=\(secret)",
            "typewhisper-pair:1?id=\(id)&s=\(secret)&s=\(secret)",
            "typewhisper-pair:1?id=\(id)&s=\(secret)&n=" + String(repeating: "a", count: 512),
        ]
        for payload in rejected {
            XCTAssertNil(RemoteLinkPairingInvitation(payload: payload), payload)
        }
    }

    func testHandshakesOmitThePairingMethodFieldsWhenNil() throws {
        let frame = try RemoteLinkHandshake(type: .pairRequest, deviceID: "device", commitment: Data(count: 32)).frame()
        let json = String(decoding: frame.payload, as: UTF8.self)
        XCTAssertFalse(json.contains("methods"), json)
        XCTAssertFalse(json.contains("secretProof"), json)
        XCTAssertFalse(json.contains("\"method\""), json)
    }

    func testTXTRecordOffersTheSecretOnlyWhilePairingIsOpen() throws {
        let (server, _) = try Self.makeServer()
        defer { server.stop() }
        XCTAssertEqual(server.txtRecord(pairing: true)[RemoteLink.txtPairingMethodsKey], "secret,compare")
        XCTAssertNil(server.txtRecord(pairing: false)[RemoteLink.txtPairingMethodsKey])
        XCTAssertNil(server.txtRecord(pairing: false)[RemoteLink.txtPairingKey])
    }

    func testScannedSecretPairsWithoutAskingTheUserAndIsUsedOnce() async throws {
        let (server, store) = try Self.makeServer()
        defer { server.stop() }
        let endpoint = try await Self.endpoint(of: server)
        let asked = RemoteLinkLockedValue(false)
        let finished = RemoteLinkLockedValue<[RemoteLinkDevice?]>([])
        server.onPairingFinished = { device in finished.set(finished.get() + [device]) }

        XCTAssertNil(server.pairingInvitation)
        server.openPairing { _ in
            asked.set(true)
            return true
        }
        let invitation = try XCTUnwrap(server.pairingInvitation)
        XCTAssertEqual(invitation.serverID, store.serverID)
        XCTAssertEqual(invitation.name, "Studio Mac")
        XCTAssertEqual(invitation.secret.count, RemoteLink.pairingSecretSize)

        let deviceID = UUID().uuidString
        let paired = try await Self.pair(endpoint: endpoint, deviceID: deviceID, methods: Self.secretMethods, secret: invitation.secret)
        XCTAssertNil(paired.error)
        XCTAssertEqual(paired.method, "secret")
        XCTAssertEqual(store.pairingKey(for: deviceID), try XCTUnwrap(paired.key))
        XCTAssertEqual(store.devices().map(\.name), ["Test iPhone"])
        XCTAssertFalse(asked.get(), "A secret attempt must not reach the approver")
        // The device can see the approval before the Mac reports it.
        try await Self.waitUntil { !finished.get().isEmpty }
        XCTAssertEqual(finished.get().compactMap { $0?.id }, [deviceID])

        // The secret is burnt: no QR code until pairing opens again.
        XCTAssertNil(server.pairingInvitation)
        let reused = try await Self.pair(endpoint: endpoint, deviceID: UUID().uuidString, methods: Self.secretMethods, secret: invitation.secret)
        XCTAssertEqual(reused.error, .remoteError("pairing-failed"))
        XCTAssertNil(reused.method)
        XCTAssertEqual(store.devices().map(\.id), [deviceID])

        // Opening pairing again shows a new QR code with a new secret.
        server.openPairing { _ in true }
        XCTAssertNotEqual(try XCTUnwrap(server.pairingInvitation).secret, invitation.secret)
    }

    func testWrongSecretStoresNothingKeepsTheSecretAndLocksTheHostOut() async throws {
        let (server, store) = try Self.makeServer()
        defer { server.stop() }
        server.pairingFailureLockout = 1.5
        let endpoint = try await Self.endpoint(of: server)
        server.openPairing { _ in true }
        let invitation = try XCTUnwrap(server.pairingInvitation)

        let wrong = try await Self.pair(
            endpoint: endpoint,
            deviceID: UUID().uuidString,
            methods: Self.secretMethods,
            secret: RemoteLinkPairingInvitation.randomSecret()
        )
        XCTAssertEqual(wrong.method, "secret")
        XCTAssertEqual(wrong.error, .remoteError("pairing-failed"))
        XCTAssertTrue(store.devices().isEmpty)
        XCTAssertEqual(server.pairingInvitation, invitation, "A wrong proof must not burn the secret")

        // The host is locked out of pairing, with the right secret too and
        // for a code request.
        let lockedOut = try await Self.pair(endpoint: endpoint, deviceID: UUID().uuidString, methods: Self.secretMethods, secret: invitation.secret)
        XCTAssertEqual(lockedOut.error, .remoteError("pairing-failed"))
        let codeRequest = try await Self.pair(endpoint: endpoint, deviceID: UUID().uuidString)
        XCTAssertEqual(codeRequest.error, .remoteError("pairing-busy"))
        XCTAssertTrue(store.devices().isEmpty)

        try await Task.sleep(for: .seconds(1.7))
        let deviceID = UUID().uuidString
        let paired = try await Self.pair(endpoint: endpoint, deviceID: deviceID, methods: Self.secretMethods, secret: invitation.secret)
        XCTAssertNil(paired.error)
        XCTAssertEqual(store.devices().map(\.id), [deviceID])
    }

    func testMissingSecretProofOrConfirmationStoresNothing() async throws {
        let (server, store) = try Self.makeServer()
        defer { server.stop() }
        server.pairingFailureLockout = 0
        server.secretPairingStepTimeout = 0.5
        let endpoint = try await Self.endpoint(of: server)
        server.openPairing { _ in true }
        let invitation = try XCTUnwrap(server.pairingInvitation)

        let missing = try await Self.pair(
            endpoint: endpoint,
            deviceID: UUID().uuidString,
            methods: Self.secretMethods,
            secret: invitation.secret,
            sendsSecretProof: false
        )
        XCTAssertEqual(missing.error, .remoteError("pairing-failed"))
        XCTAssertTrue(store.devices().isEmpty)
        XCTAssertEqual(server.pairingInvitation, invitation)

        // A device that never confirms is dropped after the step timeout.
        let connection = RemoteLinkConnection(endpoint: endpoint)
        defer { connection.close() }
        try await connection.start(timeout: 5)
        let clientKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let clientNonce = RemoteLinkCrypto.randomNonce()
        try await connection.send(RemoteLinkHandshake(
            type: .pairRequest,
            deviceID: UUID().uuidString,
            commitment: RemoteLinkCrypto.commitment(clientKey: clientKey, clientNonce: clientNonce),
            methods: Self.secretMethods
        ))
        _ = try await connection.receiveHandshake(timeout: 5).expecting(.pairChallenge)
        try await connection.send(RemoteLinkHandshake(type: .pairReveal, nonce: clientNonce, key: clientKey))
        let started = Date()
        do {
            _ = try await connection.receiveHandshake(timeout: 5)
            XCTFail("The Mac must not answer without a confirmation")
        } catch {
            XCTAssertNotEqual(error as? RemoteLinkError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertTrue(store.devices().isEmpty)
        XCTAssertEqual(server.pairingInvitation, invitation)
    }

    func testSecretExpiresIsRenewedWhilePairingIsOpenAndDiesWithTheSheet() async throws {
        let (server, store) = try Self.makeServer()
        defer { server.stop() }
        server.pairingSecretLifetime = 0.5
        server.pairingFailureLockout = 0
        let changes = RemoteLinkLockedValue(0)
        server.onPairingInvitationChange = { changes.set(changes.get() + 1) }
        let endpoint = try await Self.endpoint(of: server)
        server.openPairing { _ in true }
        let expired = try XCTUnwrap(server.pairingInvitation)

        try await Self.waitUntil {
            changes.get() >= 2 && server.pairingInvitation.map { $0.secret != expired.secret } == true
        }
        let renewed = try XCTUnwrap(server.pairingInvitation)
        XCTAssertNotEqual(renewed.secret, expired.secret)

        let late = try await Self.pair(endpoint: endpoint, deviceID: UUID().uuidString, methods: Self.secretMethods, secret: expired.secret)
        XCTAssertEqual(late.error, .remoteError("pairing-failed"))
        XCTAssertTrue(store.devices().isEmpty)

        server.closePairing()
        XCTAssertNil(server.pairingInvitation)
        let closed = try await Self.pair(endpoint: endpoint, deviceID: UUID().uuidString, methods: Self.secretMethods, secret: renewed.secret)
        XCTAssertEqual(closed.error, .remoteError("pairing-failed"))
        XCTAssertNil(closed.method)
        XCTAssertTrue(store.devices().isEmpty)
    }

    func testRequestsWithoutTheSecretCompareTheCodeWhileTheQRCodeIsShown() async throws {
        let (server, store) = try Self.makeServer()
        defer { server.stop() }
        let endpoint = try await Self.endpoint(of: server)
        let shownCodes = RemoteLinkLockedValue<[String]>([])
        server.openPairing { request in
            shownCodes.set(shownCodes.get() + [request.code])
            return true
        }
        let invitation = try XCTUnwrap(server.pairingInvitation)

        // An old iPhone sends no methods, a new one that picked the Mac
        // from the list offers the code methods.
        let old = try await Self.pair(endpoint: endpoint, deviceID: UUID().uuidString)
        let fromList = try await Self.pair(endpoint: endpoint, deviceID: UUID().uuidString, methods: ["code-entry", "compare"])
        XCTAssertNil(old.error)
        XCTAssertNil(fromList.error)
        XCTAssertNil(old.method)
        XCTAssertNil(fromList.method)
        XCTAssertEqual(shownCodes.get(), [try XCTUnwrap(old.code), try XCTUnwrap(fromList.code)])
        XCTAssertEqual(store.devices().count, 2)
        XCTAssertEqual(server.pairingInvitation, invitation, "A code pairing must not use up the QR code")

        // A request that also offers the secret gets the secret while it is
        // valid, so it cannot fall back to the code and skip the proof.
        let fallback = try await Self.pair(
            endpoint: endpoint,
            deviceID: UUID().uuidString,
            methods: ["secret", "compare"],
            secret: nil
        )
        XCTAssertEqual(fallback.method, "secret", "A live secret wins over the code")
        XCTAssertNotNil(fallback.error)
        XCTAssertEqual(store.devices().count, 2)
    }

    func testSecretAttemptPairsWhileACodeRequestHoldsTheSlotAndDeclinesIt() async throws {
        let (server, store) = try Self.makeServer()
        defer { server.stop() }
        let endpoint = try await Self.endpoint(of: server)
        let codeRequestArrived = RemoteLinkLockedValue(false)
        server.openPairing { _ in
            codeRequestArrived.set(true)
            // The user never decides.
            try? await Task.sleep(for: .seconds(30))
            return false
        }
        let invitation = try XCTUnwrap(server.pairingInvitation)

        let squatterID = UUID().uuidString
        let squatter = Task {
            try await Self.pair(endpoint: endpoint, deviceID: squatterID, replyTimeout: 10)
        }
        for _ in 0..<100 where !codeRequestArrived.get() {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(codeRequestArrived.get())

        let deviceID = UUID().uuidString
        let paired = try await Self.pair(endpoint: endpoint, deviceID: deviceID, methods: Self.secretMethods, secret: invitation.secret)
        XCTAssertNil(paired.error)

        let declined = try await squatter.value
        XCTAssertNil(declined.key)
        XCTAssertEqual(declined.error, .unexpectedMessage("pair-denied"))
        XCTAssertEqual(store.devices().map(\.id), [deviceID])
    }

    func testAtMostTwoSecretAttemptsRunAtOnce() async throws {
        let (server, _) = try Self.makeServer()
        defer { server.stop() }
        let endpoint = try await Self.endpoint(of: server)
        server.openPairing { _ in true }

        var holding: [RemoteLinkConnection] = []
        defer { holding.forEach { $0.close() } }
        for _ in 0..<RemoteLinkServer.maxSecretPairingAttempts {
            let connection = RemoteLinkConnection(endpoint: endpoint)
            try await connection.start(timeout: 5)
            holding.append(connection)
            let clientKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
            try await connection.send(RemoteLinkHandshake(
                type: .pairRequest,
                deviceID: UUID().uuidString,
                commitment: RemoteLinkCrypto.commitment(clientKey: clientKey, clientNonce: RemoteLinkCrypto.randomNonce()),
                methods: Self.secretMethods
            ))
            let challenge = try await connection.receiveHandshake(timeout: 5).expecting(.pairChallenge)
            XCTAssertEqual(challenge.method, "secret")
        }

        let third = try await Self.pair(
            endpoint: endpoint,
            deviceID: UUID().uuidString,
            methods: Self.secretMethods,
            secret: try XCTUnwrap(server.pairingInvitation).secret
        )
        XCTAssertEqual(third.error, .remoteError("pairing-busy"))
    }

    @MainActor
    func testPairingSheetShowsTheQRCodeAndTheDeviceThatScannedIt() async throws {
        let (store, _) = Self.makeStore()
        let server = RemoteLinkServer(router: APIRouter(), store: store, serverName: { "Studio Mac" }, advertises: false)
        let defaults = UserDefaults(suiteName: "RemoteLinkTests-\(UUID().uuidString)")!
        let viewModel = RemoteLinkViewModel(server: server, defaults: defaults, premiumAccess: { true })
        try server.start()
        defer { server.stop() }
        let endpoint = try await Self.endpoint(of: server)

        viewModel.beginPairing()
        let invitation = try XCTUnwrap(viewModel.pairingInvitation)
        XCTAssertEqual(invitation, server.pairingInvitation)
        XCTAssertEqual(RemoteLinkPairingInvitation(payload: invitation.payload), invitation)

        let paired = try await Self.pair(endpoint: endpoint, deviceID: UUID().uuidString, methods: Self.secretMethods, secret: invitation.secret)
        XCTAssertNil(paired.error)
        for _ in 0..<100 where viewModel.pairingState == .waiting {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(viewModel.pairingState, .paired("Test iPhone"))
        XCTAssertNil(viewModel.pairingInvitation)

        viewModel.beginPairing()
        XCTAssertNotEqual(try XCTUnwrap(viewModel.pairingInvitation).secret, invitation.secret)
        viewModel.endPairing()
        XCTAssertNil(viewModel.pairingInvitation)
        XCTAssertNil(server.pairingInvitation)
    }

    func testLongNonASCIINamesStillFitTheQRCodePayload() throws {
        let serverID = String(repeating: "A", count: 64)
        let secret = Data(repeating: 0x77, count: 16)
        for name in [String(repeating: "界", count: 64), String(repeating: "ひ", count: 48)] {
            let invitation = RemoteLinkPairingInvitation(serverID: serverID, secret: secret, name: name)
            XCTAssertLessThanOrEqual(invitation.payload.utf8.count, RemoteLinkPairingInvitation.maxPayloadLength)
            let parsed = try XCTUnwrap(RemoteLinkPairingInvitation(payload: invitation.payload))
            XCTAssertEqual(parsed.serverID, serverID)
            XCTAssertEqual(parsed.secret, secret)
            let shortened = try XCTUnwrap(parsed.name)
            XCTAssertTrue(name.hasPrefix(shortened))
            XCTAssertFalse(shortened.isEmpty)
        }
        // A name that fits stays complete.
        XCTAssertEqual(
            RemoteLinkPairingInvitation(payload: RemoteLinkPairingInvitation(serverID: serverID, secret: secret, name: "Studio Mac").payload)?.name,
            "Studio Mac"
        )
    }

    func testFailedKeychainWriteAfterAValidProofShowsANewQRCode() async throws {
        let defaults = UserDefaults(suiteName: "RemoteLinkTests-\(UUID().uuidString)")!
        let store = RemoteLinkDeviceStore(
            defaults: defaults,
            loadKey: { _ in nil },
            saveKey: { _, _ in throw RemoteLinkError.connectionFailed("keychain") },
            deleteKey: { _ in }
        )
        let server = RemoteLinkServer(router: APIRouter(), store: store, serverName: { "Studio Mac" }, advertises: false)
        try server.start()
        defer { server.stop() }
        server.pairingFailureLockout = 60
        let changes = RemoteLinkLockedValue(0)
        server.onPairingInvitationChange = { changes.set(changes.get() + 1) }
        let endpoint = try await Self.endpoint(of: server)
        server.openPairing { _ in true }
        let used = try XCTUnwrap(server.pairingInvitation)

        let failed = try await Self.pair(endpoint: endpoint, deviceID: UUID().uuidString, methods: Self.secretMethods, secret: used.secret)
        XCTAssertNil(failed.key)
        XCTAssertEqual(failed.method, "secret")
        XCTAssertTrue(store.devices().isEmpty)

        // Burnt, then replaced for the sheet that is still open. The device
        // proved the secret, so its host is not locked out.
        try await Self.waitUntil { changes.get() >= 3 && server.pairingInvitation != nil }
        let renewed = try XCTUnwrap(server.pairingInvitation)
        XCTAssertNotEqual(renewed.secret, used.secret)
        let reused = try await Self.pair(endpoint: endpoint, deviceID: UUID().uuidString, methods: Self.secretMethods, secret: used.secret)
        XCTAssertEqual(reused.error, .remoteError("pairing-failed"))
        XCTAssertEqual(server.pairingInvitation, renewed)
    }

    func testFailedApprovalOfARepairingKeepsThePreviousPairing() async throws {
        let (server, store) = try Self.makeServer()
        defer { server.stop() }
        let endpoint = try await Self.endpoint(of: server)
        server.openPairing { _ in true }
        let deviceID = UUID().uuidString
        let first = try await Self.pair(
            endpoint: endpoint,
            deviceID: deviceID,
            methods: Self.secretMethods,
            secret: try XCTUnwrap(server.pairingInvitation).secret
        )
        let previousKey = try XCTUnwrap(first.key)

        // Closing the sheet right after the proof was accepted makes the
        // approval fail to send.
        server.openPairing { _ in true }
        let invitation = try XCTUnwrap(server.pairingInvitation)
        let closed = RemoteLinkLockedValue(false)
        server.onPairingInvitationChange = {
            guard !closed.get() else { return }
            closed.set(true)
            server.closePairing()
        }
        let second = try await Self.pair(endpoint: endpoint, deviceID: deviceID, methods: Self.secretMethods, secret: invitation.secret)
        XCTAssertNil(second.key)
        XCTAssertTrue(closed.get())
        try await Self.waitUntil { store.pairingKey(for: deviceID) == previousKey }
        XCTAssertEqual(store.devices().map(\.id), [deviceID])
        XCTAssertNil(server.pairingInvitation, "A closed sheet gets no new QR code")
    }

    func testRollBackUndoesOnlyItsOwnWrite() throws {
        let (store, _) = Self.makeStore()
        let deviceID = UUID().uuidString
        let old = RemoteLinkDevice(id: deviceID, name: "Old", pairedAt: Date(timeIntervalSince1970: 1), lastSeenAt: nil)
        let oldKey = SymmetricKey(size: .bits256)
        let newKey = SymmetricKey(size: .bits256)
        let new = RemoteLinkDevice(id: deviceID, name: "New", pairedAt: Date(), lastSeenAt: nil)

        try store.addDevice(old, key: oldKey)
        let previous = store.pairing(for: deviceID)
        try store.addDevice(new, key: newKey)
        store.rollBack(deviceID: deviceID, addedKey: newKey, previous: previous)
        XCTAssertEqual(store.pairingKey(for: deviceID), oldKey)
        XCTAssertEqual(store.devices().map(\.name), ["Old"])

        // A newer pairing or a removal in between stays.
        let newerKey = SymmetricKey(size: .bits256)
        try store.addDevice(new, key: newKey)
        try store.addDevice(new, key: newerKey)
        store.rollBack(deviceID: deviceID, addedKey: newKey, previous: previous)
        XCTAssertEqual(store.pairingKey(for: deviceID), newerKey)
        store.removeDevice(id: deviceID)
        store.rollBack(deviceID: deviceID, addedKey: newerKey, previous: previous)
        XCTAssertTrue(store.devices().isEmpty)

        // Without an earlier pairing the device is forgotten.
        let other = UUID().uuidString
        try store.addDevice(RemoteLinkDevice(id: other, name: "Other", pairedAt: Date(), lastSeenAt: nil), key: newKey)
        store.rollBack(deviceID: other, addedKey: newKey, previous: nil)
        XCTAssertTrue(store.devices().isEmpty)
    }

    func testClosingTheSheetDuringAScanDoesNotLockThePhoneOutOfTheNextOne() async throws {
        let (server, store) = try Self.makeServer()
        defer { server.stop() }
        let endpoint = try await Self.endpoint(of: server)
        server.openPairing { _ in true }

        let scanning = RemoteLinkConnection(endpoint: endpoint)
        defer { scanning.close() }
        try await scanning.start(timeout: 5)
        let clientKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        try await scanning.send(RemoteLinkHandshake(
            type: .pairRequest,
            deviceID: UUID().uuidString,
            commitment: RemoteLinkCrypto.commitment(clientKey: clientKey, clientNonce: RemoteLinkCrypto.randomNonce()),
            methods: Self.secretMethods
        ))
        _ = try await scanning.receiveHandshake(timeout: 5).expecting(.pairChallenge)

        // The user closes and reopens the sheet while the attempt is open.
        server.closePairing()
        server.openPairing { _ in true }
        do {
            _ = try await scanning.receiveHandshake(timeout: 5)
            XCTFail("Closing the sheet must end the attempt")
        } catch {
            XCTAssertNotEqual(error as? RemoteLinkError, .timedOut)
        }
        try await Task.sleep(for: .milliseconds(100))

        let deviceID = UUID().uuidString
        let paired = try await Self.pair(
            endpoint: endpoint,
            deviceID: deviceID,
            methods: Self.secretMethods,
            secret: try XCTUnwrap(server.pairingInvitation).secret
        )
        XCTAssertNil(paired.error)
        XCTAssertEqual(store.devices().map(\.id), [deviceID])
    }

    func testHostIsLockedOutBeforeTheRejectionArrives() async throws {
        let (server, _) = try Self.makeServer()
        defer { server.stop() }
        let endpoint = try await Self.endpoint(of: server)
        for _ in 0..<5 {
            // Opening the sheet again lifts the lockout of the previous round.
            server.openPairing { _ in true }
            let invitation = try XCTUnwrap(server.pairingInvitation)
            let wrong = try await Self.pair(
                endpoint: endpoint,
                deviceID: UUID().uuidString,
                methods: Self.secretMethods,
                secret: RemoteLinkPairingInvitation.randomSecret()
            )
            XCTAssertEqual(wrong.error, .remoteError("pairing-failed"))
            let retry = try await Self.pair(endpoint: endpoint, deviceID: UUID().uuidString, methods: Self.secretMethods, secret: invitation.secret)
            XCTAssertEqual(retry.error, .remoteError("pairing-failed"))
            XCTAssertNil(retry.method, "A locked-out host must not get a challenge")
        }
    }

    @MainActor
    func testTryAgainAfterAFailedCodeRequestKeepsTheQRCode() async throws {
        let (store, _) = Self.makeStore()
        let server = RemoteLinkServer(router: APIRouter(), store: store, serverName: { "Studio Mac" }, advertises: false)
        let defaults = UserDefaults(suiteName: "RemoteLinkTests-\(UUID().uuidString)")!
        let viewModel = RemoteLinkViewModel(server: server, defaults: defaults, premiumAccess: { true })
        try server.start()
        defer { server.stop() }
        let endpoint = try await Self.endpoint(of: server)
        viewModel.beginPairing()
        let invitation = try XCTUnwrap(viewModel.pairingInvitation)

        // A code request whose device disconnects before the user decides.
        let connection = RemoteLinkConnection(endpoint: endpoint)
        try await connection.start(timeout: 5)
        let clientKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let clientNonce = RemoteLinkCrypto.randomNonce()
        try await connection.send(RemoteLinkHandshake(
            type: .pairRequest,
            deviceID: UUID().uuidString,
            name: "Test iPhone",
            commitment: RemoteLinkCrypto.commitment(clientKey: clientKey, clientNonce: clientNonce)
        ))
        _ = try await connection.receiveHandshake(timeout: 5).expecting(.pairChallenge)
        try await connection.send(RemoteLinkHandshake(type: .pairReveal, nonce: clientNonce, key: clientKey))
        try await Self.waitUntil {
            if case .confirming = viewModel.pairingState { return true }
            return false
        }
        connection.close()
        try await Self.waitUntil { viewModel.pairingState == .failed }

        XCTAssertEqual(viewModel.pairingInvitation, invitation, "The QR code stays valid after a failed code request")
        viewModel.retryPairing()
        XCTAssertEqual(viewModel.pairingState, .waiting)
        XCTAssertEqual(viewModel.pairingInvitation, invitation)
        XCTAssertEqual(server.pairingInvitation, invitation)
        viewModel.endPairing()
    }

    // MARK: - Helpers

    /// Polls until `condition` holds and fails the test after `timeout`.
    /// Runs on the caller's actor, so main-actor tests can read view models.
    private static func waitUntil(
        isolation: isolated (any Actor)? = #isolation,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition() {
            guard Date() < deadline else {
                XCTFail("Condition not met within \(timeout) seconds", file: file, line: line)
                throw RemoteLinkError.timedOut
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func knownAnswerTranscript() throws -> RemoteLinkPairingTranscript {
        let clientKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x11, count: 32))
        let serverKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x22, count: 32))
        return RemoteLinkPairingTranscript(
            deviceID: "6F1C2B8E-0000-4000-8000-000000000001",
            serverID: "6F1C2B8E-0000-4000-8000-000000000002",
            clientKey: clientKey.publicKey.rawRepresentation,
            serverKey: serverKey.publicKey.rawRepresentation,
            clientNonce: Data(repeating: 0x33, count: 32),
            serverNonce: Data(repeating: 0x44, count: 32)
        )
    }

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
        /// The method in the server's challenge, if one arrived.
        var method: String?
    }

    /// Runs the client side of a pairing. With `secret` it sends
    /// `secretProof` (unless `sendsSecretProof` is false) and accepts the
    /// approval only with a valid server proof of the secret.
    private static func pair(
        endpoint: NWEndpoint,
        deviceID: String,
        methods: [String]? = nil,
        secret: Data? = nil,
        sendsSecretProof: Bool = true,
        replyTimeout: TimeInterval = 5
    ) async throws -> PairingResult {
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
            commitment: RemoteLinkCrypto.commitment(clientKey: clientKey, clientNonce: clientNonce),
            methods: methods
        ))

        var method: String?
        do {
            let challenge = try await connection.receiveHandshake(timeout: 5).expecting(.pairChallenge)
            method = challenge.method
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
            try await connection.send(RemoteLinkHandshake(
                type: .pairConfirm,
                proof: transcript.proof(.clientConfirmed, key: key),
                secretProof: sendsSecretProof ? secret.map { transcript.secretProof(.client, secret: $0) } : nil
            ))
            let approved = try await connection.receiveHandshake(timeout: replyTimeout).expecting(.pairApproved)
            XCTAssertTrue(transcript.isValidProof(try XCTUnwrap(approved.proof), label: .serverApproved, key: key))
            if let secret {
                XCTAssertTrue(transcript.isValidSecretProof(try XCTUnwrap(approved.secretProof), role: .server, secret: secret))
            } else {
                XCTAssertNil(approved.secretProof)
            }
            return PairingResult(key: key, code: transcript.verificationCode, method: method)
        } catch let error as RemoteLinkError {
            return PairingResult(error: error, method: method)
        }
    }

    private static let secretMethods = [RemoteLinkPairingMethod.secret.rawValue]

    private static func makeServer() throws -> (RemoteLinkServer, RemoteLinkDeviceStore) {
        let (store, _) = makeStore()
        let server = RemoteLinkServer(router: APIRouter(), store: store, serverName: { "Studio Mac" }, advertises: false)
        try server.start()
        return (server, store)
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
