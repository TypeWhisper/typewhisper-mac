import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "typewhisper-mac", category: "StreamingHandler")

@MainActor
final class StreamingHandler {
    private var streamingTask: Task<Void, Never>?
    private var confirmedStreamingText = ""
    private let progressText = OSAllocatedUnfairLock(initialState: "")
    private var liveSessionHandle: ModelManagerService.LiveTranscriptionSessionHandle?
    private var sampleCursor = 0

    private let modelManager: ModelManagerService
    private let streamPromptProvider: () -> String
    private let bufferProvider: () -> [Float]
    private let bufferDeltaProvider: (Int) -> (samples: [Float], nextOffset: Int)
    private let bufferedDurationProvider: () -> Double

    var onPartialTextUpdate: ((String) -> Void)?
    var onStreamingStateChange: ((Bool) -> Void)?

    init(
        modelManager: ModelManagerService,
        streamPromptProvider: @escaping () -> String,
        bufferProvider: @escaping () -> [Float],
        bufferDeltaProvider: @escaping (Int) -> (samples: [Float], nextOffset: Int),
        bufferedDurationProvider: @escaping () -> Double
    ) {
        self.modelManager = modelManager
        self.streamPromptProvider = streamPromptProvider
        self.bufferProvider = bufferProvider
        self.bufferDeltaProvider = bufferDeltaProvider
        self.bufferedDurationProvider = bufferedDurationProvider
    }

    func start(
        engineOverrideId: String?,
        selectedProviderId: String?,
        languageSelection: LanguageSelection,
        task: TranscriptionTask,
        cloudModelOverride: String?,
        allowLiveTranscription: Bool,
        stateCheck: @escaping () -> Bool
    ) {
        stop()

        guard allowLiveTranscription else { return }

        let providerId = engineOverrideId ?? selectedProviderId
        guard let providerId,
              let plugin = PluginManager.shared.transcriptionEngine(for: providerId) else { return }

        confirmedStreamingText = ""
        progressText.withLock { $0 = "" }
        sampleCursor = 0
        onStreamingStateChange?(true)

        let streamPrompt = streamPromptProvider()
        let pollInterval: Duration = plugin.supportsStreaming ? .milliseconds(350) : .seconds(3)

        streamingTask = Task { [weak self] in
            guard let self else { return }
            let progressText = self.progressText

            if let handle = try? await self.modelManager.createLiveTranscriptionSession(
                languageSelection: languageSelection,
                task: task,
                engineOverrideId: engineOverrideId,
                cloudModelOverride: cloudModelOverride,
                prompt: streamPrompt,
                onProgress: { [weak self] text in
                    guard let self else { return false }
                    let confirmed = progressText.withLock { $0 }
                    let stable = Self.stabilizeText(confirmed: confirmed, new: text)
                    Task { @MainActor [weak self] in
                        progressText.withLock { $0 = stable }
                        self?.confirmedStreamingText = stable
                        self?.onPartialTextUpdate?(stable)
                    }
                    return true
                }
            ) {
                self.liveSessionHandle = handle

                while !Task.isCancelled, stateCheck() {
                    let delta = self.bufferDeltaProvider(self.sampleCursor)
                    self.sampleCursor = delta.nextOffset

                    if !delta.samples.isEmpty {
                        do {
                            try await handle.session.appendAudio(samples: delta.samples)
                        } catch {
                            logger.warning("Live transcription append failed: \(error.localizedDescription)")
                            break
                        }
                    }

                    try? await Task.sleep(for: pollInterval)
                }
                return
            }

            try? await Task.sleep(for: pollInterval)

            while !Task.isCancelled, stateCheck() {
                let buffer = self.bufferProvider()
                let bufferDuration = Double(buffer.count) / 16000.0

                if bufferDuration > 0.5 {
                    do {
                        let confirmed = self.confirmedStreamingText
                        let result = try await self.modelManager.transcribe(
                            audioSamples: buffer,
                            languageSelection: languageSelection,
                            task: task,
                            engineOverrideId: engineOverrideId,
                            cloudModelOverride: cloudModelOverride,
                            prompt: streamPrompt,
                            onProgress: { [weak self] text in
                                guard let self, !Task.isCancelled else { return false }
                                let stable = Self.stabilizeText(confirmed: confirmed, new: text)
                                Task { @MainActor [weak self] in
                                    self?.onPartialTextUpdate?(stable)
                                }
                                return true
                            }
                        )
                        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty {
                            let stable = Self.stabilizeText(confirmed: confirmed, new: text)
                            self.onPartialTextUpdate?(stable)
                            self.confirmedStreamingText = stable
                        }
                    } catch {
                        logger.warning("Streaming preview error: \(error.localizedDescription)")
                    }
                }

                try? await Task.sleep(for: pollInterval)
            }
        }
    }

    func finish() async -> TranscriptionResult? {
        streamingTask?.cancel()
        streamingTask = nil

        guard let handle = liveSessionHandle else {
            liveSessionHandle = nil
            onStreamingStateChange?(false)
            confirmedStreamingText = ""
            progressText.withLock { $0 = "" }
            sampleCursor = 0
            return nil
        }

        let delta = bufferDeltaProvider(sampleCursor)
        sampleCursor = delta.nextOffset

        do {
            if !delta.samples.isEmpty {
                try await handle.session.appendAudio(samples: delta.samples)
            }
            let result = try await modelManager.finishLiveTranscriptionSession(
                handle,
                bufferedDuration: bufferedDurationProvider()
            )
            liveSessionHandle = nil
            onStreamingStateChange?(false)
            confirmedStreamingText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalText = confirmedStreamingText
            progressText.withLock { $0 = finalText }
            sampleCursor = 0
            return result
        } catch {
            logger.warning("Finalizing live transcription failed: \(error.localizedDescription)")
            await handle.session.cancel()
            liveSessionHandle = nil
            onStreamingStateChange?(false)
            confirmedStreamingText = ""
            progressText.withLock { $0 = "" }
            sampleCursor = 0
            return nil
        }
    }

    func stop() {
        streamingTask?.cancel()
        streamingTask = nil

        if let handle = liveSessionHandle {
            Task {
                await handle.session.cancel()
            }
        }

        liveSessionHandle = nil
        onStreamingStateChange?(false)
        confirmedStreamingText = ""
        progressText.withLock { $0 = "" }
        sampleCursor = 0
    }

    /// Keeps confirmed text stable and only appends new content.
    nonisolated static func stabilizeText(confirmed: String, new: String) -> String {
        let new = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !confirmed.isEmpty else { return new }
        guard !new.isEmpty else { return confirmed }

        if new.hasPrefix(confirmed) { return new }

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

        if matchEnd > confirmed.count / 2 {
            let newContent = String(new.unicodeScalars.dropFirst(matchEnd))
            return confirmed + newContent
        }

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

        return new
    }
}
