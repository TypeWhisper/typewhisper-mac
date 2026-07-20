import AppKit
import Combine
import Foundation

enum TargetAppCorrectionCommitSignal: String, Codable, Equatable, Sendable {
    case returnKey
    case keypadEnterKey
    case tabKey
    case focusChanged
    case activeApplicationChanged

    var contributionPayloadValue: String {
        switch self {
        case .returnKey:
            "return-key"
        case .keypadEnterKey:
            "keypad-enter-key"
        case .tabKey:
            "tab-key"
        case .focusChanged:
            "focus-changed"
        case .activeApplicationChanged:
            "active-application-changed"
        }
    }
}

struct TargetAppCorrectionObservation: Equatable, Sendable {
    let correctedInsertedText: String
    let commitSignal: TargetAppCorrectionCommitSignal?
}

enum TargetAppCorrectionLearningOutcome: String, Codable, Equatable, Sendable {
    case learned
    case unsupportedTextObservation
    case noEdit
    case ambiguousEdit
    case noCommitBeforeTimeout
    case duplicateCorrection
    case cancelled
    case failed
}

struct TargetAppCorrectionLearningAttemptSnapshot: Codable, Equatable, Sendable {
    let outcome: TargetAppCorrectionLearningOutcome
    let timestamp: Date
    let commitSignal: TargetAppCorrectionCommitSignal?
    let learnedCorrectionCount: Int
}

struct TargetAppCorrectionLearningResult: Equatable, Sendable {
    let snapshot: TargetAppCorrectionLearningAttemptSnapshot
    let learnedCorrections: [LearnedDictionaryCorrection]
    let correctionObservation: TargetAppCorrectionObservation?
}

private func targetAppCorrectionCommitSignal(forKeyCode keyCode: UInt16) -> TargetAppCorrectionCommitSignal? {
    switch keyCode {
    case 0x24:
        return .returnKey
    case 0x4C:
        return .keypadEnterKey
    case 0x30:
        return .tabKey
    default:
        return nil
    }
}

private func installGlobalTargetAppCorrectionKeyMonitor(
    onCommit: @escaping @MainActor (TargetAppCorrectionCommitSignal) -> Void
) -> Any? {
    NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
        guard let signal = targetAppCorrectionCommitSignal(forKeyCode: event.keyCode) else { return }
        Task { @MainActor in
            onCommit(signal)
        }
    }
}

@MainActor
protocol TargetAppCorrectionCommitObserving: AnyObject {
    func start()
    func stop()
}

@MainActor
final class TargetAppCorrectionCommitObserver: TargetAppCorrectionCommitObserving {
    private let onCommit: @MainActor (TargetAppCorrectionCommitSignal) -> Void
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var appActivationObserver: NSObjectProtocol?

    init(onCommit: @escaping @MainActor (TargetAppCorrectionCommitSignal) -> Void) {
        self.onCommit = onCommit
    }

    func start() {
        stop()

        globalKeyMonitor = installGlobalTargetAppCorrectionKeyMonitor(onCommit: onCommit)
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
            return event
        }
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.onCommit(.activeApplicationChanged)
            }
        }
    }

    func stop() {
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        if let appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appActivationObserver)
            self.appActivationObserver = nil
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        guard let signal = Self.commitSignal(forKeyCode: event.keyCode) else { return }
        onCommit(signal)
    }

    static func commitSignal(forKeyCode keyCode: UInt16) -> TargetAppCorrectionCommitSignal? {
        targetAppCorrectionCommitSignal(forKeyCode: keyCode)
    }
}

private final class TargetAppCorrectionWakeCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    private var generation = 0

    func wait(for duration: Duration) async {
        guard duration > .seconds(0), !Task.isCancelled else { return }

        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                let waitID = self.startWait(continuation)
                let task = Task { [weak self] in
                    try? await Task.sleep(for: duration)
                    self?.resume(waitID: waitID)
                }
                self.storeSleepTask(task, waitID: waitID)
            }
        }, onCancel: {
            resume()
        })
    }

    func wake() {
        resume()
    }

    private func startWait(_ continuation: CheckedContinuation<Void, Never>) -> Int {
        lock.lock()
        generation += 1
        let waitID = generation
        self.continuation = continuation
        let oldTask = sleepTask
        sleepTask = nil
        lock.unlock()
        oldTask?.cancel()
        return waitID
    }

    private func storeSleepTask(_ task: Task<Void, Never>, waitID: Int) {
        lock.lock()
        guard waitID == generation, continuation != nil else {
            lock.unlock()
            task.cancel()
            return
        }
        sleepTask = task
        lock.unlock()
    }

    private func resume(waitID: Int? = nil) {
        lock.lock()
        if let waitID, waitID != generation {
            lock.unlock()
            return
        }
        generation += 1
        let task = sleepTask
        sleepTask = nil
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        task?.cancel()
        continuation?.resume()
    }
}

@MainActor
final class TargetAppCorrectionLearningService: ObservableObject {
    private static let defaultPollSchedule: [Duration] = (1...30).map { .seconds($0) }

    private let textInsertionService: TextInsertionService
    private let textDiffService: TextDiffService
    private let learnCorrections: @MainActor ([CorrectionSuggestion]) -> DictionaryCorrectionLearningResult
    private let pollSchedule: [Duration]
    private let sleep: @MainActor (Duration) async -> Void
    private let makeCommitObserver: (@escaping @MainActor (TargetAppCorrectionCommitSignal) -> Void) -> TargetAppCorrectionCommitObserving
    private let defaults: UserDefaults
    private let shouldPersistLatestAttempt: Bool
    private let now: @MainActor () -> Date
    private var activeAttemptID: UUID?

    @Published private(set) var latestAttempt: TargetAppCorrectionLearningAttemptSnapshot?

    init(
        textInsertionService: TextInsertionService,
        textDiffService: TextDiffService,
        dictionaryService: DictionaryService,
        pollSchedule: [Duration]? = nil,
        sleep: @escaping @MainActor (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        },
        makeCommitObserver: @escaping (@escaping @MainActor (TargetAppCorrectionCommitSignal) -> Void) -> TargetAppCorrectionCommitObserving = {
            TargetAppCorrectionCommitObserver(onCommit: $0)
        },
        learnCorrections: (@MainActor ([CorrectionSuggestion]) -> DictionaryCorrectionLearningResult)? = nil,
        defaults: UserDefaults = .standard,
        persistLatestAttempt: Bool = !AppConstants.isRunningTests,
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.textInsertionService = textInsertionService
        self.textDiffService = textDiffService
        self.learnCorrections = learnCorrections ?? { suggestions in
            dictionaryService.learnCorrectionsWithResult(suggestions)
        }
        self.pollSchedule = pollSchedule ?? Self.defaultPollSchedule
        self.sleep = sleep
        self.makeCommitObserver = makeCommitObserver
        self.defaults = defaults
        self.shouldPersistLatestAttempt = persistLatestAttempt
        self.now = now
        self.latestAttempt = Self.loadLatestAttempt(from: defaults)
    }

