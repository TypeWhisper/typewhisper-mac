import AppKit
import Foundation

enum TargetAppCorrectionCommitSignal: Equatable, Sendable {
    case returnKey
    case tabKey
    case activeApplicationChanged
}

@MainActor
protocol TargetAppCorrectionCommitObserving: AnyObject {
    func start()
    func stop()
}

@MainActor
final class TargetAppCorrectionCommitObserver: TargetAppCorrectionCommitObserving {
    private static let returnKeyCode: UInt16 = 0x24
    private static let keypadEnterKeyCode: UInt16 = 0x4C
    private static let tabKeyCode: UInt16 = 0x30

    private let onCommit: @MainActor (TargetAppCorrectionCommitSignal) -> Void
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var appActivationObserver: NSObjectProtocol?

    init(onCommit: @escaping @MainActor (TargetAppCorrectionCommitSignal) -> Void) {
        self.onCommit = onCommit
    }

    func start() {
        stop()

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
        }
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
        switch keyCode {
        case returnKeyCode, keypadEnterKeyCode:
            return .returnKey
        case tabKeyCode:
            return .tabKey
        default:
            return nil
        }
    }
}

@MainActor
final class TargetAppCorrectionLearningService {
    private static let defaultPollSchedule: [Duration] = (1...30).map { .seconds($0) }

    private let textInsertionService: TextInsertionService
    private let textDiffService: TextDiffService
    private let dictionaryService: DictionaryService
    private let pollSchedule: [Duration]
    private let sleep: @MainActor (Duration) async -> Void
    private let makeCommitObserver: (@escaping @MainActor (TargetAppCorrectionCommitSignal) -> Void) -> TargetAppCorrectionCommitObserving

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
        }
    ) {
        self.textInsertionService = textInsertionService
        self.textDiffService = textDiffService
        self.dictionaryService = dictionaryService
        self.pollSchedule = pollSchedule ?? Self.defaultPollSchedule
        self.sleep = sleep
        self.makeCommitObserver = makeCommitObserver
    }

    func trackInsertion(
        insertedText: String,
        baseline: TextInsertionService.FocusedTextObservation
    ) async -> [LearnedDictionaryCorrection] {
        let insertedText = insertedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !insertedText.isEmpty, !pollSchedule.isEmpty else { return [] }

        var commitSignal: TargetAppCorrectionCommitSignal?
        let commitObserver = makeCommitObserver { signal in
            commitSignal = signal
        }
        commitObserver.start()
        defer { commitObserver.stop() }

        var latestSuggestions: [CorrectionSuggestion] = []
        var elapsed: Duration = .seconds(0)
        for pollOffset in pollSchedule {
            if pollOffset > elapsed {
                await sleep(pollOffset - elapsed)
                elapsed = pollOffset
            } else {
                await sleep(.seconds(0))
            }
            guard !Task.isCancelled else { return [] }

            guard let observation = textInsertionService.recaptureFocusedTextObservation(matching: baseline) else {
                if textInsertionService.focusedTextElementMatches(baseline) {
                    return []
                }
                return dictionaryService.learnCorrections(latestSuggestions)
            }

            let suggestions = highConfidenceCorrectionSuggestions(
                insertedText: insertedText,
                baselineText: baseline.value,
                editedText: observation.value
            )
            if !suggestions.isEmpty {
                latestSuggestions = suggestions
            }

            if commitSignal != nil {
                return dictionaryService.learnCorrections(latestSuggestions)
            }
        }

        return []
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
