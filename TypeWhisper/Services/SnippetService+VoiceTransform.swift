import Foundation

enum SnippetScope: String, CaseIterable, Identifiable {
    case dictation
    case voiceTransform
    case both

    var id: String { rawValue }
    var includesDictation: Bool { self != .voiceTransform }
    var includesVoiceTransform: Bool { self != .dictation }
    var label: String {
        switch self {
        case .dictation: "Dictation"
        case .voiceTransform: "Voice Transform"
        case .both: "Both"
        }
    }
}

extension Snippet {
    var scope: SnippetScope? {
        guard let scopeRawValue else { return .dictation }
        return SnippetScope(rawValue: scopeRawValue)
    }
}

extension SnippetService {
    /// Resolve only the spoken instruction; never pass selected source text here.
    /// Matches are collected from the original input, so expansions cannot cascade.
    func resolveTransformInstruction(_ instruction: String) throws -> TransformInstructionResolution {
        let eligible = snippets.filter { $0.isEnabled && $0.scope?.includesVoiceTransform == true }
        var aliases = Set<String>()
        var matches: [(range: NSRange, snippet: Snippet)] = []
        for snippet in eligible {
            let alias = Self.normalizedTransformTrigger(snippet.trigger)
            guard !alias.isEmpty else { throw TransformSnippetError.invalidTrigger }
            guard aliases.insert(alias).inserted else { throw TransformSnippetError.ambiguousTrigger(snippet.trigger) }
            let words = snippet.trigger.split(whereSeparator: \.isWhitespace)
            let pattern = "(?<![\\p{L}\\p{M}\\p{N}_])"
                + words.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s+")
                + "(?![\\p{L}\\p{M}\\p{N}_])"
            let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            for match in regex.matches(in: instruction, range: NSRange(instruction.startIndex..., in: instruction)) {
                matches.append((match.range, snippet))
            }
        }
        matches.sort {
            if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
            if $0.range.length != $1.range.length { return $0.range.length > $1.range.length }
            return $0.snippet.trigger < $1.snippet.trigger
        }
        let source = instruction as NSString
        var cursor = 0
        var resolved = ""
        var applied: [String] = []
        var replacements: [UUID: String] = [:]
        for match in matches where match.range.location >= cursor {
            guard !Self.containsClipboardPlaceholder(match.snippet.replacement) else {
                throw TransformSnippetError.clipboardPlaceholder
            }
            guard !match.snippet.replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TransformSnippetError.emptyReplacement
            }
            resolved += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let replacement = replacements[match.snippet.id] ?? match.snippet.processedReplacement()
            replacements[match.snippet.id] = replacement
            resolved += replacement
            cursor = NSMaxRange(match.range)
            if !applied.contains(match.snippet.trigger) { applied.append(match.snippet.trigger) }
        }
        resolved += source.substring(from: cursor)
        return TransformInstructionResolution(original: instruction, resolved: resolved, matchedTriggers: applied)
    }

    func transformValidationError(
        trigger: String, replacement: String, scope: SnippetScope, excluding id: UUID? = nil
    ) -> String? {
        guard scope.includesVoiceTransform else { return nil }
        let normalized = Self.normalizedTransformTrigger(trigger)
        guard !normalized.isEmpty else { return TransformSnippetError.invalidTrigger.localizedDescription }
        guard !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return TransformSnippetError.emptyReplacement.localizedDescription
        }
        if Self.containsClipboardPlaceholder(replacement) {
            return TransformSnippetError.clipboardPlaceholder.localizedDescription
        }
        if snippets.contains(where: {
            $0.id != id && $0.scope?.includesVoiceTransform == true
                && Self.normalizedTransformTrigger($0.trigger) == normalized
        }) {
            return TransformSnippetError.ambiguousTrigger(trigger).localizedDescription
        }
        return nil
    }

    private static func normalizedTransformTrigger(_ trigger: String) -> String {
        trigger.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func containsClipboardPlaceholder(_ text: String) -> Bool {
        text.contains("{{CLIPBOARD}}") || text.contains("{clipboard}")
    }
}

struct TransformInstructionResolution: Equatable {
    let original: String
    let resolved: String
    let matchedTriggers: [String]
}

enum TransformSnippetError: LocalizedError {
    case invalidTrigger
    case emptyReplacement
    case ambiguousTrigger(String)
    case clipboardPlaceholder

    var errorDescription: String? {
        switch self {
        case .invalidTrigger: "A voice prompt needs a nonempty trigger."
        case .emptyReplacement: "A voice prompt needs a nonempty instruction."
        case .ambiguousTrigger(let trigger): "More than one voice prompt matches ‘\(trigger)’. Choose a unique trigger."
        case .clipboardPlaceholder: "Voice Transform prompts do not support clipboard placeholders."
        }
    }
}
