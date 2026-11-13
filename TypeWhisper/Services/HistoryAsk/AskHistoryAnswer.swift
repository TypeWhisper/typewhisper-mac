import Foundation

/// A language model's answer to a question about History.
struct AskHistoryAnswer: Equatable, Sendable {
    /// Without citations of sources that do not exist.
    var text: String
    /// The sources the model was given. `[n]` in the text is `sources[n - 1]`.
    var sources: [AskHistorySource]
    /// The numbers of the sources the answer cites, in the order they first appear.
    var citedSources: [Int]
    var providerId: String
    /// All providers that wrote the answer, comma-separated, when an overview's
    /// summaries come from more than one.
    var providerName: String
    /// Recordings of an overview's part of History that the answer leaves out,
    /// for the window to name. A cloud model names them in its text.
    var omittedRecordCount = 0
}

/// How much a provider's context holds, as far as its kind tells.
enum AskHistoryProviderKind: Sendable {
    case appleIntelligence
    /// A model on this Mac, in the MLX or the llama.cpp plugin.
    case local
    /// A server of the user's choice, often a small local one.
    case openAICompatible
    /// A cloud provider or a command-line tool with an account.
    case cloud
}

extension AskHistoryBudget {
    /// Sources Apple Intelligence gets where the system cannot count tokens.
    static let unmeasuredAppleIntelligenceSources = 4_000
    /// The share of Apple Intelligence's context a request may fill. Above
    /// it, citation numbers and then the answers went wrong.
    static let appleIntelligenceContextShare = 0.85

    /// The budget of the first attempt. Apple Intelligence starts with what
    /// its largest context holds and is then measured in tokens.
    static func initial(for kind: AskHistoryProviderKind, isOverview: Bool) -> AskHistoryBudget {
        switch kind {
        case .appleIntelligence: AskHistoryBudget(sourceCharacters: 16_000, historyCharacters: 1_500)
        case .local: AskHistoryBudget(sourceCharacters: 12_000, historyCharacters: 2_000)
        case .openAICompatible: AskHistoryBudget(sourceCharacters: 12_000, historyCharacters: 4_000)
        // Well below what cloud models hold, to keep cost and waiting low.
        case .cloud: AskHistoryBudget(sourceCharacters: isOverview ? 100_000 : 30_000, historyCharacters: 16_000)
        }
    }

    /// The budget of the one retry after the provider reported that the input
    /// exceeded its context.
    func compact(for kind: AskHistoryProviderKind) -> AskHistoryBudget {
        switch kind {
        // Small self-hosted models often have 4,000 to 8,000 tokens.
        case .openAICompatible: AskHistoryBudget(sourceCharacters: 5_000, historyCharacters: 1_000)
        case .appleIntelligence, .local, .cloud: halved
        }
    }
}

extension AskHistoryBudget {
    /// Characters of a recording one summary request holds. Apple Intelligence
    /// gets what fits its smallest context of 4,096 tokens.
    /// Parts are not made smaller than this after a context error.
    static let minimumSummaryCharacters = 1_000

    static func summaryCharacters(for kind: AskHistoryProviderKind) -> Int {
        switch kind {
        case .appleIntelligence: 8_000
        case .local, .openAICompatible: 12_000
        case .cloud: 30_000
        }
    }

    /// The passages of a recording joined into parts of at most the given
    /// length. A longer passage is cut into pieces of that length, at a space
    /// where there is one.
    static func parts(of passages: [String], maximumCharacters: Int) -> [String] {
        let limit = max(maximumCharacters, 1)
        let pieces = passages.flatMap { passage -> [String] in
            var rest = Substring(passage)
            var pieces: [String] = []
            while rest.count > limit {
                let cut = rest.prefix(limit)
                let end = cut.lastIndex(where: \.isWhitespace).flatMap { $0 > cut.startIndex ? $0 : nil } ?? cut.endIndex
                pieces.append(String(rest[..<end]))
                rest = rest[end...].drop(while: \.isWhitespace)
            }
            pieces.append(String(rest))
            return pieces
        }
        var parts: [String] = []
        for passage in pieces where !passage.isEmpty {
            if let last = parts.last, last.count + 1 + passage.count <= maximumCharacters {
                parts[parts.count - 1] = last + "\n" + passage
            } else {
                parts.append(passage)
            }
        }
        return parts
    }
}

extension AskHistoryRequest {
    /// The request for a question, from what a search found for its plan.
    init(
        plan: HistorySearchPlan,
        retrieval: HistoryRetrieval,
        history: [AskHistoryTurn] = [],
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) {
        self.init(
            question: plan.question,
            sources: retrieval.hits.map(AskHistorySource.init),
            history: history,
            overviewRecordCount: retrieval.recordCount,
            overviewReadsWholeRecordings: retrieval.readsWholeRecords,
            answerLanguage: plan.language.flatMap { Locale(identifier: "en_US").localizedString(forLanguageCode: $0) },
            now: now,
            timeZone: timeZone
        )
    }
}

extension AskHistorySource {
    /// The source a prompt shows for a passage that a search found.
    init(_ hit: HistorySearchHit) {
        self.init(
            recordID: hit.recordID,
            recordedAt: hit.recordedAt,
            origin: hit.appName ?? Self.origin(ofSource: hit.source),
            title: hit.title,
            startSeconds: hit.passage.startSeconds,
            text: hit.passage.text
        )
    }

    /// In English, because the prompt is.
    private static func origin(ofSource source: String) -> String? {
        switch RecordingSource(rawValue: source) {
        case .mac: "Mac"
        case .iPhone: "iPhone"
        case .iPad: "iPad"
        case .appleWatch: "Apple Watch"
        case .importedFile: "Imported file"
        case .keyboard: "iOS keyboard"
        case .shortcut: "Shortcut"
        case .windows: "Windows"
        case .recorder: "Recorder"
        case .other, nil: nil
        }
    }
}
