import FluidAudio
import Foundation
import TypeWhisperPluginSDK
import os

/// Runs FluidAudio's offline diarizer (segmentation, speaker embeddings, VBx
/// clustering) on a recorded file.
@objc(SpeakerDiarizationPlugin)
final class SpeakerDiarizationPlugin: NSObject, SpeakerDiarizationProviderPlugin, @unchecked Sendable {
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
    var supportedSpeakerCounts: ClosedRange<Int> { 2...8 }

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
        if let count = request.speakerCount, !supportedSpeakerCounts.contains(count) {
            throw PluginDiarizationError.unsupportedSpeakerCount(count)
        }
        let directory = try requireModelsDirectory()
        guard Self.modelsExist(in: directory) else {
            throw PluginDiarizationError.modelsNotInstalled
        }
        let start = Date()
        let result = try await runner.diarize(
            audioURL: request.audioURL,
            speakerCount: request.speakerCount,
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
        modelsDirectory: URL,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws -> PluginDiarizationResult {
        await takeTurn()
        defer { endTurn() }
        try await loadModels(from: modelsDirectory)
        guard let models else { throw PluginDiarizationError.modelsNotInstalled }
        try Task.checkCancellation()

        var config = OfflineDiarizerConfig(clusteringThreshold: SpeakerDiarizationPlugin.clusteringThreshold)
        config.clustering.numSpeakers = speakerCount
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: models)

        let result: DiarizationResult
        do {
            result = try await manager.process(audioURL) { processed, total in
                guard total > 0 else { return }
                onProgress(min(max(Double(processed) / Double(total), 0), 1))
            }
        } catch OfflineDiarizationError.noSpeechDetected {
            return PluginDiarizationResult(turns: [], engine: SpeakerDiarizationPlugin.engineIdentifier)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PluginDiarizationError.processingFailed(error.localizedDescription)
        }
        try Task.checkCancellation()

        let turns = SpeakerDiarizationPlugin.turns(from: result.segments)
        let speakers = Set(turns.map(\.speakerLabel))
        return PluginDiarizationResult(
            turns: turns,
            speakerEmbeddings: (result.speakerDatabase ?? [:]).filter { speakers.contains($0.key) },
            speakerEmbeddingModel: SpeakerDiarizationPlugin.speakerEmbeddingModel,
            engine: SpeakerDiarizationPlugin.engineIdentifier
        )
    }
}
