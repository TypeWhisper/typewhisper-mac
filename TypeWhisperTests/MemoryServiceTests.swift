import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

final class MemoryServiceTests: XCTestCase {
    func testAllDictationsScopeAllowsTranscriptionWithoutWorkflowRule() {
        let payload = makePayload(
            finalText: "My name is Marco and this transcription is long enough.",
            ruleName: nil
        )

        XCTAssertTrue(MemoryService.shouldAttemptExtraction(
            payload: payload,
            isEnabled: true,
            minimumTextLength: 10,
            captureScope: .allDictations,
            knownWorkflowNames: []
        ))
    }

    func testWorkflowOnlyScopeSkipsTranscriptionWithoutWorkflowRule() {
        let payload = makePayload(
            finalText: "My name is Marco and this transcription is long enough.",
            ruleName: nil
        )

        XCTAssertFalse(MemoryService.shouldAttemptExtraction(
            payload: payload,
            isEnabled: true,
            minimumTextLength: 10,
            captureScope: .workflowDictationsOnly,
            knownWorkflowNames: ["Notes"]
        ))
    }

    func testWorkflowOnlyScopeAllowsKnownWorkflowRule() {
        let payload = makePayload(
            finalText: "My name is Marco and this transcription is long enough.",
            ruleName: "Notes"
        )

        XCTAssertTrue(MemoryService.shouldAttemptExtraction(
            payload: payload,
            isEnabled: true,
            minimumTextLength: 10,
            captureScope: .workflowDictationsOnly,
            knownWorkflowNames: ["Notes"]
        ))
    }

    func testWorkflowOnlyScopeSkipsUnknownWorkflowRule() {
        let payload = makePayload(
            finalText: "My name is Marco and this transcription is long enough.",
            ruleName: "Legacy Profile"
        )

        XCTAssertFalse(MemoryService.shouldAttemptExtraction(
            payload: payload,
            isEnabled: true,
            minimumTextLength: 10,
            captureScope: .workflowDictationsOnly,
            knownWorkflowNames: ["Notes"]
        ))
    }

    func testExtractionPolicyRespectsGlobalEnabledFlagAndMinimumLength() {
        let payload = makePayload(finalText: "Too short", ruleName: nil)

        XCTAssertFalse(MemoryService.shouldAttemptExtraction(
            payload: payload,
            isEnabled: false,
            minimumTextLength: 10,
            captureScope: .allDictations,
            knownWorkflowNames: []
        ))
        XCTAssertFalse(MemoryService.shouldAttemptExtraction(
            payload: payload,
            isEnabled: true,
            minimumTextLength: 10,
            captureScope: .allDictations,
            knownWorkflowNames: []
        ))
    }

    func testUnknownExtractedMemoryTypeFallsBackToContext() {
        XCTAssertEqual(MemoryService.memoryType(for: "metric"), .context)
        XCTAssertEqual(MemoryService.memoryType(for: " FACT "), .fact)
    }

    func testUnknownMemoryTypesRequireExactContentForDuplicateMatch() {
        let newMetricEntry = MemoryEntry(
            content: "words=34, sentences=2, avg_wps=17.0",
            type: .context,
            metadata: [MemoryService.rawMemoryTypeMetadataKey: "metric"]
        )
        let existingMetricEntry = MemoryEntry(
            content: "words=11, sentences=1, avg_wps=11.0",
            type: .context
        )
        let existingSameMetricEntry = MemoryEntry(
            content: "words=34, sentences=2, avg_wps=17.0",
            type: .context
        )

        XCTAssertFalse(MemoryService.shouldTreatAsDuplicate(
            newEntry: newMetricEntry,
            existingEntry: existingMetricEntry,
            relevanceScore: 1.0
        ))
        XCTAssertTrue(MemoryService.shouldTreatAsDuplicate(
            newEntry: newMetricEntry,
            existingEntry: existingSameMetricEntry,
            relevanceScore: 1.0
        ))
    }

    @MainActor
    func testExtractionSkipsWhilePreviousExtractionIsInFlight() async throws {
        let originalEnabled = UserDefaults.standard.object(forKey: UserDefaultsKeys.memoryEnabled)
        let originalProvider = UserDefaults.standard.object(forKey: UserDefaultsKeys.memoryExtractionProvider)
        let originalMinimumLength = UserDefaults.standard.object(forKey: UserDefaultsKeys.memoryMinTextLength)
        defer {
            restoreUserDefault(originalEnabled, forKey: UserDefaultsKeys.memoryEnabled)
            restoreUserDefault(originalProvider, forKey: UserDefaultsKeys.memoryExtractionProvider)
            restoreUserDefault(originalMinimumLength, forKey: UserDefaultsKeys.memoryMinTextLength)
        }

        var processCallCount = 0
        var firstCallRelease: CheckedContinuation<Void, Never>?
        let firstCallStarted = expectation(description: "first memory extraction started")

        let service = MemoryService(
            promptProcessingService: PromptProcessingService(),
            promptProcessor: { _, _, _, _ in
                processCallCount += 1
                if processCallCount == 1 {
                    firstCallStarted.fulfill()
                    await withCheckedContinuation { continuation in
                        firstCallRelease = continuation
                    }
                }
                return "[]"
            }
        )
        service.isEnabled = true
        service.extractionProviderId = "test-provider"
        service.minimumTextLength = 1
        service.setExtractionCooldownForTesting(0)

        service.handleTranscriptionForTesting(makePayload(finalText: "remember this first fact", ruleName: nil))
        await fulfillment(of: [firstCallStarted], timeout: 1.0)

        service.handleTranscriptionForTesting(makePayload(finalText: "remember this second fact", ruleName: nil))

        var busySnapshot = service.extractionDiagnosticsSnapshot()
        XCTAssertTrue(busySnapshot.inFlight)
        XCTAssertEqual(busySnapshot.totalStarted, 1)
        XCTAssertEqual(busySnapshot.skippedWhileBusy, 1)
        XCTAssertEqual(processCallCount, 1)

        firstCallRelease?.resume()
        try await waitUntilMemoryExtractionFinishes(service)

        service.handleTranscriptionForTesting(makePayload(finalText: "remember this third fact", ruleName: nil))
        try await waitUntilProcessCallCount(2, currentCount: { processCallCount })
        busySnapshot = service.extractionDiagnosticsSnapshot()

        XCTAssertEqual(processCallCount, 2)
        XCTAssertEqual(busySnapshot.totalStarted, 2)
        XCTAssertEqual(busySnapshot.skippedWhileBusy, 1)
    }

    @MainActor
    private func waitUntilMemoryExtractionFinishes(
        _ service: MemoryService,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<40 {
            if !service.extractionDiagnosticsSnapshot().inFlight {
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out waiting for memory extraction to finish", file: file, line: line)
    }

    @MainActor
    private func waitUntilProcessCallCount(
        _ expectedCount: Int,
        currentCount: @MainActor () -> Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<40 {
            if currentCount() == expectedCount {
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out waiting for process call count \(expectedCount)", file: file, line: line)
    }

    private func restoreUserDefault(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func makePayload(finalText: String, ruleName: String?) -> TranscriptionCompletedPayload {
        TranscriptionCompletedPayload(
            rawText: finalText,
            finalText: finalText,
            language: "en",
            engineUsed: "Test",
            modelUsed: nil,
            durationSeconds: 1,
            appName: "TextEdit",
            bundleIdentifier: "com.apple.TextEdit",
            url: nil,
            ruleName: ruleName
        )
    }
}
