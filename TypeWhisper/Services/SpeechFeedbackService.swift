import Foundation
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
    private var sayProcess: Process?

    @Published var spokenFeedbackEnabled: Bool {
        didSet { UserDefaults.standard.set(spokenFeedbackEnabled, forKey: UserDefaultsKeys.spokenFeedbackEnabled) }
    }

    var isSpeaking: Bool {
        sayProcess?.isRunning ?? false
    }

    init() {
        self.spokenFeedbackEnabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.spokenFeedbackEnabled)
    }

    func announceEvent(_ event: SpeechFeedbackEvent) {
        guard spokenFeedbackEnabled else { return }
        guard !NSWorkspace.shared.isVoiceOverEnabled else { return }
        if case .transcriptionComplete(let text, _) = event {
            speak(text)
        } else {
            speak(event.message)
        }
    }

    func readBack(text: String, language: String?) {
        if isSpeaking {
            stopSpeaking()
            return
        }
        speak(text)
    }

    func stopSpeaking() {
        sayProcess?.terminate()
        sayProcess = nil
    }

    private func speak(_ text: String) {
        stopSpeaking()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = [text]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.sayProcess = nil }
        }
        do {
            try process.run()
            sayProcess = process
        } catch {
            sayProcess = nil
        }
    }
}
