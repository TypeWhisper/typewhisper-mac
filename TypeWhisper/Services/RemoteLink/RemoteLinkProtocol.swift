import CryptoKit
import Foundation

// Remote Link wire protocol, version 1.
//
// TypeWhisper for macOS and iOS ship identical copies of this file. A change
// here must land in both repositories together, and the known-answer tests on
// both sides must keep passing with the same expected values.
//
// Frames are `[kind: UInt8][length: UInt32 big-endian][payload]`.
// Handshake frames carry one JSON `RemoteLinkHandshake`. Sealed frames carry
// ChaCha20-Poly1305 ciphertext and tag; the nonce is the per-direction frame
// counter and is never sent. Sealed plaintext is `[flags: UInt8][chunk]`, where
// bit 0 marks the last chunk of an application message.
//
// Each session mixes a fresh X25519 exchange (hello and welcome carry one
// ephemeral public key each) into the pairing key, so traffic recorded today
// stays private even if the pairing key leaks later.

enum RemoteLink {
    static let protocolVersion = 1
    static let bonjourType = "_typewhisper._tcp"
    static let txtVersionKey = "v"
    static let txtServerIDKey = "id"
    static let txtPairingKey = "pair"

    static let maxHandshakePayloadSize = 16 * 1024
    static let maxChunkSize = 1 << 20
    static let maxMessageSize = 300 * 1024 * 1024
    static let nonceSize = 32

    static let maxSealedPayloadSize = maxChunkSize + 1 + 16
}

enum RemoteLinkError: Error, Equatable, Sendable {
    case malformedFrame
    case frameTooLarge
    case malformedHandshake
    case unexpectedMessage(String)
    case unsupportedVersion
    case authenticationFailed
    case messageTooLarge
    case commitmentMismatch
    case invalidPublicKey
    case remoteError(String)
    case connectionClosed
    case timedOut
    case connectionFailed(String)
}

// MARK: - Frames

struct RemoteLinkFrame: Equatable, Sendable {
    enum Kind: UInt8, Sendable {
        case handshake = 1
        case sealed = 2
    }

    let kind: Kind
    let payload: Data

    func encoded() -> Data {
        var data = Data(capacity: payload.count + 5)
        data.append(kind.rawValue)
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }
}

struct RemoteLinkFrameDecoder: Sendable {
    private var buffer = Data()

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    mutating func nextFrame() throws -> RemoteLinkFrame? {
        guard buffer.count >= 5 else { return nil }
        let start = buffer.startIndex
        guard let kind = RemoteLinkFrame.Kind(rawValue: buffer[start]) else {
            throw RemoteLinkError.malformedFrame
        }
        let length = buffer[(start + 1)..<(start + 5)].reduce(0) { ($0 << 8) | Int($1) }
        let limit = kind == .handshake ? RemoteLink.maxHandshakePayloadSize : RemoteLink.maxSealedPayloadSize
        guard length <= limit else { throw RemoteLinkError.frameTooLarge }
        guard buffer.count >= 5 + length else { return nil }
        let payload = Data(buffer[(start + 5)..<(start + 5 + length)])
        buffer = Data(buffer[(start + 5 + length)...])
        return RemoteLinkFrame(kind: kind, payload: payload)
    }
}

// MARK: - Handshake

struct RemoteLinkHandshake: Codable, Equatable, Sendable {
    enum MessageType: String, Codable, Sendable {
        case hello
        case welcome
        case pairRequest = "pair-request"
        case pairChallenge = "pair-challenge"
        case pairReveal = "pair-reveal"
        case pairConfirm = "pair-confirm"
        case pairApproved = "pair-approved"
        case pairDenied = "pair-denied"
        case error
    }

    enum ErrorCode: String, Sendable {
        case unsupportedVersion = "unsupported-version"
        case unknownDevice = "unknown-device"
        case pairingClosed = "pairing-closed"
        case pairingBusy = "pairing-busy"
        case pairingFailed = "pairing-failed"
        case authenticationFailed = "authentication-failed"
    }

    var type: MessageType
    var version: Int?
    var deviceID: String?
    var serverID: String?
    var name: String?
    var nonce: Data?
    var key: Data?
    var commitment: Data?
    var proof: Data?
    var code: String?

    init(
        type: MessageType,
        version: Int? = RemoteLink.protocolVersion,
        deviceID: String? = nil,
        serverID: String? = nil,
        name: String? = nil,
        nonce: Data? = nil,
        key: Data? = nil,
        commitment: Data? = nil,
        proof: Data? = nil,
        code: String? = nil
    ) {
        self.type = type
        self.version = version
        self.deviceID = deviceID
        self.serverID = serverID
        self.name = name
        self.nonce = nonce
        self.key = key
        self.commitment = commitment
        self.proof = proof
        self.code = code
    }

