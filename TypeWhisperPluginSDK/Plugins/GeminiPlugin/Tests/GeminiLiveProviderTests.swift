import AVFoundation
import Foundation
import os
import XCTest
@testable import GeminiPlugin

/// Opt-in provider smoke using synthetic 16 kHz mono WAV fixtures. Credentials
/// come from the test process environment and are never printed by this test.
final class GeminiLiveProviderTests: XCTestCase {
    func testLiveProviderColdAndWarmDictations() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["TYPEWHISPER_GEMINI_LIVE_TEST"] == "1",
              let apiKey = environment["TYPEWHISPER_GEMINI_LIVE_API_KEY"], !apiKey.isEmpty,
              let firstPath = environment["TYPEWHISPER_GEMINI_LIVE_FIRST_WAV"],
              let secondPath = environment["TYPEWHISPER_GEMINI_LIVE_SECOND_WAV"] else {
            throw XCTSkip("Opt-in Gemini provider test requires an API key and two synthetic WAV fixtures.")
        }
        // Fixture sentences: "Blue umbrellas keep the rain away."
        // and "Seven orange bicycles are waiting outside."
        let fixtures = try [firstPath, secondPath].map(Self.samples)
        for mode in [GeminiTranscriptionMode.verbatim, .smart] {
            let sockets = OSAllocatedUnfairLock(initialState: [GeminiRecordingWebSocket]())
            let pool = GeminiLiveSessionPool { configuration in
                let socket = try GeminiRecordingWebSocket(apiKey: configuration.apiKey)
                sockets.withLock { $0.append(socket) }
                return try await GeminiLiveTranscriptionSession.connect(
                    apiKey: configuration.apiKey, modelId: configuration.modelId, mode: configuration.mode,
                    languageCodes: configuration.languageCodes, customVocabulary: configuration.customVocabulary,
                    socket: socket
                )
            }
            let configuration = GeminiLiveConfiguration(
                apiKey: apiKey, modelId: "gemini-3.5-transcribe-live", mode: mode,
                languageCodes: ["en-US"], customVocabulary: ["TypeWhisper"]
            )
            do {
                for index in fixtures.indices {
                    let connectStart = ContinuousClock.now
                    let session = try await pool.checkout(configuration: configuration, onProgress: { _ in true })
                    let connectDuration = connectStart.duration(to: .now)
                    let socket = sockets.withLock { $0[index] }
                    // Send at microphone cadence, including trailing silence to
                    // exercise provider completion before hotkey release.
                    let samples = fixtures[index] + [Float](repeating: 0, count: 16_000)
                    for offset in stride(from: 0, to: samples.count, by: 1_600) {
                        try await session.appendAudio(samples: Array(samples[offset..<min(offset + 1_600, samples.count)]))
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    let eventsBeforeRelease = socket.events
                    let finishStart = ContinuousClock.now
                    let result = try await session.finish()
                    let finishDuration = finishStart.duration(to: .now)
                    print("[Gemini live] mode=\(mode.rawValue) dictation=\(index + 1) connect=\(connectDuration) finish=\(finishDuration) beforeRelease=\(eventsBeforeRelease) events=\(socket.events) text=\(result.text)")
                    XCTAssertLessThan(finishDuration, .milliseconds(3_300))
                    XCTAssertTrue(result.text.lowercased().contains(index == 0 ? "umbrella" : "bicycle"))
                    XCTAssertFalse(result.text.lowercased().contains(index == 0 ? "bicycle" : "umbrella"))
                    if index == 0 {
                        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                        while !sockets.withLock({ $0.count > 1 && $0[1].setupComplete }), ContinuousClock.now < deadline {
                            try await Task.sleep(for: .milliseconds(25))
                        }
                        XCTAssertTrue(sockets.withLock { $0.count == 2 && $0[1].setupComplete })
                    } else {
                        XCTAssertLessThan(connectDuration, .milliseconds(100), "The second dictation must use the ready connection")
                    }
                }
                await pool.shutdown()
            } catch {
                await pool.shutdown()
                throw error
            }
        }
    }

    private static func samples(path: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let data = try XCTUnwrap(buffer.floatChannelData)
        return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    }
}

private final class GeminiRecordingWebSocket: GeminiLiveWebSocket, @unchecked Sendable {
    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    private let recorded = OSAllocatedUnfairLock(initialState: [String]())
    var events: [String] { recorded.withLock { $0 } }
    var setupComplete: Bool { events.contains("setupComplete") }

    init(apiKey: String) throws {
        var url = try XCTUnwrap(URLComponents(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"))
        url.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        session = URLSession(configuration: .ephemeral)
        socket = session.webSocketTask(with: try XCTUnwrap(url.url))
    }

    func resume() { socket.resume() }
    func send(_ message: URLSessionWebSocketTask.Message) async throws { try await socket.send(message) }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        let message = try await socket.receive()
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let bytes): data = bytes
        @unknown default: return message
        }
        if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let content = object["serverContent"] as? [String: Any]
            let events = object.keys.filter { $0 != "serverContent" }.sorted() + (content?.keys.sorted() ?? [])
            recorded.withLock { $0.append(contentsOf: events) }
        }
        return message
    }
    func ping() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            socket.sendPing { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
    func close(code: URLSessionWebSocketTask.CloseCode) {
        socket.cancel(with: code, reason: nil)
        session.invalidateAndCancel()
    }
}