    func trackInsertion(
        insertedText: String,
        baseline: TextInsertionService.FocusedTextObservation
    ) async -> TargetAppCorrectionLearningResult {
        let attemptID = UUID()
        activeAttemptID = attemptID
        let insertedText = insertedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !insertedText.isEmpty else {
            return completeAttempt(
                id: attemptID,
                outcome: .unsupportedTextObservation,
                commitSignal: nil
            )
        }
        guard !pollSchedule.isEmpty else {
            return completeAttempt(
                id: attemptID,
                outcome: .noCommitBeforeTimeout,
                commitSignal: nil
            )
        }

        var commitSignal: TargetAppCorrectionCommitSignal?
        let wakeCoordinator = TargetAppCorrectionWakeCoordinator()
        let commitObserver = makeCommitObserver { signal in
            commitSignal = signal
            wakeCoordinator.wake()
        }
        commitObserver.start()
        defer { commitObserver.stop() }

        var latestSuggestions: [CorrectionSuggestion] = []
        var latestNonConfidentOutcome: TargetAppCorrectionLearningOutcome = .unsupportedTextObservation
        var latestObservation: TargetAppCorrectionObservation?
        var elapsed: Duration = .seconds(0)
        for pollOffset in pollSchedule {
            let waitDuration: Duration
            if pollOffset > elapsed {
                waitDuration = pollOffset - elapsed
                elapsed = pollOffset
            } else {
                waitDuration = .seconds(0)
            }
            if commitSignal == nil {
                if waitDuration > .seconds(0) {
                    await wakeCoordinator.wait(for: waitDuration)
                } else {
                    await sleep(.seconds(0))
                }
            }
            guard !Task.isCancelled else {
                return completeAttempt(
                    id: attemptID,
                    outcome: .cancelled,
                    commitSignal: commitSignal
                )
            }

            guard let observation = textInsertionService.recaptureFocusedTextObservation(matching: baseline) else {
                switch textInsertionService.focusedTextElementMatch(baseline) {
                case .same, .unavailable:
                    if let commitSignal {
                        return completeCommittedAttempt(
                            id: attemptID,
                            suggestions: latestSuggestions,
                            fallbackOutcome: latestNonConfidentOutcome,
                            commitSignal: commitSignal,
                            correctionObservation: committedObservation(
                                latestObservation,
                                commitSignal: commitSignal
                            )
                        )
                    }
                    continue
                case .different:
                    let resolvedCommitSignal = commitSignal ?? .focusChanged
                    return completeCommittedAttempt(
                        id: attemptID,
                        suggestions: latestSuggestions,
                        fallbackOutcome: latestNonConfidentOutcome,
                        commitSignal: resolvedCommitSignal,
                        correctionObservation: committedObservation(
                            latestObservation,
                            commitSignal: resolvedCommitSignal
                        )
                    )
                }
            }

            latestObservation = correctionObservation(
                insertedText: insertedText,
                baselineText: baseline.value,
                editedText: observation.value,
                commitSignal: commitSignal
            )

            let suggestions = highConfidenceCorrectionSuggestions(
                insertedText: insertedText,
                baselineText: baseline.value,
                editedText: observation.value
            )
            if !suggestions.isEmpty {
                latestSuggestions = suggestions
            } else {
                latestSuggestions = []
                latestNonConfidentOutcome = observation.value == baseline.value ? .noEdit : .ambiguousEdit
            }

            if let commitSignal {
                return completeCommittedAttempt(
                    id: attemptID,
                    suggestions: latestSuggestions,
                    fallbackOutcome: latestNonConfidentOutcome,
                    commitSignal: commitSignal,
                    correctionObservation: latestObservation
                )
            }
        }

        if Task.isCancelled {
            return completeAttempt(
                id: attemptID,
                outcome: .cancelled,
                commitSignal: commitSignal
            )
        }
        return completeAttempt(
            id: attemptID,
            outcome: .noCommitBeforeTimeout,
            commitSignal: nil
        )
    }

    func trackInsertionResult(
        insertedText: String,
        baseline: TextInsertionService.FocusedTextObservation
    ) async -> TargetAppCorrectionLearningResult {
        await trackInsertion(insertedText: insertedText, baseline: baseline)
    }

