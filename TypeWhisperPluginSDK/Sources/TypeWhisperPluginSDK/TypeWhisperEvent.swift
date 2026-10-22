import Foundation

// MARK: - Event Bus Protocol

public protocol EventBusProtocol: Sendable {
    @discardableResult
    func subscribe(handler: @escaping @Sendable (TypeWhisperEvent) async -> Void) -> UUID
    func unsubscribe(id: UUID)
}

// MARK: - Events

public enum TypeWhisperEvent: Sendable {
    case recordingStarted(RecordingStartedPayload)
    case recordingStopped(RecordingStoppedPayload)
    case transcriptionCompleted(TranscriptionCompletedPayload)
    case transcriptionFailed(TranscriptionFailedPayload)
    case textInserted(TextInsertedPayload)
    case textCorrectionCommitted(TextCorrectionCommittedPayload)
    case actionCompleted(ActionCompletedPayload)
    case partialTranscriptionUpdate(PartialTranscriptionPayload)
    /// A Recorder transcript and its completion receipt have been saved successfully.
    case recorderTranscriptReady(RecorderTranscriptReadyPayload)
}

// MARK: - Payloads

/// Recorder automation is independent of dictation and its post-processing pipeline.
/// `recordingID` survives retranscription; `completionID` identifies one successful save.
/// With speaker detection the event waits until detection has finished and carries
/// its speakers; `speakerState` tells whether that worked.
public struct RecorderTranscriptReadyPayload: Sendable, Codable, Equatable {
    public let recordingID: UUID
    public let completionID: UUID
    public let completedAt: Date
    public let text: String
    public let audioFilePath: String
    public let transcriptFilePath: String
    public let markdownFilePath: String?
    /// When the recording started.
    public let recordedAt: Date?
    public let durationSeconds: Double?
    /// The calendar event of a recording started from the calendar.
    public let calendarEvent: RecorderCalendarEvent?
    /// `pending`, `ready` or `failed`; nil when the recording got no speaker detection.
    /// The event itself waits for detection, so it carries `ready` or `failed`.
    public var speakerState: String?
    /// The speakers of `speakerSegments`, in order of first appearance.
    public var speakers: [RecorderSpeaker]?
    public var speakerSegments: [RecorderSpeakerSegment]?

    public init(
        recordingID: UUID,
        completionID: UUID = UUID(),
        completedAt: Date = Date(),
        text: String,
        audioFilePath: String,
        transcriptFilePath: String,
        markdownFilePath: String? = nil,
        recordedAt: Date? = nil,
        durationSeconds: Double? = nil,
        calendarEvent: RecorderCalendarEvent? = nil,
        speakerState: String? = nil,
        speakers: [RecorderSpeaker]? = nil,
        speakerSegments: [RecorderSpeakerSegment]? = nil
    ) {
        self.recordingID = recordingID
        self.completionID = completionID
        // Normalize to the wire representation so an emitted completion equals its persisted copy.
        self.completedAt = Date(timeIntervalSince1970: completedAt.timeIntervalSince1970)
        self.text = text
        self.audioFilePath = audioFilePath
        self.transcriptFilePath = transcriptFilePath
        self.markdownFilePath = markdownFilePath
        self.recordedAt = recordedAt.map { Date(timeIntervalSince1970: $0.timeIntervalSince1970) }
        self.durationSeconds = durationSeconds
        self.calendarEvent = calendarEvent
        self.speakerState = speakerState
        self.speakers = speakers
        self.speakerSegments = speakerSegments
    }

