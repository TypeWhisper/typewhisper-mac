import Foundation
import XCTest
@_spi(Testing) @testable import TypeWhisperPluginSDK

final class OpenAITranscriptionHelperTests: XCTestCase {
    override func tearDown() {
        PluginHTTPClient.resetTestingHooks()
        super.tearDown()
    }

    func testHelperInstanceLayoutStaysBinaryCompatibleWithExistingPluginBundles() {
        XCTAssertEqual(MemoryLayout<PluginOpenAITranscriptionHelper>.size, MemoryLayout<String>.size * 2)
        XCTAssertEqual(MemoryLayout<PluginOpenAITranscriptionHelper>.stride, MemoryLayout<String>.stride * 2)
    }

    func testPluginAudioUtilsPadsShortSamplesToMinimumDuration() {
        let samples = [Float](repeating: 0.1, count: 6_400)

        let paddedSamples = PluginAudioUtils.paddedSamples(samples, minimumDuration: 1.0)

        XCTAssertEqual(paddedSamples.count, 16_000)
    }

    func testPluginAudioUtilsLeavesLongEnoughSamplesUnchanged() {
        let samples = [Float](repeating: 0.1, count: 16_000)

        let paddedSamples = PluginAudioUtils.paddedSamples(samples, minimumDuration: 1.0)

        XCTAssertEqual(paddedSamples, samples)
    }

    func testPluginAudioUtilsRejectsLowConfidenceShortClipTranscription() {
        XCTAssertFalse(
            PluginAudioUtils.shouldAcceptShortClipTranscription(
                audioDuration: 0.6,
                confidence: 0.42
            )
        )
    }

    func testAudioUtilsPadsShortSamplesToMinimumDuration() {
        let samples = [Float](repeating: 0.1, count: 6_400)

        let paddedSamples = AudioUtils.paddedSamples(samples, minimumDuration: 1.0)

        XCTAssertEqual(paddedSamples.count, 16_000)
    }

    func testPluginAudioUtilsAcceptsHighConfidenceShortClipTranscription() {
        XCTAssertTrue(
            PluginAudioUtils.shouldAcceptShortClipTranscription(
                audioDuration: 0.6,
                confidence: 0.72
            )
        )
    }

    func testPluginAudioUtilsAcceptsLongClipRegardlessOfConfidence() {
        XCTAssertTrue(
            PluginAudioUtils.shouldAcceptShortClipTranscription(
                audioDuration: 1.4,
                confidence: 0.2
            )
        )
    }

    func testNormalizedAudioForUploadPadsShortAudioToOneSecond() {
        let helper = PluginOpenAITranscriptionHelper(baseURL: "https://example.com")
        let samples = [Float](repeating: 0.1, count: 8_000)
        let audio = AudioData(
            samples: samples,
            wavData: PluginWavEncoder.encode(samples),
            duration: 0.5
        )

        let normalized = helper.normalizedAudioForUpload(audio)

        XCTAssertEqual(normalized.samples.count, 16_000)
        XCTAssertEqual(normalized.duration, 1.0, accuracy: 0.0001)
        XCTAssertEqual(String(data: normalized.wavData.prefix(4), encoding: .utf8), "RIFF")
    }

    func testNormalizedAudioForUploadLeavesOneSecondAudioUnchanged() {
        let helper = PluginOpenAITranscriptionHelper(baseURL: "https://example.com")
        let samples = [Float](repeating: 0.1, count: 16_000)
        let wavData = PluginWavEncoder.encode(samples)
        let audio = AudioData(
            samples: samples,
            wavData: wavData,
            duration: 1.0
        )

        let normalized = helper.normalizedAudioForUpload(audio)

        XCTAssertEqual(normalized.samples.count, samples.count)
        XCTAssertEqual(normalized.duration, audio.duration, accuracy: 0.0001)
        XCTAssertEqual(normalized.wavData, wavData)
    }

    func testTranscribeCustomTimeoutAppliesToUploadRequest() async throws {
        let store = OpenAITranscriptionMockSessionStore()
        PluginHTTPClient.configureForTesting { _ in
            store.makeSession()
        }

        let helper = PluginOpenAITranscriptionHelper(baseURL: "https://example.test", responseFormat: "json")
        let samples = [Float](repeating: 0.1, count: 16_000)
        let audio = AudioData(
            samples: samples,
            wavData: PluginWavEncoder.encode(samples),
            duration: 1.0
        )

        let result = try await helper.transcribe(
            audio: audio,
            apiKey: "test-key",
            modelName: "whisper-1",
            language: "en",
            translate: false,
            prompt: nil,
            requestTimeout: 600
        )

        XCTAssertEqual(result.text, "ok")
        XCTAssertEqual(store.sessions.first?.requestedRequests.first?.timeoutInterval, 600)
    }

    func testTranscribeCompressedAudioRejectsEmptySamplesBeforeUpload() async throws {
        let store = OpenAITranscriptionMockSessionStore()
        PluginHTTPClient.configureForTesting { _ in
            store.makeSession()
        }

        let helper = PluginOpenAITranscriptionHelper(baseURL: "https://example.test", responseFormat: "json")
        let audio = AudioData(samples: [], wavData: Data(), duration: 1.0)

        do {
            _ = try await helper.transcribeCompressedAudio(
                audio: audio,
                apiKey: "test-key",
                modelName: "whisper-1",
                language: nil,
                translate: false,
                prompt: nil,
                requestTimeout: 600
            )
            XCTFail("Expected empty compressed audio upload to fail")
        } catch PluginTranscriptionError.apiError(let message) {
            XCTAssertTrue(message.contains("empty audio upload"))
        }

        XCTAssertTrue(store.sessions.isEmpty)
    }
}

private final class OpenAITranscriptionMockSessionStore: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var sessions: [OpenAITranscriptionMockSession] = []

    func makeSession() -> OpenAITranscriptionMockSession {
        let session = OpenAITranscriptionMockSession()
        lock.withLock {
            sessions.append(session)
        }
        return session
    }
}

private final class OpenAITranscriptionMockSession: PluginHTTPClientSession, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requestedRequests: [URLRequest] = []

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock {
            requestedRequests.append(request)
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(#"{"text":"ok","language":"en"}"#.utf8), response)
    }

    func finishTasksAndInvalidate() {}
}