    private func completeCommittedAttempt(
        id: UUID,
        suggestions: [CorrectionSuggestion],
        fallbackOutcome: TargetAppCorrectionLearningOutcome,
        commitSignal: TargetAppCorrectionCommitSignal,
        correctionObservation: TargetAppCorrectionObservation?
    ) -> TargetAppCorrectionLearningResult {
        guard !suggestions.isEmpty else {
            return completeAttempt(
                id: id,
                outcome: fallbackOutcome,
                commitSignal: commitSignal,
                correctionObservation: correctionObservation
            )
        }

        let dictionaryResult = learnCorrections(suggestions)
        let outcome: TargetAppCorrectionLearningOutcome
        if dictionaryResult.failed {
            outcome = .failed
        } else if !dictionaryResult.learnedCorrections.isEmpty {
            outcome = .learned
        } else if dictionaryResult.duplicateCount > 0 {
            outcome = .duplicateCorrection
        } else {
            outcome = .failed
        }
        return completeAttempt(
            id: id,
            outcome: outcome,
            commitSignal: commitSignal,
            learnedCorrections: dictionaryResult.learnedCorrections,
            correctionObservation: correctionObservation
        )
    }

    private func completeAttempt(
        id: UUID,
        outcome: TargetAppCorrectionLearningOutcome,
        commitSignal: TargetAppCorrectionCommitSignal?,
        learnedCorrections: [LearnedDictionaryCorrection] = [],
        correctionObservation: TargetAppCorrectionObservation? = nil
    ) -> TargetAppCorrectionLearningResult {
        let snapshot = TargetAppCorrectionLearningAttemptSnapshot(
            outcome: outcome,
            timestamp: now(),
            commitSignal: commitSignal,
            learnedCorrectionCount: learnedCorrections.count
        )
        if activeAttemptID == id {
            activeAttemptID = nil
            latestAttempt = snapshot
            persistLatestAttempt(snapshot)
        }
        return TargetAppCorrectionLearningResult(
            snapshot: snapshot,
            learnedCorrections: learnedCorrections,
            correctionObservation: correctionObservation
        )
    }

