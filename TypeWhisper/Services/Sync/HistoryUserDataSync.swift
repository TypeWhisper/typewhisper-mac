import Foundation

enum UserDataSyncHistoryComponent: String, Codable, CaseIterable, Sendable {
    case content
    case inbox
    case audio
    case transcript
    case speakers
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

/// A record's transcript by speaker. Written when speakers are detected
/// again or corrected, so rarely; names sync separately in `speakers`.
struct UserDataSyncHistoryTranscriptV1: Codable, Equatable, Sendable {
    struct Source: Codable, Equatable, Sendable {
        /// `local` or `provider`; other values from newer clients count as `local`.
        let kind: String
        let engine: String
        let modelVersion: String?
    }

    struct Segment: Codable, Equatable, Sendable {
        let start: Double
        let end: Double
        let text: String
        let speakerID: String?
        let speakerConfidence: Double?
    }

    let recordID: UUID
    let updatedAt: Date
    /// New for every detection run; names refer to it.
    let revision: UUID
    let source: Source
    let requestedSpeakerCount: Int?
    let segments: [Segment]

    init(recordID: UUID, updatedAt: Date, transcript: SpeakerTranscript) {
        self.recordID = recordID
        self.updatedAt = updatedAt
        revision = transcript.revision
        source = Source(
            kind: transcript.source.kind.rawValue,
            engine: transcript.source.engine,
            modelVersion: transcript.source.modelVersion
        )
        requestedSpeakerCount = transcript.requestedSpeakerCount
        segments = transcript.segments.map {
            Segment(
                start: $0.start,
                end: $0.end,
                text: $0.text,
                speakerID: $0.speakerID,
                speakerConfidence: $0.speakerConfidence
            )
        }
    }

    var speakerTranscript: SpeakerTranscript {
        SpeakerTranscript(
            revision: revision,
            source: .init(
                kind: SpeakerTranscript.Source.Kind(rawValue: source.kind) ?? .local,
                engine: source.engine,
                modelVersion: source.modelVersion
            ),
            segments: segments.map {
                SpeakerTranscriptSegment(
                    text: $0.text,
                    start: $0.start,
                    end: $0.end,
                    speakerID: $0.speakerID,
                    speakerConfidence: $0.speakerConfidence
                )
            },
            requestedSpeakerCount: requestedSpeakerCount
        )
    }

    var isValid: Bool { speakerTranscript.isValid }
}

/// The names given to a record's speakers. Small, so renaming does not
/// upload the transcript again. Each name and each removal carries its own
/// date, so devices that name different speakers at the same time both keep
/// their names.
struct UserDataSyncHistorySpeakersV1: Codable, Equatable, Sendable {
    struct Name: Codable, Equatable, Sendable {
        let speakerID: String
        let displayName: String
        /// No longer written: voice profile links stay on their device.
        /// Read for payloads of earlier builds and ignored.
        let profileID: UUID?
        /// When the name was given; without it the payload's date counts.
        let updatedAt: Date?

        init(speakerID: String, displayName: String, profileID: UUID? = nil, updatedAt: Date? = nil) {
            self.speakerID = speakerID
            self.displayName = displayName
            self.profileID = profileID
            self.updatedAt = updatedAt
        }
    }

    let recordID: UUID
    let updatedAt: Date
    /// Names apply only to the transcript with this revision.
    let transcriptRevision: UUID
    let names: [Name]
    /// Names removed on purpose, so an older name from another device does
    /// not come back.
    let cleared: [SpeakerNameTable.ClearedName]

    private enum CodingKeys: String, CodingKey {
        case recordID, updatedAt, transcriptRevision, names, cleared
    }

