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
    case windows
    case recorder
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
        case .windows: String(localized: "Windows")
        case .recorder: String(localized: "Recorder")
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

/// Progress of a record's speaker transcript. Records without speaker
/// detection keep this nil.
enum SpeakerTranscriptState: String, Codable, Sendable {
    case pending
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
    /// Local comparison runs. Sync and ordinary exports expose only the active content.
    var transcriptionVersionsData: Data?
    var activeTranscriptionVersionID: UUID?
    var transcriptionAlignmentResetAt: Date?
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
    var speakerTranscriptStateRaw: String?
    var speakerTranscriptData: Data?
    var speakerNamesData: Data?
    /// Speaker names another device sent for another transcript revision than
    /// the current one: `[PendingSpeakerNames]` as JSON. They become the names
    /// if that transcript arrives. Kept on this device only.
    var pendingSpeakerNamesData: Data?
    /// Transcription timing kept for speaker detection: `[TimedTextEntry]` as JSON.
    var timedTextData: Data?
    var timedTextGranularityRaw: String?
    /// Word timing of the transcription, when the engine reported it: `[TranscriptionWord]` as JSON.
    var speakerWordsData: Data?
    /// True when the word timing comes from a second pass with another engine
    /// than the text. It then places words in time but does not decide where
    /// a speaker's sentence ends.
    var speakerWordsAreFromSecondPass: Bool?
    /// When the microphone carried the user's own speech: `[[start, end]]` as JSON.
    var speakerOwnSpeechData: Data?
    /// The `recording_id` of the Recorder file this record was made from.
    /// It names a file on this Mac and does not sync.
    var recorderRecordingID: UUID?
    /// True while the Recorder's folder holds that file, for a record without
    /// History audio. Kept on this device only.
    var recorderAudioAvailable: Bool = false
    /// When the speaker transcript and the speaker names last changed, for
    /// syncing them as separate components. Epoch 0 means never.
    var speakerTranscriptUpdatedAt: Date = Date(timeIntervalSince1970: 0)
    var speakerNamesUpdatedAt: Date = Date(timeIntervalSince1970: 0)
    /// The LLM requests behind the text: `HistoryLLMUsage` as JSON. Nil when
    /// none were recorded, as for every entry made before this existed.
    var llmUsageData: Data?
    /// Seconds from stopping this Mac's dictation until its transcript was ready, before any
    /// Workflow. Kept on this device only. Nil for entries made before this existed and for
    /// entries that were not dictated on this Mac, such as Recorder, imported or synced ones.
    var dictationStopToTranscriptSeconds: Double?
    /// Seconds the dictation's Workflow took after the transcript. Nil when no Workflow ran.
    var dictationWorkflowSeconds: Double?

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

