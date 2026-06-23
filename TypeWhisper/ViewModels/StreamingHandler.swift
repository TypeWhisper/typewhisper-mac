import Foundation
import os
import TypeWhisperPluginSDK

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "typewhisper-mac", category: "StreamingHandler")

final class StreamingHandler: @unchecked Sendable {
    private struct SharedState {
        var confirmedStreamingText = ""
        var liveSessionHandle: ModelManagerService.LiveTranscriptionSessionHandle?
        var normalizeNumbers: Bool?
        var configuredLanguage: String?
        var configuredLanguageCandidates: [String] = []
        var task: TranscriptionTask = .transcribe
        var livePreviewAudioGate = LivePreviewAudioGate()
        var sampleCursor = 0
    }

    private static let liveSessionPollInterval: Duration = .milliseconds(350)
    private static let fallbackPollInterval: Duration = .seconds(3)
    private static let fallbackPreviewWindowDuration: TimeInterval = 10
    private static let livePreviewSampleRate: Double = 16_000
    private static let livePreviewAnalysisFrameDuration: TimeInterval = 0.1
    private static let livePreviewSpeechRMSFloor: Float = 0.004
    private static let livePreviewSustainedSilenceDuration: TimeInterval = 1.4

    private struct LivePreviewAudioActivity {
        var duration: TimeInterval
        var containsSpeech: Bool
        var trailingQuietDuration: TimeInterval
    }

    private struct LivePreviewAudioGate {
        var hasObservedSpeech = false
        var consecutiveQuietDuration: TimeInterval = 0

        mutating func update(with activity: LivePreviewAudioActivity) -> LivePreviewAudioGateSnapshot {
            if activity.containsSpeech {
                hasObservedSpeech = true
                consecutiveQuietDuration = activity.trailingQuietDuration
            } else {
                consecutiveQuietDuration += activity.duration
            }

            return snapshot
        }

        var snapshot: LivePreviewAudioGateSnapshot {
            LivePreviewAudioGateSnapshot(
                hasObservedSpeech: hasObservedSpeech,
                consecutiveQuietDuration: consecutiveQuietDuration
            )
        }
    }

    private struct LivePreviewAudioGateSnapshot {
        var hasObservedSpeech: Bool
        var consecutiveQuietDuration: TimeInterval

