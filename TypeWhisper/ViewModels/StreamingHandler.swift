import Foundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "typewhisper-mac", category: "StreamingHandler")

final class StreamingHandler: @unchecked Sendable {
    private struct SharedState {
        var confirmedStreamingText = ""
        var liveSessionHandle: ModelManagerService.LiveTranscriptionSessionHandle?
        var sampleCursor = 0
    }

    private static let liveSessionPollInterval: Duration = .milliseconds(350)
    private static let fallbackPollInterval: Duration = .seconds(3)
    private static let fallbackPreviewWindowDuration: TimeInterval = 10

    private var streamingTask: Task<Void, Never>?
    private let progressText = OSAllocatedUnfairLock(initialState: "")
    private let sharedState = OSAllocatedUnfairLock(initialState: SharedState())

    private let modelManager: ModelManagerService
    private let bufferProvider: () -> [Float]
    private let recentBufferProvider: (TimeInterval) -> [Float]
    private let bufferDeltaProvider: (Int) -> (samples: [Float], nextOffset: Int)
    private let bufferedDurationProvider: () -> Double

    var onPartialTextUpdate: ((String) -> Void)?
    var onStreamingStateChange: ((Bool) -> Void)?

    init(
        modelManager: ModelManagerService,
        bufferProvider: @escaping () -> [Float],
        recentBufferProvider: @escaping (TimeInterval) -> [Float],
        bufferDeltaProvider: @escaping (Int) -> (samples: [Float], nextOffset: Int),
        bufferedDurationProvider: @escaping () -> Double
    ) {
        self.modelManager = modelManager
        self.bufferProvider = bufferProvider
        self.recentBufferProvider = recentBufferProvider
        self.bufferDeltaProvider = bufferDeltaProvider
        self.bufferedDurationProvider = bufferedDurationProvider
    }

    @MainActor
    func start(
        streamPrompt: String,
        engineOverrideId: String?,
        selectedProviderId: String?,
        languageSelection: LanguageSelection,
        task: TranscriptionTask,
        cloudModelOverride: String?,
        allowLiveTranscription: Bool,
        stateCheck: @escaping @MainActor @Sendable () -> Bool
    ) {
        stop()

        guard allowLiveTranscription else { return }

        let providerId = engineOverrideId ?? selectedProviderId
        guard let providerId,
              PluginManager.shared.transcriptionEngine(for: providerId) != nil else { return }

        resetStreamingState()
        onStreamingStateChange?(true)

        streamingTask = Task { [weak self] in
            guard let self else { return }

            if let handle = try? await self.modelManager.createLiveTranscriptionSession(
                languageSelection: languageSelection,
                task: task,
                engineOverrideId: engineOverrideId,
                cloudModelOverride: cloudModelOverride,
                prompt: streamPrompt,
                onProgress: { [weak self] text in
                    guard let self else { return false }
                    let confirmed = self.progressText.withLock { $0 }
                    let stable = Self.stabilizeText(confirmed: confirmed, new: text)
                    self.progressText.withLock { $0 = stable }
                    self.sharedState.withLock { $0.confirmedStreamingText = stable }
                    Task { @MainActor [weak self] in
                        self?.onPartialTextUpdate?(stable)
                    }
                    return true
                }
            ) {
                self.sharedState.withLock { $0.liveSessionHandle = handle }
                await self.runLiveSessionLoop(stateCheck: stateCheck)
                return
            }

            await self.runFallbackLoop(
                streamPrompt: streamPrompt,
                engineOverrideId: engineOverrideId,
                languageSelection: languageSelection,
                task: task,
                cloudModelOverride: cloudModelOverride,
                stateCheck: stateCheck
            )
        }
    }