    static func error(_ code: ErrorCode) -> RemoteLinkHandshake {
        RemoteLinkHandshake(type: .error, code: code.rawValue)
    }

    func frame() throws -> RemoteLinkFrame {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return RemoteLinkFrame(kind: .handshake, payload: try encoder.encode(self))
    }

    init(frame: RemoteLinkFrame) throws {
        guard frame.kind == .handshake else { throw RemoteLinkError.malformedHandshake }
        do {
            self = try JSONDecoder().decode(RemoteLinkHandshake.self, from: frame.payload)
        } catch {
            throw RemoteLinkError.malformedHandshake
        }
    }

    /// Unwraps the expected message type and turns a peer error into a thrown error.
    func expecting(_ expected: MessageType) throws -> RemoteLinkHandshake {
        if type == .error {
            throw RemoteLinkError.remoteError(code ?? "unknown")
        }
        guard type == expected else { throw RemoteLinkError.unexpectedMessage(type.rawValue) }
        guard version == RemoteLink.protocolVersion else { throw RemoteLinkError.unsupportedVersion }
        return self
    }
}

// MARK: - Session keys and sealing

enum RemoteLinkRole: Sendable {
    case client
    case server
}

struct RemoteLinkSessionKeys: Sendable {
    let sending: SymmetricKey
    let receiving: SymmetricKey

    /// Combines this side's ephemeral private key with the peer's ephemeral
    /// public key from the hello or welcome message.
    static func ephemeralSecret(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        peerKey: Data
    ) throws -> Data {
        let publicKey: Curve25519.KeyAgreement.PublicKey
        do {
            publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerKey)
        } catch {
            throw RemoteLinkError.invalidPublicKey
        }
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        let data = secret.withUnsafeBytes { Data($0) }
        // A low-order peer key yields an all-zero secret.
        guard data.contains(where: { $0 != 0 }) else { throw RemoteLinkError.invalidPublicKey }
        return data
    }

    init(
        pairingKey: SymmetricKey,
        ephemeralSecret: Data,
        deviceID: String,
        serverID: String,
        clientNonce: Data,
        serverNonce: Data,
        role: RemoteLinkRole
    ) {
        let salt = clientNonce + serverNonce
        let inputKeyMaterial = SymmetricKey(data: pairingKey.withUnsafeBytes { Data($0) } + ephemeralSecret)
        func derive(_ label: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(
                inputKeyMaterial: inputKeyMaterial,
                salt: salt,
                info: RemoteLinkCrypto.fields([Data("typewhisper-remote-link-v1 \(label)".utf8), Data(deviceID.utf8), Data(serverID.utf8)]),
                outputByteCount: 32
            )
        }
        let clientToServer = derive("c2s")
        let serverToClient = derive("s2c")
        switch role {
        case .client:
            sending = clientToServer
            receiving = serverToClient
        case .server:
            sending = serverToClient
            receiving = clientToServer
        }
    }
}

struct RemoteLinkSealer: Sendable {
    private let key: SymmetricKey
    private var counter: UInt64 = 0

    init(key: SymmetricKey) {
        self.key = key
    }

    mutating func seal(chunk: Data, isFinal: Bool) throws -> RemoteLinkFrame {
        precondition(chunk.count <= RemoteLink.maxChunkSize)
        var plaintext = Data(capacity: chunk.count + 1)
        plaintext.append(isFinal ? 1 : 0)
        plaintext.append(chunk)
        let nonce = try RemoteLinkCrypto.nonce(for: counter)
        counter += 1
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce, authenticating: RemoteLinkCrypto.sealedAAD)
        return RemoteLinkFrame(kind: .sealed, payload: box.ciphertext + box.tag)
    }

    /// Splits one application message into sealed frames.
    mutating func seal(message: Data) throws -> [RemoteLinkFrame] {
        guard message.count <= RemoteLink.maxMessageSize else { throw RemoteLinkError.messageTooLarge }
        guard !message.isEmpty else { return [try seal(chunk: Data(), isFinal: true)] }
        var frames: [RemoteLinkFrame] = []
        var offset = message.startIndex
        while offset < message.endIndex {
            let end = min(offset + RemoteLink.maxChunkSize, message.endIndex)
            frames.append(try seal(chunk: Data(message[offset..<end]), isFinal: end == message.endIndex))
            offset = end
        }
        return frames
    }
}

