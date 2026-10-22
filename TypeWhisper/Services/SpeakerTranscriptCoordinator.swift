import AVFoundation
import Combine
import Foundation
import TypeWhisperPluginSDK
import os

private let speakerLogger = Logger(subsystem: AppConstants.loggerSubsystem, category: "SpeakerTranscript")

/// Writes the History audio copy of a recording with speaker detection.
enum SpeakerAudioWriter {
    static let sampleRate: Double = 16_000

    /// Encodes 16 kHz mono samples as AAC in an `.m4a` file.
    static func writeAAC(samples: [Float], to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let chunkFrames = Int(sampleRate) * 30
        var offset = 0
        while offset < samples.count {
            let count = min(chunkFrames, samples.count - offset)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(count)
            ), let channel = buffer.floatChannelData?[0] else {
                throw CocoaError(.fileWriteUnknown)
            }
            samples.withUnsafeBufferPointer { pointer in
                channel.update(from: pointer.baseAddress! + offset, count: count)
            }
            buffer.frameLength = AVAudioFrameCount(count)
            try file.write(from: buffer)
            offset += count
        }
    }
}

/// Turns transcription and diarization results into the speaker model.
enum SpeakerTranscriptBuilder {
    /// The segments of a speaker transcript whose text was edited, as timed
    /// text for a new detection run, so the run keeps the edits; nil while the
    /// transcript holds the text the run would start from anyway. Paragraph
    /// edits change only the speaker transcript and `finalText`, not the
    /// transcription's timing.
    static func editedTimedText(
        of transcript: SpeakerTranscript?,
        insteadOf transcribedTiming: [TimedTextEntry],
        granularity: TimedTextGranularity,
        text: String
    ) -> [TimedTextEntry]? {
        guard let transcript, !transcript.segments.isEmpty else { return nil }
        // Corrections only cut segments apart, so spaces do not count.
        func letters(_ strings: [String]) -> String {
            String(strings.joined().filter { !$0.isWhitespace })
        }
        let transcribed = granularity == .word ? [text] : transcribedTiming.map(\.text)
        guard letters(transcript.segments.map(\.text)) != letters(transcribed) else { return nil }
        let edited = Self.timedText(from: transcript.segments.map {
            TranscriptionSegment(text: $0.text, start: $0.start, end: $0.end)
        })
        return edited.isEmpty ? nil : edited
    }