    private enum CodingKeys: String, CodingKey {
        case recordingID = "recording_id", completionID = "completion_id"
        case completedAt = "completed_at", text, source
        case audioFilePath = "audio_file", transcriptFilePath = "transcript_file"
        case markdownFilePath = "markdown_file"
        case recordedAt = "recorded_at", durationSeconds = "duration_seconds"
        case calendarEvent = "calendar_event", speakerState = "speaker_state"
        case speakers, speakerSegments = "speaker_segments"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        recordingID = try values.decode(UUID.self, forKey: .recordingID)
        completionID = try values.decode(UUID.self, forKey: .completionID)
        completedAt = Date(timeIntervalSince1970: try values.decode(Double.self, forKey: .completedAt))
        text = try values.decode(String.self, forKey: .text)
        audioFilePath = try values.decode(String.self, forKey: .audioFilePath)
        transcriptFilePath = try values.decode(String.self, forKey: .transcriptFilePath)
        markdownFilePath = try values.decodeIfPresent(String.self, forKey: .markdownFilePath)
        recordedAt = try values.decodeIfPresent(Double.self, forKey: .recordedAt).map(Date.init(timeIntervalSince1970:))
        durationSeconds = try values.decodeIfPresent(Double.self, forKey: .durationSeconds)
        calendarEvent = try values.decodeIfPresent(RecorderCalendarEvent.self, forKey: .calendarEvent)
        speakerState = try values.decodeIfPresent(String.self, forKey: .speakerState)
        speakers = try values.decodeIfPresent([RecorderSpeaker].self, forKey: .speakers)
        speakerSegments = try values.decodeIfPresent([RecorderSpeakerSegment].self, forKey: .speakerSegments)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(recordingID, forKey: .recordingID)
        try values.encode(completionID, forKey: .completionID)
        // Unix seconds retain subsecond precision, independently of the encoder's date strategy.
        try values.encode(completedAt.timeIntervalSince1970, forKey: .completedAt)
        try values.encode("recorder", forKey: .source)
        try values.encode(text, forKey: .text)
        try values.encode(audioFilePath, forKey: .audioFilePath)
        try values.encode(transcriptFilePath, forKey: .transcriptFilePath)
        try values.encodeIfPresent(markdownFilePath, forKey: .markdownFilePath)
        try values.encodeIfPresent(recordedAt?.timeIntervalSince1970, forKey: .recordedAt)
        try values.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
        try values.encodeIfPresent(calendarEvent, forKey: .calendarEvent)
        try values.encodeIfPresent(speakerState, forKey: .speakerState)
        try values.encodeIfPresent(speakers, forKey: .speakers)
        try values.encodeIfPresent(speakerSegments, forKey: .speakerSegments)
    }
}

/// A speaker of a Recorder transcript. `name` is `Speaker N` until someone names the
/// speaker; a name a voice profile only suggested is in `suggestedName`.
public struct RecorderSpeaker: Sendable, Codable, Equatable {
    public let id: String
    public let name: String
    public let suggestedName: String?
    /// The speaker heard on the microphone, the user of this Mac.
    public let isMe: Bool

    public init(id: String, name: String, suggestedName: String? = nil, isMe: Bool = false) {
        self.id = id
        self.name = name
        self.suggestedName = suggestedName
        self.isMe = isMe
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, suggestedName = "suggested_name", isMe = "is_me"
    }
}

/// A passage of a Recorder transcript; `speaker` is a `RecorderSpeaker` ID, nil when
/// no speaker could be assigned. Times are seconds into the recording.
public struct RecorderSpeakerSegment: Sendable, Codable, Equatable {
    public let start: Double
    public let end: Double
    public let speaker: String?
    public let text: String

    public init(start: Double, end: Double, speaker: String?, text: String) {
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
    }
}

/// The calendar event a Recorder recording was started from. Times are Unix seconds.
public struct RecorderCalendarEvent: Sendable, Codable, Equatable {
    public let title: String
    public let start: Date
    public let end: Date
    public let location: String?
    public let organizer: RecorderCalendarParticipant?
    public let attendees: [RecorderCalendarParticipant]

    public init(
        title: String,
        start: Date,
        end: Date,
        location: String? = nil,
        organizer: RecorderCalendarParticipant? = nil,
        attendees: [RecorderCalendarParticipant] = []
    ) {
        self.title = title
        self.start = Date(timeIntervalSince1970: start.timeIntervalSince1970)
        self.end = Date(timeIntervalSince1970: end.timeIntervalSince1970)
        self.location = location
        self.organizer = organizer
        self.attendees = attendees
    }