    /// The confirmed names of a table. Names only suggested by a voice
    /// profile are a guess of this device and are not written.
    init(recordID: UUID, updatedAt: Date, transcriptRevision: UUID, table: SpeakerNameTable?) {
        self.recordID = recordID
        self.updatedAt = updatedAt
        self.transcriptRevision = transcriptRevision
        let table = table?.transcriptRevision == transcriptRevision ? table : nil
        names = (table?.confirmedEntries ?? []).map {
            Name(speakerID: $0.speakerID, displayName: $0.displayName, updatedAt: $0.updatedAt ?? updatedAt)
        }
        cleared = table?.cleared ?? []
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recordID = try container.decode(UUID.self, forKey: .recordID)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        transcriptRevision = try container.decode(UUID.self, forKey: .transcriptRevision)
        names = try container.decode([Name].self, forKey: .names)
        cleared = try container.decodeIfPresent([SpeakerNameTable.ClearedName].self, forKey: .cleared) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(recordID, forKey: .recordID)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(transcriptRevision, forKey: .transcriptRevision)
        try container.encode(names, forKey: .names)
        if !cleared.isEmpty { try container.encode(cleared, forKey: .cleared) }
    }

    var isValid: Bool {
        let speakerIDs = names.map(\.speakerID) + cleared.map(\.speakerID)
        return Set(speakerIDs).count == speakerIDs.count
            && cleared.allSatisfy { SpeakerTranscript.isValidSpeakerID($0.speakerID) }
            && names.allSatisfy { name in
                let trimmed = name.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                return SpeakerTranscript.isValidSpeakerID(name.speakerID)
                    && !trimmed.isEmpty
                    && name.displayName.count <= SpeakerNameTable.maximumNameLength
            }
    }

    /// The names as table entries, each with its date. Without profile
    /// links: another device's profile means nothing here.
    var entries: [SpeakerNameTable.Entry] {
        names.map {
            SpeakerNameTable.Entry(
                speakerID: $0.speakerID,
                displayName: $0.displayName,
                updatedAt: $0.updatedAt ?? updatedAt
            )
        }
    }

    /// The name table these names make, keeping this device's pending
    /// suggestions for speakers the names do not cover.
    func nameTable(keepingSuggestionsFrom local: SpeakerNameTable?) -> SpeakerNameTable {
        var table = SpeakerNameTable(transcriptRevision: transcriptRevision)
        _ = table.merge(names: entries, cleared: cleared, remoteDate: updatedAt, localDate: updatedAt)
        if let local, local.transcriptRevision == transcriptRevision {
            for entry in local.entries
            where entry.isSuggestion == true && table.displayName(for: entry.speakerID) == nil {
                table.setName(entry.displayName, for: entry.speakerID, profileID: entry.profileID, isSuggestion: true)
            }
        }
        return table
    }
}

struct UserDataSyncHistoryRecord: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case content
        case inbox
        case audio
        case transcript
        case speakers
    }

    let content: UserDataSyncHistoryContentV1
    let inbox: UserDataSyncHistoryInboxV1
    let audio: UserDataSyncHistoryAudioV1?
    let transcript: UserDataSyncHistoryTranscriptV1?
    let speakers: UserDataSyncHistorySpeakersV1?
    let localAudioFileURL: URL?
    let audioEligible: Bool

    init(
        content: UserDataSyncHistoryContentV1,
        inbox: UserDataSyncHistoryInboxV1,
        audio: UserDataSyncHistoryAudioV1?,
        transcript: UserDataSyncHistoryTranscriptV1? = nil,
        speakers: UserDataSyncHistorySpeakersV1? = nil,
        localAudioFileURL: URL?,
        audioEligible: Bool
    ) {
        self.content = content
        self.inbox = inbox
        self.audio = audio
        self.transcript = transcript
        self.speakers = speakers
        self.localAudioFileURL = localAudioFileURL
        self.audioEligible = audioEligible
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try container.decode(UserDataSyncHistoryContentV1.self, forKey: .content)
        inbox = try container.decode(UserDataSyncHistoryInboxV1.self, forKey: .inbox)
        audio = try container.decodeIfPresent(UserDataSyncHistoryAudioV1.self, forKey: .audio)
        transcript = try container.decodeIfPresent(UserDataSyncHistoryTranscriptV1.self, forKey: .transcript)
        speakers = try container.decodeIfPresent(UserDataSyncHistorySpeakersV1.self, forKey: .speakers)
        localAudioFileURL = nil
        audioEligible = false
    }
}

struct UserDataSyncHistoryDeletion: Codable, Equatable, Sendable {
    let recordID: UUID
    let deletedAt: Date
}
