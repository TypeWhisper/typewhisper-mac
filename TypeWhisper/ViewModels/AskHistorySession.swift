import Foundation

/// One question of a conversation about History and what became of it.
struct AskHistorySessionTurn: Identifiable, Equatable {
    enum Stage: Equatable {
        /// The index takes in History's records, on first use all of them.
        case preparingIndex
        case searching
        /// An overview on Apple Intelligence or a local model summarizes
        /// recording `number` of `count`.
        case summarizing(number: Int, count: Int)
        case answering
        case answered
        /// No language model is set up. `found` still holds what the search found.
        case needsLanguageModel
        case stopped
        case failed(String)
    }

    let id = UUID()
    let question: String
    var stage = Stage.searching
    /// The passages the search found, best first, before the budget picks
    /// the sources of the answer.
    var found: [HistorySearchHit] = []
    var answer: AskHistoryAnswer?

    var isFinished: Bool {
        switch stage {
        case .preparingIndex, .searching, .summarizing, .answering: false
        case .answered, .needsLanguageModel, .stopped, .failed: true
        }
    }

    /// The passages the answer cites, which a follow-up question keeps as
    /// candidates. Empty for an overview, whose sources are summaries.
    var citedPassages: [HistorySearchHit] {
        guard let answer else { return [] }
        return answer.citedSources.compactMap { number in
            let source = answer.sources[number - 1]
            return found.first { $0.recordID == source.recordID && $0.passage.text == source.text }
        }
    }
}

/// A conversation about History: plans each question, searches the index and
/// has a language model answer from what it found.
@MainActor
final class AskHistorySession: ObservableObject {
    static let maximumQuestionCharacters = 2_000
    /// Passages a question gets before the budget picks its sources.
    static let lookupLimit = 12
    /// Recordings an overview reads at most. A cloud model's budget holds the
    /// beginning of about this many; the others summarize the newest 20.
    static let overviewLimit = 100

    @Published private(set) var turns: [AskHistorySessionTurn] = []
    @Published private(set) var isWorking = false
    /// When the conversation last changed, so the panel can tell whether to continue it.
    @Published private(set) var updatedAt: Date
    /// The provider the panel chose for Ask, or nil for the global list.
    var providerOverride: String?

    private let index: HistorySearchIndex
    private let retriever: HistoryRetriever
    private let service: PromptProcessingService
    private let prepareIndex: @MainActor () async -> Void
    private let now: () -> Date
    private var task: Task<Void, Never>?
    /// Tells a question that ended after a new conversation began from the running one.
    private var generation = UUID()
    private var preparation: Task<Void, Never>?

    /// - Parameter prepareIndex: Turns the index on and brings it up to date.
    ///   Called when the panel opens.
    init(
        index: HistorySearchIndex,
        retriever: HistoryRetriever,
        service: PromptProcessingService,
        prepareIndex: @escaping @MainActor () async -> Void = {},
        now: @escaping () -> Date = Date.init
    ) {
        self.index = index
        self.retriever = retriever
        self.service = service
        self.prepareIndex = prepareIndex
        self.now = now
        updatedAt = now()
    }

    /// Brings the index up to date. The panel calls it when it opens, and a
    /// question waits for it.
    func prepare() async {
        if preparation == nil {
            preparation = Task { [prepareIndex] in await prepareIndex() }
        }
        await preparation?.value
        preparation = nil
    }

