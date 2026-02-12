import Foundation

enum EngineType: String, CaseIterable, Identifiable, Codable {
    case whisper
    case parakeet

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whisper: "WhisperKit"
        case .parakeet: "Parakeet (FluidAudio)"
        }
    }

    var supportsStreaming: Bool {
        switch self {
        case .whisper: true
        case .parakeet: false
        }
    }

    var supportsTranslation: Bool {
        switch self {
        case .whisper: true
        case .parakeet: false
        }
    }
}
