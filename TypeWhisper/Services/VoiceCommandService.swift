import Foundation

final class VoiceCommandService: Sendable {
    struct ProcessingResult: Sendable {
        let text: String
        let shouldStop: Bool
    }

    private struct Command: Sendable {
        let pattern: String
        let replacement: String?
        let isStop: Bool
        let isDeleteLastSentence: Bool

        init(pattern: String, replacement: String, isStop: Bool = false, isDeleteLastSentence: Bool = false) {
            self.pattern = pattern
            self.replacement = replacement
            self.isStop = isStop
            self.isDeleteLastSentence = isDeleteLastSentence
        }

        init(pattern: String, isStop: Bool = false, isDeleteLastSentence: Bool = false) {
            self.pattern = pattern
            self.replacement = nil
            self.isStop = isStop
            self.isDeleteLastSentence = isDeleteLastSentence
        }
    }

    private let commands: [Command] = [
        // Paragraph / line breaks
        Command(pattern: "new paragraph", replacement: "\n\n"),
        Command(pattern: "neuer Absatz", replacement: "\n\n"),
        Command(pattern: "new line", replacement: "\n"),
        Command(pattern: "neue Zeile", replacement: "\n"),

        // Punctuation
        Command(pattern: "period", replacement: "."),
        Command(pattern: "Punkt", replacement: "."),
        Command(pattern: "comma", replacement: ","),
        Command(pattern: "Komma", replacement: ","),
        Command(pattern: "question mark", replacement: "?"),
        Command(pattern: "Fragezeichen", replacement: "?"),
        Command(pattern: "exclamation mark", replacement: "!"),
        Command(pattern: "Ausrufezeichen", replacement: "!"),
        Command(pattern: "colon", replacement: ":"),
        Command(pattern: "Doppelpunkt", replacement: ":"),
        Command(pattern: "semicolon", replacement: ";"),
        Command(pattern: "Semikolon", replacement: ";"),

        // Delete last sentence
        Command(pattern: "delete last sentence", isDeleteLastSentence: true),
        Command(pattern: "letzten Satz loeschen", isDeleteLastSentence: true),
        Command(pattern: "letzten Satz löschen", isDeleteLastSentence: true),

        // Stop dictation
        Command(pattern: "stop dictation", isStop: true),
        Command(pattern: "Diktat stoppen", isStop: true),
    ]

    func process(text: String) -> ProcessingResult {
        var result = text
        var shouldStop = false

        // Process from end to beginning to avoid index shifting issues.
        // We repeatedly scan for commands until none are found.
        var didProcess = true
        while didProcess {
            didProcess = false
            for command in commands {
                if let match = findLastMatch(in: result, pattern: command.pattern) {
                    didProcess = true

                    if command.isStop {
                        // Remove the command text and surrounding whitespace
                        result = removeCommandText(in: result, range: match)
                        shouldStop = true
                    } else if command.isDeleteLastSentence {
                        result = deleteLastSentence(in: result, commandRange: match)
                    } else if let replacement = command.replacement {
                        result = replaceCommand(in: result, range: match, with: replacement)
                    }
                    break // restart scan after each replacement
                }
            }
        }

        return ProcessingResult(
            text: result.trimmingCharacters(in: .whitespacesAndNewlines),
            shouldStop: shouldStop
        )
    }

    // MARK: - Private Helpers

    /// Finds the last case-insensitive occurrence of `pattern` at a word boundary in `text`.
    private func findLastMatch(in text: String, pattern: String) -> Range<String.Index>? {
        let lowered = text.lowercased()
        let patternLowered = pattern.lowercased()

        // Search from the end
        var searchEnd = lowered.endIndex
        while searchEnd > lowered.startIndex {
            let searchRange = lowered.startIndex..<searchEnd
            guard let range = lowered.range(of: patternLowered, options: .backwards, range: searchRange) else {
                return nil
            }

            // Check word boundaries
            let isStartBoundary = range.lowerBound == lowered.startIndex ||
                !lowered[lowered.index(before: range.lowerBound)].isLetter
            let isEndBoundary = range.upperBound == lowered.endIndex ||
                !lowered[range.upperBound].isLetter

            if isStartBoundary && isEndBoundary {
                // Map back to original string indices
                return range
            }

            searchEnd = range.lowerBound
        }

        return nil
    }

    /// Removes the command text and any surrounding whitespace.
    private func removeCommandText(in text: String, range: Range<String.Index>) -> String {
        var start = range.lowerBound
        var end = range.upperBound

        // Trim whitespace before the command
        while start > text.startIndex {
            let prev = text.index(before: start)
            if text[prev] == " " {
                start = prev
            } else {
                break
            }
        }

        // Trim whitespace after the command
        while end < text.endIndex, text[end] == " " {
            end = text.index(after: end)
        }

        var result = text
        result.replaceSubrange(start..<end, with: "")
        return result
    }

    /// Replaces a command with its punctuation replacement.
    /// Removes whitespace before the command so punctuation attaches to the previous word.
    private func replaceCommand(in text: String, range: Range<String.Index>, with replacement: String) -> String {
        var start = range.lowerBound
        let end = range.upperBound

        // Trim whitespace before the command so punctuation attaches directly
        while start > text.startIndex {
            let prev = text.index(before: start)
            if text[prev] == " " {
                start = prev
            } else {
                break
            }
        }

        var result = text
        result.replaceSubrange(start..<end, with: replacement)
        return result
    }

    /// Deletes the last sentence before the command. Finds the last sentence-ending
    /// punctuation before the command, and removes everything from after that punctuation
    /// to the command (inclusive).
    private func deleteLastSentence(in text: String, commandRange: Range<String.Index>) -> String {
        // First, remove the command itself
        var start = commandRange.lowerBound

        // Trim whitespace before the command
        while start > text.startIndex {
            let prev = text.index(before: start)
            if text[prev] == " " {
                start = prev
            } else {
                break
            }
        }

        let textBeforeCommand = String(text[text.startIndex..<start])
        let textAfterCommand = String(text[commandRange.upperBound...])

        // Find the last sentence-ending punctuation in the text before the command
        let sentenceEnders: Set<Character> = [".", "!", "?"]
        var lastSentenceEnd: String.Index?

        for idx in textBeforeCommand.indices {
            if sentenceEnders.contains(textBeforeCommand[idx]) {
                lastSentenceEnd = idx
            }
        }

        let cleaned: String
        if let sentenceEnd = lastSentenceEnd {
            // Keep everything up to and including the sentence-ending punctuation
            cleaned = String(textBeforeCommand[...sentenceEnd])
        } else {
            // No sentence ending found - delete everything before the command
            cleaned = ""
        }

        return cleaned + textAfterCommand
    }
}
