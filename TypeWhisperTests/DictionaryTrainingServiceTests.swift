import XCTest
@testable import TypeWhisper

final class DictionaryTrainingServiceTests: XCTestCase {
    private enum TestError: Error {
        case transcriptionFailed
        case saveFailed
    }

    @MainActor
    func testExampleSentencesAreLocalizedDeterministicAndContainTargetOnce() {
        let english = DictionaryTrainingService.exampleSentences(
            for: "TypeWhisper",
            localeIdentifier: "en_US"
        )
        let german = DictionaryTrainingService.exampleSentences(
            for: "TypeWhisper",
            localeIdentifier: "de_DE"
        )

        XCTAssertEqual(english.count, DictionaryTrainingService.requiredSampleCount)
        XCTAssertEqual(german.count, DictionaryTrainingService.requiredSampleCount)
        XCTAssertEqual(
            english,
            DictionaryTrainingService.exampleSentences(for: "TypeWhisper", localeIdentifier: "en_US")
        )
        XCTAssertNotEqual(english, german)
        XCTAssertTrue((english + german).allSatisfy {
            DictionaryTrainingService.sentenceContainsTargetExactlyOnce($0, target: "TypeWhisper")
        })
        XCTAssertTrue(DictionaryTrainingService.isValidCanonicalWord("TypeWhisper"))
        XCTAssertFalse(DictionaryTrainingService.isValidCanonicalWord("Type Whisper"))
        XCTAssertFalse(DictionaryTrainingService.isValidCanonicalWord("TypeWhisper!"))
    }

    @MainActor
    func testEvaluatorAcceptsOnlyOneUnambiguousTargetWordDifference() {
        XCTAssertEqual(
            DictionaryTrainingService.evaluate(
                expectedSentence: "Please write TypeWhisper today.",
                rawTranscript: "Please write TypeWisper today.",
                targetWord: "TypeWhisper"
            ),
            .candidate("TypeWisper")
        )
        XCTAssertEqual(
            DictionaryTrainingService.evaluate(
                expectedSentence: "Please write TypeWhisper today.",
                rawTranscript: "Please write TypeWhisper today!",
                targetWord: "TypeWhisper"
            ),
            .correct
        )
        XCTAssertEqual(
            DictionaryTrainingService.evaluate(
                expectedSentence: "Please write TypeWhisper today.",
                rawTranscript: "Please write typewhisper today.",
                targetWord: "TypeWhisper"
            ),
            .skipped
        )
        XCTAssertEqual(
            DictionaryTrainingService.evaluate(
                expectedSentence: "Please write TypeWhisper today.",
                rawTranscript: "Please now write TypeWisper today.",
                targetWord: "TypeWhisper"
            ),
            .skipped
        )
        XCTAssertEqual(
            DictionaryTrainingService.evaluate(
                expectedSentence: "Please write TypeWhisper today.",
                rawTranscript: "Please type TypeWisper today.",
                targetWord: "TypeWhisper"
            ),
            .skipped
        )
        XCTAssertEqual(
            DictionaryTrainingService.evaluate(
                expectedSentence: "Please write TypeWhisper today.",
                rawTranscript: "",
                targetWord: "TypeWhisper"
            ),
            .skipped
        )
    }

    @MainActor
    func testThreeSamplesUseRawSnapshotTranscriptionAndDeduplicateCandidates() async throws {
        let snapshot = makeSnapshot()
        var requests: [DictionaryTrainingTranscriptionRequest] = []
        var transcriptIndex = 0
        var commitWord: String?
        var commitCandidates: [String] = []
        let transcripts = [
            "Today I want to say TypeWisper clearly.",
            "Please write TypeWisper in this sentence.",
            "The important word today is TypeWhispr."
        ]
        let service = DictionaryTrainingService(dependencies: DictionaryTrainingDependencies(
            engineSnapshot: { snapshot },
            canTranscribe: { true },
            requestMicrophonePermission: { true },
            startRecording: {},
            stopRecording: { [0.1, 0.2] },
            discardActiveRecording: {},
            transcribe: { request in
                requests.append(request)
                defer { transcriptIndex += 1 }
                return transcripts[transcriptIndex]
            },
            dictionaryEntries: { [] },
            commit: { word, candidates in
                commitWord = word
                commitCandidates = candidates
                return DictionaryTrainingCommitResult(
                    addedTerm: true,
                    addedCorrections: candidates,
                    duplicateCorrections: [],
                    conflictingCorrections: []
                )
            }
        ))

        service.canonicalWord = "TypeWhisper"
        service.beginTraining(localeIdentifier: "en_US")
        XCTAssertEqual(service.engineSnapshot, snapshot)

        for sample in service.samples {
            await service.startRecording(sampleID: sample.id)
            await service.stopRecordingAndTranscribe(sampleID: sample.id)
        }

        XCTAssertTrue(service.canProceedToReview)
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests.allSatisfy {
            $0.snapshot == snapshot &&
                $0.prompt == nil &&
                $0.dictionaryTermHints.isEmpty &&
                !$0.normalizeNumbers
        })