    @MainActor
    func finish() async -> TranscriptionResult? {
        streamingTask?.cancel()
        streamingTask = nil

        guard let handle = sharedState.withLock({ $0.liveSessionHandle }) else {
            clearStreamingState(notifyStreamingStopped: true)
            return nil
        }

        let delta = nextBufferDelta()

        do {
            if !delta.samples.isEmpty {
                try await handle.session.appendAudio(samples: delta.samples)
            }
            let result = try await modelManager.finishLiveTranscriptionSession(
                handle,
                bufferedDuration: bufferedDurationProvider()
            )
            clearStreamingState(notifyStreamingStopped: true)

            let finalText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            progressText.withLock { $0 = finalText }
            sharedState.withLock { $0.confirmedStreamingText = finalText }
            return result
        } catch {
            logger.warning("Finalizing live transcription failed: \(error.localizedDescription)")
            await handle.session.cancel()
            clearStreamingState(notifyStreamingStopped: true)
            return nil
        }
    }

    @MainActor
    func stop() {
        streamingTask?.cancel()
        streamingTask = nil

        let handle = sharedState.withLock { state in
            let handle = state.liveSessionHandle
            state.liveSessionHandle = nil
            return handle
        }
        if let handle {
            Task {
                await handle.session.cancel()
            }
        }

        clearStreamingState(notifyStreamingStopped: true)
    }

    private func runLiveSessionLoop(stateCheck: @escaping @MainActor @Sendable () -> Bool) async {
        while !Task.isCancelled {
            guard await stateCheck() else { break }
            let delta = nextBufferDelta()

            if !delta.samples.isEmpty,
               let handle = sharedState.withLock({ $0.liveSessionHandle }) {
                do {
                    try await handle.session.appendAudio(samples: delta.samples)
                } catch {
                    logger.warning("Live transcription append failed: \(error.localizedDescription)")
                    break
                }
            }

            try? await Task.sleep(for: Self.liveSessionPollInterval)
        }
    }

    private func runFallbackLoop(
        streamPrompt: String,
        engineOverrideId: String?,
        languageSelection: LanguageSelection,
        task: TranscriptionTask,
        cloudModelOverride: String?,
        stateCheck: @escaping @MainActor @Sendable () -> Bool
    ) async {
        try? await Task.sleep(for: Self.fallbackPollInterval)

        while !Task.isCancelled {
            guard await stateCheck() else { break }
            let buffer = recentBufferProvider(Self.fallbackPreviewWindowDuration)
            let bufferDuration = Double(buffer.count) / 16000.0

            if bufferDuration > 0.5 {
                do {
                    let result = try await modelManager.transcribe(
                        audioSamples: buffer,
                        languageSelection: languageSelection,
                        task: task,
                        engineOverrideId: engineOverrideId,
                        cloudModelOverride: cloudModelOverride,
                        prompt: streamPrompt,
                        onProgress: { [weak self] text in
                            guard let self, !Task.isCancelled else { return false }
                            let confirmed = self.progressText.withLock { $0 }
                            let stable = Self.stabilizeText(confirmed: confirmed, new: text)
                            Task { @MainActor [weak self] in
                                self?.onPartialTextUpdate?(stable)
                            }
                            return true
                        }
                    )
                    let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        let confirmed = confirmedStreamingText()
                        let stable = Self.stabilizeText(confirmed: confirmed, new: text)
                        progressText.withLock { $0 = stable }
                        sharedState.withLock { $0.confirmedStreamingText = stable }
                        await MainActor.run { [weak self] in
                            self?.onPartialTextUpdate?(stable)
                        }
                    }
                } catch {
                    logger.warning("Streaming preview error: \(error.localizedDescription)")
                }
            }

            try? await Task.sleep(for: Self.fallbackPollInterval)
        }
    }

    private func nextBufferDelta() -> (samples: [Float], nextOffset: Int) {
        let sampleCursor = sharedState.withLock { $0.sampleCursor }
        let delta = bufferDeltaProvider(sampleCursor)
        sharedState.withLock { $0.sampleCursor = delta.nextOffset }
        return delta
    }

    private func resetStreamingState() {
        sharedState.withLock { state in
            state.confirmedStreamingText = ""
            state.liveSessionHandle = nil
            state.sampleCursor = 0
        }
        progressText.withLock { $0 = "" }
    }

    @MainActor
    private func clearStreamingState(notifyStreamingStopped: Bool) {
        resetStreamingState()
        if notifyStreamingStopped {
            onStreamingStateChange?(false)
        }
    }

    private func confirmedStreamingText() -> String {
        sharedState.withLock { $0.confirmedStreamingText }
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
