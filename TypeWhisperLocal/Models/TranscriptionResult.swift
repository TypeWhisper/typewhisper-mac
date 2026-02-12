import Foundation

struct TranscriptionResult {
    let text: String
    let detectedLanguage: String?
    let duration: TimeInterval
    let processingTime: TimeInterval
    let engineUsed: EngineType

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
