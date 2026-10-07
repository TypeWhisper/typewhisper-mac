import Foundation
import XCTest
@_spi(Testing) @testable import TypeWhisperPluginSDK

final class PluginAudioChunkingTests: XCTestCase {
    private static let sampleRate = 16_000

    override func tearDown() {
        PluginHTTPClient.resetTestingHooks()
        super.tearDown()
    }

    // MARK: - Chunk boundaries

    func testAudioThatFitsIntoOneChunkIsNotSplit() {
        let samples = Self.speech(seconds: 10)

        let ranges = PluginAudioChunking.chunkRanges(for: samples, maximumChunkSampleCount: samples.count)

        XCTAssertEqual(ranges, [0..<samples.count])
    }

    func testCutLandsInTheQuietStretchNearTheMiddle() throws {
        // 100 s of speech with a 1 s pause from 48 s, chunks of at most 60 s.
        var samples = Self.speech(seconds: 100)
        samples.replaceSubrange(48 * Self.sampleRate..<49 * Self.sampleRate, with: Self.silence(seconds: 1))

        let ranges = PluginAudioChunking.chunkRanges(for: samples, maximumChunkSampleCount: 60 * Self.sampleRate)

        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges.first?.lowerBound, 0)
        XCTAssertEqual(ranges.last?.upperBound, samples.count)
        let cut = try XCTUnwrap(ranges.first?.upperBound)
        XCTAssertEqual(ranges.last?.lowerBound, cut)
        XCTAssertTrue((48 * Self.sampleRate..<49 * Self.sampleRate).contains(cut), "cut at \(cut)")
    }

    func testChunksNeverExceedTheMaximumAndCoverEverySample() {
        // 25 s of speech with short pauses, chunks of at most 10 s.
        var samples = Self.speech(seconds: 25)
        for pause in stride(from: 3_000, to: 25_000, by: 3_700) {
            let start = pause * Self.sampleRate / 1_000
            samples.replaceSubrange(start..<(start + 3_200), with: Self.silence(seconds: 0.2))
        }
        let maximum = 10 * Self.sampleRate

        let ranges = PluginAudioChunking.chunkRanges(for: samples, maximumChunkSampleCount: maximum)

        XCTAssertEqual(ranges.count, 3)
        XCTAssertEqual(ranges.first?.lowerBound, 0)
        XCTAssertEqual(ranges.last?.upperBound, samples.count)
        for (previous, next) in zip(ranges, ranges.dropFirst()) {
            XCTAssertEqual(previous.upperBound, next.lowerBound)
        }
        XCTAssertTrue(ranges.allSatisfy { $0.count <= maximum }, "\(ranges.map(\.count))")
    }

    func testAnEarlyPauseDoesNotAddAChunk() {
        // 119 s with chunks of at most 60 s needs two chunks. A cut in the
        // pause at 57 s would leave 62 s for the second one and add a third.
        var samples = Self.speech(seconds: 119)
        samples.replaceSubrange(57 * Self.sampleRate..<58 * Self.sampleRate, with: Self.silence(seconds: 1))

        let ranges = PluginAudioChunking.chunkRanges(for: samples, maximumChunkSampleCount: 60 * Self.sampleRate)

        XCTAssertEqual(ranges.count, 2)
        XCTAssertTrue(ranges.allSatisfy { $0.count <= 60 * Self.sampleRate }, "\(ranges.map(\.count))")
    }

    // MARK: - Merging

    func testShortAudioIsTranscribedInOneCallWithTheOriginalAudio() async throws {
        let audio = Self.audio(Self.speech(seconds: 5))
        var calls: [Int] = []

        let result = try await PluginAudioChunking.transcribe(audio, maximumChunkDuration: 60) { chunk in
            calls.append(chunk.samples.count)
            return PluginTranscriptionResult(text: " whole ", detectedLanguage: "en")
        }

        XCTAssertEqual(calls, [audio.samples.count])
        XCTAssertEqual(result.text, " whole ", "a single call returns the engine result unchanged")
    }

    func testChunkResultsAreMergedWithTimesShiftedByTheChunkOffset() async throws {
        var samples = Self.speech(seconds: 100)
        samples.replaceSubrange(48 * Self.sampleRate..<49 * Self.sampleRate, with: Self.silence(seconds: 1))
        let audio = Self.audio(samples)
        let collector = PluginWordTimingCollector()
        var chunkDurations: [TimeInterval] = []

        let result = try await PluginWordTimings.$collector.withValue(collector) {
            try await PluginAudioChunking.transcribe(audio, maximumChunkDuration: 60) { chunk in
                let index = chunkDurations.count
                chunkDurations.append(chunk.duration)
                XCTAssertEqual(chunk.wavData, PluginWavEncoder.encode(chunk.samples))
                PluginWordTimings.report([PluginWordTiming(text: "word\(index)", start: 1, end: 2)])
                return PluginTranscriptionResult(
                    text: index == 0 ? " Hello there. " : "General Kenobi.",
                    detectedLanguage: index == 0 ? nil : "en",
                    segments: [PluginTranscriptionSegment(text: "segment\(index)", start: 1, end: 2)]
                )
            }
        }

        XCTAssertEqual(chunkDurations.count, 2)
        let offset = try XCTUnwrap(chunkDurations.first)
        XCTAssertEqual(chunkDurations.reduce(0, +), 100, accuracy: 0.001)
        XCTAssertEqual(result.text, "Hello there. General Kenobi.")
        XCTAssertEqual(result.detectedLanguage, "en")
        XCTAssertEqual(result.segments.map(\.text), ["segment0", "segment1"])
        XCTAssertEqual(result.segments.map(\.start), [1, 1 + offset])
        XCTAssertEqual(result.segments.map(\.end), [2, 2 + offset])
        XCTAssertEqual(collector.words, [
            PluginWordTiming(text: "word0", start: 1, end: 2),
            PluginWordTiming(text: "word1", start: 1 + offset, end: 2 + offset),
        ])
    }

    func testAFailingChunkFailsTheTranscription() async {
        let audio = Self.audio(Self.speech(seconds: 100))
        var calls = 0

        do {
            _ = try await PluginAudioChunking.transcribe(audio, maximumChunkDuration: 60) { _ in
                calls += 1
                throw PluginTranscriptionError.fileTooLarge
            }
            XCTFail("expected the chunk error")
        } catch {
            XCTAssertEqual(error.localizedDescription, PluginTranscriptionError.fileTooLarge.localizedDescription)
        }
        XCTAssertEqual(calls, 1)
    }

    func testJoinedTextAddsSpacesOnlyWhereTheScriptUsesThem() {
        XCTAssertEqual(PluginAudioChunking.joinedText(["Hello.", "", " World "]), "Hello. World")
        XCTAssertEqual(PluginAudioChunking.joinedText(["今日は。", "元気です"]), "今日は。元気です")
        XCTAssertEqual(PluginAudioChunking.joinedText(["我们走吧", "好的"]), "我们走吧好的")
        XCTAssertEqual(PluginAudioChunking.joinedText(["안녕하세요.", "반갑습니다"]), "안녕하세요. 반갑습니다")
        XCTAssertEqual(PluginAudioChunking.joinedText(["Tokyo", "東京"]), "Tokyo 東京")
    }

    // MARK: - OpenAI-compatible helper

    func testGPT4oTranscribeModelsGetShorterChunksForTheirOutputTokenLimit() {
        for model in ["gpt-4o-transcribe", "gpt-4o-mini-transcribe", "openai/gpt-4o-transcribe"] {
            XCTAssertEqual(PluginOpenAITranscriptionHelper.maximumChunkDuration(forModel: model), 300, model)
        }
        for model in ["whisper-large-v3", "whisper-1", "gpt-transcribe", "gpt-4o"] {
            XCTAssertEqual(
                PluginOpenAITranscriptionHelper.maximumChunkDuration(forModel: model),
                PluginAudioChunking.defaultMaximumChunkDuration,
                model
            )
        }
    }

    func testHelperUploadsLongAudioInChunksThatFitTheUploadCap() async throws {
        PluginOpenAITranscriptionHelper.resetWordTimingSupportForTesting()
        let session = ChunkingMockSession(responses: [
            #"{"text":" first part","language":"de","segments":[{"start":0.5,"end":2,"text":" first part"}]}"#,
            #"{"text":" second part","language":"de","segments":[{"start":0.5,"end":2,"text":" second part"}]}"#,
        ])
        PluginHTTPClient.configureForTesting { _ in session }
        let helper = PluginOpenAITranscriptionHelper(baseURL: "https://chunks.example.test")
        // 11 minutes with a pause at 330 s, the middle.
        var samples = Self.speech(seconds: 660)
        samples.replaceSubrange(330 * Self.sampleRate..<331 * Self.sampleRate, with: Self.silence(seconds: 1))
        let audio = Self.audio(samples, encodingWav: false)

        let result = try await helper.transcribe(
            audio: audio, apiKey: "k", modelName: "whisper-large-v3",
            language: "de", translate: false, prompt: "TypeWhisper"
        )

        XCTAssertEqual(result.text, "first part second part")
        XCTAssertEqual(result.detectedLanguage, "de")
        let requests = session.requests
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            let body = try XCTUnwrap(request.httpBody)
            XCTAssertLessThan(body.count, 25 * 1_024 * 1_024)
            // The form fields follow the audio file.
            let fields = String(decoding: body.suffix(1_000), as: UTF8.self)
            XCTAssertTrue(fields.contains("name=\"language\"\r\n\r\nde"))
            XCTAssertTrue(fields.contains("name=\"prompt\"\r\n\r\nTypeWhisper"))
        }
        let secondStart = try XCTUnwrap(result.segments.last?.start)
        XCTAssertEqual(secondStart, 330.5, accuracy: 1)
    }

    func testCompressedHelperEncodesEveryChunkAsItsOwnFile() async throws {
        let session = ChunkingMockSession(responses: [#"{"text":"one"}"#, #"{"text":"two"}"#])
        PluginHTTPClient.configureForTesting { _ in session }
        let helper = PluginOpenAITranscriptionHelper(baseURL: "https://chunks.example.test", responseFormat: "json")
        let audio = Self.audio(
            Self.speech(seconds: PluginAudioChunking.defaultMaximumChunkDuration + 60),
            encodingWav: false
        )

        let result = try await helper.transcribeCompressedAudioWithWavFallback(
            audio: audio, apiKey: "k", modelName: "whisper-large-v3",
            language: nil, translate: false, prompt: nil, requestTimeout: 600
        )

        XCTAssertEqual(result.text, "one two")
        let headers = session.requests.map { String(decoding: ($0.httpBody ?? Data()).prefix(300), as: UTF8.self) }
        XCTAssertEqual(headers.count, 2)
        XCTAssertTrue(headers.allSatisfy { $0.contains(#"filename="audio.m4a""#) })
    }

    // MARK: - Fixtures

    /// A steady level loud enough that silence is clearly the quietest stretch.
    private static func speech(seconds: Double) -> [Float] {
        [Float](repeating: 0.3, count: Int(seconds * Double(sampleRate)))
    }

    private static func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * Double(sampleRate)))
    }

    /// Chunks carry their own WAV, so long fixtures can skip encoding the
    /// whole recording.
    private static func audio(_ samples: [Float], encodingWav: Bool = true) -> AudioData {
        AudioData(
            samples: samples,
            wavData: encodingWav ? PluginWavEncoder.encode(samples) : Data(),
            duration: Double(samples.count) / Double(sampleRate)
        )
    }
}

private final class ChunkingMockSession: PluginHTTPClientSession, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String]
    private var recordedRequests: [URLRequest] = []

    init(responses: [String]) {
        self.responses = responses
    }

    var requests: [URLRequest] {
        lock.withLock { recordedRequests }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let body = lock.withLock {
            recordedRequests.append(request)
            return responses.isEmpty ? #"{"text":""}"# : responses.removeFirst()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }

    func finishTasksAndInvalidate() {}
}
