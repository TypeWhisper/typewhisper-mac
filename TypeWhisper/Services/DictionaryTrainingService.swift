import Foundation
import TypeWhisperPluginSDK

struct DictionaryTrainingEngineSnapshot: Equatable, Sendable {
    let providerID: String
    let engineName: String
    let modelID: String?
    let modelName: String
    let languageSelection: LanguageSelection
}

enum DictionaryTrainingStage: Equatable, Sendable {
    case word
    case samples
    case review
    case summary
}

enum DictionaryTrainingSampleState: Equatable, Sendable {
    case pending
    case preparing
    case recording
    case transcribing
    case completed
    case failed(String)
}

enum DictionaryTrainingSampleEvaluation: Equatable, Sendable {
    case correct
    case candidate(String)
    case skipped
}

struct DictionaryTrainingSample: Identifiable, Equatable, Sendable {
    let id: UUID
    var sentence: String
    var transcript: String?
    var state: DictionaryTrainingSampleState
    var evaluation: DictionaryTrainingSampleEvaluation?
}

enum DictionaryTrainingCandidateDisposition: Equatable, Sendable {
    case available
    case duplicate
    case conflict(existingReplacement: String)
    case invalid
}

struct DictionaryTrainingCandidate: Identifiable, Equatable, Sendable {
    let id: UUID
    var original: String
    var isSelected: Bool
    var disposition: DictionaryTrainingCandidateDisposition
}

struct DictionaryTrainingSummary: Equatable, Sendable {
    let addedTerm: Bool
    let addedCorrections: [String]
    let duplicateCorrections: [String]
    let conflictingCorrections: [String]
}

struct DictionaryTrainingTranscriptionRequest: Equatable, Sendable {
    let audioSamples: [Float]
    let snapshot: DictionaryTrainingEngineSnapshot
    let prompt: String?
    let dictionaryTermHints: [PluginDictionaryTermHint]
    let normalizeNumbers: Bool
}

@MainActor
struct DictionaryTrainingDependencies {
    var engineSnapshot: () -> DictionaryTrainingEngineSnapshot?
    var canTranscribe: () -> Bool
    var requestMicrophonePermission: () async -> Bool
    var startRecording: () async throws -> Void
    var cancelRecordingStart: () -> Void = {}
    var stopRecording: () async -> [Float]
    var discardActiveRecording: () -> Void
    var transcribe: (DictionaryTrainingTranscriptionRequest) async throws -> String
    var dictionaryEntries: () -> [DictionaryEntry]
    var commit: (String, [String]) throws -> DictionaryTrainingCommitResult

    static func live(
        audioRecordingService: AudioRecordingService,
        modelManager: ModelManagerService,
        settingsViewModel: SettingsViewModel,
        dictionaryService: DictionaryService
    ) -> DictionaryTrainingDependencies {
        DictionaryTrainingDependencies(
            engineSnapshot: {
                guard let providerID = modelManager.selectedProviderId,
                      let engineName = modelManager.activeEngineName else {
                    return nil
                }
                return DictionaryTrainingEngineSnapshot(
                    providerID: providerID,
                    engineName: engineName,
                    modelID: modelManager.selectedModelId,
                    modelName: modelManager.activeModelName ?? engineName,
                    languageSelection: settingsViewModel.languageSelection
                )
            },
            canTranscribe: { modelManager.canTranscribe },
            requestMicrophonePermission: {
                await audioRecordingService.requestMicrophonePermission()
            },
            startRecording: {
                try await audioRecordingService.startRecordingAsync()
            },
            cancelRecordingStart: {
                audioRecordingService.cancelPendingRecordingStart()
            },
            stopRecording: {
                await audioRecordingService.stopRecording(policy: .immediate)
            },
            discardActiveRecording: {
                audioRecordingService.discardActiveRecoveryRecording()
            },
            transcribe: { request in
                let result = try await modelManager.transcribe(
                    audioSamples: request.audioSamples,
                    languageSelection: request.snapshot.languageSelection,
                    task: .transcribe,
                    engineOverrideId: request.snapshot.providerID,
                    cloudModelOverride: request.snapshot.modelID,
                    prompt: request.prompt,
                    dictionaryTermHints: request.dictionaryTermHints,
                    normalizeNumbers: request.normalizeNumbers
                )
                return result.text
            },
            dictionaryEntries: { dictionaryService.entries },
            commit: { canonicalWord, candidates in
                try dictionaryService.applyDictionaryTraining(
                    canonicalWord: canonicalWord,
                    approvedCandidates: candidates
                )
            }
        )
    }
}

