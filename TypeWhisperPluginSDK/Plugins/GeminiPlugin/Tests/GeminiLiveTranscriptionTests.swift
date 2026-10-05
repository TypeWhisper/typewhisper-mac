import Foundation
import os
import XCTest
import TypeWhisperPluginSDK
@testable import GeminiPlugin

final class GeminiLiveTranscriptionTests: XCTestCase {
    func testCompletionReceivedBeforeReleaseDoesNotWaitForAnotherTurn() async throws {
        let socket = GeminiTestWebSocket()
        let session = try await makeSession(socket: socket)
        try await session.handle(.string(#"{"serverContent":{"inputTranscription":{"text":"Already complete"},"generationComplete":true}}"#))

        let start = ContinuousClock.now
        let result = try await session.finish()

        XCTAssertEqual(result.text, "Already complete")
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(250))
        XCTAssertTrue(socket.isClosed)
    }

    func testGenerationCompleteAfterReleaseEndsWait() async throws {
        let socket = GeminiTestWebSocket()
        let session = try await makeSession(socket: socket)
        try await session.handle(.string(#"{"serverContent":{"inputTranscription":{"text":"Complete"}}}"#))
        socket.onSend = { message in
            if case .string(let text) = message, text == GeminiLiveTranscriptionSession.audioStreamEndMessage {
                socket.enqueue(#"{"serverContent":{"generationComplete":true}}"#)
            }
        }

        let start = ContinuousClock.now
        let result = try await session.finish()

        XCTAssertEqual(result.text, "Complete")
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(250))
    }

    func testSilentAudioAfterCompletionDoesNotWaitForAnotherTurn() async throws {
        for completion in ["generationComplete", "turnComplete"] {
            let socket = GeminiTestWebSocket()
            let clock = GeminiTestClock()
            let session = try await makeSession(socket: socket, clock: clock)
            try await session.appendAudio(samples: [0.1])
            clock.advance(by: .seconds(1))
            try await session.handle(.string("{\"serverContent\":{\"inputTranscription\":{\"text\":\"Already complete\"},\"\(completion)\":true}}"))
            try await session.appendAudio(samples: [Float](repeating: 0, count: 4_800))
            clock.advance(by: .milliseconds(50))

            let start = ContinuousClock.now
            let result = try await finishWithWatchdog(session)

            XCTAssertEqual(result.text, "Already complete")
            XCTAssertLessThan(start.duration(to: .now), .milliseconds(250))
            XCTAssertTrue(socket.isClosed)
        }
    }

    func testTimeoutReturnsCommittedAndInterimText() async throws {
        let session = try await makeSession(socket: GeminiTestWebSocket())
        try await session.handle(.string(#"{"serverContent":{"inputTranscription":{"text":"Hello"}}}"#))
        try await session.handle(.string(#"{"serverContent":{"interimInputTranscription":{"text":"world"}}}"#))

        let result = try await session.finish()

        XCTAssertEqual(result.text, "Hello world")
    }

    func testTurnCompleteReceivedBeforeReleaseEndsWait() async throws {
        let socket = GeminiTestWebSocket()
        let session = try await makeSession(socket: socket)
        try await session.handle(.string(#"{"serverContent":{"inputTranscription":{"text":"Complete"},"turnComplete":true}}"#))
        let start = ContinuousClock.now
        let result = try await session.finish()
        XCTAssertEqual(result.text, "Complete")
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(250))
    }

    func testCompletionAllowsLateTranscriptToSettle() async throws {
        let clock = GeminiTestClock()
        let session = try await makeSession(socket: GeminiTestWebSocket(), clock: clock)
        try await session.handle(.string(#"{"serverContent":{"inputTranscription":{"text":"Hello"}}}"#))
        try await session.handle(.string(#"{"serverContent":{"generationComplete":true}}"#))
        clock.advance(by: .milliseconds(30))
        let beforeLateText = await session.hasSettledCompletion
        XCTAssertFalse(beforeLateText)
        try await session.handle(.string(#"{"serverContent":{"inputTranscription":{"text":"world"}}}"#))
        clock.advance(by: .milliseconds(49))
        let beforeTextSettles = await session.hasSettledCompletion
        XCTAssertFalse(beforeTextSettles, "Late transcription restarts the settling interval")
        clock.advance(by: .milliseconds(1))
        let settled = await session.hasSettledCompletion
        XCTAssertTrue(settled)
        let result = try await finishWithWatchdog(session)
        XCTAssertEqual(result.text, "Hello world")
    }

    func testFirstFinalChunkDoesNotDropFollowingTranscript() async throws {
        let clock = GeminiTestClock()
        let session = try await makeSession(socket: GeminiTestWebSocket(), clock: clock)
        try await session.handle(.string(#"{"serverContent":{"inputTranscription":{"text":"Hello"}}}"#))
        clock.advance(by: .milliseconds(80))
        let afterFirstChunk = await session.hasSettledCompletion
        XCTAssertFalse(afterFirstChunk)
        try await session.handle(.string(#"{"serverContent":{"interimInputTranscription":{"text":"world"}}}"#))
        clock.advance(by: .milliseconds(80))
        let afterInterim = await session.hasSettledCompletion
        XCTAssertFalse(afterInterim)
        try await session.handle(.string(#"{"serverContent":{"inputTranscription":{"text":"world"},"turnComplete":true}}"#))
        clock.advance(by: .milliseconds(50))
        let result = try await finishWithWatchdog(session)
        XCTAssertEqual(result.text, "Hello world")
    }

    func testNewAudioInvalidatesEarlierCompletion() async throws {
        let clock = GeminiTestClock()
        let session = try await makeSession(socket: GeminiTestWebSocket(), clock: clock)
        try await session.handle(.string(#"{"serverContent":{"inputTranscription":{"text":"First"},"generationComplete":true}}"#))
        // Even the quietest nonzero PCM sample must invalidate completion.
        // Trailing silence must not make that earlier completion valid again.
        try await session.appendAudio(samples: [1 / Float(Int16.max)])
        try await session.appendAudio(samples: [Float](repeating: 0, count: 3_200))
        clock.advance(by: .milliseconds(280))
        let staleCompletion = await session.hasSettledCompletion
        XCTAssertFalse(staleCompletion)
        try await session.handle(.string(#"{"serverContent":{"interimInputTranscription":{"text":"second"}}}"#))
        clock.advance(by: .seconds(1))
        try await session.handle(.string(#"{"serverContent":{"inputTranscription":{"text":"second"},"generationComplete":true}}"#))
        clock.advance(by: .milliseconds(50))
        let result = try await finishWithWatchdog(session)
        XCTAssertEqual(result.text, "First second")
    }

    func testCompletionWithPendingInterimWaitsForFinalText() async throws {
        let clock = GeminiTestClock()
        let session = try await makeSession(socket: GeminiTestWebSocket(), clock: clock)
        try await session.handle(.string(#"{"serverContent":{"interimInputTranscription":{"text":"draft"},"generationComplete":true}}"#))
        clock.advance(by: .milliseconds(100))
        let pendingInterim = await session.hasSettledCompletion
        XCTAssertFalse(pendingInterim)
        try await session.handle(.string(#"{"serverContent":{"inputTranscription":{"text":"Corrected final"}}}"#))
        clock.advance(by: .milliseconds(50))
        let result = try await finishWithWatchdog(session)
        XCTAssertEqual(result.text, "Corrected final")
    }

    func testCompletionSoonAfterResumedAudioStaysUncredited() async throws {
        for completion in ["generationComplete", "turnComplete"] {
            let clock = GeminiTestClock()
            let session = try await makeSession(socket: GeminiTestWebSocket(), clock: clock)
            try await session.handle(.string(#"{"serverContent":{"inputTranscription":{"text":"First"},"generationComplete":true}}"#))
            clock.advance(by: .seconds(2))
            try await session.appendAudio(samples: [0.1])
            clock.advance(by: .milliseconds(100))
            try await session.handle(.string("{\"serverContent\":{\"\(completion)\":true}}"))
            clock.advance(by: .seconds(2))

            let attributedToResumedSpeech = await session.hasSettledCompletion
            XCTAssertFalse(attributedToResumedSpeech, "An early completion must not become valid just because more time passes")

            try await session.handle(.string(#"{"serverContent":{"inputTranscription":{"text":"second"},"generationComplete":true}}"#))
            clock.advance(by: .milliseconds(50))
            let result = try await finishWithWatchdog(session)
            XCTAssertEqual(result.text, "First second")
        }
    }

    func testCompletionDuringSendStaysUncreditedAfterSendReturns() async throws {
        let clock = GeminiTestClock()
        let socket = GeminiTestWebSocket()
        let session = try await makeSession(socket: socket, clock: clock)
        try await session.handle(.string(#"{"serverContent":{"inputTranscription":{"text":"First"},"generationComplete":true}}"#))
        clock.advance(by: .seconds(2))
        socket.onSend = { _ in
            clock.advance(by: .seconds(2))
            try await session.handle(.string(#"{"serverContent":{"generationComplete":true}}"#))
            clock.advance(by: .seconds(2))
        }
        try await session.appendAudio(samples: [0.1])
        socket.onSend = nil
        clock.advance(by: .milliseconds(50))
        let completionDuringSend = await session.hasSettledCompletion
        XCTAssertFalse(completionDuringSend)

        try await session.handle(.string(#"{"serverContent":{"turnComplete":true}}"#))
        clock.advance(by: .seconds(2))
        let completionJustAfterSend = await session.hasSettledCompletion
        XCTAssertFalse(completionJustAfterSend, "The guard window must start when the send returns")

        try await session.handle(.string(#"{"serverContent":{"inputTranscription":{"text":"second"},"generationComplete":true}}"#))
        clock.advance(by: .milliseconds(50))
        let result = try await finishWithWatchdog(session)
        XCTAssertEqual(result.text, "First second")
    }

    func testCompletionBetweenAudioChunksDoesNotFinalizeRemainingAudio() async throws {
        let socket = GeminiTestWebSocket()
        let clock = GeminiTestClock()
        let session = try await makeSession(socket: socket, clock: clock)
        let sends = OSAllocatedUnfairLock(initialState: 0)
        socket.onSend = { _ in
            let count = sends.withLock { $0 += 1; return $0 }
            if count == 1 {
                try await session.handle(.string(#"{"serverContent":{"inputTranscription":{"text":"First"},"generationComplete":true}}"#))
            }
        }
        try await session.appendAudio(samples: [Float](repeating: 0.1, count: 3_200))
        socket.onSend = nil
        clock.advance(by: .milliseconds(280))
        let staleCompletion = await session.hasSettledCompletion
        XCTAssertFalse(staleCompletion)
        try await session.handle(.string(#"{"serverContent":{"interimInputTranscription":{"text":"last chunk"}}}"#))
        clock.advance(by: .seconds(1))
        try await session.handle(.string(#"{"serverContent":{"inputTranscription":{"text":"last chunk"},"generationComplete":true}}"#))
        clock.advance(by: .milliseconds(50))
        let result = try await finishWithWatchdog(session)
        XCTAssertEqual(result.text, "First last chunk")
    }

    func testServerTurnEndCreditsCompletionDespiteRoomNoise() async throws {
        let socket = GeminiTestWebSocket()
        let session = try await makeSession(socket: socket)
        try await session.appendAudio(samples: [0.1])
        try await session.handle(.string(activity("ACTIVITY_START")))
        try await session.handle(.string(#"{"serverContent":{"inputTranscription":{"text":"Already complete"}}}"#))
        try await session.handle(.string(#"{"serverContent":{"generationComplete":true}}"#))
        try await session.handle(.string(activity("ACTIVITY_END")))
        // Room noise is not digital silence, so only the server VAD can tell that no speech followed.
        try await session.appendAudio(samples: [Float](repeating: 0.001, count: 4_800))

        let start = ContinuousClock.now
        let result = try await session.finish()

        XCTAssertEqual(result.text, "Already complete")
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(300))
        XCTAssertTrue(socket.isClosed)
    }

    func testServerTurnEndAfterReleaseEndsWait() async throws {
        let socket = GeminiTestWebSocket()
        let session = try await makeSession(socket: socket)
        try await session.handle(.string(activity("ACTIVITY_START")))
        try await session.handle(.string(#"{"serverContent":{"interimInputTranscription":{"text":"Hello"}}}"#))
        // The release flush arrives within the attribution delay of the last audio chunk.
        try await session.appendAudio(samples: [0.1])
        socket.onSend = { message in
            guard isGeminiEndMessage(message) else { return }
            socket.enqueue(#"{"serverContent":{"inputTranscription":{"text":"Hello world"}}}"#)
            socket.enqueue(#"{"serverContent":{"generationComplete":true}}"#)
            socket.enqueue(activity("ACTIVITY_END"))
        }

        let start = ContinuousClock.now
        let result = try await session.finish()

        XCTAssertEqual(result.text, "Hello world")
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(300))
    }

    func testSpeechResumedBeforeReleaseWaitsForNewServerTurn() async throws {
        let socket = GeminiTestWebSocket()
        let session = try await makeSession(socket: socket, finishTimeout: .seconds(2))
        try await session.handle(.string(activity("ACTIVITY_START")))
        try await session.handle(.string(#"{"serverContent":{"inputTranscription":{"text":"First"},"generationComplete":true}}"#))
        try await session.handle(.string(activity("ACTIVITY_END")))
        try await session.appendAudio(samples: [0.1])
        socket.onSend = { message in
            guard isGeminiEndMessage(message) else { return }
            // Gemini reports the resumed speech only after audioStreamEnd, within the grace.
            socket.enqueue(activity("ACTIVITY_START"))
            Task {
                try await Task.sleep(for: .milliseconds(300))
                socket.enqueue(#"{"serverContent":{"inputTranscription":{"text":"second"}}}"#)
                socket.enqueue(#"{"serverContent":{"generationComplete":true}}"#)
                socket.enqueue(activity("ACTIVITY_END"))
            }
        }

        let start = ContinuousClock.now
        let result = try await finishWithWatchdog(session)

        XCTAssertEqual(result.text, "First second")
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
    }

    func testInterruptedTurnCompleteDoesNotSettleResumedSpeech() async throws {
        let socket = GeminiTestWebSocket()
        let session = try await makeSession(socket: socket, finishTimeout: .seconds(2))
        try await session.handle(.string(activity("ACTIVITY_START")))
        try await session.handle(.string(#"{"serverContent":{"inputTranscription":{"text":"First"},"generationComplete":true}}"#))
        try await session.handle(.string(activity("ACTIVITY_END")))
        try await session.appendAudio(samples: [0.1])
        socket.onSend = { message in
            guard isGeminiEndMessage(message) else { return }
            socket.enqueue(activity("ACTIVITY_START"))
            socket.enqueue(#"{"serverContent":{"inputTranscription":{"text":"second"}}}"#)
            // The turnComplete after interrupted closes the earlier turn, not the resumed speech.
            socket.enqueue(#"{"serverContent":{"interrupted":true}}"#)
            socket.enqueue(#"{"serverContent":{"turnComplete":true}}"#)
            socket.enqueue(activity("ACTIVITY_END"))
            Task {
                try await Task.sleep(for: .milliseconds(300))
                socket.enqueue(#"{"serverContent":{"inputTranscription":{"text":"turn"},"generationComplete":true}}"#)
            }
        }

        let result = try await finishWithWatchdog(session)

        XCTAssertEqual(result.text, "First second turn")
    }

    func testInterruptedTurnCompleteIsNotAttributedAfterQuietAudio() async throws {
        let clock = GeminiTestClock()
        let session = try await makeSession(socket: GeminiTestWebSocket(), clock: clock)
        try await session.appendAudio(samples: [0.1])
        try await session.handle(.string(#"{"serverContent":{"inputTranscription":{"text":"First"}}}"#))
        clock.advance(by: .seconds(2))
        try await session.handle(.string(#"{"serverContent":{"interrupted":true}}"#))
        try await session.handle(.string(#"{"serverContent":{"turnComplete":true}}"#))
        clock.advance(by: .milliseconds(100))
        let interruptedTurn = await session.hasSettledCompletion
        XCTAssertFalse(interruptedTurn, "turnComplete after interrupted closes the earlier turn")

        try await session.handle(.string(#"{"serverContent":{"inputTranscription":{"text":"second"},"generationComplete":true}}"#))
        clock.advance(by: .milliseconds(50))
        let result = try await finishWithWatchdog(session)
        XCTAssertEqual(result.text, "First second")
    }

    func testServerTurnWaitsForCurrentTurnFinalTranscript() async throws {
        let socket = GeminiTestWebSocket()
        let session = try await makeSession(socket: socket, finishTimeout: .seconds(2))
        try await session.handle(.string(activity("ACTIVITY_START")))
        try await session.handle(.string(#"{"serverContent":{"inputTranscription":{"text":"First"},"generationComplete":true}}"#))
        try await session.handle(.string(activity("ACTIVITY_END")))
        try await session.appendAudio(samples: [0.1])
        socket.onSend = { message in
            guard isGeminiEndMessage(message) else { return }
            socket.enqueue(activity("ACTIVITY_START"))
            socket.enqueue(#"{"serverContent":{"generationComplete":true}}"#)
            socket.enqueue(activity("ACTIVITY_END"))
            // Input transcription has no guaranteed order relative to completion.
            Task {
                try await Task.sleep(for: .milliseconds(300))
                socket.enqueue(#"{"serverContent":{"inputTranscription":{"text":"second"}}}"#)
            }
        }

        let result = try await finishWithWatchdog(session)

        XCTAssertEqual(result.text, "First second")
    }

    func testDelayedFinalOfPreviousTurnDoesNotSettleResumedTurn() async throws {
        let socket = GeminiTestWebSocket()
        let session = try await makeSession(socket: socket, finishTimeout: .seconds(2))
        try await session.handle(.string(activity("ACTIVITY_START")))
        try await session.handle(.string(#"{"serverContent":{"generationComplete":true}}"#))
        try await session.handle(.string(activity("ACTIVITY_END")))
        try await session.appendAudio(samples: [0.1])
        socket.onSend = { message in
            guard isGeminiEndMessage(message) else { return }
            socket.enqueue(activity("ACTIVITY_START"))
            // The first turn's final arrives late, after the resumed turn started.
            socket.enqueue(#"{"serverContent":{"inputTranscription":{"text":"First"}}}"#)
            socket.enqueue(#"{"serverContent":{"generationComplete":true}}"#)
            socket.enqueue(activity("ACTIVITY_END"))
            Task {
                try await Task.sleep(for: .milliseconds(300))
                socket.enqueue(#"{"serverContent":{"inputTranscription":{"text":"second"}}}"#)
            }
        }

        let result = try await finishWithWatchdog(session)

        XCTAssertEqual(result.text, "First second")
    }

    func testDelayedTurnCompleteOfPreviousGenerationDoesNotSettleResumedTurn() async throws {
        let socket = GeminiTestWebSocket()
        let session = try await makeSession(socket: socket, finishTimeout: .seconds(2))
        try await session.handle(.string(activity("ACTIVITY_START")))
        try await session.handle(.string(#"{"serverContent":{"inputTranscription":{"text":"First"},"generationComplete":true}}"#))
        try await session.handle(.string(activity("ACTIVITY_END")))
        try await session.appendAudio(samples: [0.1])
        socket.onSend = { message in
            guard isGeminiEndMessage(message) else { return }
            socket.enqueue(activity("ACTIVITY_START"))
            socket.enqueue(#"{"serverContent":{"inputTranscription":{"text":"second"}}}"#)
            // This turnComplete closes the first generation, not the resumed turn.
            socket.enqueue(#"{"serverContent":{"turnComplete":true}}"#)
            socket.enqueue(activity("ACTIVITY_END"))
            Task {
                try await Task.sleep(for: .milliseconds(300))
                socket.enqueue(#"{"serverContent":{"inputTranscription":{"text":"turn"},"generationComplete":true}}"#)
            }
        }

        let result = try await finishWithWatchdog(session)

        XCTAssertEqual(result.text, "First second turn")
    }

    func testVoiceActivityTypeKeyIsDecoded() async throws {
        let socket = GeminiTestWebSocket()
        let session = try await makeSession(socket: socket)
        try await session.handle(.string(#"{"voiceActivity":{"voiceActivityType":"ACTIVITY_START"}}"#))
        try await session.handle(.string(#"{"serverContent":{"inputTranscription":{"text":"Done"},"generationComplete":true}}"#))
        try await session.handle(.string(#"{"voiceActivity":{"voiceActivityType":"ACTIVITY_END"}}"#))
        try await session.appendAudio(samples: [Float](repeating: 0.001, count: 1_600))

        let start = ContinuousClock.now
        let result = try await session.finish()

        XCTAssertEqual(result.text, "Done")
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(300))
    }

    func testServerTurnEndWaitsForSpeechResumeGrace() async throws {
        let clock = GeminiTestClock()
        let socket = GeminiTestWebSocket()
        let session = try await makeSession(socket: socket, clock: clock)
        try await session.handle(.string(activity("ACTIVITY_START")))
        try await session.handle(.string(#"{"serverContent":{"inputTranscription":{"text":"Done"},"generationComplete":true}}"#))
        try await session.handle(.string(activity("ACTIVITY_END")))
        try await session.appendAudio(samples: [0.1])
        clock.advance(by: .seconds(2))
        let beforeRelease = await session.hasSettledCompletion
        XCTAssertFalse(beforeRelease, "The server turn path only applies after audioStreamEnd")

        let finish = Task { try await finishWithWatchdog(session) }
        try await waitUntil { socket.sentMessages.contains(where: isGeminiEndMessage) }
        try await Task.sleep(for: .milliseconds(50))
        let withinGrace = await session.hasSettledCompletion
        XCTAssertFalse(withinGrace)
        clock.advance(by: .milliseconds(100))
        let result = try await finish.value
        XCTAssertEqual(result.text, "Done")
    }

    func testTranscriptStillArrivingExtendsWaitPastTimeout() async throws {
        let socket = GeminiTestWebSocket()
        let session = try await makeSession(socket: socket, maximumFinishTime: .milliseconds(1_500))
        try await session.handle(.string(#"{"serverContent":{"interimInputTranscription":{"text":"Quick test"}}}"#))
        socket.onSend = { message in
            guard isGeminiEndMessage(message) else { return }
            Task {
                try await Task.sleep(for: .milliseconds(300))
                socket.enqueue(#"{"serverContent":{"interimInputTranscription":{"text":"Quick test number one."}}}"#)
                try await Task.sleep(for: .milliseconds(300))
                socket.enqueue(#"{"serverContent":{"inputTranscription":{"text":"Quick test number one. The last words are purple."}}}"#)
            }
        }

        let start = ContinuousClock.now
        let result = try await finishWithWatchdog(session)
        let elapsed = start.duration(to: .now)

        XCTAssertEqual(result.text, "Quick test number one. The last words are purple.")
        XCTAssertGreaterThan(elapsed, .milliseconds(600))
        XCTAssertLessThan(elapsed, .milliseconds(1_800))
    }

    func testTranscriptExtensionStopsAtMaximumFinishTime() async throws {
        let socket = GeminiTestWebSocket()
        let session = try await makeSession(socket: socket, maximumFinishTime: .milliseconds(900))
        try await session.handle(.string(#"{"serverContent":{"interimInputTranscription":{"text":"word"}}}"#))
        let feeder = Task {
            var text = "word"
            while !Task.isCancelled {
                try await Task.sleep(for: .milliseconds(100))
                text += " word"
                socket.enqueue("{\"serverContent\":{\"interimInputTranscription\":{\"text\":\"\(text)\"}}}")
            }
        }
        defer { feeder.cancel() }

        let start = ContinuousClock.now
        let result = try await finishWithWatchdog(session)
        let elapsed = start.duration(to: .now)

        XCTAssertTrue(result.text.hasPrefix("word word"))
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(900))
        XCTAssertLessThan(elapsed, .milliseconds(1_200))
    }

    func testReceiveFailureReturnsAvailableText() async throws {
        let socket = GeminiTestWebSocket()
        let session = try await makeSession(socket: socket)
        try await session.handle(.string(#"{"serverContent":{"inputTranscription":{"text":"Hello"},"generationComplete":true}}"#))
        try await session.handle(.string(#"{"serverContent":{"interimInputTranscription":{"text":"world"}}}"#))
        socket.close(code: .abnormalClosure)
        let start = ContinuousClock.now
        let result = try await session.finish()
        XCTAssertEqual(result.text, "Hello world")
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(250))
    }

    func testTimeoutWithoutTextStillFails() async throws {
        let socket = GeminiTestWebSocket()
        let session = try await makeSession(socket: socket)
        do {
            _ = try await session.finish()
            XCTFail("An empty dictation must not succeed")
        } catch is PluginTranscriptionError {
            XCTAssertTrue(socket.isClosed)
        }
    }

    func testStalledEndSignalIsIncludedInFinishBudget() async throws {
        let socket = GeminiTestWebSocket()
        let session = try await makeSession(socket: socket)
        try await session.handle(.string(#"{"serverContent":{"interimInputTranscription":{"text":"Kept text"}}}"#))
        socket.onSend = { message in
            if isGeminiEndMessage(message) { try await Task.sleep(for: .seconds(10)) }
        }
        let start = ContinuousClock.now
        let result = try await session.finish()
        XCTAssertEqual(result.text, "Kept text")
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(650))
        XCTAssertTrue(socket.isClosed)
    }

    func testCancellingFinishClosesSocketAndDoesNotReturnPartialText() async throws {
        let socket = GeminiTestWebSocket()
        let session = try await makeSession(socket: socket)
        try await session.handle(.string(#"{"serverContent":{"interimInputTranscription":{"text":"Cancelled"}}}"#))
        socket.onSend = { message in
            if isGeminiEndMessage(message) { try await Task.sleep(for: .seconds(10)) }
        }
        let finish = Task { try await session.finish() }
        try await waitUntil { socket.sentMessages.contains(where: isGeminiEndMessage) }
        let start = ContinuousClock.now
        finish.cancel()
        do {
            _ = try await finish.value
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {}
        try await waitUntil { socket.isClosed }
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(250))
    }

    func testConcurrentFinishSendsEndOnlyOnce() async throws {
        let socket = GeminiTestWebSocket()
        let session = try await makeSession(socket: socket)
        socket.onSend = { message in
            if isGeminiEndMessage(message) {
                socket.enqueue(#"{"serverContent":{"inputTranscription":{"text":"One result"},"turnComplete":true}}"#)
            }
        }
        async let first = session.finish()
        async let second = session.finish()
        let results = try await [first, second]
        XCTAssertEqual(results.map(\.text), ["One result", "One result"])
        XCTAssertEqual(socket.sentMessages.filter(isGeminiEndMessage).count, 1)
    }

    func testCancelledSetupClosesTransport() async throws {
        let socket = GeminiTestWebSocket(automaticallyCompleteSetup: false)
        let connect = Task {
            try await GeminiLiveTranscriptionSession.connect(
                apiKey: "test-key", modelId: "test-model", mode: .verbatim,
                languageCodes: [], customVocabulary: [], socket: socket
            )
        }
        try await waitUntil { !socket.sentMessages.isEmpty }
        connect.cancel()
        do {
            _ = try await connect.value
            XCTFail("Setup cancellation must propagate")
        } catch is CancellationError {}
        XCTAssertTrue(socket.isClosed)
    }

    private func makeSession(
        socket: GeminiTestWebSocket,
        clock: GeminiTestClock? = nil,
        finishTimeout: Duration = .milliseconds(400),
        maximumFinishTime: Duration = .milliseconds(400)
    ) async throws -> GeminiLiveTranscriptionSession {
        try await GeminiLiveTranscriptionSession.connect(
            apiKey: "test-key", modelId: "gemini-3.5-transcribe-live", mode: .verbatim,
            languageCodes: ["ru-RU"], customVocabulary: ["TypeWhisper"],
            socket: socket, finishTimeout: finishTimeout, maximumFinishTime: maximumFinishTime,
            completionSettleTime: .milliseconds(50), speechResumeGrace: .milliseconds(100),
            now: { clock?.now() ?? .now }, onProgress: { _ in true }
        )
    }
}

private func activity(_ type: String) -> String {
    #"{"serverContent":{},"voiceActivity":{"type":""# + type + #"","audioOffset":"1.000s"}}"#
}

final class GeminiTestWebSocket: GeminiLiveWebSocket, @unchecked Sendable {
    private struct State {
        var queued: [URLSessionWebSocketTask.Message] = []
        var receiver: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
        var closed = false
        var sent: [URLSessionWebSocketTask.Message] = []
        var pingCount = 0
        var onSend: (@Sendable (URLSessionWebSocketTask.Message) async throws -> Void)?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let automaticallyCompleteSetup: Bool

    init(automaticallyCompleteSetup: Bool = true) {
        self.automaticallyCompleteSetup = automaticallyCompleteSetup
    }

    var isClosed: Bool { state.withLock { $0.closed } }
    var sentMessages: [URLSessionWebSocketTask.Message] { state.withLock { $0.sent } }
    var pingCount: Int { state.withLock { $0.pingCount } }
    var onSend: (@Sendable (URLSessionWebSocketTask.Message) async throws -> Void)? {
        get { state.withLock { $0.onSend } }
        set { state.withLock { $0.onSend = newValue } }
    }

    func resume() {
        if automaticallyCompleteSetup { enqueue(#"{"setupComplete":{}}"#) }
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        let handler = try state.withLock { state in
            guard !state.closed else { throw URLError(.cancelled) }
            state.sent.append(message)
            return state.onSend
        }
        try await handler?(message)
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            let result: Result<URLSessionWebSocketTask.Message, Error>? = state.withLock { state in
                if state.closed { return .failure(URLError(.cancelled)) }
                if !state.queued.isEmpty { return .success(state.queued.removeFirst()) }
                state.receiver = continuation
                return nil
            }
            if let result { continuation.resume(with: result) }
        }
    }

    func enqueue(_ text: String) {
        let message = URLSessionWebSocketTask.Message.string(text)
        let receiver = state.withLock { state in
            guard !state.closed else { return Optional<CheckedContinuation<URLSessionWebSocketTask.Message, Error>>.none }
            if let receiver = state.receiver {
                state.receiver = nil
                return receiver
            }
            state.queued.append(message)
            return nil
        }
        receiver?.resume(returning: message)
    }

    func ping() async throws {
        try state.withLock { state in
            guard !state.closed else { throw URLError(.cancelled) }
            state.pingCount += 1
        }
    }

    func close(code: URLSessionWebSocketTask.CloseCode) {
        let receiver = state.withLock { state in
            state.closed = true
            state.onSend = nil
            let receiver = state.receiver
            state.receiver = nil
            return receiver
        }
        receiver?.resume(throwing: URLError(.cancelled))
    }
}

func waitUntil(_ condition: @Sendable () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    guard condition() else {
        XCTFail("Timed out waiting for the test transport")
        throw URLError(.timedOut)
    }
}

private func isGeminiEndMessage(_ message: URLSessionWebSocketTask.Message) -> Bool {
    if case .string(let text) = message { return text == GeminiLiveTranscriptionSession.audioStreamEndMessage }
    return false
}

// A frozen test clock must not leave a broken finalization rule hanging forever.
// This generous wall-clock watchdog is cleanup, not a timing assertion.
private func finishWithWatchdog(_ session: GeminiLiveTranscriptionSession) async throws -> PluginTranscriptionResult {
    try await withThrowingTaskGroup(of: PluginTranscriptionResult.self) { group in
        group.addTask { try await session.finish() }
        group.addTask {
            try await Task.sleep(for: .seconds(10))
            await session.cancel()
            throw URLError(.timedOut)
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
