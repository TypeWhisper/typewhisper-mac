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

    func testPluginAudioUploadEncoderCreatesWavUploadMetadata() {
        let samples = [Float](repeating: 0.1, count: 16_000)
        let audio = AudioData(
            samples: samples,
            wavData: PluginWavEncoder.encode(samples),
            duration: 1.0
        )

        let upload = PluginAudioUploadEncoder.wavUpload(from: audio)

        XCTAssertEqual(upload.filename, "audio.wav")
        XCTAssertEqual(upload.contentType, "audio/wav")
        XCTAssertEqual(upload.format, "wav")
        XCTAssertEqual(String(data: upload.data.prefix(4), encoding: .utf8), "RIFF")
    }

    func testPluginAudioUploadEncoderCreatesCompressedM4AUpload() throws {
        let samples = [Float](repeating: 0.1, count: 16_000)
        let wavData = PluginWavEncoder.encode(samples)

        let upload = try PluginAudioUploadEncoder.compressedM4AUpload(from: samples)

        XCTAssertEqual(upload.filename, "audio.m4a")
        XCTAssertEqual(upload.contentType, "audio/mp4")
        XCTAssertEqual(upload.format, "m4a")
        XCTAssertTrue(upload.data.count > 0)
        XCTAssertLessThan(upload.data.count, wavData.count)
        XCTAssertNotNil(upload.data.range(of: Data("ftyp".utf8)))
        XCTAssertNotNil(upload.data.range(of: Data("mdat".utf8)))
        XCTAssertNotNil(upload.data.range(of: Data("moov".utf8)))
    }

    func testWavFallbackRetryClassifierRequiresMediaFormatOrProbeFailure() {
        XCTAssertTrue(
            PluginAudioUploadEncoder.shouldRetryWithWavUpload(
                statusCode: 400,
                responseData: Data(#"{"error":"unsupported audio format"}"#.utf8)
            )
        )
        XCTAssertTrue(
            PluginAudioUploadEncoder.shouldRetryWithWavUpload(
                statusCode: 422,
                responseData: Data(#"{"error":"invalid MIME type audio/mp4"}"#.utf8)
            )
        )
        XCTAssertTrue(
            PluginAudioUploadEncoder.shouldRetryWithWavUpload(
                statusCode: 400,
                responseData: Data(#"{"error":{"message":"could not process file - is it a valid media file?","type":"invalid_request_error"}}"#.utf8)
            )
        )
        XCTAssertTrue(
            PluginAudioUploadEncoder.shouldRetryWithWavUpload(
                statusCode: 400,
                responseData: Data(#"{"err_msg":"Bad Request: failed to process audio: corrupt or unsupported data"}"#.utf8)
            )
        )
        XCTAssertTrue(
            PluginAudioUploadEncoder.shouldRetryWithWavUpload(
                statusCode: 415,
                responseData: Data(#"{"error":"bad upload"}"#.utf8)
            )
        )
        XCTAssertTrue(
            PluginAudioUploadEncoder.shouldRetryWithWavUpload(
                statusCode: 500,
                responseData: Data(#"{"error":"ffprobe failed: moov atom not found"}"#.utf8)
            )
        )
        XCTAssertTrue(
            PluginAudioUploadEncoder.shouldRetryWithWavUpload(
                error: PluginTranscriptionError.apiError(
                    #"HTTP 500: {"error":"Invalid data found when processing input"}"#
                )
            )
        )
        XCTAssertFalse(
            PluginAudioUploadEncoder.shouldRetryWithWavUpload(
                statusCode: 400,
                responseData: Data(#"{"error":"file too large"}"#.utf8)
            )
        )
        XCTAssertFalse(
            PluginAudioUploadEncoder.shouldRetryWithWavUpload(
                statusCode: 422,
                responseData: Data(#"{"error":"audio too short"}"#.utf8)
            )
        )
        XCTAssertFalse(
            PluginAudioUploadEncoder.shouldRetryWithWavUpload(
                statusCode: 400,
                responseData: Data(#"{"error":{"message":"audio too short","type":"invalid_request_error"}}"#.utf8)
            )
        )
        XCTAssertFalse(
            PluginAudioUploadEncoder.shouldRetryWithWavUpload(
                statusCode: 400,
                responseData: Data(#"{"error":{"message":"invalid file size","type":"invalid_request_error"}}"#.utf8)
            )
        )
        XCTAssertFalse(
            PluginAudioUploadEncoder.shouldRetryWithWavUpload(
                statusCode: 400,
                responseData: Data(#"{"error":{"message":"corrupt request data","type":"invalid_request_error"}}"#.utf8)
            )
        )
        XCTAssertFalse(
            PluginAudioUploadEncoder.shouldRetryWithWavUpload(
                statusCode: 500,
                responseData: Data(#"{"error":"internal server error"}"#.utf8)
            )
        )
        XCTAssertFalse(
            PluginAudioUploadEncoder.shouldRetryWithWavUpload(
                statusCode: 500,
                responseData: Data(#"{"error":"ffmpeg worker unavailable"}"#.utf8)
            )
        )
    }

    func testGenericWavFallbackClassifiesRawHTTPBodyBeyondDisplayLimit() async throws {
        let longError = Data(
            #"{"error":""#
                .appending(String(repeating: "x", count: 700))
                .appending(" unsupported audio format\"}")
                .utf8
        )
        let audio = AudioData(
            samples: [Float](repeating: 0.1, count: 16_000),
            wavData: PluginWavEncoder.encode([Float](repeating: 0.1, count: 16_000)),
            duration: 1.0
        )

        let format = try await PluginAudioUploadEncoder.withCompressedM4AUploadWavFallback(
            from: audio
        ) { uploadFile in
            if uploadFile.format != "wav" {
                let displayedBody = PluginHTTPErrorBodyFormatter.summary(
                    from: longError,
                    contentType: "application/json"
                )
                throw PluginAudioUploadHTTPFailure(
                    statusCode: 400,
                    responseData: longError,
                    underlyingError: PluginTranscriptionError.apiError("HTTP 400: \(displayedBody)")
                )
            }
            return uploadFile.format
        }

        XCTAssertEqual(format, "wav")
    }

    func testGenericWavFallbackUnwrapsNonRetryableHTTPFailure() async throws {
        let audio = AudioData(
            samples: [Float](repeating: 0.1, count: 16_000),
            wavData: PluginWavEncoder.encode([Float](repeating: 0.1, count: 16_000)),
            duration: 1.0
        )
        var attemptedFormats: [String] = []

        do {
            _ = try await PluginAudioUploadEncoder.withCompressedM4AUploadWavFallback(
                from: audio
            ) { uploadFile -> String in
                attemptedFormats.append(uploadFile.format)
                throw PluginAudioUploadHTTPFailure(
                    statusCode: 522,
                    responseData: Data("<html><title>Origin timeout</title></html>".utf8),
                    underlyingError: PluginTranscriptionError.apiError("HTTP 522: bounded summary")
                )
            }
            XCTFail("Expected HTTP failure")
        } catch PluginTranscriptionError.apiError(let message) {
            XCTAssertEqual(message, "HTTP 522: bounded summary")
        }

        XCTAssertEqual(attemptedFormats, ["m4a"])
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
        XCTAssertNil(store.sessions.first?.requestedRequests.first?.url?.query)
    }

    func testTranscribeWithAPIVersionPreservesExistingQueryItems() async throws {
        let store = OpenAITranscriptionMockSessionStore()
        PluginHTTPClient.configureForTesting { _ in
            store.makeSession()
        }

        let helper = PluginOpenAITranscriptionHelper(
            baseURL: "https://example.test/openai?tenant=contoso",
            responseFormat: "json"
        )
        let samples = [Float](repeating: 0.1, count: 16_000)
        let audio = AudioData(
            samples: samples,
            wavData: PluginWavEncoder.encode(samples),
            duration: 1.0
        )

        let result = try await helper.transcribeCompressedAudioWithWavFallback(
            audio: audio,
            apiKey: "test-key",
            modelName: "gpt-live-transcribe",
            language: "en",
            translate: false,
            prompt: nil,
            requestTimeout: 600,
            apiVersion: " preview "
        )

        XCTAssertEqual(result.text, "ok")
        let requestURL = try XCTUnwrap(store.sessions.first?.requestedRequests.first?.url)
        let components = try XCTUnwrap(URLComponents(url: requestURL, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/openai/v1/audio/transcriptions")
        XCTAssertEqual(
            components.queryItems,
            [
                URLQueryItem(name: "tenant", value: "contoso"),
                URLQueryItem(name: "api-version", value: "preview"),
            ]
        )
    }

    func testTranscribeWithAPIVersionReplacesExistingVersion() async throws {
        let store = OpenAITranscriptionMockSessionStore()
        PluginHTTPClient.configureForTesting { _ in
            store.makeSession()
        }

        let helper = PluginOpenAITranscriptionHelper(
            baseURL: "https://example.test/openai?api-version=2024-06-01",
            responseFormat: "json"
        )
        let samples = [Float](repeating: 0.1, count: 16_000)
        let audio = AudioData(
            samples: samples,
            wavData: PluginWavEncoder.encode(samples),
            duration: 1.0
        )

        _ = try await helper.transcribeCompressedAudioWithWavFallback(
            audio: audio,
            apiKey: "test-key",
            modelName: "gpt-live-transcribe",
            language: "en",
            translate: false,
            prompt: nil,
            requestTimeout: 600,
            apiVersion: " preview "
        )

        let requestURL = try XCTUnwrap(store.sessions.first?.requestedRequests.first?.url)
        let components = try XCTUnwrap(URLComponents(url: requestURL, resolvingAgainstBaseURL: false))
        let apiVersionItems = components.queryItems?.filter {
            $0.name.caseInsensitiveCompare("api-version") == .orderedSame
        }
        XCTAssertEqual(apiVersionItems, [URLQueryItem(name: "api-version", value: "preview")])
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

    func testCompressedAudioWithWavFallbackRetriesUnsupportedMediaAndPreservesFields() async throws {
        let store = OpenAITranscriptionMockSessionStore()
        PluginHTTPClient.configureForTesting { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"error":"unsupported audio format"}"#.utf8),
                    415
                ),
                .success(
                    Data(#"{"text":"fallback ok","language":"de"}"#.utf8),
                    200
                ),
            ])
        }

        let helper = PluginOpenAITranscriptionHelper(baseURL: "https://example.test", responseFormat: "json")
        let samples = [Float](repeating: 0.1, count: 16_000)
        let audio = AudioData(
            samples: samples,
            wavData: PluginWavEncoder.encode(samples),
            duration: 1.0
        )

        let result = try await helper.transcribeCompressedAudioWithWavFallback(
            audio: audio,
            apiKey: "test-key",
            modelName: "whisper-1",
            language: "de",
            translate: false,
            prompt: "TypeWhisper",
            requestTimeout: 600
        )

        XCTAssertEqual(result.text, "fallback ok")
        let requests = try XCTUnwrap(store.sessions.first?.requestedRequests)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map(\.timeoutInterval), [600, 600])

        let firstBody = String(decoding: try XCTUnwrap(requests[0].httpBody), as: UTF8.self)
        XCTAssertTrue(firstBody.contains(#"filename="audio.m4a""#))
        XCTAssertTrue(firstBody.contains("Content-Type: audio/mp4"))

        let retryBody = String(decoding: try XCTUnwrap(requests[1].httpBody), as: UTF8.self)
        XCTAssertTrue(retryBody.contains(#"filename="audio.wav""#))
        XCTAssertTrue(retryBody.contains("Content-Type: audio/wav"))
        XCTAssertTrue(retryBody.contains("name=\"model\"\r\n\r\nwhisper-1"))
        XCTAssertTrue(retryBody.contains("name=\"language\"\r\n\r\nde"))
        XCTAssertTrue(retryBody.contains("name=\"prompt\"\r\n\r\nTypeWhisper"))
    }

    func testCompressedAudioWithWavFallbackDoesNotRetryAuthFailure() async throws {
        let store = OpenAITranscriptionMockSessionStore()
        PluginHTTPClient.configureForTesting { _ in
            store.makeSession(outcomes: [
                .success(Data(#"{"error":"bad key"}"#.utf8), 401),
                .success(Data(#"{"text":"should not retry"}"#.utf8), 200),
            ])
        }

        let helper = PluginOpenAITranscriptionHelper(baseURL: "https://example.test", responseFormat: "json")
        let samples = [Float](repeating: 0.1, count: 16_000)
        let audio = AudioData(
            samples: samples,
            wavData: PluginWavEncoder.encode(samples),
            duration: 1.0
        )

        do {
            _ = try await helper.transcribeCompressedAudioWithWavFallback(
                audio: audio,
                apiKey: "bad-key",
                modelName: "whisper-1",
                language: nil,
                translate: false,
                prompt: nil,
                requestTimeout: 600
            )
            XCTFail("Expected invalid API key")
        } catch PluginTranscriptionError.invalidApiKey {
            // Expected
        }

        XCTAssertEqual(store.sessions.first?.requestedRequests.count, 1)
    }

    func testTranscribeSummarizesHTMLHTTPErrorBody() async throws {
        let html = """
            <!DOCTYPE html>
            <html><head><title>example.com | 522: Connection timed out</title></head>
            <body>IP address: 203.0.113.42; trace: secret-trace</body></html>
            """
        var data = Data(html.utf8)
        data.append(Data(repeating: 0x20, count: 7_224 - data.count))

        let store = OpenAITranscriptionMockSessionStore()
        PluginHTTPClient.configureForTesting { _ in
            store.makeSession(outcomes: [
                .response(data, 522, ["Content-Type": "text/html; charset=UTF-8"]),
            ])
        }

        let helper = PluginOpenAITranscriptionHelper(baseURL: "https://example.test", responseFormat: "json")
        let samples = [Float](repeating: 0.1, count: 16_000)
        let audio = AudioData(
            samples: samples,
            wavData: PluginWavEncoder.encode(samples),
            duration: 1.0
        )

        do {
            _ = try await helper.transcribe(
                audio: audio,
                apiKey: "test-key",
                modelName: "whisper-1",
                language: nil,
                translate: false,
                prompt: nil
            )
            XCTFail("Expected HTTP error")
        } catch PluginTranscriptionError.apiError(let message) {
            XCTAssertEqual(
                message,
                "HTTP 522: upstream returned an HTML error page (7224 bytes): example.com | 522: Connection timed out"
            )
            XCTAssertFalse(message.contains("203.0.113.42"))
            XCTAssertFalse(message.contains("secret-trace"))
        }
    }

    func testSuccessfulStatusWithHTMLBodyReportsUpstreamPage() async throws {
        let data = Data("<html><head><title>Proxy failure</title></head></html>".utf8)
        let store = OpenAITranscriptionMockSessionStore()
        PluginHTTPClient.configureForTesting { _ in
            store.makeSession(outcomes: [
                .response(data, 200, ["Content-Type": "text/html"]),
            ])
        }

        let helper = PluginOpenAITranscriptionHelper(baseURL: "https://example.test", responseFormat: "json")
        let samples = [Float](repeating: 0.1, count: 16_000)
        let audio = AudioData(
            samples: samples,
            wavData: PluginWavEncoder.encode(samples),
            duration: 1.0
        )

        do {
            _ = try await helper.transcribe(
                audio: audio,
                apiKey: "test-key",
                modelName: "whisper-1",
                language: nil,
                translate: false,
                prompt: nil
            )
            XCTFail("Expected parse error")
        } catch PluginTranscriptionError.apiError(let message) {
            XCTAssertEqual(
                message,
                "Failed to parse response: upstream returned an HTML error page (\(data.count) bytes): Proxy failure"
            )
        }
    }

    func testWavFallbackUsesRawBodyBeyondDisplayedErrorLimit() async throws {
        let longError = Data(
            #"{"error":""#
                .appending(String(repeating: "x", count: 700))
                .appending(" unsupported audio format\"}")
                .utf8
        )
        let store = OpenAITranscriptionMockSessionStore()
        PluginHTTPClient.configureForTesting { _ in
            store.makeSession(outcomes: [
                .success(longError, 400),
                .success(Data(#"{"text":"fallback ok"}"#.utf8), 200),
            ])
        }

        let helper = PluginOpenAITranscriptionHelper(baseURL: "https://example.test", responseFormat: "json")
        let samples = [Float](repeating: 0.1, count: 16_000)
        let audio = AudioData(
            samples: samples,
            wavData: PluginWavEncoder.encode(samples),
            duration: 1.0
        )

        let result = try await helper.transcribeCompressedAudioWithWavFallback(
            audio: audio,
            apiKey: "test-key",
            modelName: "whisper-1",
            language: nil,
            translate: false,
            prompt: nil,
            requestTimeout: 600
        )

        XCTAssertEqual(result.text, "fallback ok")
        let requests = try XCTUnwrap(store.sessions.first?.requestedRequests)
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(String(decoding: try XCTUnwrap(requests[0].httpBody), as: UTF8.self).contains(#"filename="audio.m4a""#))
        XCTAssertTrue(String(decoding: try XCTUnwrap(requests[1].httpBody), as: UTF8.self).contains(#"filename="audio.wav""#))
    }
}

private final class OpenAITranscriptionMockSessionStore: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var sessions: [OpenAITranscriptionMockSession] = []

    func makeSession(
        outcomes: [OpenAITranscriptionMockSession.Outcome] = [
            .success(Data(#"{"text":"ok","language":"en"}"#.utf8), 200),
        ]
    ) -> OpenAITranscriptionMockSession {
        let session = OpenAITranscriptionMockSession(outcomes: outcomes)
        lock.withLock {
            sessions.append(session)
        }
        return session
    }
}

private final class OpenAITranscriptionMockSession: PluginHTTPClientSession, @unchecked Sendable {
    enum Outcome {
        case success(Data, Int)
        case response(Data, Int, [String: String])
        case failure(Error)
    }

    private let lock = NSLock()
    private var outcomes: [Outcome]
    private(set) var requestedRequests: [URLRequest] = []

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let outcome = lock.withLock {
            requestedRequests.append(request)
            if outcomes.count > 1 {
                return outcomes.removeFirst()
            }
            return outcomes.first ?? .failure(URLError(.badServerResponse))
        }

        switch outcome {
        case .success(let data, let statusCode):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (data, response)
        case .response(let data, let statusCode, let headerFields):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: headerFields
            )!
            return (data, response)
        case .failure(let error):
            throw error
        }
    }

    func finishTasksAndInvalidate() {}
}
