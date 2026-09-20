import Foundation
import TypeWhisperPluginSDK
import XCTest
@testable import R2T2Plugin

final class R2T2PluginTests: XCTestCase {
    func testLanguageMappingUsesCanonicalNamesAndAutoFallback() {
        XCTAssertNil(R2T2Protocol.languageName(for: nil))
        XCTAssertNil(R2T2Protocol.languageName(for: " "))
        XCTAssertEqual(R2T2Protocol.languageName(for: "zh"), "Chinese")
        XCTAssertEqual(R2T2Protocol.languageName(for: "en-US"), "English")
        XCTAssertEqual(R2T2Protocol.languageName(for: "de_DE"), "German")
        XCTAssertNil(R2T2Protocol.languageName(for: "xx"))
    }

    func testLiveRequestHeadIsChunkedPostWithQueryParameters() {
        let url = URL(string: "http://127.0.0.1:8488")!
        let head = String(decoding: R2T2Protocol.makeLiveRequestHead(serverURL: url, modelId: "r2t2", language: "English"), as: UTF8.self)

        XCTAssertTrue(head.hasPrefix("POST /v1/audio/transcriptions/live?model=r2t2&sample_rate=16000&channels=1&sample_format=s16le&language=English HTTP/1.1\r\n"))
        XCTAssertTrue(head.contains("\r\nHost: 127.0.0.1:8488\r\n"))
        XCTAssertTrue(head.contains("\r\nTransfer-Encoding: chunked\r\n"))
        XCTAssertTrue(head.hasSuffix("\r\n\r\n"))
        XCTAssertFalse(R2T2Protocol.livePath(modelId: "r2t2", language: nil).contains("language"))
    }

    func testPromptIsForwardedAsURLEncodedQueryParameter() {
        let path = R2T2Protocol.livePath(modelId: "r2t2", language: nil, prompt: "CaperWhite, Gerrit, Shop Server")
        XCTAssertTrue(path.hasSuffix("&prompt=CaperWhite,%20Gerrit,%20Shop%20Server"), path)
        XCTAssertFalse(R2T2Protocol.livePath(modelId: "r2t2", language: nil, prompt: "").contains("prompt"))
    }

    func testContextPromptJoinsDictionaryTerms() {
        XCTAssertNil(R2T2Protocol.contextPrompt(from: nil))
        XCTAssertNil(R2T2Protocol.contextPrompt(from: "   "))
        let joined = R2T2Protocol.contextPrompt(from: "CaperWhite, Gerrit\nShopServer")
        XCTAssertNotNil(joined)
        for term in ["CaperWhite", "Gerrit", "ShopServer"] {
            XCTAssertTrue(joined!.contains(term), joined!)
        }
        XCTAssertEqual(R2T2Plugin().dictionaryTermsSupport, .supported)
    }

    func testChunkFraming() {
        XCTAssertEqual([UInt8](R2T2Protocol.chunkFrame(Data([1, 2, 3]))), Array("3\r\n".utf8) + [1, 2, 3] + Array("\r\n".utf8))
        XCTAssertEqual(String(decoding: R2T2Protocol.chunkFrame(Data(repeating: 0, count: 4096)).prefix(6), as: UTF8.self), "1000\r\n")
        XCTAssertEqual(String(decoding: R2T2Protocol.terminatingChunk, as: UTF8.self), "0\r\n\r\n")
    }