    /// Segment timing of a transcription, for aligning with speaker turns later.
    static func timedText(from segments: [TranscriptionSegment]) -> [TimedTextEntry] {
        var location = 0
        return segments.compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, segment.start.isFinite, segment.end.isFinite, segment.end >= segment.start else {
                return nil
            }
            let length = (text as NSString).length
            defer { location += length + 1 }
            return TimedTextEntry(
                text: text,
                start: max(0, segment.start),
                end: segment.end,
                utf16Location: location,
                utf16Length: length
            )
        }
    }

    /// A speaker transcript from the labels a transcription engine returned
    /// itself, or nil when it returned none. Labels become `S1`, `S2`, … in
    /// order of first appearance.
    static func providerTranscript(from segments: [TranscriptionSegment], engine: String) -> SpeakerTranscript? {
        guard segments.contains(where: { $0.speakerLabel != nil }) else { return nil }
        var numbering: [String: String] = [:]
        let mapped: [SpeakerTranscriptSegment] = segments.compactMap { segment in
            guard segment.start.isFinite, segment.end.isFinite, segment.start >= 0, segment.end >= segment.start else {
                return nil
            }
            var text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            var speakerID: String?
            if let label = segment.speakerLabel {
                if numbering[label] == nil {
                    numbering[label] = SpeakerTranscript.speakerID(number: numbering.count + 1)
                }
                speakerID = numbering[label]
                // Cloud engines also write the label into the text.
                if text.hasPrefix("\(label):") {
                    text = String(text.dropFirst(label.count + 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            guard !text.isEmpty else { return nil }
            return SpeakerTranscriptSegment(
                text: text,
                start: segment.start,
                end: segment.end,
                speakerID: speakerID,
                speakerConfidence: segment.speakerConfidence.map { min(max($0, 0), 1) }
            )
        }
        let transcript = SpeakerTranscript(
            source: .init(kind: .provider, engine: engine),
            segments: mapped
        )
        return mapped.isEmpty || !transcript.isValid ? nil : transcript
    }

    /// The label a speaker gets in output that carries no name table: API
    /// responses and watch-folder files. Not localized, so scripts can rely on it.
    /// The language code of what an engine stored as a record's language:
    /// "de" for "de", "de-DE" or "German".
    static func languageCode(from stored: String?) -> String? {
        guard let stored = stored?.trimmingCharacters(in: .whitespacesAndNewlines), !stored.isEmpty else { return nil }
        let primary = stored.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.lowercased() } ?? stored
        let codes = Locale.LanguageCode.isoLanguageCodes.map(\.identifier)
        if codes.contains(primary) { return primary }
        let english = Locale(identifier: "en")
        return codes.first {
            english.localizedString(forLanguageCode: $0)?.caseInsensitiveCompare(stored) == .orderedSame
        }
    }

    static func outputLabel(for speakerID: String) -> String {
        "Speaker \(SpeakerTranscript.speakerNumber(of: speakerID) ?? 0)"
    }

    /// `Label: text` paragraphs, one per turn, as cloud engines with speaker labels write their text.
    static func textWithSpeakers(_ segments: [TranscriptionSegment]) -> String {
        var paragraphs: [(label: String?, text: String)] = []
        for segment in segments {
            var text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Cloud engines also write the label into the text.
            if let label = segment.speakerLabel, text.hasPrefix("\(label):") {
                text = String(text.dropFirst(label.count + 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !text.isEmpty else { continue }
            if let last = paragraphs.last, last.label == segment.speakerLabel {
                paragraphs[paragraphs.count - 1].text += " " + text
            } else {
                paragraphs.append((segment.speakerLabel, text))
            }
        }
        return paragraphs
            .map { paragraph in paragraph.label.map { "\($0): \(paragraph.text)" } ?? paragraph.text }
            .joined(separator: "\n\n")
    }
}

/// A transcribed recording or imported file that should get a speaker transcript.
struct SpeakerRecordingInput {
    let result: TranscriptionResult
    /// 16 kHz mono samples of the whole recording.
    let samples: [Float]
    let title: String?
    let source: RecordingSource
    let modelUsed: String?
    /// When the microphone carried the user's own speech, from a Recorder
    /// recording with microphone and system audio.
    var ownSpeech: [ClosedRange<TimeInterval>] = []
    /// The Recorder's `recording_id` for the audio file this record came from.
    var recorderRecordingID: UUID?
}

/// Saves a recording to History and starts speaker detection. Returns the
/// record's ID, or nil when nothing was saved.
typealias SpeakerRecordIntake = @MainActor (SpeakerRecordingInput) async -> UUID?

/// Runs speaker detection for History records: one record at a time, with
/// the Premium check, model download, alignment, and storage.
@MainActor
final class SpeakerTranscriptCoordinator: ObservableObject {
    /// The plugin that ships in the app and provides the detection.
    static let bundledPluginID = "com.typewhisper.speaker-diarization"

    enum Stage: Equatable {
        case waiting
        /// Transcribing again, for a record stored without timestamps.
        case transcribing
        case downloadingModels(Double)
        case detecting(Double)
    }

    enum StartError: Error, Equatable {
        case providerUnavailable
        case audioMissing
        case timingMissing
    }

    /// How a detection run ended. A failed or cancelled run keeps an earlier
    /// transcript, so the transcript alone does not tell whether the run worked.
    enum Outcome: Equatable {
        case succeeded
        case failed
        case cancelled
    }

    /// Records whose speakers are being detected or wait for it.
    @Published private(set) var stages: [UUID: Stage] = [:]
    /// How the last run of each record ended. Set before its stage is removed;
    /// absent while a run is queued or when a sync replaced the record meanwhile.
    @Published private(set) var outcomes: [UUID: Outcome] = [:]
    /// Progress of a model download started from the settings; nil when none runs.
    @Published private(set) var modelDownloadProgress: Double?
    @Published private(set) var modelError: String?

    private let historyService: HistoryService
    private let providerSource: @MainActor () -> (any SpeakerDiarizationProviderPlugin)?
    /// Transcribes a record's audio again to get segment timing, for records
    /// stored without it (dictations). Parameters: audio file and language.
    var timingSource: (@MainActor (URL, String?) async throws -> TranscriptionResult)?
    /// Word timing for a recording whose engine reported none, from a second
    /// pass with a local engine. Parameters: audio file and language. An
    /// empty result leaves the record with segment timing.
    var wordTimingSource: (@MainActor (URL, String?) async throws -> [TranscriptionWord])?
    /// Voice profiles; nil leaves every speaker anonymous.
    var voices: SpeakerVoiceProfileService?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Records whose detection has started, past the wait for earlier ones.
    private var runningRecordIDs: Set<UUID> = []
    private var lastTask: Task<Void, Never>?

    init(
        historyService: HistoryService,
        providerSource: @escaping @MainActor () -> (any SpeakerDiarizationProviderPlugin)?
    ) {
        self.historyService = historyService
        self.providerSource = providerSource
        historyService.isSpeakerDetectionActive = { [weak self] recordID in
            self?.stages[recordID] != nil
        }
    }

    var provider: (any SpeakerDiarizationProviderPlugin)? { providerSource() }

    /// Fixed speaker counts offered besides automatic detection.
    var selectableSpeakerCounts: [Int] {
        provider.map { Array($0.supportedSpeakerCounts) } ?? SpeakerTranscript.selectableSpeakerCounts
    }

    var areModelsInstalled: Bool { provider?.areDiarizationModelsInstalled == true }

    /// The diarization models are downloaded on first use; the managed settings may refuse that.
    private static func requireModelDownloadAllowed() throws {
        if let refusal = ManagedPolicySnapshotStore.shared.providerPolicy.modelDownloadRefusal {
            throw ManagedPolicyRefusal(reason: refusal)
        }
    }

    func downloadModels() {
        guard let provider, modelDownloadProgress == nil else { return }
        if let refusal = ManagedPolicySnapshotStore.shared.providerPolicy.modelDownloadRefusal {
            modelError = refusal
            return
        }
        modelDownloadProgress = 0
        modelError = nil
        Task { [weak self] in
            do {
                try await provider.prepareDiarizationModels { progress in
                    Task { @MainActor in
                        guard self?.modelDownloadProgress != nil else { return }
                        self?.modelDownloadProgress = progress
                    }
                }
                await provider.unloadDiarizationModels()
            } catch {
                self?.modelError = error.localizedDescription
            }
            self?.modelDownloadProgress = nil
        }
    }

    func deleteModels() {
        guard let provider, tasks.isEmpty, modelDownloadProgress == nil else { return }
        modelError = nil
        Task { [weak self] in
            do {
                try await provider.deleteDiarizationModels()
            } catch {
                self?.modelError = error.localizedDescription
            }
            self?.objectWillChange.send()
        }
    }

    /// Why speaker detection cannot start for the record, or nil when it can.
    func startError(for record: TranscriptionRecord) -> StartError? {
        guard providerSource() != nil else { return .providerUnavailable }
        guard historyService.audioFileURL(for: record) != nil else { return .audioMissing }
        guard record.timedTextGranularity != .none || timingSource != nil else { return .timingMissing }
        return nil
    }

    /// Whether a run for the record starts by transcribing it again, for the
    /// segment or word timing it lacks, instead of detecting speakers right
    /// away. Follows the order of `run(recordID:speakerCount:)`.
    func runStartsWithTranscription(for record: TranscriptionRecord) -> Bool {
        if record.timedTextGranularity == .none { return timingSource != nil }
        return record.speakerWords.isEmpty && wordTimingSource != nil
    }

    /// Queues speaker detection for a record with audio and timing.
    /// - Parameter speakerCount: A fixed number of speakers, or nil to detect it.
    /// - Returns: Why detection could not start, or nil when it was queued.
    @discardableResult
    func start(recordID: UUID, speakerCount: Int? = nil) -> StartError? {
        guard let record = historyService.record(withID: recordID) else { return .audioMissing }
        if let error = startError(for: record) {
            if record.speakerTranscriptState == .pending {
                historyService.setSpeakerTranscriptState(.failed, forRecordID: recordID)
            }
            return error
        }
        guard tasks[recordID] == nil else { return nil }

        outcomes[recordID] = nil
        stages[recordID] = .waiting
        if record.speakerTranscript == nil {
            historyService.setSpeakerTranscriptState(.pending, forRecordID: recordID)
        }
        let previous = lastTask
        let task = Task { [weak self] in
            await previous?.value
            // A recording cancelled while it waited was already taken off the queue.
            guard !Task.isCancelled, let self else { return }
            self.runningRecordIDs.insert(recordID)
            defer { self.runningRecordIDs.remove(recordID) }
            await self.run(recordID: recordID, speakerCount: speakerCount)
        }
        tasks[recordID] = task
        lastTask = task
        return nil
    }

    /// Saves a recording with its audio to History. Speaker labels the engine
    /// returned itself are used as they are; otherwise detection is queued.
    /// A Recorder recording that already has its record keeps that record,
    /// whose ID is returned.
    func addRecording(_ input: SpeakerRecordingInput) async -> UUID? {
        if let recordingID = input.recorderRecordingID {
            do {
                if let existing = try historyService.speakerRecord(forRecorderRecordingID: recordingID) {
                    return existing.id
                }
            } catch {
                // Without the lookup a second record for the same recording could be saved.
                speakerLogger.error("Failed to look up the speaker record of a recording: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        let segments = input.result.segments
        let timedText = SpeakerTranscriptBuilder.timedText(from: segments)
        let providerTranscript = SpeakerTranscriptBuilder.providerTranscript(
            from: segments,
            engine: input.result.engineUsed
        )
        // Without timestamps the recording is still kept when a second
        // transcription pass can provide them before detection.
        guard providerTranscript != nil
            || (providerSource() != nil && (!timedText.isEmpty || timingSource != nil)) else { return nil }

        let id = UUID()
        let audioURL = historyService.speakerAudioFileURL(forRecordID: id)
        let samples = input.samples
        let clearGeneration = historyService.clearGeneration
        let didWriteAudio = await Task.detached(priority: .utility) {
            do {
                try SpeakerAudioWriter.writeAAC(samples: samples, to: audioURL)
                return true
            } catch {
                speakerLogger.error("Failed to save speaker audio: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }.value
        guard didWriteAudio, historyService.addSpeakerRecord(
            id: id,
            text: input.result.text,
            title: input.title,
            source: input.source,
            durationSeconds: input.result.duration,
            language: input.result.detectedLanguage,
            engineUsed: input.result.engineUsed,
            modelUsed: input.modelUsed,
            timedText: timedText,
            granularity: timedText.isEmpty ? .none : .segment,
            words: input.result.words,
            ownSpeech: input.ownSpeech,
            recorderRecordingID: input.recorderRecordingID,
            transcript: providerTranscript,
            capturedInClearGeneration: clearGeneration
        ) else { return nil }

        if providerTranscript == nil {
            start(recordID: id)
        }
        return id
    }

    /// Detects speakers for a transcription that is not kept in History: an
    /// API request or a watch-folder file. Returns the segments with
    /// `Speaker N` labels; segments an engine already labelled are returned as they are.
    func labelingSpeakers(
        in result: TranscriptionResult,
        samples: [Float],
        speakerCount: Int? = nil
    ) async throws -> [TranscriptionSegment] {
        // Labels the engine returned are kept, unless a fixed number of speakers was asked for.
        guard speakerCount != nil || !result.segments.contains(where: { $0.speakerLabel != nil }) else {
            return result.segments
        }
        guard let provider = providerSource() else { throw StartError.providerUnavailable }
        let timedText = SpeakerTranscriptBuilder.timedText(from: result.segments)
        guard !timedText.isEmpty else { throw StartError.timingMissing }

        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TypeWhisper-speakers-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        try await Task.detached(priority: .utility) {
            try SpeakerAudioWriter.writeAAC(samples: samples, to: audioURL)
        }.value

        // History records are detected one at a time; wait for them.
        await lastTask?.value
        if !provider.areDiarizationModelsInstalled {
            try Self.requireModelDownloadAllowed()
            try await provider.prepareDiarizationModels { _ in }
        }
        let diarization = try await provider.diarize(
            PluginDiarizationRequest(audioURL: audioURL, duration: result.duration, speakerCount: speakerCount)
        ) { _ in }
        if tasks.isEmpty {
            Task { await provider.unloadDiarizationModels() }
        }
        let turns = SpeakerAlignment.normalizedTurns(diarization.turns.map {
            SpeakerTurn(speakerID: $0.speakerLabel, start: $0.start, end: $0.end)
        })
        guard !turns.isEmpty else { return result.segments }
        return SpeakerAlignment.segments(
            sentences: timedText.map { SpeakerTranscriptSegment(text: $0.text, start: $0.start, end: $0.end) },
            words: result.words,
            turns: turns
        ).map {
            TranscriptionSegment(
                text: $0.text,
                start: $0.start,
                end: $0.end,
                speakerLabel: $0.speakerID.map(SpeakerTranscriptBuilder.outputLabel(for:)),
                speakerConfidence: $0.speakerConfidence
            )
        }
    }

    func cancel(recordID: UUID) {
        guard let task = tasks[recordID] else { return }
        task.cancel()
        // Waiting behind another recording would keep the cancelled one
        // queued until that recording is done, so it leaves the queue now.
        guard !runningRecordIDs.contains(recordID) else { return }
        outcomes[recordID] = .cancelled
        stages[recordID] = nil
        tasks[recordID] = nil
        finishWithoutResult(recordID: recordID)
    }

    private func run(recordID: UUID, speakerCount: Int?) async {
        let provider = providerSource()
        defer {
            stages[recordID] = nil
            tasks[recordID] = nil
            if tasks.isEmpty, let provider {
                Task { await provider.unloadDiarizationModels() }
            }
        }
        guard !Task.isCancelled,
              let provider,
              let record = historyService.record(withID: recordID),
              let audioURL = historyService.audioFileURL(for: record) else {
            outcomes[recordID] = Task.isCancelled ? .cancelled : .failed
            finishWithoutResult(recordID: recordID)
            return
        }
        let text = record.rawText
        let alignmentResetAt = record.transcriptionAlignmentResetAt
        // Sync can replace a version while a provider is suspended. Neither a
        // late result nor an error may change the replacement's alignment state.
        func isCurrent() -> Bool {
            historyService.record(withID: recordID) === record && !record.isDeleted
                && record.rawText == text && record.transcriptionAlignmentResetAt == alignmentResetAt
        }
        var timedText = record.timedText
        var granularity = record.timedTextGranularity
        // Words of a second pass belong to another engine's text.
        var words = record.speakerWordsAreFromSecondPass == true ? [] : record.speakerWords
        var hasWordTiming = !record.speakerWords.isEmpty
        let ownSpeech = record.speakerOwnSpeech
        let duration = record.durationSeconds
        let language = record.language

        do {
            if granularity == .none, let timingSource {
                stages[recordID] = .transcribing
                let result = try await timingSource(audioURL, language)
                guard isCurrent() else { return }
                // The pass only provides times; the saved text stays. Its
                // words then belong to another text, like a second pass.
                let sentences = SpeakerTranscriptPresentation.timedSentences(
                    of: text,
                    duration: duration,
                    timing: result
                )
                let keepsText = !sentences.isEmpty
                timedText = keepsText ? sentences : SpeakerTranscriptBuilder.timedText(from: result.segments)
                granularity = timedText.isEmpty ? .none : .segment
                hasWordTiming = !result.words.isEmpty
                words = keepsText ? [] : result.words
                try Task.checkCancellation()
                historyService.setTimedText(
                    timedText,
                    granularity: granularity,
                    words: result.words,
                    wordsAreFromSecondPass: keepsText,
                    forRecordID: recordID
                )
            }
            if !hasWordTiming, granularity != .none, let wordTimingSource {
                stages[recordID] = .transcribing
                // Without word timing the detection still runs on segments.
                var timed: [TranscriptionWord] = []
                do {
                    timed = try await wordTimingSource(audioURL, language)
                } catch {
                    speakerLogger.info("No word timing from the second pass: \(error.localizedDescription, privacy: .public)")
                }
                try Task.checkCancellation()
                guard isCurrent() else { return }
                speakerLogger.info("Second pass for word timing returned \(timed.count) words")
                if !timed.isEmpty {
                    historyService.setTimedText(
                        timedText,
                        granularity: granularity,
                        words: timed,
                        wordsAreFromSecondPass: true,
                        forRecordID: recordID
                    )
                }
            }
            if !provider.areDiarizationModelsInstalled {
                try Self.requireModelDownloadAllowed()
                stages[recordID] = .downloadingModels(0)
                try await provider.prepareDiarizationModels { [weak self] progress in
                    Task { @MainActor in
                        guard self?.stages[recordID] != nil else { return }
                        self?.stages[recordID] = .downloadingModels(progress)
                    }
                }
            }
            try Task.checkCancellation()
            guard isCurrent() else { return }
            stages[recordID] = .detecting(0)
            let result = try await provider.diarize(
                PluginDiarizationRequest(audioURL: audioURL, duration: duration, speakerCount: speakerCount)
            ) { [weak self] progress in
                Task { @MainActor in
                    guard self?.stages[recordID] != nil else { return }
                    self?.stages[recordID] = .detecting(progress)
                }
            }
            try Task.checkCancellation()
            guard isCurrent() else { return }

            // A paragraph edit is kept: the run starts from the edited text.
            if let edited = SpeakerTranscriptBuilder.editedTimedText(
                of: record.speakerTranscript,
                insteadOf: timedText,
                granularity: granularity,
                text: text
            ) {
                timedText = edited
                granularity = .segment
            }

            // With a microphone channel the user's own speech is taken from it.
            let rawTurns = SpeakerChannelAttribution.combining(result.turns, ownSpeech: ownSpeech)
                .map { SpeakerTurn(speakerID: $0.speakerLabel, start: $0.start, end: $0.end) }
            let numbering = SpeakerAlignment.speakerNumbering(rawTurns)
            let engine = ownSpeech.isEmpty ? result.engine : result.engine + "+microphone-channel"
            guard let transcript = SpeakerAlignment.transcript(
                text: text,
                timedText: timedText,
                granularity: granularity,
                turns: SpeakerAlignment.normalizedTurns(rawTurns),
                words: words,
                source: .init(kind: .local, engine: engine, modelVersion: result.modelVersion),
                requestedSpeakerCount: speakerCount
            ), historyService.storeSpeakerTranscript(
                transcript,
                names: carriedNames(to: transcript, recordID: recordID),
                forRecordID: recordID
            ) else {
                speakerLogger.info("Speaker detection found no speakers")
                outcomes[recordID] = .failed
                finishWithoutResult(recordID: recordID)
                return
            }
            outcomes[recordID] = .succeeded
            if let ownID = numbering[SpeakerChannelAttribution.ownSpeakerLabel],
               transcript.speakerIDs.contains(ownID),
               historyService.record(withID: recordID)?.speakerNames?.displayName(for: ownID) == nil {
                historyService.setSpeakerName(String(localized: "speakers.me"), for: ownID, inRecordID: recordID)
            }
            // Embeddings are keyed by provider labels; the transcript uses numbered speakers.
            var embeddings: [String: [Float]] = [:]
            for (label, embedding) in result.speakerEmbeddings {
                if let speakerID = numbering[label] { embeddings[speakerID] = embedding }
            }
            voices?.recordVoices(
                embeddings,
                model: result.speakerEmbeddingModel ?? result.engine,
                of: transcript,
                recordID: recordID
            )
        } catch is CancellationError {
            guard isCurrent() else { return }
            outcomes[recordID] = .cancelled
            finishWithoutResult(recordID: recordID)
        } catch {
            guard isCurrent() else { return }
            speakerLogger.error("Speaker detection failed: \(error.localizedDescription, privacy: .public)")
            outcomes[recordID] = .failed
            finishWithoutResult(recordID: recordID)
        }
    }

    /// Names of an earlier run stay with the voices that are found again.
    private func carriedNames(to transcript: SpeakerTranscript, recordID: UUID) -> SpeakerNameTable? {
        guard let record = historyService.record(withID: recordID),
              let earlier = record.speakerTranscript else { return nil }
        return SpeakerCarryOver.names(from: earlier, names: record.speakerNames, to: transcript).names
    }

    /// A run that produced nothing keeps an earlier transcript; without one
    /// the record is marked failed so it can be retried.
    private func finishWithoutResult(recordID: UUID) {
        guard let record = historyService.record(withID: recordID) else { return }
        historyService.setSpeakerTranscriptState(
            record.speakerTranscript == nil ? .failed : .ready,
            forRecordID: recordID
        )
    }
}
