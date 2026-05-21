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
