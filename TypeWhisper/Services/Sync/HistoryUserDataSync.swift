import Foundation

enum UserDataSyncHistoryComponent: String, Codable, CaseIterable, Sendable {
    case content
    case inbox
    case audio
}

struct UserDataSyncHistoryStructuredDocumentV1: Codable, Equatable, Sendable {
    let kind: String
    let title: String?
    let body: String
    let renderedText: String
    let fields: [String: String]

    init(
        kind: String,
        title: String? = nil,
        body: String,
        renderedText: String,
        fields: [String: String] = [:]
    ) {
        self.kind = kind
        self.title = title
        self.body = body
        self.renderedText = renderedText
        self.fields = fields
    }
}

struct UserDataSyncHistoryContentV1: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case recordID
        case createdAt
        case updatedAt
        case originDeviceID
        case originPlatform
        case source
        case processingState
        case rawTranscript
        case finalText
        case renderedDocument
        case structuredDocument
        case appDisplayName
        case durationSeconds
        case detectedLanguage
        case engineDisplayName
        case modelDisplayName
        case processingFailureCategory
        case processingFailureMessage
    }

    let recordID: UUID
    let createdAt: Date
    let updatedAt: Date
    let originDeviceID: String
    let originPlatform: String
    let source: String
    let processingState: String
    let rawTranscript: String
    let finalText: String
    let renderedDocument: String?
    let structuredDocument: UserDataSyncHistoryStructuredDocumentV1?
    let appDisplayName: String?
    let durationSeconds: Double
    let detectedLanguage: String?
    let engineDisplayName: String
    let modelDisplayName: String?
    let processingFailureCategory: String?
    let processingFailureMessage: String?

    init(
        recordID: UUID,
        createdAt: Date,
        updatedAt: Date,
        originDeviceID: String,
        originPlatform: String,
        source: String,
        processingState: String,
        rawTranscript: String,
        finalText: String,
        renderedDocument: String? = nil,
        structuredDocument: UserDataSyncHistoryStructuredDocumentV1? = nil,
        appDisplayName: String? = nil,
        durationSeconds: Double,
        detectedLanguage: String? = nil,
        engineDisplayName: String,
        modelDisplayName: String? = nil,
        processingFailureCategory: String? = nil,
        processingFailureMessage: String? = nil
    ) {
        self.recordID = recordID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.originDeviceID = originDeviceID
        self.originPlatform = originPlatform
        self.source = source
        self.processingState = processingState
        self.rawTranscript = rawTranscript
        self.finalText = finalText
        self.renderedDocument = renderedDocument
        self.structuredDocument = structuredDocument
        self.appDisplayName = appDisplayName
        self.durationSeconds = durationSeconds.isFinite && durationSeconds >= 0
            ? durationSeconds
            : 0
        self.detectedLanguage = detectedLanguage
        self.engineDisplayName = engineDisplayName
        self.modelDisplayName = modelDisplayName
        self.processingFailureCategory = processingFailureCategory
        self.processingFailureMessage = processingFailureMessage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recordID = try container.decode(UUID.self, forKey: .recordID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        originDeviceID = try container.decode(String.self, forKey: .originDeviceID)
        originPlatform = try container.decode(String.self, forKey: .originPlatform)
        source = try container.decode(String.self, forKey: .source)
        processingState = try container.decode(String.self, forKey: .processingState)
        rawTranscript = try container.decode(String.self, forKey: .rawTranscript)
        finalText = try container.decode(String.self, forKey: .finalText)
        renderedDocument = try container.decodeIfPresent(String.self, forKey: .renderedDocument)
        structuredDocument = try container.decodeIfPresent(
            UserDataSyncHistoryStructuredDocumentV1.self,
            forKey: .structuredDocument
        )
        appDisplayName = try container.decodeIfPresent(String.self, forKey: .appDisplayName)
        let decodedDuration = try container.decode(Double.self, forKey: .durationSeconds)
        durationSeconds = decodedDuration.isFinite && decodedDuration >= 0
            ? decodedDuration
            : 0
        detectedLanguage = try container.decodeIfPresent(String.self, forKey: .detectedLanguage)
        engineDisplayName = try container.decode(String.self, forKey: .engineDisplayName)
        modelDisplayName = try container.decodeIfPresent(String.self, forKey: .modelDisplayName)
        processingFailureCategory = try container.decodeIfPresent(
            String.self,
            forKey: .processingFailureCategory
        )
        processingFailureMessage = try container.decodeIfPresent(
            String.self,
            forKey: .processingFailureMessage
        )
    }
}

