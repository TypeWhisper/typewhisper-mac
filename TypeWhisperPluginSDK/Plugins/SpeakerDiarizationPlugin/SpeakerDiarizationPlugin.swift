import FluidAudio
import Foundation
import TypeWhisperPluginSDK
import os

/// Runs FluidAudio's offline diarizer (segmentation, speaker embeddings, VBx
/// clustering) on a recorded file.
@objc(SpeakerDiarizationPlugin)
final class SpeakerDiarizationPlugin: NSObject, SpeakerDiarizationMinimumCountProviding, @unchecked Sendable {
    static let pluginId = "com.typewhisper.speaker-diarization"
    static let pluginName = "Speaker Detection"
    static let engineIdentifier = "fluidaudio-offline-diarizer"
    /// The offline diarizer's speaker embeddings come from pyannote's
    /// community-1 embedding model. Voice profiles learned from them only
    /// match embeddings of the same model.
    static let speakerEmbeddingModel = "fluidaudio-offline-diarizer.community-1"
    /// Euclidean cut distance between unit-normalized embeddings. On five AMI
    /// table-microphone meetings 0.6 (the pyannote default) and 0.7 score the
    /// same; 0.775 merges two speakers of EN2002a into one. iOS uses 0.7 as
    /// well.
    static let clusteringThreshold = 0.7
    /// Segmentation windows start every second, as in pyannote's community-1
    /// pipeline; FluidAudio starts them every two seconds. VBx's weights were
    /// tuned on one embedding per second, and with half of them the second
    /// person of a short conversation often lacked the evidence to stay a
    /// speaker of their own. Detection takes twice as long: 52 s instead of
    /// 26 s for a 35-minute meeting on an M5 Pro.
    static let segmentationStepRatio = 0.1
    /// VBx's speaker prior weight (Fb). pyannote's 0.8 merged the two people
    /// of 14 of 73 two-person table-microphone excerpts (AMI, 1 to 3 minutes)
    /// into one speaker even with one embedding per second, 0.6 merged 9, and
    /// 0.4 split some of them into three or four speakers instead. On 16 AMI
    /// meetings 0.6 also scores best (DER 26.3 %, 27.6 % before with
    /// two-second windows).
    static let speakerPriorWeight = 0.6
    /// With a fixed number of speakers K-Means re-clusters a surplus, so the
    /// prior only needs to keep voices apart. Asked for two speakers, 0.3
    /// found both people in 64 of the 66 excerpts of one and one and a half
    /// minutes, 0.6 in 59. VBx can still put two people in one cluster and a
    /// few stray seconds in another, which already counts as two speakers and
    /// skips K-Means.
    static let fixedCountSpeakerPriorWeight = 0.3

    /// Share of the speech a speaker needs to count towards a minimum number
    /// of speakers. Automatic detection can put two people in one cluster and
    /// leave a few stray seconds in another: in a 56-minute call it gave one
    /// speaker 2,385 s and the other 16 s.
    static let minimumSpeakerShare = 0.1

    /// Speakers in `turns` with at least `minimumSpeakerShare` of the speech.
    static func speakersWithShare(of turns: [PluginSpeakerTurn]) -> Int {
        var spoken: [String: Double] = [:]
        for turn in turns { spoken[turn.speakerLabel, default: 0] += max(0, turn.end - turn.start) }
        let total = spoken.values.reduce(0, +)
        guard total > 0 else { return 0 }
        return spoken.values.filter { $0 >= minimumSpeakerShare * total }.count
    }

    static let speakerCounts = 2...8

    /// The fixed number of speakers to detect again with, or nil to keep the
    /// automatic result: when fewer than `minimum` speakers have
    /// `minimumSpeakerShare` of the speech. It is never below the number of
    /// speakers the automatic pass found, so the quieter people of a meeting
    /// stay apart; with more speakers than a fixed count allows, the
    /// automatic result stays.
    static func speakerCountForSecondPass(after turns: [PluginSpeakerTurn], minimum: Int) -> Int? {
        guard speakersWithShare(of: turns) < minimum else { return nil }
        let count = max(minimum, Set(turns.map(\.speakerLabel)).count)
        return speakerCounts.contains(count) ? count : nil
    }