    var speakerTranscriptState: SpeakerTranscriptState? {
        get { speakerTranscriptStateRaw.flatMap(SpeakerTranscriptState.init(rawValue:)) }
        set { speakerTranscriptStateRaw = newValue?.rawValue }
    }
    /// Audio stays until speaker detection has finished, even when retention would delete it.
    var holdsAudioForSpeakerTranscript: Bool {
        speakerTranscriptState == .pending || speakerTranscriptState == .failed
    }
    var speakerTranscript: SpeakerTranscript? {
        get { speakerTranscriptData.flatMap { try? JSONDecoder().decode(SpeakerTranscript.self, from: $0) } }
        set { speakerTranscriptData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }
    /// Names for the current speaker transcript; names given for an older
    /// detection run are ignored.
    var speakerNames: SpeakerNameTable? {
        get {
            guard let data = speakerNamesData,
                  let names = try? JSONDecoder().decode(SpeakerNameTable.self, from: data),
                  let transcript = speakerTranscript,
                  names.applies(to: transcript) else { return nil }
            return names
        }
        set { speakerNamesData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }
    var pendingSpeakerNames: [PendingSpeakerNames] {
        get {
            pendingSpeakerNamesData.flatMap { try? JSONDecoder().decode([PendingSpeakerNames].self, from: $0) } ?? []
        }
        set { pendingSpeakerNamesData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }
    var timedText: [TimedTextEntry] {
        get { timedTextData.flatMap { try? JSONDecoder().decode([TimedTextEntry].self, from: $0) } ?? [] }
        set { timedTextData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }
    var speakerWords: [TranscriptionWord] {
        get { speakerWordsData.flatMap { try? JSONDecoder().decode([TranscriptionWord].self, from: $0) } ?? [] }
        set { speakerWordsData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }
    var speakerOwnSpeech: [ClosedRange<TimeInterval>] {
        get {
            let pairs = speakerOwnSpeechData.flatMap { try? JSONDecoder().decode([[Double]].self, from: $0) } ?? []
            return pairs.compactMap { $0.count == 2 && $0[0] <= $0[1] ? $0[0]...$0[1] : nil }
        }
        set {
            speakerOwnSpeechData = newValue.isEmpty
                ? nil
                : try? JSONEncoder().encode(newValue.map { [$0.lowerBound, $0.upperBound] })
        }
    }
    var timedTextGranularity: TimedTextGranularity {
        get {
            guard timedTextData != nil else { return .none }
            return timedTextGranularityRaw.flatMap(TimedTextGranularity.init(rawValue:)) ?? .none
        }
        set { timedTextGranularityRaw = newValue == .none ? nil : newValue.rawValue }
    }

    /// The LLM requests behind the text; nil without any, including when the
    /// text was made without an LLM.
    var llmUsage: HistoryLLMUsage? {
        get {
            guard let usage = HistoryLLMUsage.decode(llmUsageData), !usage.entries.isEmpty else { return nil }
            return usage
        }
        set { llmUsageData = newValue?.encodedData() }
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
        self.wordsCount = WordCount.count(in: finalText)
        self.audioFileName = audioFileName
        sourceRaw = RecordingSource.mac.rawValue
        processingStateRaw = RecordingProcessingState.ready.rawValue
        originPlatformRaw = "macOS"
        contentUpdatedAt = timestamp
        inboxUpdatedAt = timestamp
        audioUpdatedAt = timestamp
    }
}

/// How long a dictation on this Mac took after the recording stopped, as History shows it.
struct HistoryDictationTiming: Equatable, Sendable {
    var stopToTranscriptSeconds: Double?
    var workflowSeconds: Double?

    /// Takes the measurements of a dictation's latency trace. The Workflow time counts only
    /// when a Workflow processed the text; the rest of the pipeline takes no noticeable time.
    init(trace: DictationLatencyTrace) {
        self.init(
            stopToTranscriptSeconds: trace.stopToFinalTranscriptMs.map { $0 / 1_000 },
            workflowSeconds: trace.llmPostProcessing == true ? trace.postProcessingMs.map { $0 / 1_000 } : nil
        )
    }

    init(stopToTranscriptSeconds: Double?, workflowSeconds: Double?) {
        self.stopToTranscriptSeconds = Self.valid(stopToTranscriptSeconds)
        self.workflowSeconds = Self.valid(workflowSeconds)
    }

    var isEmpty: Bool { stopToTranscriptSeconds == nil && workflowSeconds == nil }

    private static func valid(_ seconds: Double?) -> Double? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }
}

extension TranscriptionRecord {
    /// The original dictation's timing, or nil when none was measured.
    var dictationTiming: HistoryDictationTiming? {
        let timing = HistoryDictationTiming(
            stopToTranscriptSeconds: dictationStopToTranscriptSeconds,
            workflowSeconds: dictationWorkflowSeconds
        )
        return timing.isEmpty ? nil : timing
    }

    /// The original dictation's timing while its text is the one in use; nil after another
    /// run was chosen or synchronized text replaced it, since the times did not produce that text.
    var dictationTimingForActiveText: HistoryDictationTiming? {
        guard let timing = dictationTiming else { return nil }
        if let activeID = activeTranscriptionVersionID, activeID != id { return nil }
        // A saved original keeps the dictated text; a synchronized replacement clears the
        // active version without matching it. Without saved versions, sync clears the times.
        guard transcriptionVersionsData != nil,
              let original = (try? savedTranscriptionVersions())?.first(where: { $0.id == id })
        else { return timing }
        return original.matchesContent(of: self) ? timing : nil
    }
}