@MainActor
final class DictionaryTrainingService: ObservableObject {
    static let requiredSampleCount = 3

    @Published private(set) var stage: DictionaryTrainingStage = .word
    @Published var canonicalWord = ""
    @Published private(set) var engineSnapshot: DictionaryTrainingEngineSnapshot?
    @Published private(set) var samples: [DictionaryTrainingSample] = []
    @Published private(set) var candidates: [DictionaryTrainingCandidate] = []
    @Published private(set) var summary: DictionaryTrainingSummary?
    @Published private(set) var errorMessage: String?

    private let dependencies: DictionaryTrainingDependencies
    private var isCancelled = false
    private var sessionID = UUID()

    init(dependencies: DictionaryTrainingDependencies) {
        self.dependencies = dependencies
    }

    convenience init(
        audioRecordingService: AudioRecordingService,
        modelManager: ModelManagerService,
        settingsViewModel: SettingsViewModel,
        dictionaryService: DictionaryService
    ) {
        self.init(dependencies: .live(
            audioRecordingService: audioRecordingService,
            modelManager: modelManager,
            settingsViewModel: settingsViewModel,
            dictionaryService: dictionaryService
        ))
    }

    var activeSampleID: UUID? {
        samples.first {
            $0.state == .preparing || $0.state == .recording || $0.state == .transcribing
        }?.id
    }

    var canProceedToReview: Bool {
        samples.count >= Self.requiredSampleCount && samples.allSatisfy {
            $0.state == .completed
        }
    }

    var selectedCandidateCount: Int {
        candidates.filter {
            $0.isSelected && $0.disposition == .available
        }.count
    }

    func reset() {
        sessionID = UUID()
        stage = .word
        canonicalWord = ""
        engineSnapshot = nil
        samples = []
        candidates = []
        summary = nil
        errorMessage = nil
        isCancelled = false
        dependencies.discardActiveRecording()
    }

    func beginTraining(localeIdentifier: String = Locale.current.identifier) {
        errorMessage = nil
        let normalizedWord = canonicalWord.trimmingCharacters(in: .whitespacesAndNewlines)

        guard Self.isValidCanonicalWord(normalizedWord) else {
            errorMessage = localizedAppText(
                "Enter exactly one word without punctuation.",
                de: "Gib genau ein Wort ohne Satzzeichen ein."
            )
            return
        }
        guard dependencies.canTranscribe(), let snapshot = dependencies.engineSnapshot() else {
            errorMessage = localizedAppText(
                "The selected transcription engine or model is unavailable.",
                de: "Die ausgewählte Transkriptions-Engine oder das Modell ist nicht verfügbar."
            )
            return
        }

        canonicalWord = normalizedWord
        engineSnapshot = snapshot
        samples = Self.exampleSentences(
            for: normalizedWord,
            localeIdentifier: localeIdentifier
        ).map {
            DictionaryTrainingSample(
                id: UUID(),
                sentence: $0,
                transcript: nil,
                state: .pending,
                evaluation: nil
            )
        }
        candidates = []
        summary = nil
        isCancelled = false
        stage = .samples
    }

    func updateSentence(id: UUID, sentence: String) {
        guard let index = samples.firstIndex(where: { $0.id == id }),
              samples[index].state != .preparing,
              samples[index].state != .recording,
              samples[index].state != .transcribing else {
            return
        }
        samples[index].sentence = sentence
        samples[index].transcript = nil
        samples[index].evaluation = nil
        samples[index].state = .pending
    }

    func startRecording(sampleID: UUID) async {
        errorMessage = nil
        let requestedSessionID = sessionID
        guard activeSampleID == nil,
              let index = samples.firstIndex(where: { $0.id == sampleID }) else {
            return
        }
        guard Self.sentenceContainsTargetExactlyOnce(samples[index].sentence, target: canonicalWord) else {
            samples[index].state = .failed(localizedAppText(
                "The sentence must contain the target word exactly once.",
                de: "Der Satz muss das Zielwort genau einmal enthalten."
            ))
            return
        }
        samples[index].state = .preparing
        guard await dependencies.requestMicrophonePermission() else {
            guard requestedSessionID == sessionID else { return }
            samples[index].state = .failed(localizedAppText(
                "Microphone permission is required.",
                de: "Der Mikrofonzugriff ist erforderlich."
            ))
            return
        }

        do {
            guard requestedSessionID == sessionID else { return }
            try await dependencies.startRecording()
            guard requestedSessionID == sessionID,
                  !isCancelled,
                  samples.indices.contains(index),
                  samples[index].id == sampleID else {
                _ = await dependencies.stopRecording()
                dependencies.discardActiveRecording()
                return
            }
            samples[index].transcript = nil
            samples[index].evaluation = nil
            samples[index].state = .recording
        } catch {
            dependencies.discardActiveRecording()
            guard requestedSessionID == sessionID,
                  samples.indices.contains(index),
                  samples[index].id == sampleID else {
                return
            }
            samples[index].state = .failed(error.localizedDescription)
        }
    }

