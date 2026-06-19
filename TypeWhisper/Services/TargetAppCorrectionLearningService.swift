import Foundation

@MainActor
final class TargetAppCorrectionLearningService {
    private let textInsertionService: TextInsertionService
    private let textDiffService: TextDiffService
    private let dictionaryService: DictionaryService
    private let pollSchedule: [Duration]
    private let sleep: @MainActor (Duration) async -> Void

    init(
        textInsertionService: TextInsertionService,
        textDiffService: TextDiffService,
        dictionaryService: DictionaryService,
        pollSchedule: [Duration] = [.seconds(2), .seconds(5), .seconds(10)],
        sleep: @escaping @MainActor (Duration) async -> Void = { duration in
            try? await Task.sleep(for: duration)
        }
    ) {
        self.textInsertionService = textInsertionService
        self.textDiffService = textDiffService
        self.dictionaryService = dictionaryService
        self.pollSchedule = pollSchedule
        self.sleep = sleep
    }

    func trackInsertion(
        insertedText: String,
        baseline: TextInsertionService.FocusedTextObservation
    ) async -> [LearnedDictionaryCorrection] {
        let insertedText = insertedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !insertedText.isEmpty, !pollSchedule.isEmpty else { return [] }

        var finalObservation: TextInsertionService.FocusedTextObservation?
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
                return []
            }
            finalObservation = observation
        }

        guard let finalObservation,
              finalObservation.value != baseline.value else {
            return []
        }

        let suggestions = highConfidenceCorrectionSuggestions(
            insertedText: insertedText,
            baselineText: baseline.value,
            editedText: finalObservation.value
        )
        return dictionaryService.learnCorrections(suggestions)
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
