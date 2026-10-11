import XCTest
@testable import TypeWhisper

@MainActor
final class TextProcessingAPITests: XCTestCase {
    private struct Captured: Sendable {
        var systemPrompt: String?
        var text: String?
        var providerID: String?
        var modelID: String?
    }

    private let workflowID = UUID(uuidString: "6F1C2B8E-0000-4000-8000-000000000010")!

    private func makeAPI(
        processResult: Result<String, Error> = .success("Processed"),
        processDelay: Duration? = nil,
        workflowResult: Result<TextProcessingAPI.WorkflowResult, Error>? = nil,
        writingAllowed: Bool = true,
        captured: RemoteLinkLockedValue<Captured> = RemoteLinkLockedValue(Captured()),
        cancelled: RemoteLinkLockedValue<Bool> = RemoteLinkLockedValue(false)
    ) -> TextProcessingAPI {
        TextProcessingAPI(
            listModels: {
                [
                    .init(providerID: "appleIntelligence", providerName: "Apple Intelligence", modelID: nil, name: "Apple Intelligence", isReady: true),
                    .init(providerID: "groq", providerName: "Groq", modelID: "llama-3.3", name: "Llama 3.3", isReady: false),
                ]
            },
            processPrompt: { systemPrompt, text, providerID, modelID in
                captured.set(Captured(systemPrompt: systemPrompt, text: text, providerID: providerID, modelID: modelID))
                if let processDelay {
                    do {
                        try await Task.sleep(for: processDelay)
                    } catch {
                        cancelled.set(true)
                        throw error
                    }
                }
                return try processResult.get()
            },
            listWorkflows: {
                [.init(id: UUID(uuidString: "6F1C2B8E-0000-4000-8000-000000000010")!, name: "Clean up", template: "cleanedText")]
            },
            runWorkflow: { id, text, _ in
                if let workflowResult {
                    return try workflowResult.get()
                }
                return .init(text: text.uppercased(), workflowID: id, workflowName: "Clean up")
            },
            isRemoteWritingAllowed: { writingAllowed }
        )
    }

    private func request(_ method: String, _ path: String, json: String = "", device: String? = nil) -> HTTPRequest {
        var headers = ["content-type": "application/json"]
        if let device {
            headers[RemoteLinkServer.remoteDeviceHeader] = device
        }
        return HTTPRequest(method: method, path: path, queryParams: [:], headers: headers, body: Data(json.utf8))
    }

    private func json(_ response: HTTPResponse) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    private func errorCode(_ response: HTTPResponse) -> String? {
        ((try? json(response))?["error"] as? [String: Any])?["code"] as? String
    }

    private let promptBody = #"{"system_prompt":"x","text":"hello"}"#