    func testParseSSEEvents() {
        XCTAssertEqual(R2T2Protocol.parseSSEData(#"{"type":"transcript.text.delta","delta":" hello"}"#), .delta(" hello"))
        XCTAssertEqual(R2T2Protocol.parseSSEData(#"{"type":"transcript.text.done","text":"Hello world.","timing":{"ttft_ms":12.5}}"#), .done("Hello world."))
        XCTAssertEqual(R2T2Protocol.parseSSEData(#"{"type":"error","error":{"message":"boom"}}"#), .error("boom"))
        XCTAssertEqual(R2T2Protocol.parseSSEData("[DONE]"), .finished)
        XCTAssertNil(R2T2Protocol.parseSSEData("not json"))
    }

    func testResponseParserHandlesChunkedSSEAcrossSplitPackets() {
        let body = "data: {\"type\":\"transcript.text.delta\",\"delta\":\"Some\"}\n\n"
            + "data: {\"type\":\"transcript.text.delta\",\"delta\":\" call\"}\n\n"
            + "data: {\"type\":\"transcript.text.done\",\"text\":\"Some call\"}\n\n"
            + "data: [DONE]\n\n"
        var wire = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nTransfer-Encoding: chunked\r\n\r\n"
        // Split the body into two uneven HTTP chunks.
        let split = 40
        let first = String(body.prefix(split)), second = String(body.dropFirst(split))
        wire += String(first.utf8.count, radix: 16) + "\r\n" + first + "\r\n"
        wire += String(second.utf8.count, radix: 16) + "\r\n" + second + "\r\n0\r\n\r\n"
        let bytes = Data(wire.utf8)

        var parser = R2T2ResponseParser()
        var events: [R2T2Protocol.ServerEvent] = []
        // Feed byte by byte to exercise every partial-state path.
        for byte in bytes {
            events += parser.feed(Data([byte]))
        }

        XCTAssertEqual(parser.statusCode, 200)
        XCTAssertEqual(events, [.delta("Some"), .delta(" call"), .done("Some call"), .finished])
    }

    func testResponseParserSurfacesHTTPErrors() {
        let json = #"{"error":{"message":"live transcription requires a model configured with mode=streaming: r2t2","type":"invalid_request_error"}}"#
        let wire = "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: \(json.utf8.count)\r\n\r\n" + json
        var parser = R2T2ResponseParser()
        let events = parser.feed(Data(wire.utf8))
        XCTAssertEqual(parser.statusCode, 400)
        XCTAssertEqual(events, [.error("HTTP 400: live transcription requires a model configured with mode=streaming: r2t2")])
    }

    func testPCM16LEEncodingClampsAndUsesLittleEndian() {
        let data = R2T2Protocol.makePCM16LEData(samples: [-1, 0, 1, 0.5])
        XCTAssertEqual([UInt8](data), [0x01, 0x80, 0x00, 0x00, 0xff, 0x7f, 0xff, 0x3f])
    }

    func testServerURLNormalization() {
        XCTAssertEqual(R2T2Protocol.normalizedServerURL("http://127.0.0.1:8488")?.absoluteString, "http://127.0.0.1:8488")
        XCTAssertEqual(R2T2Protocol.normalizedServerURL("localhost:8488/")?.absoluteString, "http://localhost:8488")
        XCTAssertEqual(R2T2Protocol.normalizedServerURL("https://asr.example.com")?.absoluteString, "https://asr.example.com")
        XCTAssertNil(R2T2Protocol.normalizedServerURL(""))
    }

    func testPluginDefaults() {
        let plugin = R2T2Plugin()
        XCTAssertTrue(plugin.isConfigured)
        XCTAssertEqual(plugin.selectedModelId, "r2t2")
        XCTAssertEqual(plugin.serverURLString, "http://127.0.0.1:8488")
        XCTAssertTrue(plugin.supportedLanguages.contains("zh"))
        XCTAssertTrue(plugin.supportedLanguages.contains("en"))
        XCTAssertTrue(plugin.supportsStreaming)
    }

    /// End-to-end against a locally running audiocpp_server (devboard project `r2t2`). Skips when absent.
    func testLiveTranscriptionAgainstLocalServer() async throws {
        let health = URL(string: "http://127.0.0.1:8488/health")!
        var request = URLRequest(url: health)
        request.timeoutInterval = 1
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw XCTSkip("No audiocpp_server on 127.0.0.1:8488")
        }
        let wavURL = URL(fileURLWithPath: NSString(string: "~/github/audio.cpp/assets/resources/sample_16k.wav").expandingTildeInPath)
        guard let wav = try? Data(contentsOf: wavURL) else {
            throw XCTSkip("Sample audio not found at \(wavURL.path)")
        }
        let pcm = wav.dropFirst(44)
        var samples = [Float](repeating: 0, count: pcm.count / 2)
        pcm.withUnsafeBytes { raw in
            for i in 0..<samples.count {
                samples[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768
            }
        }

        let plugin = R2T2Plugin()
        let progress = OSAllocatedUnfairLockBox<[String]>([])
        let result = try await plugin.transcribe(
            audio: AudioData(samples: samples, wavData: wav, duration: Double(samples.count) / 16_000),
            language: "en",
            translate: false,
            prompt: nil,
            onProgress: { text in progress.withLock { $0.append(text) }; return true }
        )

        XCTAssertTrue(result.text.lowercased().contains("mother nature"), result.text)
        XCTAssertTrue(result.text.contains("22,500"), result.text)
        XCTAssertGreaterThan(progress.withLock { $0.count }, 3, "expected streamed progress callbacks")
    }
}

private final class OSAllocatedUnfairLockBox<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}