    /// Asks a question in the conversation. Does nothing while another runs.
    func ask(_ question: String) {
        let question = String(
            question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumQuestionCharacters)
        )
        guard !question.isEmpty, task == nil else { return }
        let history = conversation()
        let earlierCited = turns.last { $0.stage == .answered }?.citedPassages ?? []
        let turn = AskHistorySessionTurn(question: question)
        turns.append(turn)
        updatedAt = now()
        isWorking = true
        let generation = generation
        task = Task { [weak self] in
            await self?.answer(question, turnID: turn.id, history: history, earlierCited: earlierCited)
            guard let self, self.generation == generation else { return }
            self.task = nil
            self.isWorking = false
            self.updatedAt = self.now()
        }
    }

    /// Stops the running question. Its turn keeps what it had found.
    func stop() {
        task?.cancel()
    }

    /// Clears the turns. A running question stops and no longer holds up the next.
    func startNewConversation() {
        stop()
        task = nil
        isWorking = false
        generation = UUID()
        turns = []
        updatedAt = now()
    }

    /// Earlier questions with their answers, oldest first.
    private func conversation() -> [AskHistoryTurn] {
        turns.filter { $0.stage == .answered }.flatMap { turn in
            [
                AskHistoryTurn(role: .user, text: turn.question),
                AskHistoryTurn(role: .assistant, text: turn.answer?.text ?? ""),
            ]
        }
    }

    private func answer(
        _ question: String, turnID: UUID, history: [AskHistoryTurn], earlierCited: [HistorySearchHit]
    ) async {
        do {
            if preparation != nil {
                update(turnID) { $0.stage = .preparingIndex }
                while preparation != nil {
                    try await Task.sleep(for: .milliseconds(100))
                }
                update(turnID) { $0.stage = .searching }
            }
            let planner = AskHistoryPlanner(vocabulary: try await index.vocabulary(), now: now())
            var plan = planner.plan(for: question)
            if AskHistoryPlanner.needsFollowUpPlan(plan, history: history),
               let followUp = await service.planHistoryFollowUp(
                   question: question, history: history, providerOverride: providerOverride
               ) {
                plan = planner.plan(for: question, followUp: followUp)
            }
            try Task.checkCancellation()

            let isOverview = plan.intent == .overview
            var retrieval = try await retriever.retrieve(
                plan, limit: isOverview ? Self.overviewLimit : Self.lookupLimit, now: now()
            )
            if !isOverview, !earlierCited.isEmpty {
                // What the last answer cited stays a candidate of a follow-up,
                // unless a passage the search found covers all of it.
                let new = earlierCited.filter { cited in
                    !retrieval.hits.contains {
                        $0.recordID == cited.recordID && $0.ordinals.lowerBound <= cited.ordinals.lowerBound
                            && $0.ordinals.upperBound >= cited.ordinals.upperBound
                    }
                }
                retrieval.hits += try await retriever.existing(new)
            }
            try Task.checkCancellation()
            update(turnID) {
                $0.found = retrieval.hits
                $0.stage = .answering
            }

            let answer: AskHistoryAnswer
            if isOverview {
                answer = try await AskHistoryOverview(index: index, service: service).answer(
                    plan: plan, retrieval: retrieval, history: history, now: now(), providerOverride: providerOverride
                ) { [weak self] number, count in
                    self?.update(turnID) { $0.stage = .summarizing(number: number, count: count) }
                }
            } else {
                answer = try await service.answerHistoryQuestion(
                    AskHistoryRequest(plan: plan, retrieval: retrieval, history: history, now: now()),
                    providerOverride: providerOverride
                )
            }
            try Task.checkCancellation()
            update(turnID) {
                $0.answer = answer
                $0.stage = .answered
            }
        } catch {
            update(turnID) { $0.stage = Self.stage(after: error) }
        }
    }

    private static func stage(after error: Error) -> AskHistorySessionTurn.Stage {
        if Task.isCancelled || error is CancellationError {
            return .stopped
        }
        if let exhausted = error as? LLMFallbackExhaustedError, exhausted.failures.allSatisfy(\.isNotSetUp) {
            return .needsLanguageModel
        }
        switch error as? LLMError {
        case .notAvailable, .noProviderConfigured, .noApiKey, .providerNotReady: return .needsLanguageModel
        default: break
        }
        return .failed(error.localizedDescription)
    }

    private func update(_ turnID: UUID, _ change: (inout AskHistorySessionTurn) -> Void) {
        guard let position = turns.firstIndex(where: { $0.id == turnID }) else { return }
        change(&turns[position])
    }
}
