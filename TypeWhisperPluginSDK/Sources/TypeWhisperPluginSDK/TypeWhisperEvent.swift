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
    case actionCompleted(ActionCompletedPayload)
    case partialTranscriptionUpdate(PartialTranscriptionPayload)
}

// MARK: - Payloads

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