    func stopRecordingAndTranscribe(sampleID: UUID) async {
        guard let index = samples.firstIndex(where: { $0.id == sampleID }),
              samples[index].state == .recording,
              let snapshot = engineSnapshot else {
            return
        }
        let requestedSessionID = sessionID

        samples[index].state = .transcribing
        let sentence = samples[index].sentence
        let audioSamples = await dependencies.stopRecording()
        defer { dependencies.discardActiveRecording() }

        guard requestedSessionID == sessionID, !isCancelled else { return }
        guard !audioSamples.isEmpty else {
            samples[index].state = .failed(localizedAppText(
                "No audio was recorded.",
                de: "Es wurde kein Audio aufgenommen."
            ))
            return
        }

        do {
            let request = DictionaryTrainingTranscriptionRequest(
                audioSamples: audioSamples,
                snapshot: snapshot,
                prompt: nil,
                dictionaryTermHints: [],
                normalizeNumbers: false
            )
            let transcript = try await dependencies.transcribe(request)
            guard !Task.isCancelled,
                  requestedSessionID == sessionID,
                  !isCancelled else { return }
            let evaluation = Self.evaluate(
                expectedSentence: sentence,
                rawTranscript: transcript,
                targetWord: canonicalWord
            )
            samples[index].transcript = transcript
            samples[index].evaluation = evaluation
            samples[index].state = .completed
        } catch is CancellationError {
            guard requestedSessionID == sessionID, !isCancelled else { return }
            samples[index].state = .failed(localizedAppText(
                "Transcription was cancelled.",
                de: "Die Transkription wurde abgebrochen."
            ))
        } catch {
            guard requestedSessionID == sessionID, !isCancelled else { return }
            samples[index].state = .failed(error.localizedDescription)
        }
    }

    func retrySample(id: UUID) {
        guard let index = samples.firstIndex(where: { $0.id == id }),
              samples[index].state != .preparing,
              samples[index].state != .recording,
              samples[index].state != .transcribing else {
            return
        }
        samples[index].transcript = nil
        samples[index].evaluation = nil
        samples[index].state = .pending
    }

    func proceedToReview() {
        guard canProceedToReview else { return }
        candidates = makeCandidates()
        stage = .review
    }

    func returnToSamples() {
        guard stage == .review else { return }
        stage = .samples
    }

    func updateCandidate(id: UUID, original: String) {
        guard let index = candidates.firstIndex(where: { $0.id == id }) else { return }
        candidates[index].original = original
        refreshCandidateDispositions(keeping: id)
    }

    func setCandidateSelected(id: UUID, selected: Bool) {
        guard let index = candidates.firstIndex(where: { $0.id == id }),
              candidates[index].disposition == .available else {
            return
        }
        candidates[index].isSelected = selected
    }