        var suppressesAdditivePreview: Bool {
            !hasObservedSpeech || consecutiveQuietDuration >= StreamingHandler.livePreviewSustainedSilenceDuration
        }
    }

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
        dictionaryTermHints: [PluginDictionaryTermHint] = [],
        engineOverrideId: String?,
        selectedProviderId: String?,
        languageSelection: LanguageSelection,
        task: TranscriptionTask,
        cloudModelOverride: String?,
        normalizeNumbers: Bool? = nil,
        allowLiveTranscription: Bool,
        stateCheck: @escaping @MainActor @Sendable () -> Bool
    ) {
        stop()

        guard allowLiveTranscription else {
            logger.info("Live transcript preview skipped: disabled")
            return
        }

        let providerId = engineOverrideId ?? selectedProviderId
        guard let providerId,
              PluginManager.shared.transcriptionEngine(for: providerId) != nil else {
            logger.info("Live transcript preview skipped: provider unavailable")
            return
        }

        resetStreamingState()
        sharedState.withLock { state in
            state.normalizeNumbers = normalizeNumbers
            state.configuredLanguage = languageSelection.requestedLanguage
            state.configuredLanguageCandidates = languageSelection.selectedCodes
            state.task = task
        }
        onStreamingStateChange?(true)

        streamingTask = Task { [weak self] in
            guard let self else { return }

            if let handle = try? await self.modelManager.createLiveTranscriptionSession(
                languageSelection: languageSelection,
                task: task,
                engineOverrideId: engineOverrideId,
                cloudModelOverride: cloudModelOverride,
                prompt: streamPrompt,
                dictionaryTermHints: dictionaryTermHints,
                onProgress: { [weak self] text in
                    guard let self else { return false }
                    _ = self.processPreviewUpdate(
                        text,
                        audioGate: self.currentLivePreviewAudioGateSnapshot(),
                        persist: true
                    )
                    return true
                }
            ) {
                logger.info("Live transcript preview using live session providerId=\(handle.providerId, privacy: .public)")
                self.sharedState.withLock { $0.liveSessionHandle = handle }
                await self.runLiveSessionLoop(stateCheck: stateCheck)
                return
            }

            guard self.modelManager.allowsTranscriptPreviewFallback(
                engineOverrideId: engineOverrideId,
                selectedProviderId: selectedProviderId
            ) else {
                logger.info("Live transcript preview fallback skipped providerId=\(providerId, privacy: .public) reason=policy-opt-out")
                await MainActor.run { [weak self] in
                    self?.clearStreamingState(notifyStreamingStopped: true)
                }
                return
            }

            logger.info("Live transcript preview using fallback batch providerId=\(providerId, privacy: .public)")
            await self.runFallbackLoop(
                streamPrompt: streamPrompt,
                dictionaryTermHints: dictionaryTermHints,
                engineOverrideId: engineOverrideId,
                languageSelection: languageSelection,
                task: task,
                cloudModelOverride: cloudModelOverride,
                normalizeNumbers: normalizeNumbers,
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
                bufferedDuration: bufferedDurationProvider(),
                language: sharedState.withLock { $0.configuredLanguage },
                languageCandidates: sharedState.withLock { $0.configuredLanguageCandidates },
                task: sharedState.withLock { $0.task },
                normalizeNumbers: sharedState.withLock { $0.normalizeNumbers }
            )
            clearStreamingState(notifyStreamingStopped: true)

            let finalText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            progressText.withLock { $0 = finalText }
            sharedState.withLock { $0.confirmedStreamingText = finalText }
            return result
        } catch {
            logger.warning("Finalizing live transcription failed: \(error.localizedDescription)")
            await modelManager.cancelLiveTranscriptionSession(handle)
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
            let modelManager = self.modelManager
            Task {
                await modelManager.cancelLiveTranscriptionSession(handle)
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
                _ = recordLivePreviewAudio(delta.samples)
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
        dictionaryTermHints: [PluginDictionaryTermHint],
        engineOverrideId: String?,
        languageSelection: LanguageSelection,
        task: TranscriptionTask,
        cloudModelOverride: String?,
        normalizeNumbers: Bool?,
        stateCheck: @escaping @MainActor @Sendable () -> Bool
    ) async {
        try? await Task.sleep(for: Self.fallbackPollInterval)

        while !Task.isCancelled {
            guard await stateCheck() else { break }
            let buffer = recentBufferProvider(Self.fallbackPreviewWindowDuration)
            let bufferDuration = Double(buffer.count) / 16000.0
            let audioActivity = Self.livePreviewAudioActivity(in: buffer)

            if bufferDuration > 0.5, Self.shouldRunFallbackPreview(for: audioActivity) {
                do {
                    let result = try await modelManager.transcribe(
                        audioSamples: buffer,
                        languageSelection: languageSelection,
                        task: task,
                        engineOverrideId: engineOverrideId,
                        cloudModelOverride: cloudModelOverride,
                        prompt: streamPrompt,
                        dictionaryTermHints: dictionaryTermHints,
                        normalizeNumbers: normalizeNumbers,
                        onProgress: { [weak self] text in
                            guard let self, !Task.isCancelled else { return false }
                            _ = self.processPreviewUpdate(text, audioGate: nil, persist: false)
                            return true
                        }
                    )
                    _ = processPreviewUpdate(result.text, audioGate: nil, persist: true)
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
            state.normalizeNumbers = nil
            state.configuredLanguage = nil
            state.configuredLanguageCandidates = []
            state.task = .transcribe
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

    @discardableResult
    private func recordLivePreviewAudio(_ samples: [Float]) -> LivePreviewAudioGateSnapshot {
        let activity = Self.livePreviewAudioActivity(in: samples)
        return sharedState.withLock { state in
            state.livePreviewAudioGate.update(with: activity)
        }
    }

    private func currentLivePreviewAudioGateSnapshot() -> LivePreviewAudioGateSnapshot {
        sharedState.withLock { $0.livePreviewAudioGate.snapshot }
    }

    @discardableResult
    private func processPreviewUpdate(
        _ text: String,
        audioGate: LivePreviewAudioGateSnapshot?,
        persist: Bool
    ) -> Bool {
        let preview = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preview.isEmpty else { return false }

        let confirmed = progressText.withLock { $0 }
        let stable = Self.stabilizeText(confirmed: confirmed, new: preview)
        if Self.shouldSuppressLivePreviewUpdate(confirmed: confirmed, stable: stable, audioGate: audioGate) {
            logger.debug("Live transcript preview update suppressed during sustained silence")
            return false
        }

        if persist {
            progressText.withLock { $0 = stable }
            sharedState.withLock { $0.confirmedStreamingText = stable }
        }

        Task { @MainActor [weak self] in
            self?.onPartialTextUpdate?(stable)
        }
        return true
    }

    private nonisolated static func shouldRunFallbackPreview(for activity: LivePreviewAudioActivity) -> Bool {
        activity.containsSpeech && activity.trailingQuietDuration < livePreviewSustainedSilenceDuration
    }

    private nonisolated static func shouldSuppressLivePreviewUpdate(
        confirmed: String,
        stable: String,
        audioGate: LivePreviewAudioGateSnapshot?
    ) -> Bool {
        guard let audioGate, audioGate.suppressesAdditivePreview else { return false }

        let confirmed = confirmed.trimmingCharacters(in: .whitespacesAndNewlines)
        let stable = stable.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stable.isEmpty else { return false }

        let confirmedWordCount = transcriptWords(in: confirmed).count
        let stableWordCount = transcriptWords(in: stable).count
        guard stableWordCount > confirmedWordCount else { return false }

        return confirmed.isEmpty || stable.hasPrefix(confirmed)
    }

    private nonisolated static func livePreviewAudioActivity(in samples: [Float]) -> LivePreviewAudioActivity {
        guard !samples.isEmpty else {
            return LivePreviewAudioActivity(duration: 0, containsSpeech: false, trailingQuietDuration: 0)
        }

        let frameSize = max(1, Int(livePreviewSampleRate * livePreviewAnalysisFrameDuration))
        let duration = Double(samples.count) / livePreviewSampleRate
        var containsSpeech = false
        var trailingQuietDuration: TimeInterval = 0

        var offset = 0
        while offset < samples.count {
            let end = min(samples.count, offset + frameSize)
            let frame = samples[offset..<end]
            let rms = sqrt(frame.reduce(Float(0)) { $0 + $1 * $1 } / Float(frame.count))
            let frameDuration = Double(end - offset) / livePreviewSampleRate

            if rms >= livePreviewSpeechRMSFloor {
                containsSpeech = true
                trailingQuietDuration = 0
            } else {
                trailingQuietDuration += frameDuration
            }

            offset = end
        }

        return LivePreviewAudioActivity(
            duration: duration,
            containsSpeech: containsSpeech,
            trailingQuietDuration: trailingQuietDuration
        )
    }

    /// Keeps confirmed text stable and only appends new content.
    nonisolated static func stabilizeText(confirmed: String, new: String) -> String {
        let confirmed = confirmed.trimmingCharacters(in: .whitespacesAndNewlines)
        let new = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !confirmed.isEmpty else { return new }
        guard !new.isEmpty else { return confirmed }

        if new == confirmed { return confirmed }
        if new.hasPrefix(confirmed) { return new }
        if confirmed.hasPrefix(new) || confirmed.contains(new) { return confirmed }

        if looksLikeProviderCorrection(confirmed: confirmed, new: new) {
            return new
        }

        if let overlapLength = suffixPrefixOverlapLength(confirmed: confirmed, new: new) {
            let newTail = String(new.unicodeScalars.dropFirst(overlapLength))
            return appendPreviewText(confirmed, newTail)
        }

        if let fuzzyOverlapTail = fuzzyWordOverlapTail(confirmed: confirmed, new: new) {
            return appendPreviewText(confirmed, fuzzyOverlapTail)
        }

        if let repeatedPrefixTail = repeatedEarlierPrefixTail(confirmed: confirmed, new: new) {
            return appendPreviewText(confirmed, repeatedPrefixTail)
        }

        return appendPreviewText(confirmed, new)
    }

    private nonisolated static func looksLikeProviderCorrection(confirmed: String, new: String) -> Bool {
        let confirmedScalars = Array(confirmed.unicodeScalars)
        let newScalars = Array(new.unicodeScalars)
        let shortestCount = min(confirmedScalars.count, newScalars.count)
        guard shortestCount > 0 else { return false }

        var commonPrefixCount = 0
        for index in 0..<shortestCount {
            guard confirmedScalars[index] == newScalars[index] else { break }
            commonPrefixCount += 1
        }

        let minimumCommonPrefix = max(8, shortestCount / 2)
        let lengthRatio = Double(max(confirmedScalars.count, newScalars.count)) / Double(shortestCount)
        if commonPrefixCount >= minimumCommonPrefix && lengthRatio <= 1.6 {
            return true
        }

        return looksLikeProviderCorrectionByWords(confirmed: confirmed, new: new)
    }

    private nonisolated static func looksLikeProviderCorrectionByWords(confirmed: String, new: String) -> Bool {
        let confirmedWords = transcriptWords(in: confirmed)
        let newWords = transcriptWords(in: new)
        guard confirmedWords.count >= 4, newWords.count >= 4 else { return false }

        let matchedCount = approximateWordMatchCount(newWords, in: confirmedWords)
        let newCoverage = Double(matchedCount) / Double(newWords.count)
        let confirmedCoverage = Double(matchedCount) / Double(confirmedWords.count)
        let wordCountRatio = Double(max(confirmedWords.count, newWords.count)) / Double(min(confirmedWords.count, newWords.count))

        return newCoverage >= 0.72 && confirmedCoverage >= 0.60 && wordCountRatio <= 1.5
    }

    private nonisolated static func approximateWordMatchCount(
        _ lhs: [(normalized: String, endIndex: String.Index)],
        in rhs: [(normalized: String, endIndex: String.Index)]
    ) -> Int {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }

        var previous = Array(repeating: 0, count: rhs.count + 1)
        for lhsWord in lhs {
            var current = Array(repeating: 0, count: rhs.count + 1)
            for rhsIndex in rhs.indices {
                let currentIndex = rhsIndex + 1
                if transcriptWordsMatch(lhsWord.normalized, rhs[rhsIndex].normalized) {
                    current[currentIndex] = previous[currentIndex - 1] + 1
                } else {
                    current[currentIndex] = max(previous[currentIndex], current[currentIndex - 1])
                }
            }
            previous = current
        }

        return previous[rhs.count]
    }

    private nonisolated static func suffixPrefixOverlapLength(confirmed: String, new: String) -> Int? {
        let confirmedScalars = Array(confirmed.unicodeScalars)
        let newScalars = Array(new.unicodeScalars)
        let maxOverlap = min(confirmedScalars.count, newScalars.count)
        guard maxOverlap > 0 else { return nil }

        let minimumOverlap = min(maxOverlap, max(8, min(20, maxOverlap / 4)))
        guard minimumOverlap <= maxOverlap else { return nil }

        for overlapLength in stride(from: maxOverlap, through: minimumOverlap, by: -1) {
            let suffix = Array(confirmedScalars.suffix(overlapLength))
            let prefix = Array(newScalars.prefix(overlapLength))
            if suffix == prefix {
                return overlapLength
            }
        }

        return nil
    }

    private nonisolated static func fuzzyWordOverlapTail(confirmed: String, new: String) -> String? {
        let confirmedWords = transcriptWords(in: confirmed)
        let newWords = transcriptWords(in: new)
        let maxPrefixCount = min(confirmedWords.count, newWords.count, 8)
        guard maxPrefixCount >= 2 else { return nil }

        for prefixCount in stride(from: maxPrefixCount, through: 2, by: -1) {
            let newPrefix = Array(newWords.prefix(prefixCount))
            let maxConfirmedWindowCount = min(confirmedWords.count, prefixCount + 2)

            for confirmedWindowCount in stride(from: maxConfirmedWindowCount, through: prefixCount, by: -1) {
                let confirmedSuffix = Array(confirmedWords.suffix(confirmedWindowCount))
                guard newPrefixWords(newPrefix, matchAsSubsequenceOf: confirmedSuffix) else {
                    continue
                }

                let tailStart = newPrefix.last?.endIndex ?? new.startIndex
                let tail = String(new[tailStart...])
                return tail.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return nil
    }

    private nonisolated static func repeatedEarlierPrefixTail(confirmed: String, new: String) -> String? {
        let confirmedWords = transcriptWords(in: confirmed)
        let newWords = transcriptWords(in: new)
        guard confirmedWords.count >= 6, newWords.count >= 6 else { return nil }

        let firstSentenceCount = firstSentenceWordCount(in: new, words: newWords)
        let maxPrefixCount = min(firstSentenceCount ?? (newWords.count - 1), 14)
        guard maxPrefixCount >= 6 else { return nil }

        for prefixCount in stride(from: maxPrefixCount, through: 6, by: -1) {
            let newPrefix = Array(newWords.prefix(prefixCount))
            let maxConfirmedWindowCount = min(confirmedWords.count, prefixCount + 4)

            for confirmedWindowCount in stride(from: maxConfirmedWindowCount, through: prefixCount, by: -1) {
                guard confirmedWords.count >= confirmedWindowCount else { continue }

                for startIndex in 0...(confirmedWords.count - confirmedWindowCount) {
                    let endIndex = startIndex + confirmedWindowCount
                    let confirmedWindow = Array(confirmedWords[startIndex..<endIndex])
                    guard newPrefixWords(newPrefix, matchAsSubsequenceOf: confirmedWindow) else {
                        continue
                    }

                    let tailStart = newPrefix.last?.endIndex ?? new.startIndex
                    return String(new[tailStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        return nil
    }

    private nonisolated static func firstSentenceWordCount(
        in text: String,
        words: [(normalized: String, endIndex: String.Index)]
    ) -> Int? {
        guard let sentenceEnd = text.firstIndex(where: { ".!?".contains($0) }) else {
            return nil
        }

        let count = words.prefix { $0.endIndex <= sentenceEnd }.count
        return count > 0 ? count : nil
    }

    private nonisolated static func newPrefixWords(
        _ newPrefix: [(normalized: String, endIndex: String.Index)],
        matchAsSubsequenceOf confirmedSuffix: [(normalized: String, endIndex: String.Index)]
    ) -> Bool {
        var searchIndex = confirmedSuffix.startIndex
        var matchedCount = 0
        var skippedNewWords = 0
        var lastMatchedNewWordIndex: Int?
        let allowedSkippedNewWords = min(2, max(0, newPrefix.count / 3))

        for (newWordIndex, word) in newPrefix.enumerated() {
            guard searchIndex < confirmedSuffix.endIndex,
                  let matchIndex = confirmedSuffix[searchIndex...].firstIndex(where: {
                      transcriptWordsMatch($0.normalized, word.normalized)
                  }) else {
                skippedNewWords += 1
                guard skippedNewWords <= allowedSkippedNewWords else { return false }
                continue
            }
            matchedCount += 1
            lastMatchedNewWordIndex = newWordIndex
            searchIndex = confirmedSuffix.index(after: matchIndex)
        }

        return matchedCount >= max(2, newPrefix.count - allowedSkippedNewWords)
            && lastMatchedNewWordIndex == newPrefix.count - 1
    }

    private nonisolated static func transcriptWordsMatch(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }

        let lhsCount = lhs.count
        let rhsCount = rhs.count
        let shorterCount = min(lhsCount, rhsCount)
        let longerCount = max(lhsCount, rhsCount)
        guard shorterCount >= 4, longerCount - shorterCount <= 2 else { return false }

        return lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs)
    }

    private nonisolated static func transcriptWords(in text: String) -> [(normalized: String, endIndex: String.Index)] {
        var words: [(normalized: String, endIndex: String.Index)] = []
        var wordStart: String.Index?

        var index = text.startIndex
        while index < text.endIndex {
            let scalar = text[index].unicodeScalars.first
            let isWordCharacter = scalar.map {
                CharacterSet.alphanumerics.contains($0) || $0 == "'"
            } ?? false

            if isWordCharacter {
                if wordStart == nil { wordStart = index }
            } else if let start = wordStart {
                appendTranscriptWord(from: start, to: index, in: text, to: &words)
                wordStart = nil
            }

            index = text.index(after: index)
        }

        if let start = wordStart {
            appendTranscriptWord(from: start, to: text.endIndex, in: text, to: &words)
        }

        return words
    }

    private nonisolated static func appendTranscriptWord(
        from start: String.Index,
        to end: String.Index,
        in text: String,
        to words: inout [(normalized: String, endIndex: String.Index)]
    ) {
        let normalized = String(text[start..<end])
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        guard !normalized.isEmpty else { return }
        words.append((normalized, end))
    }

    private nonisolated static func appendPreviewText(_ confirmed: String, _ newTail: String) -> String {
        var tail = newTail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tail.isEmpty else { return confirmed }

        if let firstScalar = tail.unicodeScalars.first,
           let lastScalar = confirmed.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.last,
           CharacterSet.punctuationCharacters.contains(firstScalar),
           firstScalar == lastScalar {
            tail.removeFirst()
            tail = tail.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tail.isEmpty else { return confirmed }
        }

        if let firstScalar = tail.unicodeScalars.first,
           CharacterSet.punctuationCharacters.contains(firstScalar) {
            return confirmed + tail
        }

        return confirmed + " " + tail
    }
}