    func testModelsListEveryProviderWithReadiness() async throws {
        let response = await makeAPI().handleModels(request("GET", "/v1/llm/models"))
        XCTAssertEqual(response.status, 200)
        let models = try XCTUnwrap(try json(response)["models"] as? [[String: Any]])
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models[0]["provider_id"] as? String, "appleIntelligence")
        XCTAssertNil(models[0]["model_id"])
        XCTAssertEqual(models[1]["model_id"] as? String, "llama-3.3")
        XCTAssertEqual(models[1]["ready"] as? Bool, false)
    }

    func testProcessForwardsPromptTextAndOverrides() async throws {
        let captured = RemoteLinkLockedValue(Captured())
        let response = await makeAPI(captured: captured).handleProcess(request(
            "POST", "/v1/llm/process",
            json: #"{"system_prompt":"Write an email.","text":"hallo welt","provider_id":"groq","model_id":"llama-3.3"}"#
        ))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(try json(response)["text"] as? String, "Processed")
        XCTAssertEqual(captured.get().systemPrompt, "Write an email.")
        XCTAssertEqual(captured.get().text, "hallo welt")
        XCTAssertEqual(captured.get().providerID, "groq")
        XCTAssertEqual(captured.get().modelID, "llama-3.3")
    }

    func testProcessRejectsInvalidAndOversizedInputBeforeProcessing() async {
        let api = makeAPI()
        let malformed = await api.handleProcess(request("POST", "/v1/llm/process", json: "{}"))
        let empty = await api.handleProcess(request("POST", "/v1/llm/process", json: #"{"system_prompt":"x","text":"   "}"#))
        let modelWithoutProvider = await api.handleProcess(request(
            "POST", "/v1/llm/process", json: #"{"system_prompt":"x","text":"hi","model_id":"m"}"#
        ))
        let largeText = String(repeating: "a", count: TextProcessingAPI.maxTextBytes + 1)
        let oversizedText = await api.handleProcess(request(
            "POST", "/v1/llm/process", json: #"{"system_prompt":"x","text":"\#(largeText)"}"#
        ))
        let largePrompt = String(repeating: "p", count: TextProcessingAPI.maxSystemPromptBytes + 1)
        let oversizedPrompt = await api.handleProcess(request(
            "POST", "/v1/llm/process", json: #"{"system_prompt":"\#(largePrompt)","text":"ok"}"#
        ))
        let padding = String(repeating: "z", count: TextProcessingAPI.maxBodyBytes)
        let oversizedBody = await api.handleProcess(request(
            "POST", "/v1/llm/process", json: #"{"system_prompt":"x","text":"ok","unknown":"\#(padding)"}"#
        ))

        XCTAssertEqual(malformed.status, 400)
        XCTAssertEqual(empty.status, 400)
        XCTAssertEqual(modelWithoutProvider.status, 400)
        XCTAssertEqual(oversizedText.status, 413)
        XCTAssertEqual(oversizedPrompt.status, 413)
        XCTAssertEqual(oversizedBody.status, 413)
        XCTAssertEqual(errorCode(oversizedBody), "payload_too_large")
    }

    func testErrorsCarryStableCodesWithoutProviderDetails() async {
        let notConfigured = await makeAPI(processResult: .failure(LLMError.noApiKey))
            .handleProcess(request("POST", "/v1/llm/process", json: promptBody))
        let providerFailure = await makeAPI(processResult: .failure(LLMError.providerError("secret upstream detail")))
            .handleProcess(request("POST", "/v1/llm/process", json: promptBody))
        let tooLong = await makeAPI(processResult: .failure(LLMError.inputTooLong))
            .handleProcess(request("POST", "/v1/llm/process", json: promptBody))
        let exhausted = await makeAPI(processResult: .failure(LLMFallbackExhaustedError(failures: [])))
            .handleProcess(request("POST", "/v1/llm/process", json: promptBody))

        XCTAssertEqual(notConfigured.status, 503)
        XCTAssertEqual(errorCode(notConfigured), "llm_not_configured")
        XCTAssertEqual(providerFailure.status, 502)
        XCTAssertEqual(errorCode(providerFailure), "llm_failed")
        XCTAssertFalse(String(decoding: providerFailure.body, as: UTF8.self).contains("secret upstream detail"))
        XCTAssertEqual(tooLong.status, 413)
        XCTAssertEqual(errorCode(tooLong), "context_length_exceeded")
        XCTAssertEqual(errorCode(exhausted), "llm_not_configured")
    }

    func testPairedDevicesNeedThePermissionButLocalToolsDoNot() async {
        let api = makeAPI(writingAllowed: false)
        let remote = await api.handleProcess(request("POST", "/v1/llm/process", json: promptBody, device: "phone"))
        let remoteModels = await api.handleModels(request("GET", "/v1/llm/models", device: "phone"))
        let remoteWorkflows = await api.handleWorkflows(request("GET", "/v1/workflows", device: "phone"))
        let local = await api.handleProcess(request("POST", "/v1/llm/process", json: promptBody))

        XCTAssertEqual(remote.status, 403)
        XCTAssertEqual(errorCode(remote), "writing_not_allowed")
        XCTAssertEqual(remoteModels.status, 403)
        XCTAssertEqual(remoteWorkflows.status, 403)
        XCTAssertEqual(local.status, 200)
    }

    func testOneRequestPerDeviceAtATimeAndAPerMinuteLimit() async {
        let limiter = TextProcessingLimiter(perClient: 1, overall: 2, perMinute: 3)
        let first = await limiter.acquire(client: "a")
        let secondWhileBusy = await limiter.acquire(client: "a")
        let otherDevice = await limiter.acquire(client: "b")
        let thirdOverall = await limiter.acquire(client: "c")
        XCTAssertNil(first)
        XCTAssertEqual(secondWhileBusy, .busy)
        XCTAssertNil(otherDevice)
        XCTAssertEqual(thirdOverall, .busy)

        await limiter.release(client: "a")
        let afterRelease = await limiter.acquire(client: "a")
        await limiter.release(client: "a")
        let third = await limiter.acquire(client: "a")
        await limiter.release(client: "a")
        let fourth = await limiter.acquire(client: "a")
        XCTAssertNil(afterRelease)
        XCTAssertNil(third)
        XCTAssertEqual(fourth, .rateLimited)
    }

    func testDeadlineCancelsTheProcessingAndAnswersWithTimeout() async {
        let cancelled = RemoteLinkLockedValue(false)
        var api = makeAPI(processDelay: .seconds(30), cancelled: cancelled)
        api.deadline = 0.2
        let started = Date()
        let response = await api.handleProcess(request("POST", "/v1/llm/process", json: promptBody))

        XCTAssertEqual(response.status, 504)
        XCTAssertEqual(errorCode(response), "timeout")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        for _ in 0..<40 where !cancelled.get() {
            try? await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(cancelled.get())
    }

    func testDeadlineAnswersEvenIfTheWorkIgnoresCancellationAndKeepsItsSlot() async {
        var api = TextProcessingAPI(
            listModels: { [] },
            processPrompt: { _, _, _, _ in
                // Work that cannot be cancelled, like a translation waiting on
                // a continuation without a cancellation handler.
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { continuation.resume() }
                }
                return "late"
            },
            listWorkflows: { [] },
            runWorkflow: { id, text, _ in .init(text: text, workflowID: id, workflowName: "x") },
            isRemoteWritingAllowed: { true }
        )
        api.deadline = 0.2
        let started = Date()
        let first = await api.handleProcess(request("POST", "/v1/llm/process", json: promptBody))
        XCTAssertEqual(first.status, 504)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)

        let whileStillRunning = await api.handleProcess(request("POST", "/v1/llm/process", json: promptBody))
        XCTAssertEqual(errorCode(whileStillRunning), "busy")

        try? await Task.sleep(for: .seconds(2))
        let afterItEnded = await api.handleProcess(request("POST", "/v1/llm/process", json: promptBody))
        XCTAssertNotEqual(errorCode(afterItEnded), "busy")
    }

    func testContextErrorsSurviveTheFallbackList() {
        let viaFallback = TextProcessingAPI.errorResponse(for: LLMFallbackExhaustedError(failures: [
            LLMFallbackAttemptFailure(providerId: "appleIntelligence", modelId: nil, effortId: nil, reason: "too long", exceededContext: true),
            LLMFallbackAttemptFailure(providerId: "groq", modelId: nil, effortId: nil, reason: "no key"),
        ]))
        XCTAssertEqual(viaFallback.status, 413)
        XCTAssertEqual(errorCode(viaFallback), "context_length_exceeded")
    }

    func testWorkflowsListAndRun() async throws {
        let api = makeAPI()
        let list = await api.handleWorkflows(request("GET", "/v1/workflows"))
        let workflows = try XCTUnwrap(try json(list)["workflows"] as? [[String: Any]])
        XCTAssertEqual(workflows.first?["name"] as? String, "Clean up")
        XCTAssertEqual(workflows.first?["template"] as? String, "cleanedText")

        let run = await api.handleRunWorkflow(request(
            "POST", "/v1/workflows/run",
            json: #"{"workflow_id":"\#(workflowID.uuidString)","text":"hello"}"#
        ))
        XCTAssertEqual(run.status, 200)
        XCTAssertEqual(try json(run)["text"] as? String, "HELLO")
        XCTAssertEqual(try json(run)["workflow_name"] as? String, "Clean up")
    }

    func testWorkflowRunMapsMissingDisabledAndInvalidWorkflows() async {
        let body = #"{"workflow_id":"\#(workflowID.uuidString)","text":"hello"}"#
        let missing = await makeAPI(workflowResult: .failure(TextProcessingAPI.WorkflowRunError.notFound))
            .handleRunWorkflow(request("POST", "/v1/workflows/run", json: body))
        let disabled = await makeAPI(workflowResult: .failure(TextProcessingAPI.WorkflowRunError.disabled))
            .handleRunWorkflow(request("POST", "/v1/workflows/run", json: body))
        let notRunnable = await makeAPI(workflowResult: .failure(TextProcessingAPI.WorkflowRunError.notRunnable))
            .handleRunWorkflow(request("POST", "/v1/workflows/run", json: body))
        let invalidID = await makeAPI()
            .handleRunWorkflow(request("POST", "/v1/workflows/run", json: #"{"workflow_id":"nope","text":"hello"}"#))

        XCTAssertEqual(missing.status, 404)
        XCTAssertEqual(errorCode(missing), "workflow_not_found")
        XCTAssertEqual(errorCode(disabled), "workflow_disabled")
        XCTAssertEqual(errorCode(notRunnable), "workflow_not_runnable")
        XCTAssertEqual(invalidID.status, 400)
    }

    func testOnlyWorkflowsThatProcessTextAreRunnableHeadlessly() {
        let prompt = Workflow(
            name: "Summary",
            template: .custom,
            trigger: .manual(),
            behavior: WorkflowBehavior(settings: ["instruction": "Summarize the text."])
        )
        let plainDictation = Workflow(name: "Dictation", template: .dictation, trigger: .global())

        var appleTranslateBehavior = WorkflowBehavior()
        appleTranslateBehavior.settings = [
            WorkflowBehavior.translationProcessorSettingKey: WorkflowTranslationProcessor.appleTranslate.rawValue,
        ]
        let appleTranslate = Workflow(
            name: "Translate", template: .translation, trigger: .manual(), behavior: appleTranslateBehavior
        )

        XCTAssertTrue(prompt.processesTextHeadlessly)
        XCTAssertFalse(plainDictation.processesTextHeadlessly)
        XCTAssertTrue(appleTranslate.usesAppleTranslate)
        XCTAssertFalse(appleTranslate.processesTextHeadlessly)
    }

    func testPairedDevicesReachTheTextProcessingRoutesTaggedWithTheirDevice() async throws {
        let router = APIRouter(authenticationProvider: { .required(token: "local-token") })
        let captured = RemoteLinkLockedValue(Captured())
        makeAPI(captured: captured).register(on: router)

        let models = await RemoteLinkServer.response(
            for: Data("GET /v1/llm/models HTTP/1.1\r\n\r\n".utf8), router: router, deviceID: "phone"
        )
        let spoofed = "POST /v1/llm/process HTTP/1.1\r\n\(RemoteLinkServer.remoteDeviceHeader): other\r\nContent-Length: \(promptBody.utf8.count)\r\n\r\n\(promptBody)"
        let process = await RemoteLinkServer.response(for: Data(spoofed.utf8), router: router, deviceID: "phone")

        XCTAssertEqual(models.status, 200)
        XCTAssertEqual(process.status, 200)
        XCTAssertEqual(captured.get().text, "hello")
    }

    func testLocalClientsCannotClaimToBeAPairedDevice() async {
        let router = APIRouter(authenticationProvider: { .disabled })
        makeAPI(writingAllowed: false).register(on: router)
        let spoofed = HTTPRequest(
            method: "POST",
            path: "/v1/llm/process",
            queryParams: [:],
            headers: [
                "content-type": "application/json",
                RemoteLinkServer.remoteDeviceHeader: "phone",
            ],
            body: Data(promptBody.utf8)
        )

        // The header is dropped, so the request is handled as a local one and
        // the paired-device permission does not apply.
        let response = await router.route(spoofed)

        XCTAssertEqual(response.status, 200)
        XCTAssertNil(APIRouter.withoutRemoteDeviceHeader(spoofed).headers[RemoteLinkServer.remoteDeviceHeader])
    }
}
