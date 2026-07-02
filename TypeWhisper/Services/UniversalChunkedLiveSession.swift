import Foundation
import os
import TypeWhisperPluginSDK

// A universal live transcription session that works with any TranscriptionEnginePlugin
// by processing audio in background chunks during recording. When the recording stops,
// only the remaining "tail" audio (since the last committed chunk) needs transcription,
// dramatically reducing the delay for long recordings.
final class UniversalChunkedLiveSession: LiveTranscriptionSession, @unchecked Sendable {

    // MARK: - Types

    typealias ChunkTranscriber = @Sendable ([Float]) async throws -> PluginTranscriptionResult

    // MARK: - Configuration

    private static let chunkThresholdSeconds: Double = 7.0
    private static let safetyMarginSeconds: Double = 2.0
    private static let sampleRate: Double = 16_000

    // MARK: - State

    private struct State {
        var allSamples: [Float] = []
        var confirmedEndIndex: Int = 0
        var confirmedText: String = ""
        var isCancelled: Bool = false
        var chunkTask: Task<Void, Never>? = nil
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let transcribeChunk: ChunkTranscriber
    private let onProgress: @Sendable (String) -> Bool

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "typewhisper-mac",
        category: "UniversalChunkedLiveSession"
    )

    // MARK: - Init

    init(
        transcribeChunk: @escaping ChunkTranscriber,
        onProgress: @escaping @Sendable (String) -> Bool
    ) {
        self.transcribeChunk = transcribeChunk
        self.onProgress = onProgress
    }

    // MARK: - LiveTranscriptionSession

    func appendAudio(samples: [Float]) async throws {
        guard !state.withLock({ $0.isCancelled }) else { return }

        state.withLock { $0.allSamples.append(contentsOf: samples) }

        // Only trigger one chunk at a time
        guard state.withLock({ $0.chunkTask == nil }) else { return }

        let pendingDuration = state.withLock {
            Double($0.allSamples.count - $0.confirmedEndIndex) / Self.sampleRate
        }

        guard pendingDuration >= Self.chunkThresholdSeconds else { return }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.processChunk()
        }
        state.withLock { $0.chunkTask = task }
    }

    func finish() async throws -> PluginTranscriptionResult {
        // Wait for any in-progress chunk to complete so we commit as much text as possible
        // before transcribing only the remaining tail.
        let taskToWait = state.withLock { $0.chunkTask }
        await taskToWait?.value

        let (endIndex, confirmed, samples) = state.withLock {
            ($0.confirmedEndIndex, $0.confirmedText, $0.allSamples)
        }

        let tailSamples = Array(samples.dropFirst(endIndex))

        guard !tailSamples.isEmpty else {
            Self.logger.info("finish: no tail, returning confirmed text (\(confirmed.count) chars)")
            return PluginTranscriptionResult(text: confirmed, detectedLanguage: nil, segments: [])
        }

        Self.logger.info(
            "finish: confirmed=\(confirmed.isEmpty ? "empty" : "\(confirmed.count) chars"), tail=\(String(format: "%.1f", Double(tailSamples.count) / Self.sampleRate))s"
        )

        let tailResult = try await transcribeChunk(tailSamples)
        let tailText = tailResult.text.trimmingCharacters(in: .whitespacesAndNewlines)

        let finalText: String
        if confirmed.isEmpty {
            finalText = tailText
        } else if tailText.isEmpty {
            finalText = confirmed
        } else {
            finalText = confirmed + " " + tailText
        }

        return PluginTranscriptionResult(
            text: finalText,
            detectedLanguage: tailResult.detectedLanguage,
            segments: []
        )
    }

    func cancel() async {
        state.withLock { $0.isCancelled = true }
        state.withLock { $0.chunkTask }?.cancel()
    }

    // MARK: - Private

    private func processChunk() async {
        defer { state.withLock { $0.chunkTask = nil } }

        guard !state.withLock({ $0.isCancelled }) else { return }

        // Slice audio from confirmedEndIndex to end minus the safety margin.
        // The safety margin prevents committing words that may still be forming at the boundary.
        let (chunkSamples, chunkStartIndex): ([Float], Int) = state.withLock { s in
            let start = s.confirmedEndIndex
            let safetyCount = Int(Self.safetyMarginSeconds * Self.sampleRate)
            let end = max(start, s.allSamples.count - safetyCount)
            guard end > start else { return ([], start) }
            return (Array(s.allSamples[start..<end]), start)
        }

        guard !chunkSamples.isEmpty else { return }

        Self.logger.info(
            "processChunk: transcribing \(String(format: "%.1f", Double(chunkSamples.count) / Self.sampleRate))s from offset \(chunkStartIndex)"
        )

        guard let result = try? await transcribeChunk(chunkSamples) else {
            Self.logger.warning("processChunk: transcription failed, skipping commit")
            return
        }

        guard !state.withLock({ $0.isCancelled }) else { return }

        commitStableSegments(result: result, chunkStartIndex: chunkStartIndex, chunkSampleCount: chunkSamples.count)
    }

    private func commitStableSegments(
        result: PluginTranscriptionResult,
        chunkStartIndex: Int,
        chunkSampleCount: Int
    ) {
        let chunkDuration = Double(chunkSampleCount) / Self.sampleRate
        let safeCommitBefore = chunkDuration - Self.safetyMarginSeconds

        guard safeCommitBefore > 0 else { return }

        let (stableText, stableEndSeconds): (String, Double)

        if result.segments.isEmpty {
            // Engine returned no segment timestamps — commit everything up to the safety margin.
            let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            stableText = trimmed
            stableEndSeconds = safeCommitBefore
        } else {
            // Use segment timestamps to only commit segments fully before the safety margin.
            let stable = result.segments.filter {
                $0.end <= safeCommitBefore && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            guard !stable.isEmpty else { return }
            stableText = stable
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .joined(separator: " ")
            stableEndSeconds = stable.last!.end
        }

        guard !stableText.isEmpty else { return }

        let newEndIndex = chunkStartIndex + Int(stableEndSeconds * Self.sampleRate)

        let progressText: String = state.withLock { s in
            guard newEndIndex > s.confirmedEndIndex else { return s.confirmedText }
            s.confirmedEndIndex = min(newEndIndex, s.allSamples.count)
            if s.confirmedText.isEmpty {
                s.confirmedText = stableText
            } else {
                s.confirmedText = (s.confirmedText + " " + stableText)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return s.confirmedText
        }

        Self.logger.info("processChunk: committed \(String(format: "%.1f", stableEndSeconds))s, confirmed text now \(progressText.count) chars")

        _ = onProgress(progressText)
    }
}