    func confirm() {
        errorMessage = nil
        let selected = candidates.compactMap { candidate in
            candidate.isSelected && candidate.disposition == .available
                ? candidate.original.trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
        }

        do {
            let result = try dependencies.commit(canonicalWord, selected)
            summary = DictionaryTrainingSummary(
                addedTerm: result.addedTerm,
                addedCorrections: result.addedCorrections,
                duplicateCorrections: result.duplicateCorrections,
                conflictingCorrections: result.conflictingCorrections
            )
            stage = .summary
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancel() async {
        isCancelled = true
        if let activeSampleID,
           let index = samples.firstIndex(where: { $0.id == activeSampleID }),
           samples[index].state == .preparing {
            dependencies.cancelRecordingStart()
        }
        if let activeSampleID,
           let index = samples.firstIndex(where: { $0.id == activeSampleID }),
           samples[index].state == .recording {
            _ = await dependencies.stopRecording()
        }
        dependencies.discardActiveRecording()
        reset()
    }

    static func exampleSentences(for word: String, localeIdentifier: String) -> [String] {
        let isGerman = localeIdentifier.lowercased().hasPrefix("de")
        if isGerman {
            return [
                "Heute möchte ich \(word) deutlich sagen.",
                "Bitte schreibe \(word) in diesen Satz.",
                "Das wichtige Wort ist heute \(word)."
            ]
        }
        return [
            "Today I want to say \(word) clearly.",
            "Please write \(word) in this sentence.",
            "The important word today is \(word)."
        ]
    }

    static func isValidCanonicalWord(_ word: String) -> Bool {
        let tokens = wordTokens(in: word)
        return tokens.count == 1 && tokens[0] == word
    }

    static func sentenceContainsTargetExactlyOnce(_ sentence: String, target: String) -> Bool {
        wordTokens(in: sentence).filter {
            $0.compare(target, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }.count == 1
    }

    static func evaluate(
        expectedSentence: String,
        rawTranscript: String,
        targetWord: String
    ) -> DictionaryTrainingSampleEvaluation {
        let expectedTokens = wordTokens(in: expectedSentence)
        let transcriptTokens = wordTokens(in: rawTranscript)

        guard !transcriptTokens.isEmpty,
              expectedTokens.count == transcriptTokens.count else {
            return .skipped
        }

        let differences = zip(expectedTokens, transcriptTokens).enumerated().filter { _, pair in
            pair.0 != pair.1
        }
        guard differences.count == 1,
              let difference = differences.first else {
            if expectedTokens == transcriptTokens {
                return .correct
            }
            return .skipped
        }

        let expectedWord = difference.element.0
        let candidate = difference.element.1
        guard expectedWord.compare(
            targetWord,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) == .orderedSame else {
            return .skipped
        }
        guard candidate.compare(
            targetWord,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != .orderedSame else {
            return .skipped
        }
        guard isValidCanonicalWord(candidate) else { return .skipped }
        return .candidate(candidate)
    }

    private func makeCandidates() -> [DictionaryTrainingCandidate] {
        var seen = Set<String>()
        return samples.compactMap { sample in
            guard case .candidate(let original) = sample.evaluation else { return nil }
            let key = normalizedKey(original)
            guard seen.insert(key).inserted else { return nil }
            let disposition = disposition(for: original)
            return DictionaryTrainingCandidate(
                id: UUID(),
                original: original,
                isSelected: disposition == .available,
                disposition: disposition
            )
        }
    }

    private func disposition(for rawCandidate: String) -> DictionaryTrainingCandidateDisposition {
        let candidate = rawCandidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidCanonicalWord(candidate),
              normalizedKey(candidate) != normalizedKey(canonicalWord) else {
            return .invalid
        }

        guard let existing = dependencies.dictionaryEntries().first(where: {
            $0.type == .correction && normalizedKey($0.original) == normalizedKey(candidate)
        }) else {
            return .available
        }

        if normalizedKey(existing.replacement ?? "") == normalizedKey(canonicalWord) {
            return .duplicate
        }
        return .conflict(existingReplacement: existing.replacement ?? "")
    }

    private func refreshCandidateDispositions(keeping candidateID: UUID) {
        for index in candidates.indices {
            let wasAvailable = candidates[index].disposition == .available
            candidates[index].disposition = disposition(for: candidates[index].original)
            if candidates[index].disposition != .available {
                candidates[index].isSelected = false
            } else if !wasAvailable || candidates[index].id == candidateID {
                candidates[index].isSelected = true
            }
        }

        var preferredIndexByKey: [String: Int] = [:]
        for index in candidates.indices where candidates[index].disposition == .available {
            let key = normalizedKey(candidates[index].original)
            guard !key.isEmpty else { continue }

            if let existingIndex = preferredIndexByKey[key] {
                let duplicateIndex: Int
                if candidates[index].id == candidateID {
                    duplicateIndex = existingIndex
                    preferredIndexByKey[key] = index
                } else {
                    duplicateIndex = index
                }
                candidates[duplicateIndex].disposition = .invalid
                candidates[duplicateIndex].isSelected = false
            } else {
                preferredIndexByKey[key] = index
            }
        }
    }

    private func normalizedKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
    }

    private static func wordTokens(in text: String) -> [String] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let pattern = #"[\p{L}\p{N}]+(?:['’_-][\p{L}\p{N}]+)*"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: text, range: range).compactMap { match in
            guard let tokenRange = Range(match.range, in: text) else { return nil }
            return String(text[tokenRange])
        }
    }
}
