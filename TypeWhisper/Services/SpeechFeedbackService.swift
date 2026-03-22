import AVFoundation
import AppKit

enum SpeechFeedbackEvent {
    case recordingStarted
    case transcriptionComplete(text: String, language: String?)
    case error(reason: String)
    case promptProcessing
    case promptComplete

    var message: String {
        switch self {
        case .recordingStarted:
            return String(localized: "Recording")
        case .transcriptionComplete:
            return ""
        case .error(let reason):
            return String(localized: "Error: \(reason)")
        case .promptProcessing:
            return String(localized: "Processing prompt")
        case .promptComplete:
            return String(localized: "Prompt complete")
        }
    }
}

@MainActor
class SpeechFeedbackService {
    private let synthesizer = AVSpeechSynthesizer()

    @Published var spokenFeedbackEnabled: Bool {
        didSet { UserDefaults.standard.set(spokenFeedbackEnabled, forKey: UserDefaultsKeys.spokenFeedbackEnabled) }
    }

    var isSpeaking: Bool {
        synthesizer.isSpeaking
    }

    init() {
        self.spokenFeedbackEnabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.spokenFeedbackEnabled)
    }

    func announceEvent(_ event: SpeechFeedbackEvent) {
        guard spokenFeedbackEnabled else { return }
        guard !NSWorkspace.shared.isVoiceOverEnabled else { return }
        if case .transcriptionComplete(let text, let language) = event {
            speak(text, language: language)
        } else {
            speak(event.message, language: nil)
        }
    }

    func readBack(text: String, language: String?) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
            return
        }
        speak(text, language: language)
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func speak(_ text: String, language: String?) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        if let language {
            utterance.voice = AVSpeechSynthesisVoice(language: language)
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.1
        synthesizer.speak(utterance)
    }
}