    private func persistLatestAttempt(_ snapshot: TargetAppCorrectionLearningAttemptSnapshot) {
        guard shouldPersistLatestAttempt else { return }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: UserDefaultsKeys.targetAppCorrectionLearningLatestAttempt)
    }

    private static func loadLatestAttempt(from defaults: UserDefaults) -> TargetAppCorrectionLearningAttemptSnapshot? {
        guard let data = defaults.data(forKey: UserDefaultsKeys.targetAppCorrectionLearningLatestAttempt) else {
            return nil
        }
        return try? JSONDecoder().decode(TargetAppCorrectionLearningAttemptSnapshot.self, from: data)
    }

    func correctedInsertedText(
        insertedText: String,
        baselineText: String,
        editedText: String
    ) -> String? {
        guard let changedRanges = Self.changedRanges(from: baselineText, to: editedText),
              let baselineInsertedRange = Self.insertedRange(
                containing: changedRanges.baseline,
                insertedText: insertedText,
                in: baselineText
              ),
              Self.range(changedRanges.baseline, isContainedIn: baselineInsertedRange) else {
            return nil
        }

        let beforeCorrection = baselineText[baselineInsertedRange.lowerBound..<changedRanges.baseline.lowerBound]
        let correction = editedText[changedRanges.edited]
        let afterCorrection = baselineText[changedRanges.baseline.upperBound..<baselineInsertedRange.upperBound]
        let corrected = (String(beforeCorrection) + String(correction) + String(afterCorrection))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return corrected.isEmpty || corrected == insertedText ? nil : corrected
    }

    private func correctionObservation(
        insertedText: String,
        baselineText: String,
        editedText: String,
        commitSignal: TargetAppCorrectionCommitSignal?
    ) -> TargetAppCorrectionObservation? {
        correctedInsertedText(
            insertedText: insertedText,
            baselineText: baselineText,
            editedText: editedText
        ).map {
            TargetAppCorrectionObservation(
                correctedInsertedText: $0,
                commitSignal: commitSignal
            )
        }
    }

    private func committedObservation(
        _ observation: TargetAppCorrectionObservation?,
        commitSignal: TargetAppCorrectionCommitSignal
    ) -> TargetAppCorrectionObservation? {
        observation.map {
            TargetAppCorrectionObservation(
                correctedInsertedText: $0.correctedInsertedText,
                commitSignal: commitSignal
            )
        }
    }

    func highConfidenceCorrectionSuggestions(
        insertedText: String,
        baselineText: String,
        editedText: String
    ) -> [CorrectionSuggestion] {
        guard let changedRanges = Self.changedRanges(from: baselineText, to: editedText),
              !changedRanges.baseline.isEmpty,
              !changedRanges.edited.isEmpty,
              let baselineInsertedRange = Self.insertedRange(
                containing: changedRanges.baseline,
                insertedText: insertedText,
                in: baselineText
              ) else {
            return []
        }

        let expandedBaselineRange = Self.expandedTokenRange(in: baselineText, around: changedRanges.baseline)
        guard Self.range(expandedBaselineRange, isContainedIn: baselineInsertedRange) else {
            return []
        }

        let expandedEditedRange = Self.expandedTokenRange(in: editedText, around: changedRanges.edited)
        let original = String(baselineText[expandedBaselineRange])
        let edited = String(editedText[expandedEditedRange])

        return textDiffService.extractHighConfidenceCorrections(original: original, edited: edited)
    }

    private static func insertedRange(
        containing changedRange: Range<String.Index>,
        insertedText: String,
        in baselineText: String
    ) -> Range<String.Index>? {
        guard !insertedText.isEmpty else { return nil }

        var searchStart = baselineText.startIndex
        while searchStart <= baselineText.endIndex,
              let range = baselineText.range(of: insertedText, range: searchStart..<baselineText.endIndex) {
            if Self.range(changedRange, isContainedIn: range) {
                return range
            }
            searchStart = range.upperBound
            if searchStart == baselineText.endIndex { break }
        }

        return nil
    }

    private static func changedRanges(
        from baselineText: String,
        to editedText: String
    ) -> (baseline: Range<String.Index>, edited: Range<String.Index>)? {
        guard baselineText != editedText else { return nil }

        var baselinePrefix = baselineText.startIndex
        var editedPrefix = editedText.startIndex
        while baselinePrefix < baselineText.endIndex,
              editedPrefix < editedText.endIndex,
              baselineText[baselinePrefix] == editedText[editedPrefix] {
            baselineText.formIndex(after: &baselinePrefix)
            editedText.formIndex(after: &editedPrefix)
        }

        var baselineSuffix = baselineText.endIndex
        var editedSuffix = editedText.endIndex
        while baselineSuffix > baselinePrefix,
              editedSuffix > editedPrefix {
            let previousBaseline = baselineText.index(before: baselineSuffix)
            let previousEdited = editedText.index(before: editedSuffix)
            guard baselineText[previousBaseline] == editedText[previousEdited] else {
                break
            }
            baselineSuffix = previousBaseline
            editedSuffix = previousEdited
        }

        return (baselinePrefix..<baselineSuffix, editedPrefix..<editedSuffix)
    }

    private static func expandedTokenRange(
        in text: String,
        around range: Range<String.Index>
    ) -> Range<String.Index> {
        var lowerBound = range.lowerBound
        while lowerBound > text.startIndex {
            let previous = text.index(before: lowerBound)
            guard !Self.isWhitespace(text[previous]) else { break }
            lowerBound = previous
        }

        var upperBound = range.upperBound
        while upperBound < text.endIndex, !Self.isWhitespace(text[upperBound]) {
            text.formIndex(after: &upperBound)
        }

        return lowerBound..<upperBound
    }

    private static func range(
        _ inner: Range<String.Index>,
        isContainedIn outer: Range<String.Index>
    ) -> Bool {
        inner.lowerBound >= outer.lowerBound && inner.upperBound <= outer.upperBound
    }

    private static func isWhitespace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }
}
