import Foundation

@MainActor
final class VoiceCommandHandler {
    let voiceCommandService: VoiceCommandService

    var onStopRequested: (() -> Void)?

    init(voiceCommandService: VoiceCommandService) {
        self.voiceCommandService = voiceCommandService
    }

    /// Processes streaming text, applying voice commands if enabled.
    /// Returns the cleaned text. Triggers `onStopRequested` if a stop command is detected.
    func processStreamingText(_ text: String) -> String {
        guard UserDefaults.standard.bool(forKey: UserDefaultsKeys.voiceCommandsEnabled) else {
            return text
        }
        let result = voiceCommandService.process(text: text)
        if result.shouldStop {
            onStopRequested?()
        }
        return result.text
    }

    /// Processes final transcription text, applying voice commands if enabled.
    /// Returns the cleaned text (stop commands are stripped but not acted on here).
    func processFinalText(_ text: String) -> String {
        guard UserDefaults.standard.bool(forKey: UserDefaultsKeys.voiceCommandsEnabled) else {
            return text
        }
        return voiceCommandService.process(text: text).text
    }
}