    private enum CodingKeys: String, CodingKey {
        case title, start, end, location, organizer, attendees
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        title = try values.decode(String.self, forKey: .title)
        start = Date(timeIntervalSince1970: try values.decode(Double.self, forKey: .start))
        end = Date(timeIntervalSince1970: try values.decode(Double.self, forKey: .end))
        location = try values.decodeIfPresent(String.self, forKey: .location)
        organizer = try values.decodeIfPresent(RecorderCalendarParticipant.self, forKey: .organizer)
        attendees = try values.decodeIfPresent([RecorderCalendarParticipant].self, forKey: .attendees) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(title, forKey: .title)
        try values.encode(start.timeIntervalSince1970, forKey: .start)
        try values.encode(end.timeIntervalSince1970, forKey: .end)
        try values.encodeIfPresent(location, forKey: .location)
        try values.encodeIfPresent(organizer, forKey: .organizer)
        try values.encode(attendees, forKey: .attendees)
    }
}

public struct RecorderCalendarParticipant: Sendable, Codable, Equatable {
    public let name: String?
    public let email: String?
    /// `accepted`, `tentative`, `declined`, … as the calendar reports it.
    public let status: String?
    public let isCurrentUser: Bool

    public init(name: String? = nil, email: String? = nil, status: String? = nil, isCurrentUser: Bool = false) {
        self.name = name
        self.email = email
        self.status = status
        self.isCurrentUser = isCurrentUser
    }

    private enum CodingKeys: String, CodingKey {
        case name, email, status, isCurrentUser = "is_current_user"
    }
}

public struct RecordingStartedPayload: Sendable, Codable {
    public let timestamp: Date
    public let appName: String?
    public let bundleIdentifier: String?

    public init(timestamp: Date = Date(), appName: String? = nil, bundleIdentifier: String? = nil) {
        self.timestamp = timestamp
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
    }
}

public struct RecordingStoppedPayload: Sendable, Codable {
    public let timestamp: Date
    public let durationSeconds: Double

    public init(timestamp: Date = Date(), durationSeconds: Double) {
        self.timestamp = timestamp
        self.durationSeconds = durationSeconds
    }
}

public struct TranscriptionCompletedPayload: Sendable, Codable {
    public let timestamp: Date
    public let rawText: String
    public let finalText: String
    public let language: String?
    public let engineUsed: String
    public let modelUsed: String?
    public let durationSeconds: Double
    public let appName: String?
    public let bundleIdentifier: String?
    public let url: String?
    public let ruleName: String?

    enum CodingKeys: String, CodingKey {
        case timestamp
        case rawText
        case finalText
        case language
        case engineUsed
        case modelUsed
        case durationSeconds
        case appName
        case bundleIdentifier
        case url
        case ruleName
        case profileName
    }

    public init(
        timestamp: Date = Date(),
        rawText: String,
        finalText: String,
        language: String? = nil,
        engineUsed: String,
        modelUsed: String? = nil,
        durationSeconds: Double,
        appName: String? = nil,
        bundleIdentifier: String? = nil,
        url: String? = nil,
        ruleName: String? = nil
    ) {
        self.timestamp = timestamp
        self.rawText = rawText
        self.finalText = finalText
        self.language = language
        self.engineUsed = engineUsed
        self.modelUsed = modelUsed
        self.durationSeconds = durationSeconds
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.url = url
        self.ruleName = ruleName
    }

    @available(*, deprecated, renamed: "init(timestamp:rawText:finalText:language:engineUsed:modelUsed:durationSeconds:appName:bundleIdentifier:url:ruleName:)")
    public init(
        timestamp: Date = Date(),
        rawText: String,
        finalText: String,
        language: String? = nil,
        engineUsed: String,
        modelUsed: String? = nil,
        durationSeconds: Double,
        appName: String? = nil,
        bundleIdentifier: String? = nil,
        url: String? = nil,
        profileName: String? = nil
    ) {
        self.init(
            timestamp: timestamp,
            rawText: rawText,
            finalText: finalText,
            language: language,
            engineUsed: engineUsed,
            modelUsed: modelUsed,
            durationSeconds: durationSeconds,
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            url: url,
            ruleName: profileName
        )
    }

