import Foundation

struct TranscriptionSegment {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let speakerLabel: String?
    let speakerConfidence: Double?

    init(
        text: String,
        start: TimeInterval,
        end: TimeInterval,
        speakerLabel: String? = nil,
        speakerConfidence: Double? = nil
    ) {
        self.text = text
        self.start = start
        self.end = end
        self.speakerLabel = speakerLabel
        self.speakerConfidence = speakerConfidence
    }
}

struct TranscriptionResult {
    let text: String
    let detectedLanguage: String?
    let duration: TimeInterval
    let processingTime: TimeInterval
    let engineUsed: String
    let segments: [TranscriptionSegment]

    var realTimeFactor: Double {
        guard duration > 0 else { return 0 }
        return duration / processingTime
    }
}

enum TranscriptionTask: String, CaseIterable, Identifiable {
    case transcribe
    case translate

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .transcribe: String(localized: "Transcribe")
        case .translate: String(localized: "Translate to English")
        }
    }
}
