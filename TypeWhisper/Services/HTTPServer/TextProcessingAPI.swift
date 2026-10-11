import Foundation
import os

/// Routes that process given text on this Mac without inserting it anywhere:
/// a prompt on the user's language model, or one of their workflows. Paired
/// iPhones use them through Remote Link once the user allows it; local tools
/// can call them with the API token.
struct TextProcessingAPI: Sendable {
    struct LLMModel: Equatable, Sendable {
        let providerID: String
        let providerName: String
        let modelID: String?
        let name: String
        let isReady: Bool
    }

    struct WorkflowSummary: Equatable, Sendable {
        let id: UUID
        let name: String
        let template: String
    }

    struct WorkflowResult: Equatable, Sendable {
        let text: String
        let workflowID: UUID
        let workflowName: String
    }

    enum WorkflowRunError: Error, Equatable {
        case notFound
        case disabled
        case notRunnable
    }

    static let maxBodyBytes = 512 * 1024
    static let maxSystemPromptBytes = 32 * 1024
    static let maxTextBytes = 400 * 1024
    static let maxResponseBytes = 1024 * 1024
    static let processingDeadline: TimeInterval = 120

    let listModels: @MainActor @Sendable () -> [LLMModel]
    let processPrompt: @MainActor @Sendable (_ systemPrompt: String, _ text: String, _ providerID: String?, _ modelID: String?) async throws -> String
    let listWorkflows: @MainActor @Sendable () -> [WorkflowSummary]
    let runWorkflow: @MainActor @Sendable (_ id: UUID, _ text: String, _ language: String?) async throws -> WorkflowResult
    /// Whether paired devices may use these routes. Local tools are not affected.
    let isRemoteWritingAllowed: @Sendable () -> Bool
    var limiter = TextProcessingLimiter()
    var deadline: TimeInterval = Self.processingDeadline

