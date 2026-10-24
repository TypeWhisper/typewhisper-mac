import Foundation

enum VoiceBarState: Equatable {
    case idle
    case preparing
    case listening
    case listeningWithText
    case translating
    case targetMenu
    case polishing(translating: Bool)
    case inserted(count: Int)
    case copied
    case recoveredError
    case translationFailed
    case blockingError(String)
    case noSpeech
    case downloading(Double?)
    case notDownloaded
    case modelFailed(String)
    case noAI
    case countdown(seconds: Int)
    case cancelled(remaining: Double)

    struct Input {
        enum Activity { case idle, preparing, recording, processing }
        enum Outcome { case inserted(Int), copied, recoveredError, translationFailed, blockingError(String), noSpeech, noAI }
        enum Model { case downloading(Double?), loading, notDownloaded, failed(String) }
        var activity: Activity = .idle
        var outcome: Outcome?
        var model: Model?
        var confirmedText = ""
        var tentativeText = ""
        var translation = false
        var targetMenuOpen = false
        var duration: TimeInterval = 0
        var cancellationRemaining: TimeInterval?
    }

    static func derive(_ input: Input) -> Self {
        if let remaining = input.cancellationRemaining, remaining > 0 {
            return .cancelled(remaining: min(1, remaining / 3))
        }
        if let outcome = input.outcome {
            switch outcome {
            case .inserted(let count): return .inserted(count: count)
            case .copied: return .copied
            case .recoveredError: return .recoveredError
            case .translationFailed: return .translationFailed
            case .blockingError(let message): return .blockingError(message)
            case .noSpeech: return .noSpeech
            case .noAI: return .noAI
            }
        }
        if let model = input.model {
            switch model {
            case .downloading(let progress): return .downloading(progress)
            case .loading: return .preparing
            case .notDownloaded: return .notDownloaded
            case .failed(let message): return .modelFailed(message)
            }
        }
        switch input.activity {
        case .idle: return .idle
        case .preparing: return .preparing
        case .processing: return .polishing(translating: input.translation)
        case .recording:
            if input.duration >= 480 { return .countdown(seconds: max(0, Int(ceil(540 - input.duration)))) }
            if input.translation { return input.targetMenuOpen ? .targetMenu : .translating }
            return input.confirmedText.isEmpty && input.tentativeText.isEmpty ? .listening : .listeningWithText
        }
    }
}
