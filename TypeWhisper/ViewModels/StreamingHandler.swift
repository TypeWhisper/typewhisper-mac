import Foundation
import os
import TypeWhisperPluginSDK

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "typewhisper-mac", category: "StreamingHandler")

@MainActor
final class StreamingHandler {
    private var streamingTask: Task<Void, Never>?
    private var confirmedStreamingText = ""

    private let modelManager: ModelManagerService
    private let audioRecordingService: AudioRecordingService
    private let dictionaryService: DictionaryService
    private let voiceCommandService: VoiceCommandService

    var onPartialTextUpdate: ((String) -> Void)?
    var onStreamingStateChange: ((Bool) -> Void)?

    init(
        modelManager: ModelManagerService,
        audioRecordingService: AudioRecordingService,
        dictionaryService: DictionaryService,
        voiceCommandService: VoiceCommandService
    ) {
        self.modelManager = modelManager
        self.audioRecordingService = audioRecordingService
        self.dictionaryService = dictionaryService
        self.voiceCommandService = voiceCommandService
    }

    func start(
        engineOverrideId: String?,
        selectedProviderId: String?,
        language: String?,
        task: TranscriptionTask,
        cloudModelOverride: String?,
        stateCheck: @MainActor @escaping () -> DictationViewModel.State
    ) {
        let providerId = engineOverrideId ?? selectedProviderId
        guard let providerId,
              let plugin = PluginManager.shared.transcriptionEngine(for: providerId) else { return }

        let pollInterval: Double = plugin.supportsStreaming ? 1.5 : 3.0

        onStreamingStateChange?(true)
        confirmedStreamingText = ""
        let streamPrompt = dictionaryService.getTermsForPrompt()
        streamingTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(pollInterval))

            while !Task.isCancelled, stateCheck() == .recording {
                let buffer = self.audioRecordingService.getRecentBuffer(maxDuration: 3600)
                let bufferDuration = Double(buffer.count) / 16000.0

                if bufferDuration > 0.5 {
                    do {
                        let confirmed = self.confirmedStreamingText
                        let vcService = self.voiceCommandService
                        let vcEnabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.voiceCommandsEnabled)
                        let result = try await self.modelManager.transcribe(
                            audioSamples: buffer,
                            language: language,
                            task: task,
                            engineOverrideId: engineOverrideId,
                            cloudModelOverride: cloudModelOverride,
                            prompt: streamPrompt,
                            onProgress: { [weak self] text in
                                guard let self, !Task.isCancelled else { return false }
                                let stable = Self.stabilizeText(confirmed: confirmed, new: text)
                                let display = vcEnabled ? vcService.process(text: stable).text : stable
                                Task { @MainActor [weak self] in
                                    self?.onPartialTextUpdate?(display)
                                }
                                return true
                            }
                        )
                        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty {
                            let stable = Self.stabilizeText(confirmed: confirmed, new: text)
                            let display = vcEnabled ? vcService.process(text: stable).text : stable
                            self.onPartialTextUpdate?(display)
                            self.confirmedStreamingText = stable
                        }
                    } catch {
                        logger.warning("Streaming preview error: \(error.localizedDescription)")
                    }
                }

                try? await Task.sleep(for: .seconds(pollInterval))
            }
        }
    }

    func stop() {
        streamingTask?.cancel()
        streamingTask = nil
        onStreamingStateChange?(false)
        confirmedStreamingText = ""
    }

    /// Keeps confirmed text stable and only appends new content.
    nonisolated static func stabilizeText(confirmed: String, new: String) -> String {
        let new = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !confirmed.isEmpty else { return new }
        guard !new.isEmpty else { return confirmed }

        // Best case: new text starts with confirmed text
        if new.hasPrefix(confirmed) { return new }

        // Find how far the texts match from the start
        let confirmedChars = Array(confirmed.unicodeScalars)
        let newChars = Array(new.unicodeScalars)
        var matchEnd = 0
        for i in 0..<min(confirmedChars.count, newChars.count) {
            if confirmedChars[i] == newChars[i] {
                matchEnd = i + 1
            } else {
                break
            }
        }

        // If more than half matches, keep confirmed and append the new tail
        if matchEnd > confirmed.count / 2 {
            let newContent = String(new.unicodeScalars.dropFirst(matchEnd))
            return confirmed + newContent
        }

        // Suffix-prefix overlap: new text starts with a suffix of confirmed
        // (happens when the streaming window has shifted forward)
        let minOverlap = min(20, confirmedChars.count / 4)
        let maxShift = min(confirmedChars.count - minOverlap, 150)
        if maxShift > 0 {
            for dropCount in 1...maxShift {
                let suffix = String(confirmed.unicodeScalars.dropFirst(dropCount))
                if new.hasPrefix(suffix) {
                    let newTail = String(new.unicodeScalars.dropFirst(confirmed.unicodeScalars.count - dropCount))
                    return newTail.isEmpty ? confirmed : confirmed + newTail
                }
            }
        }

        // Very different result - accept the new text to avoid freezing the preview
        return new
    }
}