        service.proceedToReview()
        XCTAssertEqual(service.candidates.map(\.original), ["TypeWisper", "TypeWhispr"])
        XCTAssertEqual(service.selectedCandidateCount, 2)

        let firstCandidateID = service.candidates[0].id
        let secondCandidateID = service.candidates[1].id
        service.updateCandidate(id: secondCandidateID, original: "TypeWisper")
        XCTAssertEqual(service.selectedCandidateCount, 1)
        XCTAssertEqual(service.candidates[0].disposition, .invalid)
        service.updateCandidate(id: secondCandidateID, original: "TypeWhispr")
        XCTAssertEqual(service.selectedCandidateCount, 2)
        XCTAssertEqual(service.candidates[0].disposition, .available)
        XCTAssertEqual(service.candidates[0].id, firstCandidateID)

        service.confirm()
        XCTAssertEqual(commitWord, "TypeWhisper")
        XCTAssertEqual(commitCandidates, ["TypeWisper", "TypeWhispr"])
        XCTAssertEqual(service.stage, .summary)
    }

    @MainActor
    func testFailedSampleCanRetryWithoutLosingCompletedSamples() async {
        let snapshot = makeSnapshot()
        var shouldFail = false
        let service = DictionaryTrainingService(dependencies: DictionaryTrainingDependencies(
            engineSnapshot: { snapshot },
            canTranscribe: { true },
            requestMicrophonePermission: { true },
            startRecording: {},
            stopRecording: { [0.1] },
            discardActiveRecording: {},
            transcribe: { request in
                if shouldFail { throw TestError.transcriptionFailed }
                return request.snapshot.providerID == snapshot.providerID
                    ? "Today I want to say TypeWhisper clearly."
                    : ""
            },
            dictionaryEntries: { [] },
            commit: { [self] _, _ in self.emptyCommitResult() }
        ))

        service.canonicalWord = "TypeWhisper"
        service.beginTraining(localeIdentifier: "en_US")
        let first = service.samples[0]
        await service.startRecording(sampleID: first.id)
        await service.stopRecordingAndTranscribe(sampleID: first.id)
        XCTAssertEqual(service.samples[0].state, .completed)

        shouldFail = true
        let second = service.samples[1]
        await service.startRecording(sampleID: second.id)
        await service.stopRecordingAndTranscribe(sampleID: second.id)
        guard case .failed = service.samples[1].state else {
            return XCTFail("Expected failed sample")
        }
        XCTAssertEqual(service.samples[0].state, .completed)

        shouldFail = false
        service.retrySample(id: second.id)
        service.updateSentence(id: second.id, sentence: "Today I want to say TypeWhisper clearly.")
        await service.startRecording(sampleID: second.id)
        await service.stopRecordingAndTranscribe(sampleID: second.id)
        XCTAssertEqual(service.samples[1].state, .completed)
        XCTAssertEqual(service.samples[0].state, .completed)
    }

    @MainActor
    func testPreparingSampleRejectsDuplicateRecordingTaskAndEditing() async {
        let snapshot = makeSnapshot()
        var permissionContinuation: CheckedContinuation<Bool, Never>?
        var permissionRequestCount = 0
        var startCount = 0
        let service = DictionaryTrainingService(dependencies: DictionaryTrainingDependencies(
            engineSnapshot: { snapshot },
            canTranscribe: { true },
            requestMicrophonePermission: {
                permissionRequestCount += 1
                return await withCheckedContinuation { continuation in
                    permissionContinuation = continuation
                }
            },
            startRecording: { startCount += 1 },
            stopRecording: { [0.1] },
            discardActiveRecording: {},
            transcribe: { _ in "unused" },
            dictionaryEntries: { [] },
            commit: { [self] _, _ in self.emptyCommitResult() }
        ))

        service.canonicalWord = "TypeWhisper"
        service.beginTraining(localeIdentifier: "en_US")
        let sample = service.samples[0]
        let firstRecording = Task { @MainActor in
            await service.startRecording(sampleID: sample.id)
        }
        await Task.yield()

        XCTAssertEqual(service.samples[0].state, .preparing)
        XCTAssertEqual(service.activeSampleID, sample.id)
        service.updateSentence(id: sample.id, sentence: "Please write TypeWhisper today.")
        XCTAssertEqual(service.samples[0].sentence, sample.sentence)

        await service.startRecording(sampleID: sample.id)
        XCTAssertEqual(permissionRequestCount, 1)

        permissionContinuation?.resume(returning: true)
        await firstRecording.value
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(service.samples[0].state, .recording)
    }

    @MainActor
    func testDependencyCancellationMarksCurrentSampleFailed() async {
        let snapshot = makeSnapshot()
        let service = DictionaryTrainingService(dependencies: DictionaryTrainingDependencies(
            engineSnapshot: { snapshot },
            canTranscribe: { true },
            requestMicrophonePermission: { true },
            startRecording: {},
            stopRecording: { [0.1] },
            discardActiveRecording: {},
            transcribe: { _ in throw CancellationError() },
            dictionaryEntries: { [] },
            commit: { [self] _, _ in self.emptyCommitResult() }
        ))

        service.canonicalWord = "TypeWhisper"
        service.beginTraining(localeIdentifier: "en_US")
        let sampleID = service.samples[0].id
        await service.startRecording(sampleID: sampleID)
        await service.stopRecordingAndTranscribe(sampleID: sampleID)

        guard case .failed = service.samples[0].state else {
            return XCTFail("Expected cancelled transcription to fail the sample")
        }
        XCTAssertNil(service.activeSampleID)
    }

    @MainActor
    func testCancelDuringRecordingDiscardsAudioWithoutDictionaryMutation() async {
        let snapshot = makeSnapshot()
        var stopCount = 0
        var discardCount = 0
        var commitCount = 0
        let service = DictionaryTrainingService(dependencies: DictionaryTrainingDependencies(
            engineSnapshot: { snapshot },
            canTranscribe: { true },
            requestMicrophonePermission: { true },
            startRecording: {},
            stopRecording: {
                stopCount += 1
                return [0.1]
            },
            discardActiveRecording: { discardCount += 1 },
            transcribe: { _ in "unused" },
            dictionaryEntries: { [] },
            commit: { _, _ in
                commitCount += 1
                return self.emptyCommitResult()
            }
        ))

        service.canonicalWord = "TypeWhisper"
        service.beginTraining(localeIdentifier: "en_US")
        await service.startRecording(sampleID: service.samples[0].id)
        await service.cancel()

        XCTAssertEqual(stopCount, 1)
        XCTAssertGreaterThanOrEqual(discardCount, 1)
        XCTAssertEqual(commitCount, 0)
        XCTAssertEqual(service.stage, .word)
    }

    @MainActor
    func testCancelDuringMicrophonePreparationCancelsPendingAudioStart() async {
        let snapshot = makeSnapshot()
        var startContinuation: CheckedContinuation<Void, Error>?
        var cancelStartCount = 0
        var stopCount = 0
        var discardCount = 0
        let service = DictionaryTrainingService(dependencies: DictionaryTrainingDependencies(
            engineSnapshot: { snapshot },
            canTranscribe: { true },
            requestMicrophonePermission: { true },
            startRecording: {
                try await withCheckedThrowingContinuation { continuation in
                    startContinuation = continuation
                }
            },
            cancelRecordingStart: {
                cancelStartCount += 1
                startContinuation?.resume(throwing: CancellationError())
                startContinuation = nil
            },
            stopRecording: {
                stopCount += 1
                return []
            },
            discardActiveRecording: { discardCount += 1 },
            transcribe: { _ in "unused" },
            dictionaryEntries: { [] },
            commit: { [self] _, _ in self.emptyCommitResult() }
        ))

        service.canonicalWord = "TypeWhisper"
        service.beginTraining(localeIdentifier: "en_US")
        let sampleID = service.samples[0].id
        let startTask = Task { @MainActor in
            await service.startRecording(sampleID: sampleID)
        }

        for _ in 0..<20 where startContinuation == nil {
            await Task.yield()
        }
        XCTAssertEqual(service.samples[0].state, .preparing)

        await service.cancel()
        await startTask.value

        XCTAssertEqual(cancelStartCount, 1)
        XCTAssertEqual(stopCount, 0)
        XCTAssertGreaterThanOrEqual(discardCount, 1)
        XCTAssertEqual(service.stage, .word)
        XCTAssertTrue(service.samples.isEmpty)
    }

    @MainActor
    func testLateTranscriptionResultCannotMutateCancelledSession() async {
        let snapshot = makeSnapshot()
        let service = DictionaryTrainingService(dependencies: DictionaryTrainingDependencies(
            engineSnapshot: { snapshot },
            canTranscribe: { true },
            requestMicrophonePermission: { true },
            startRecording: {},
            stopRecording: { [0.1] },
            discardActiveRecording: {},
            transcribe: { _ in
                try await Task.sleep(for: .milliseconds(30))
                return "Today I want to say TypeWisper clearly."
            },
            dictionaryEntries: { [] },
            commit: { [self] _, _ in self.emptyCommitResult() }
        ))

        service.canonicalWord = "TypeWhisper"
        service.beginTraining(localeIdentifier: "en_US")
        let sampleID = service.samples[0].id
        await service.startRecording(sampleID: sampleID)
        let transcription = Task { @MainActor in
            await service.stopRecordingAndTranscribe(sampleID: sampleID)
        }
        await Task.yield()
        await service.cancel()
        await transcription.value

        XCTAssertEqual(service.stage, .word)
        XCTAssertTrue(service.samples.isEmpty)
        XCTAssertTrue(service.candidates.isEmpty)
    }

    @MainActor
    func testDictionaryCommitAddsManualFlatEntriesAndSkipsDuplicateAndConflict() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        let dictionary = DictionaryService(appSupportDirectory: directory)
        dictionary.addEntry(type: .correction, original: "TypeWisper", replacement: "TypeWhisper")
        dictionary.addEntry(type: .correction, original: "TypeWhispr", replacement: "Other")

        let result = try dictionary.applyDictionaryTraining(
            canonicalWord: "TypeWhisper",
            approvedCandidates: ["TypeWisper", "TypeWhispr", "TypeWhispper", "typewhispper"]
        )

        XCTAssertTrue(result.addedTerm)
        XCTAssertEqual(result.addedCorrections, ["TypeWhispper"])
        XCTAssertEqual(result.duplicateCorrections, ["TypeWisper"])
        XCTAssertEqual(result.conflictingCorrections, ["TypeWhispr"])
        XCTAssertTrue(dictionary.entries.contains {
            $0.type == .term && $0.original == "TypeWhisper" && $0.source == .manual
        })
        XCTAssertTrue(dictionary.entries.contains {
            $0.type == .correction &&
                $0.original == "TypeWhispper" &&
                $0.replacement == "TypeWhisper" &&
                $0.source == .manual
        })
        XCTAssertEqual(
            dictionary.entries.first { $0.original == "TypeWhispr" }?.replacement,
            "Other"
        )
    }

    @MainActor
    func testDictionaryCommitRollsBackTermAndCorrectionsOnSaveFailure() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        let dictionary = DictionaryService(appSupportDirectory: directory)
        dictionary.setTrainingSaveOverrideForTesting { throw TestError.saveFailed }

        XCTAssertThrowsError(try dictionary.applyDictionaryTraining(
            canonicalWord: "TypeWhisper",
            approvedCandidates: ["TypeWisper"]
        ))
        XCTAssertTrue(dictionary.entries.isEmpty)
    }

    private func makeSnapshot() -> DictionaryTrainingEngineSnapshot {
        DictionaryTrainingEngineSnapshot(
            providerID: "mock-engine",
            engineName: "Mock Engine",
            modelID: "mock-model",
            modelName: "Mock Model",
            languageSelection: .exact("en")
        )
    }

    @MainActor
    private func emptyCommitResult() -> DictionaryTrainingCommitResult {
        DictionaryTrainingCommitResult(
            addedTerm: false,
            addedCorrections: [],
            duplicateCorrections: [],
            conflictingCorrections: []
        )
    }
}