struct RemoteLinkOpener: Sendable {
    private let key: SymmetricKey
    private var counter: UInt64 = 0
    private var pending = Data()

    init(key: SymmetricKey) {
        self.key = key
    }

    /// Returns the complete message once its final chunk arrives.
    mutating func open(_ frame: RemoteLinkFrame) throws -> Data? {
        guard frame.kind == .sealed, frame.payload.count >= 17 else { throw RemoteLinkError.authenticationFailed }
        let nonce = try RemoteLinkCrypto.nonce(for: counter)
        counter += 1
        let payload = frame.payload
        let tagStart = payload.endIndex - 16
        let plaintext: Data
        do {
            let box = try ChaChaPoly.SealedBox(
                nonce: nonce,
                ciphertext: payload[payload.startIndex..<tagStart],
                tag: payload[tagStart...]
            )
            plaintext = try ChaChaPoly.open(box, using: key, authenticating: RemoteLinkCrypto.sealedAAD)
        } catch {
            throw RemoteLinkError.authenticationFailed
        }
        guard let flags = plaintext.first, flags & ~1 == 0 else { throw RemoteLinkError.malformedFrame }
        guard pending.count + plaintext.count - 1 <= RemoteLink.maxMessageSize else {
            throw RemoteLinkError.messageTooLarge
        }
        pending.append(plaintext.dropFirst())
        guard flags & 1 == 1 else { return nil }
        defer { pending = Data() }
        return pending
    }
}

// MARK: - Pairing

/// Numeric-comparison pairing: the client commits to its X25519 key, the
/// server answers with its key, the client reveals. Both sides then show the
/// same six-digit code, and the user confirms it on both devices.
struct RemoteLinkPairingTranscript: Sendable {
    let deviceID: String
    let serverID: String
    let clientKey: Data
    let serverKey: Data
    let clientNonce: Data
    let serverNonce: Data

    var digest: Data {
        Data(SHA256.hash(data: RemoteLinkCrypto.fields([
            Data("typewhisper-remote-link-v1 pairing".utf8),
            Data(deviceID.utf8),
            Data(serverID.utf8),
            clientKey,
            serverKey,
            clientNonce,
            serverNonce,
        ])))
    }

    var verificationCode: String {
        let hash = Data(SHA256.hash(data: RemoteLinkCrypto.fields([Data("typewhisper-remote-link-v1 code".utf8), digest])))
        let value = hash.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let code = String(value % 1_000_000)
        return String(repeating: "0", count: 6 - code.count) + code
    }

    func pairingKey(privateKey: Curve25519.KeyAgreement.PrivateKey, peerKey: Data) throws -> SymmetricKey {
        let publicKey: Curve25519.KeyAgreement.PublicKey
        do {
            publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerKey)
        } catch {
            throw RemoteLinkError.invalidPublicKey
        }
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
        return secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: digest,
            sharedInfo: Data("typewhisper-remote-link-v1 pairing key".utf8),
            outputByteCount: 32
        )
    }

    func proof(_ label: RemoteLinkCrypto.ProofLabel, key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: RemoteLinkCrypto.fields([Data(label.rawValue.utf8), digest]), using: key))
    }

    func isValidProof(_ proof: Data, label: RemoteLinkCrypto.ProofLabel, key: SymmetricKey) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(
            proof,
            authenticating: RemoteLinkCrypto.fields([Data(label.rawValue.utf8), digest]),
            using: key
        )
    }
}

enum RemoteLinkCrypto {
    enum ProofLabel: String, Sendable {
        case clientConfirmed = "client-confirmed"
        case serverApproved = "server-approved"
    }

    static let sealedAAD = Data("typewhisper-remote-link-v1 sealed".utf8)

    static func commitment(clientKey: Data, clientNonce: Data) -> Data {
        Data(SHA256.hash(data: fields([Data("typewhisper-remote-link-v1 commit".utf8), clientKey, clientNonce])))
    }

    static func randomNonce() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    static func nonce(for counter: UInt64) throws -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        var bigEndian = counter.bigEndian
        withUnsafeBytes(of: &bigEndian) { bytes.append(contentsOf: $0) }
        return try ChaChaPoly.Nonce(data: bytes)
    }

    /// Length-prefixed concatenation, so field boundaries cannot shift.
    static func fields(_ parts: [Data]) -> Data {
        var data = Data()
        for part in parts {
            var length = UInt32(part.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(part)
        }
        return data
    }
}