    private static let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "TextProcessingAPI")

    func register(on router: APIRouter) {
        router.register("GET", "/v1/llm/models") { request in await handleModels(request) }
        router.register("POST", "/v1/llm/process") { request in await handleProcess(request) }
        router.register("GET", "/v1/workflows") { request in await handleWorkflows(request) }
        router.register("POST", "/v1/workflows/run") { request in await handleRunWorkflow(request) }
    }

    // MARK: - Handlers

    func handleModels(_ request: HTTPRequest) async -> HTTPResponse {
        if let rejection = permissionRejection(for: request) { return rejection }
        struct Entry: Encodable {
            let provider_id: String
            let provider_name: String
            let model_id: String?
            let name: String
            let ready: Bool
        }
        struct Response: Encodable { let models: [Entry] }

        let models = await listModels()
        return .json(Response(models: models.map {
            Entry(provider_id: $0.providerID, provider_name: $0.providerName, model_id: $0.modelID, name: $0.name, ready: $0.isReady)
        }))
    }

    func handleProcess(_ request: HTTPRequest) async -> HTTPResponse {
        struct Body: Decodable {
            let system_prompt: String
            let text: String
            let provider_id: String?
            let model_id: String?
        }
        struct Response: Encodable { let text: String }

        if let rejection = permissionRejection(for: request) ?? Self.sizeRejection(for: request) { return rejection }
        guard let body = try? JSONDecoder().decode(Body.self, from: request.body) else {
            return .error(status: 400, message: "Expected JSON with system_prompt and text")
        }
        if let rejection = Self.validate(text: body.text, systemPrompt: body.system_prompt) { return rejection }
        let providerID = body.provider_id.flatMap(Self.nonEmpty)
        let modelID = body.model_id.flatMap(Self.nonEmpty)
        if modelID != nil && providerID == nil {
            return .error(status: 400, message: "model_id requires provider_id")
        }

        let processPrompt = self.processPrompt
        return await limited(request) {
            let output = try await processPrompt(body.system_prompt, body.text, providerID, modelID)
            return try Self.cappedResponse(Response(text: output), text: output)
        }
    }

    func handleWorkflows(_ request: HTTPRequest) async -> HTTPResponse {
        if let rejection = permissionRejection(for: request) { return rejection }
        struct Entry: Encodable {
            let id: String
            let name: String
            let template: String
        }
        struct Response: Encodable { let workflows: [Entry] }

        let workflows = await listWorkflows()
        return .json(Response(workflows: workflows.map {
            Entry(id: $0.id.uuidString, name: $0.name, template: $0.template)
        }))
    }

    func handleRunWorkflow(_ request: HTTPRequest) async -> HTTPResponse {
        struct Body: Decodable {
            let workflow_id: String
            let text: String
            let language: String?
        }
        struct Response: Encodable {
            let text: String
            let workflow_id: String
            let workflow_name: String
        }

        if let rejection = permissionRejection(for: request) ?? Self.sizeRejection(for: request) { return rejection }
        guard let body = try? JSONDecoder().decode(Body.self, from: request.body) else {
            return .error(status: 400, message: "Expected JSON with workflow_id and text")
        }
        guard let workflowID = UUID(uuidString: body.workflow_id) else {
            return .error(status: 400, message: "Invalid workflow_id")
        }
        if let rejection = Self.validate(text: body.text, systemPrompt: nil) { return rejection }

        let runWorkflow = self.runWorkflow
        let language = body.language.flatMap(Self.nonEmpty)
        return await limited(request) {
            let result = try await runWorkflow(workflowID, body.text, language)
            return try Self.cappedResponse(
                Response(text: result.text, workflow_id: result.workflowID.uuidString, workflow_name: result.workflowName),
                text: result.text
            )
        }
    }

    // MARK: - Guards

    private func permissionRejection(for request: HTTPRequest) -> HTTPResponse? {
        guard Self.remoteDeviceID(of: request) != nil, !isRemoteWritingAllowed() else { return nil }
        return .error(
            status: 403,
            message: "Writing with this Mac is turned off in TypeWhisper settings",
            code: "writing_not_allowed"
        )
    }

    /// Runs `operation` under the in-flight and rate limits and the processing
    /// deadline. The client gets its answer at the deadline or on cancellation
    /// even if the work ignores cancellation, while the work keeps its slot
    /// until it really ends.
    private func limited(
        _ request: HTTPRequest,
        _ operation: @escaping @Sendable () async throws -> HTTPResponse
    ) async -> HTTPResponse {
        let client = Self.remoteDeviceID(of: request) ?? "local"
        switch await limiter.acquire(client: client) {
        case .busy:
            return .error(status: 429, message: "The Mac is already processing a request", code: "busy")
        case .rateLimited:
            return .error(status: 429, message: "Too many requests, try again in a minute", code: "rate_limited")
        case nil:
            break
        }
        let limiter = self.limiter
        let work = Task { () -> HTTPResponse in
            let response: HTTPResponse
            do {
                response = try await operation()
            } catch {
                response = Self.errorResponse(for: error)
            }
            await limiter.release(client: client)
            return response
        }
        do {
            return try await Self.awaitWithDeadline(work, seconds: deadline)
        } catch {
            return Self.errorResponse(for: error)
        }
    }

    /// Waits for `work` until it finishes, the deadline passes or the caller is
    /// cancelled, whichever comes first, and cancels the work in the latter two cases.
    static func awaitWithDeadline<T: Sendable>(_ work: Task<T, Never>, seconds: TimeInterval) async throws -> T {
        let waiter = DeadlineWaiter<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                waiter.start(continuation, work: work, seconds: seconds)
            }
        } onCancel: {
            waiter.finish(.failure(CancellationError()))
        }
    }

    static func remoteDeviceID(of request: HTTPRequest) -> String? {
        request.headers[RemoteLinkServer.remoteDeviceHeader]
    }

    static func sizeRejection(for request: HTTPRequest) -> HTTPResponse? {
        guard request.body.count > maxBodyBytes else { return nil }
        return .error(status: 413, message: "The request is larger than 512 KiB", code: "payload_too_large")
    }

    static func validate(text: String, systemPrompt: String?) -> HTTPResponse? {
        if let systemPrompt, systemPrompt.utf8.count > maxSystemPromptBytes {
            return .error(status: 413, message: "system_prompt is larger than 32 KiB", code: "payload_too_large")
        }
        if text.utf8.count > maxTextBytes {
            return .error(status: 413, message: "text is larger than 400 KiB", code: "payload_too_large")
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .error(status: 400, message: "text is empty")
        }
        return nil
    }

    private struct ResponseTooLarge: Error {}
    struct ProcessingTimedOut: Error {}

    private static func cappedResponse(_ value: Encodable, text: String) throws -> HTTPResponse {
        guard text.utf8.count <= maxResponseBytes else { throw ResponseTooLarge() }
        return .json(value)
    }

    /// Maps failures to stable codes with short messages; provider details
    /// stay in the Mac's log instead of reaching the client.
    static func errorResponse(for error: Error) -> HTTPResponse {
        switch error {
        case WorkflowRunError.notFound:
            return .error(status: 404, message: "Workflow not found", code: "workflow_not_found")
        case WorkflowRunError.disabled:
            return .error(status: 409, message: "Workflow is disabled", code: "workflow_disabled")
        case WorkflowRunError.notRunnable:
            return .error(status: 409, message: "Workflow does not process text", code: "workflow_not_runnable")
        case is ProcessingTimedOut:
            return .error(status: 504, message: "The Mac did not finish in time", code: "timeout")
        case is ResponseTooLarge:
            return .error(status: 502, message: "The result is larger than 1 MiB", code: "llm_failed")
        case is CancellationError:
            return .error(status: 503, message: "Processing was cancelled", code: "cancelled")
        default:
            break
        }

        logger.error("Text processing failed: \(error.localizedDescription, privacy: .private(mask: .hash))")
        let exceededContext = LLMContextLimit.isExceeded(error)
            || (error as? LLMFallbackExhaustedError)?.failures.contains(where: \.exceededContext) == true
        if exceededContext {
            return .error(status: 413, message: "The text is too long for the language model", code: "context_length_exceeded")
        }
        if let error = error as? LLMError {
            switch error {
            case .inputTooLong:
                return .error(status: 413, message: "The text is too long for the language model", code: "context_length_exceeded")
            case .providerError:
                return .error(status: 502, message: "The language model on the Mac failed", code: "llm_failed")
            case .notAvailable, .providerNotReady, .noProviderConfigured, .noApiKey:
                return .error(status: 503, message: "No language model is ready on the Mac", code: "llm_not_configured")
            }
        }
        if error is LLMFallbackExhaustedError {
            return .error(status: 503, message: "No language model is ready on the Mac", code: "llm_not_configured")
        }
        return .error(status: 502, message: "The language model on the Mac failed", code: "llm_failed")
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Resolves one waiting request with the first of: the work's result, the
/// deadline or a cancellation. Later outcomes are ignored.
final class DeadlineWaiter<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var isFinished = false
    private var work: Task<T, Never>?
    private var timer: Task<Void, Never>?

    func start(_ continuation: CheckedContinuation<T, Error>, work: Task<T, Never>, seconds: TimeInterval) {
        let alreadyFinished = lock.withLock {
            self.work = work
            guard !isFinished else { return true }
            self.continuation = continuation
            return false
        }
        if alreadyFinished {
            work.cancel()
            continuation.resume(throwing: CancellationError())
            return
        }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.finish(.failure(TextProcessingAPI.ProcessingTimedOut()))
        }
        lock.withLock { self.timer = timer }
        Task { [weak self] in
            let value = await work.value
            self?.finish(.success(value))
        }
    }

    func finish(_ result: Result<T, Error>) {
        let (continuation, work, timer) = lock.withLock { () -> (CheckedContinuation<T, Error>?, Task<T, Never>?, Task<Void, Never>?) in
            guard !isFinished else { return (nil, nil, nil) }
            isFinished = true
            let pending = (self.continuation, self.work, self.timer)
            self.continuation = nil
            return pending
        }
        timer?.cancel()
        if case .failure = result {
            work?.cancel()
        }
        continuation?.resume(with: result)
    }
}

