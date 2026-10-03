import XCTest
@testable import TypeWhisper

final class DictationLatencyTraceTests: XCTestCase {
    private func trace() -> DictationLatencyTrace {
        var trace = DictationLatencyTrace(requestUptimeNanoseconds: 1_000_000_000)
        trace.firstAudioBufferUptimeNanoseconds = 1_080_000_000
        trace.stopUptimeNanoseconds = 5_000_000_000
        trace.finalTranscriptUptimeNanoseconds = 5_400_000_000
        trace.postProcessingDoneUptimeNanoseconds = 5_412_500_000
        return trace
    }

    func testPhasesAreMeasuredFromTheirStartEvents() {
        let trace = trace()

        XCTAssertEqual(trace.requestToFirstAudioBufferMs, 80)
        XCTAssertEqual(trace.stopToFinalTranscriptMs, 400)
        XCTAssertEqual(trace.postProcessingMs, 12.5)
        XCTAssertNil(trace.stopToInsertionMs)
        XCTAssertNil(trace.stopToVerifiedInsertionMs)
    }

    func testAccessibilityInsertionCountsAsVerifiedWhenItReturns() {
        var trace = trace()
        trace.recordInsertion(.insertedViaAccessibility, at: 5_450_000_000)

        XCTAssertEqual(trace.insertion, .accessibility)
        XCTAssertEqual(trace.stopToInsertionMs, 450)
        XCTAssertEqual(trace.stopToVerifiedInsertionMs, 450)
        XCTAssertNil(trace.pasteVerification)
    }

    func testUnawaitedPasteStaysUnverifiedUntilItsVerificationResolves() {
        var trace = trace()
        trace.recordInsertion(.pasted(verification: .notAwaited), at: 5_420_000_000)

        XCTAssertEqual(trace.insertion, .paste)
        XCTAssertEqual(trace.pasteVerification, .notChecked)
        XCTAssertEqual(trace.stopToInsertionMs, 420)
        XCTAssertNil(trace.stopToVerifiedInsertionMs)

        trace.recordPasteVerification(.verified, at: 5_520_000_000)
        XCTAssertEqual(trace.pasteVerification, .verified)
        XCTAssertEqual(trace.stopToVerifiedInsertionMs, 520)
    }

    func testFailedPasteVerificationKeepsItsReasonAndNoVerifiedTime() {
        var trace = trace()
        trace.recordInsertion(.pasted(verification: .unverified(.focusedTextUnchanged)), at: 5_900_000_000)

        XCTAssertEqual(trace.pasteVerification, .unverified("focused-text-unchanged"))
        XCTAssertEqual(trace.pasteVerification?.name, "unverified")
        XCTAssertEqual(trace.stopToInsertionMs, 900)
        XCTAssertNil(trace.stopToVerifiedInsertionMs)
        XCTAssertTrue(trace.logDescription.contains("pasteVerification=unverified"))
        XCTAssertTrue(trace.logDescription.contains("stopToVerifiedInsertionMs=nil"))
    }

    func testMissingOrReversedTimestampsYieldNoDuration() {
        var trace = DictationLatencyTrace(requestUptimeNanoseconds: 2_000_000_000)
        trace.firstAudioBufferUptimeNanoseconds = 1_000_000_000

        XCTAssertNil(trace.requestToFirstAudioBufferMs)
        XCTAssertNil(trace.stopToFinalTranscriptMs)
        XCTAssertNil(trace.postProcessingMs)
    }
}