    /// The offline diarizer's settings for automatic detection or a fixed number of speakers.
    static func diarizerConfig(speakerCount: Int?) -> OfflineDiarizerConfig {
        var config = OfflineDiarizerConfig(
            clusteringThreshold: clusteringThreshold,
            Fb: speakerCount == nil ? speakerPriorWeight : fixedCountSpeakerPriorWeight,
            segmentationStepRatio: segmentationStepRatio
        )
        config.clustering.numSpeakers = speakerCount
        return config
    }

    /// The diarizer's segments as turns, without those no speaker evidence
    /// backs. A stretch no embedding voted for gets a quality of 0 and goes to
    /// the first speaker as a tie-break, so a short reply such as "See you"
    /// showed up as the jingle voice that opened the recording. Without such a
    /// turn the app gives the text to the nearest speaker. On five AMI
    /// meetings this leaves the error rate unchanged.
    static func turns(from segments: [TimedSpeakerSegment]) -> [PluginSpeakerTurn] {
        segments
            .filter { $0.qualityScore > 0 }
            .map {
                PluginSpeakerTurn(
                    speakerLabel: $0.speakerId,
                    start: Double($0.startTimeSeconds),
                    end: Double($0.endTimeSeconds)
                )
            }
    }
    private static let logger = Logger(subsystem: "com.typewhisper.speaker-diarization", category: "Plugin")

    private let state = OSAllocatedUnfairLock<State>(initialState: State())
    private let runner = DiarizationRunner()

    private struct State {
        var host: HostServices?
    }

    required override init() {
        super.init()
    }

    func activate(host: HostServices) {
        state.withLock { $0.host = host }
    }

    func deactivate() {
        state.withLock { $0.host = nil }
        Task { await runner.unload() }
    }

    // MARK: - SpeakerDiarizationProviderPlugin

    var diarizationProviderId: String { Self.pluginId }
    var diarizationProviderDisplayName: String { Self.pluginName }
    var supportedSpeakerCounts: ClosedRange<Int> { Self.speakerCounts }

    var areDiarizationModelsInstalled: Bool {
        guard let directory = modelsDirectory else { return false }
        return Self.modelsExist(in: directory)
    }

    func prepareDiarizationModels(onProgress: @Sendable @escaping (Double) -> Void) async throws {
        let directory = try requireModelsDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await runner.load(from: directory) { progress in
            onProgress(min(max(progress.fractionCompleted, 0), 1))
        }
        onProgress(1)
        state.withLock { $0.host }?.notifyCapabilitiesChanged()
    }

    func deleteDiarizationModels() async throws {
        await runner.unload()
        guard let directory = modelsDirectory,
              FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
        state.withLock { $0.host }?.notifyCapabilitiesChanged()
    }

    func unloadDiarizationModels() async {
        await runner.unload()
    }

