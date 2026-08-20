import Foundation
import SwiftData

enum RecordingSource: String, Codable, CaseIterable, Sendable, Hashable {
    case mac
    case iPhone
    case iPad
    case appleWatch
    case importedFile
    case keyboard
    case shortcut
    case other

    var displayName: String {
        switch self {
        case .mac: String(localized: "This Mac")
        case .iPhone: String(localized: "iPhone")
        case .iPad: String(localized: "iPad")
        case .appleWatch: String(localized: "Apple Watch")
        case .importedFile: String(localized: "Imported File")
        case .keyboard: String(localized: "iOS Keyboard")
        case .shortcut: String(localized: "Shortcut")
        case .other: String(localized: "Other")
        }
    }
}

enum RecordingProcessingState: String, Codable, Sendable {
    case importing
    case transcribing
    case ready
    case failed
}

enum CaptureInboxState: String, Codable, Sendable {
    case none
    case open
    case completed
}

@Model
final class TranscriptionRecord {
    var id: UUID
    var timestamp: Date
    var rawText: String
    var finalText: String
    var appName: String?
    var appBundleIdentifier: String?
    var appURL: String?
    var durationSeconds: Double
    var language: String?
    var engineUsed: String
    var modelUsed: String?
    var wordsCount: Int = 0
    var audioFileName: String?
    var pipelineSteps: String?
    var sourceRaw: String = RecordingSource.mac.rawValue
    var processingStateRaw: String = RecordingProcessingState.ready.rawValue
    var processingFailureCategory: String?
    var processingFailureMessage: String?
    var renderedDocument: String?
    var structuredDocumentData: Data?
    var originDeviceID: String = ""
    var originPlatformRaw: String = "macOS"
    var contentUpdatedAt: Date = Date(timeIntervalSince1970: 0)
    var inboxStateRaw: String = CaptureInboxState.none.rawValue
    var inboxKindRaw: String?
    var inboxCompletionPolicyRaw: String = UserDataSyncHistoryCompletionPolicy.explicit.rawValue
    var inboxCompletedAt: Date?
    var inboxUpdatedAt: Date = Date(timeIntervalSince1970: 0)
    var inboxSafeActionData: Data?
    var audioUpdatedAt: Date = Date(timeIntervalSince1970: 0)
    var historySyncAudioEligible: Bool = false
    var remoteAudioRelativePath: String?
    var remoteAudioMediaType: String?
    var remoteAudioByteCount: Int64 = 0
    var remoteAudioSHA256: String?
    var remoteAudioCreatedAt: Date?
    var remoteAudioDurationSeconds: Double?

    var preview: String { String(finalText.prefix(100)) }
    var source: RecordingSource {
        get { RecordingSource(rawValue: sourceRaw) ?? .other }
        set { sourceRaw = newValue.rawValue }
    }
    var processingState: RecordingProcessingState {
        get { RecordingProcessingState(rawValue: processingStateRaw) ?? .ready }
        set { processingStateRaw = newValue.rawValue }
    }
    var inboxState: CaptureInboxState {
        get { CaptureInboxState(rawValue: inboxStateRaw) ?? .none }
        set { inboxStateRaw = newValue.rawValue }
    }
    var isOpenInInbox: Bool { inboxState == .open }
    var displayText: String { renderedDocument ?? finalText }
    var hasRemoteAudio: Bool { remoteAudioRelativePath != nil }
    var synchronizedStructuredDocument: UserDataSyncHistoryStructuredDocumentV1? {
        get {
            guard let structuredDocumentData else { return nil }
            return try? JSONDecoder().decode(
                UserDataSyncHistoryStructuredDocumentV1.self,
                from: structuredDocumentData
            )
        }
        set {
            structuredDocumentData = newValue.flatMap {
                try? JSONEncoder().encode($0)
            }
        }
    }

    var wasPostProcessed: Bool {
        rawText.trimmingCharacters(in: .whitespacesAndNewlines) != finalText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var pipelineStepList: [String] {
        get {
            guard let pipelineSteps, !pipelineSteps.isEmpty else { return [] }
            if let data = pipelineSteps.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String].self, from: data) {
                return decoded
            }
            return pipelineSteps
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        set {
            guard !newValue.isEmpty else {
                pipelineSteps = nil
                return
            }
            if let data = try? JSONEncoder().encode(newValue),
               let encoded = String(data: data, encoding: .utf8) {
                pipelineSteps = encoded
            } else {
                pipelineSteps = newValue.joined(separator: ",")
            }
        }
    }

    /// Extracts the domain from appURL (e.g. "https://github.com/foo" → "github.com")
    var appDomain: String? {
        guard let urlString = appURL,
              let url = URL(string: urlString),
              let host = url.host() else { return nil }
        return host
    }

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        rawText: String,
        finalText: String,
        appName: String? = nil,
        appBundleIdentifier: String? = nil,
        appURL: String? = nil,
        durationSeconds: Double,
        language: String? = nil,
        engineUsed: String,
        modelUsed: String? = nil,
        audioFileName: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.rawText = rawText
        self.finalText = finalText
        self.appName = appName
        self.appBundleIdentifier = appBundleIdentifier
        self.appURL = appURL
        self.durationSeconds = durationSeconds
        self.language = language
        self.engineUsed = engineUsed
        self.modelUsed = modelUsed
        self.wordsCount = finalText.split(separator: " ").count
        self.audioFileName = audioFileName
        sourceRaw = RecordingSource.mac.rawValue
        processingStateRaw = RecordingProcessingState.ready.rawValue
        originPlatformRaw = "macOS"
        contentUpdatedAt = timestamp
        inboxUpdatedAt = timestamp
        audioUpdatedAt = timestamp
    }
}
