import Foundation

/// Answers a question about what a part of History held, such as "Summarize
/// last week".
///
/// Cloud models get the beginning of every recording in one prompt and write
/// the overview from it. Apple Intelligence and the local models drop
/// recordings from such a prompt and, given summaries, mostly repeat them. For
/// them every recording is summarized on its own, and the overview is the list
/// of those summaries, newest first, each citing its recording. A summary is
/// kept in the index until its recording changes, so a second overview needs
/// no new ones.
@MainActor
struct AskHistoryOverview {
    /// More summaries would take minutes on a local model.
    static let maximumSummaries = 20

    let index: HistorySearchIndex
    let service: PromptProcessingService

    /// - Parameters:
    ///   - retrieval: The recordings of the plan's scope, newest first.
    ///   - progress: Called before each recording that has to be summarized,
    ///     with its number and how many there are.
    func answer(
        plan: HistorySearchPlan,
        retrieval: HistoryRetrieval,
        history: [AskHistoryTurn] = [],
        now: Date = Date(),
        timeZone: TimeZone = .current,
        providerOverride: String? = nil,
        cloudModelOverride: String? = nil,
        effortOverride: String? = nil,
        progress: (_ number: Int, _ count: Int) -> Void = { _, _ in }
    ) async throws -> AskHistoryAnswer {
        // Each run of the provider list writes the overview its own way, so a
        // local model that stands in for a cloud one still summarizes.
        var failures: [LLMFallbackAttemptFailure] = []
        for run in service.historyOverviewRuns(providerOverride: providerOverride) {
            do {
                if run.usesSummaries, let answer = try await summarized(
                    plan: plan, retrieval: retrieval, candidates: run.candidates, providerOverride: providerOverride,
                    cloudModelOverride: cloudModelOverride, effortOverride: effortOverride, progress: progress
                ) {
                    return answer
                }
                // Without recordings, the model says so in the question's language.
                let found = run.usesSummaries ? HistoryRetrieval(hits: [], recordCount: 0) : retrieval
                return try await service.answerHistoryQuestion(
                    AskHistoryRequest(plan: plan, retrieval: found, history: history, now: now, timeZone: timeZone),
                    providerOverride: providerOverride, cloudModelOverride: cloudModelOverride,
                    effortOverride: effortOverride, candidates: run.candidates
                )
            } catch let error as LLMFallbackExhaustedError {
                failures += error.failures
            }
        }
        throw LLMFallbackExhaustedError(failures: failures)
    }

    /// The list of a summary of each recording, or nil when no recording has text.
    private func summarized(
        plan: HistorySearchPlan,
        retrieval: HistoryRetrieval,
        candidates: Range<Int>,
        providerOverride: String?,
        cloudModelOverride: String?,
        effortOverride: String?,
        progress: (_ number: Int, _ count: Int) -> Void
    ) async throws -> AskHistoryAnswer? {
        let hits = Array(retrieval.hits.prefix(Self.maximumSummaries))
        guard !hits.isEmpty else { return nil }
        // In the question's language, kept apart from those in others.
        let language = plan.language ?? ""
        let languageName = plan.language.flatMap { Locale(identifier: "en_US").localizedString(forLanguageCode: $0) }
        var summaries: [UUID: (text: String, providerId: String)] = [:]
        for hit in hits {
            summaries[hit.recordID] = try await index.summary(ofRecord: hit.recordID, language: language)
        }
        let missing = hits.filter { summaries[$0.recordID] == nil }
        for (offset, hit) in missing.enumerated() {
            try Task.checkCancellation()
            progress(offset + 1, missing.count)
            // Deleted since the search.
            guard let transcript = try await index.transcript(ofRecord: hit.recordID),
                  !transcript.passages.isEmpty else { continue }
            let summary = try await service.summarizeHistoryRecording(
                passages: transcript.passages.map(\.text), title: hit.title, language: languageName,
                providerOverride: providerOverride, cloudModelOverride: cloudModelOverride,
                effortOverride: effortOverride, candidates: candidates
            )
            try await index.setSummary(
                summary.text, providerId: summary.providerId, ofRecord: hit.recordID,
                contentHash: transcript.contentHash, language: language
            )
            summaries[hit.recordID] = summary
        }

        var sources: [AskHistorySource] = []
        var lines: [String] = []
        // The providers that wrote the listed summaries, a fallback among them.
        var providerIds: [String] = []
        for hit in hits {
            guard let summary = summaries[hit.recordID] else { continue }
            var source = AskHistorySource(hit)
            source.text = summary.text
            source.startSeconds = nil
            sources.append(source)
            // Only the number added here cites a recording.
            let title = hit.title.map(AskHistoryCitations.withoutCitations).flatMap { $0.isEmpty ? nil : "\($0): " } ?? ""
            let text = AskHistoryCitations.withoutCitations(summary.text).split(whereSeparator: \.isNewline).joined(separator: " ")
            lines.append("- " + title + text + " [\(sources.count)]")
            if !summary.providerId.isEmpty, !providerIds.contains(summary.providerId) {
                providerIds.append(summary.providerId)
            }
        }
        guard let providerId = providerIds.first else { return nil }
        return AskHistoryAnswer(
            text: lines.joined(separator: "\n"),
            sources: sources,
            citedSources: Array(sources.indices.map { $0 + 1 }),
            providerId: providerId,
            providerName: providerIds.map(service.displayName(for:)).joined(separator: ", "),
            omittedRecordCount: max((retrieval.recordCount ?? retrieval.hits.count) - sources.count, 0)
        )
    }
}