    func diarize(
        _ request: PluginDiarizationRequest,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws -> PluginDiarizationResult {
        try await detectSpeakers(request, minimumSpeakerCount: nil, onProgress: onProgress)
    }

    /// Detects the speakers and, when fewer than `minimumSpeakerCount` of them
    /// have `minimumSpeakerShare` of the speech, detects again with a fixed
    /// count; see `speakerCountForSecondPass`.
    func diarize(
        _ request: PluginDiarizationRequest,
        minimumSpeakerCount: Int,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws -> PluginDiarizationResult {
        try await detectSpeakers(request, minimumSpeakerCount: minimumSpeakerCount, onProgress: onProgress)
    }

    private func detectSpeakers(
        _ request: PluginDiarizationRequest,
        minimumSpeakerCount: Int?,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws -> PluginDiarizationResult {
        if let count = request.speakerCount, !supportedSpeakerCounts.contains(count) {
            throw PluginDiarizationError.unsupportedSpeakerCount(count)
        }
        // A fixed count needs no minimum; one beyond the supported counts is left out.
        let minimumSpeakerCount = request.speakerCount == nil
            ? minimumSpeakerCount.map { min($0, supportedSpeakerCounts.upperBound) }.flatMap { $0 > 1 ? $0 : nil }
            : nil
        let directory = try requireModelsDirectory()
        guard Self.modelsExist(in: directory) else {
            throw PluginDiarizationError.modelsNotInstalled
        }
        let start = Date()
        let result = try await runner.diarize(
            audioURL: request.audioURL,
            speakerCount: request.speakerCount,
            minimumSpeakerCount: minimumSpeakerCount,
            modelsDirectory: directory,
            onProgress: onProgress
        )
        Self.logger.info(
            "Diarized \(Set(result.turns.map(\.speakerLabel)).count, privacy: .public) speakers in \(Date().timeIntervalSince(start), privacy: .public) s"
        )
        return result
    }

    // MARK: - Models on disk

    private var modelsDirectory: URL? {
        state.withLock { $0.host }?.pluginDataDirectory.appendingPathComponent("Models", isDirectory: true)
    }

    private func requireModelsDirectory() throws -> URL {
        guard let modelsDirectory else {
            throw PluginDiarizationError.processingFailed("Plugin is not active")
        }
        return modelsDirectory
    }

    /// FluidAudio decides the folder layout below the models directory, so
    /// the required files are looked up by name anywhere beneath it.
    static func modelsExist(in directory: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return false }
        var missing = ModelNames.OfflineDiarizer.requiredModels
        for case let url as URL in enumerator {
            if missing.remove(url.lastPathComponent) != nil, url.pathExtension == "mlmodelc" {
                enumerator.skipDescendants()
            }
            if missing.isEmpty { return true }
        }
        return false
    }
}

/// Serializes model loading and inference; one recording is diarized at a time.
/// The actor alone does not ensure that: it takes the next call at every
/// `await`, so each operation holds a turn until it is done.
private actor DiarizationRunner {
    private var models: OfflineDiarizerModels?
    private var isBusy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private func takeTurn() async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func endTurn() {
        if waiting.isEmpty {
            isBusy = false
        } else {
            waiting.removeFirst().resume()
        }
    }

    func load(from directory: URL, progress: ProgressHandler? = nil) async throws {
        await takeTurn()
        defer { endTurn() }
        try await loadModels(from: directory, progress: progress)
    }

    private func loadModels(from directory: URL, progress: ProgressHandler? = nil) async throws {
        guard models == nil else { return }
        models = try await OfflineDiarizerModels.load(from: directory, progressHandler: progress)
    }

    func unload() {
        models = nil
    }

    func diarize(
        audioURL: URL,
        speakerCount: Int?,
        minimumSpeakerCount: Int?,
        modelsDirectory: URL,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws -> PluginDiarizationResult {
        await takeTurn()
        defer { endTurn() }
        try await loadModels(from: modelsDirectory)
        guard let models else { throw PluginDiarizationError.modelsNotInstalled }
        try Task.checkCancellation()

        // With a minimum, the first pass is the first half of the progress.
        let firstShare = minimumSpeakerCount == nil ? 1.0 : 0.5
        guard var result = try await process(audioURL, speakerCount: speakerCount, models: models, onProgress: {
            onProgress($0 * firstShare)
        }) else {
            return PluginDiarizationResult(turns: [], engine: SpeakerDiarizationPlugin.engineIdentifier)
        }
        var turns = SpeakerDiarizationPlugin.turns(from: result.segments)
        if let minimumSpeakerCount,
           let count = SpeakerDiarizationPlugin.speakerCountForSecondPass(after: turns, minimum: minimumSpeakerCount),
           let second = try await process(audioURL, speakerCount: count, models: models, onProgress: {
               onProgress(firstShare + $0 * (1 - firstShare))
           }) {
            result = second
            turns = SpeakerDiarizationPlugin.turns(from: result.segments)
        }
        onProgress(1)

        let speakers = Set(turns.map(\.speakerLabel))
        return PluginDiarizationResult(
            turns: turns,
            speakerEmbeddings: (result.speakerDatabase ?? [:]).filter { speakers.contains($0.key) },
            speakerEmbeddingModel: SpeakerDiarizationPlugin.speakerEmbeddingModel,
            engine: SpeakerDiarizationPlugin.engineIdentifier
        )
    }

    /// One pass of the offline diarizer, or nil when the audio has no speech.
    private func process(
        _ audioURL: URL,
        speakerCount: Int?,
        models: OfflineDiarizerModels,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws -> DiarizationResult? {
        let manager = OfflineDiarizerManager(config: SpeakerDiarizationPlugin.diarizerConfig(speakerCount: speakerCount))
        manager.initialize(models: models)
        let result: DiarizationResult
        do {
            result = try await manager.process(audioURL) { processed, total in
                guard total > 0 else { return }
                onProgress(min(max(Double(processed) / Double(total), 0), 1))
            }
        } catch OfflineDiarizationError.noSpeechDetected {
            return nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PluginDiarizationError.processingFailed(error.localizedDescription)
        }
        try Task.checkCancellation()
        return result
    }
}