enum UserDataSyncHistoryCompletionPolicy: String, Codable, Sendable {
    case onOpen
    case explicit
    case afterAction
}

struct UserDataSyncHistorySafeActionV1: Codable, Equatable, Sendable {
    let action: String
    let version: Int
    let payload: [String: String]

    init(action: String, version: Int = 1, payload: [String: String] = [:]) {
        self.action = action
        self.version = version
        self.payload = payload
    }
}

struct UserDataSyncHistoryInboxV1: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case recordID
        case updatedAt
        case state
        case kind
        case completionPolicy
        case completedAt
        case safeAction
    }

    let recordID: UUID
    let updatedAt: Date
    let state: String
    let kind: String?
    let completionPolicy: UserDataSyncHistoryCompletionPolicy
    let completedAt: Date?
    let safeAction: UserDataSyncHistorySafeActionV1?

    init(
        recordID: UUID,
        updatedAt: Date,
        state: String,
        kind: String?,
        completionPolicy: UserDataSyncHistoryCompletionPolicy,
        completedAt: Date?,
        safeAction: UserDataSyncHistorySafeActionV1?
    ) {
        self.recordID = recordID
        self.updatedAt = updatedAt
        self.state = state
        self.kind = kind
        self.completionPolicy = completionPolicy
        self.completedAt = completedAt
        self.safeAction = safeAction
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recordID = try container.decode(UUID.self, forKey: .recordID)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        state = try container.decode(String.self, forKey: .state)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        let rawPolicy = try container.decodeIfPresent(String.self, forKey: .completionPolicy)
        completionPolicy = rawPolicy.flatMap(UserDataSyncHistoryCompletionPolicy.init(rawValue:))
            ?? .explicit
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        safeAction = try container.decodeIfPresent(
            UserDataSyncHistorySafeActionV1.self,
            forKey: .safeAction
        )
    }
}

struct UserDataSyncHistoryAudioV1: Codable, Equatable, Sendable {
    let recordID: UUID
    let updatedAt: Date
    let relativeAssetPath: String
    let mediaType: String
    let byteCount: Int64
    let sha256: String
    let createdAt: Date
    let durationSeconds: Double?

    var isValid: Bool {
        byteCount >= 0
            && Self.isSafeRelativePath(relativeAssetPath)
            && sha256.count == 64
            && sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase }
            && (durationSeconds == nil
                || (durationSeconds?.isFinite == true && durationSeconds! >= 0))
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        guard path.hasPrefix("assets/history/"), !path.hasPrefix("/") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }
}

struct UserDataSyncHistoryRecord: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case content
        case inbox
        case audio
    }

    let content: UserDataSyncHistoryContentV1
    let inbox: UserDataSyncHistoryInboxV1
    let audio: UserDataSyncHistoryAudioV1?
    let localAudioFileURL: URL?
    let audioEligible: Bool

    init(
        content: UserDataSyncHistoryContentV1,
        inbox: UserDataSyncHistoryInboxV1,
        audio: UserDataSyncHistoryAudioV1?,
        localAudioFileURL: URL?,
        audioEligible: Bool
    ) {
        self.content = content
        self.inbox = inbox
        self.audio = audio
        self.localAudioFileURL = localAudioFileURL
        self.audioEligible = audioEligible
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try container.decode(UserDataSyncHistoryContentV1.self, forKey: .content)
        inbox = try container.decode(UserDataSyncHistoryInboxV1.self, forKey: .inbox)
        audio = try container.decodeIfPresent(UserDataSyncHistoryAudioV1.self, forKey: .audio)
        localAudioFileURL = nil
        audioEligible = false
    }
}

struct UserDataSyncHistoryDeletion: Codable, Equatable, Sendable {
    let recordID: UUID
    let deletedAt: Date
}