    @available(*, deprecated, renamed: "ruleName")
    public var profileName: String? { ruleName }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        rawText = try container.decode(String.self, forKey: .rawText)
        finalText = try container.decode(String.self, forKey: .finalText)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        engineUsed = try container.decode(String.self, forKey: .engineUsed)
        modelUsed = try container.decodeIfPresent(String.self, forKey: .modelUsed)
        durationSeconds = try container.decode(Double.self, forKey: .durationSeconds)
        appName = try container.decodeIfPresent(String.self, forKey: .appName)
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        ruleName = try container.decodeIfPresent(String.self, forKey: .ruleName)
            ?? container.decodeIfPresent(String.self, forKey: .profileName)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(rawText, forKey: .rawText)
        try container.encode(finalText, forKey: .finalText)
        try container.encodeIfPresent(language, forKey: .language)
        try container.encode(engineUsed, forKey: .engineUsed)
        try container.encodeIfPresent(modelUsed, forKey: .modelUsed)
        try container.encode(durationSeconds, forKey: .durationSeconds)
        try container.encodeIfPresent(appName, forKey: .appName)
        try container.encodeIfPresent(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encodeIfPresent(ruleName, forKey: .ruleName)
        try container.encodeIfPresent(ruleName, forKey: .profileName)
    }
}

public struct TranscriptionFailedPayload: Sendable, Codable {
    public let timestamp: Date
    public let error: String
    public let appName: String?
    public let bundleIdentifier: String?

    public init(timestamp: Date = Date(), error: String, appName: String? = nil, bundleIdentifier: String? = nil) {
        self.timestamp = timestamp
        self.error = error
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
    }
}

public struct TextInsertedPayload: Sendable, Codable {
    public let timestamp: Date
    public let text: String
    public let appName: String?
    public let bundleIdentifier: String?

    public init(timestamp: Date = Date(), text: String, appName: String? = nil, bundleIdentifier: String? = nil) {
        self.timestamp = timestamp
        self.text = text
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
    }
}

public struct TextCorrectionCommittedPayload: Sendable, Codable, Equatable {
    public enum SourceChannel: String, Sendable, Codable {
        case production
        case development
    }

    public let schemaVersion: Int
    public let id: UUID
    public let capturedAt: Date
    public let originalText: String
    public let correctedText: String
    public let language: String?
    public let engineId: String
    public let modelId: String?
    public let appVersion: String
    public let appBuild: String
    public let platformVersion: String
    public let commitSignal: String?
    public let sourceChannel: SourceChannel

    public init(
        schemaVersion: Int = 1,
        id: UUID = UUID(),
        capturedAt: Date = Date(),
        originalText: String,
        correctedText: String,
        language: String? = nil,
        engineId: String,
        modelId: String? = nil,
        appVersion: String,
        appBuild: String,
        platformVersion: String,
        commitSignal: String? = nil,
        sourceChannel: SourceChannel
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.capturedAt = capturedAt
        self.originalText = originalText
        self.correctedText = correctedText
        self.language = language
        self.engineId = engineId
        self.modelId = modelId
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.platformVersion = platformVersion
        self.commitSignal = commitSignal
        self.sourceChannel = sourceChannel
    }
}

public struct ActionCompletedPayload: Sendable, Codable {
    public let timestamp: Date
    public let actionId: String
    public let success: Bool
    public let message: String
    public let url: String?
    public let appName: String?
    public let bundleIdentifier: String?

    public init(timestamp: Date = Date(), actionId: String, success: Bool, message: String,
                url: String? = nil, appName: String? = nil, bundleIdentifier: String? = nil) {
        self.timestamp = timestamp
        self.actionId = actionId
        self.success = success
        self.message = message
        self.url = url
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
    }
}

public struct PartialTranscriptionPayload: Sendable, Codable {
    public let timestamp: Date
    public let text: String
    public let isFinal: Bool
    public let elapsedSeconds: Double

    public init(timestamp: Date = Date(), text: String, isFinal: Bool = false, elapsedSeconds: Double = 0) {
        self.timestamp = timestamp
        self.text = text
        self.isFinal = isFinal
        self.elapsedSeconds = elapsedSeconds
    }
}