/// In-flight and per-minute limits for text processing, keyed by paired device.
actor TextProcessingLimiter {
    enum Rejection: Equatable {
        case busy
        case rateLimited
    }

    private let perClient: Int
    private let overall: Int
    private let perMinute: Int
    private let now: @Sendable () -> Date
    private var inFlight: [String: Int] = [:]
    private var recent: [String: [Date]] = [:]

    init(perClient: Int = 1, overall: Int = 2, perMinute: Int = 30, now: @escaping @Sendable () -> Date = Date.init) {
        self.perClient = perClient
        self.overall = overall
        self.perMinute = perMinute
        self.now = now
    }

    func acquire(client: String) -> Rejection? {
        let current = now()
        let window = (recent[client] ?? []).filter { current.timeIntervalSince($0) < 60 }
        recent[client] = window
        guard window.count < perMinute else { return .rateLimited }
        guard inFlight[client, default: 0] < perClient,
              inFlight.values.reduce(0, +) < overall else {
            return .busy
        }
        inFlight[client, default: 0] += 1
        recent[client] = window + [current]
        return nil
    }

    func release(client: String) {
        guard let count = inFlight[client] else { return }
        inFlight[client] = count > 1 ? count - 1 : nil
    }
}

extension TextProcessingAPI {
    /// Wires the routes to the app's prompt processing and workflows.
    @MainActor
    static func live(
        promptProcessingService: PromptProcessingService,
        workflowService: WorkflowService,
        workflowTextProcessor: WorkflowTextProcessingService,
        isRemoteWritingAllowed: @escaping @Sendable () -> Bool
    ) -> TextProcessingAPI {
        TextProcessingAPI(
            listModels: {
                promptProcessingService.availableProviders.flatMap { provider -> [LLMModel] in
                    let isReady = promptProcessingService.isProviderReady(provider.id)
                    let models = promptProcessingService.modelsForProvider(provider.id)
                    guard !models.isEmpty else {
                        return [LLMModel(providerID: provider.id, providerName: provider.displayName, modelID: nil, name: provider.displayName, isReady: isReady)]
                    }
                    return models.map {
                        LLMModel(providerID: provider.id, providerName: provider.displayName, modelID: $0.id, name: $0.displayName, isReady: isReady)
                    }
                }
            },
            processPrompt: { systemPrompt, text, providerID, modelID in
                try await promptProcessingService.processWorkflow(
                    prompt: systemPrompt,
                    text: text,
                    providerOverride: providerID,
                    cloudModelOverride: modelID,
                    temperatureDirective: .inheritProviderSetting
                )
            },
            listWorkflows: {
                workflowService.workflows
                    .filter { $0.isEnabled && $0.processesTextHeadlessly }
                    .map { WorkflowSummary(id: $0.id, name: $0.name, template: $0.template.rawValue) }
            },
            runWorkflow: { id, text, language in
                guard let workflow = workflowService.workflow(id: id) else { throw WorkflowRunError.notFound }
                guard workflow.isEnabled else { throw WorkflowRunError.disabled }
                guard workflow.processesTextHeadlessly else {
                    throw WorkflowRunError.notRunnable
                }
                // No frontmost app here, so an "auto" output format resolves
                // without app context while explicit formats are kept.
                let output = try await workflowTextProcessor.process(
                    workflow: workflow,
                    text: text,
                    detectedLanguage: language,
                    resolvedOutputFormat: nil
                )
                return WorkflowResult(text: output, workflowID: workflow.id, workflowName: workflow.name)
            },
            isRemoteWritingAllowed: isRemoteWritingAllowed
        )
    }
}

extension Workflow {
    /// Runnable without this Mac's text field: inline commands or a prompt.
    /// Action plugins and auto-enter only act on this Mac. Apple Translate
    /// stays local: its shared session falls back to the source text and
    /// skips output formats, and paired devices translate on their own.
    var processesTextHeadlessly: Bool {
        guard !usesAppleTranslate else { return false }
        return usesInlineCommands || systemPrompt() != nil
    }
}
