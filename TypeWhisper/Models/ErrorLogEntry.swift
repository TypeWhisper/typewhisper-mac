import Foundation

struct ErrorLogEntry: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let message: String
    let category: String

    init(message: String, category: String = "general") {
        self.id = UUID()
        self.timestamp = Date()
        self.message = message
        self.category = category
    }

    var categoryIcon: String {
        switch category {
        case "transcription": return "waveform"
        case "recording": return "mic"
        case "prompt": return "text.bubble"
        case "plugin": return "puzzlepiece"
        default: return "exclamationmark.triangle"
        }
    }

    var categoryDisplayName: String {
        switch category {
        case "transcription": return String(localized: "Transcription")
        case "recording": return String(localized: "Recording")
        case "prompt": return String(localized: "Prompt")
        case "plugin": return String(localized: "Plugin")
        default: return String(localized: "General")
        }
    }
}
