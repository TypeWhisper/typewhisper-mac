import Foundation
import TypeWhisperPluginSDK
import TypeWhisperPluginSDKTesting
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

    func testPromptPlusIsPercentEncoded() {
        let path = R2T2Protocol.livePath(modelId: "r2t2", language: nil, prompt: "C++, a+b")
        XCTAssertTrue(path.contains("prompt=C%2B%2B,%20a%2Bb"), path)
        XCTAssertFalse(path.contains("+"), path)
    }

    func testConnectTimesOutWhenNothingListens() async throws {
        // TEST-NET-1 (RFC 5737) is not routed, so the connection neither succeeds nor fails and
        // only the connect timeout ends it. Without a route it may also fail fast; both must not hang.
        let host = try PluginTestHostServices(defaults: [R2T2Plugin.serverURLKey: "http://192.0.2.1:9"])
        let plugin = R2T2Plugin()
        plugin.activate(host: host)
        let started = Date()
        do {
            _ = try await plugin.transcribe(audio: AudioData(samples: [0], wavData: Data(), duration: 0),
                                            language: nil, translate: false, prompt: nil)
            XCTFail("expected a connection error")
        } catch {
            XCTAssertFalse(error is CancellationError, "timeouts must surface as a connection error, got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 15, "connect timeout did not fire")
    }

    func testCancellingWhileConnectingEndsPromptly() async throws {
        let host = try PluginTestHostServices(defaults: [R2T2Plugin.serverURLKey: "http://192.0.2.1:9"])
        let plugin = R2T2Plugin()
        plugin.activate(host: host)
        let task = Task {
            try await plugin.transcribe(audio: AudioData(samples: [0], wavData: Data(), duration: 0),
                                        language: nil, translate: false, prompt: nil)
        }
        try await Task.sleep(for: .milliseconds(300))
        let started = Date()
        task.cancel()
        _ = try? await task.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "cancellation did not end the connect")
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
        // Split inside the JSON: the error is reported once, complete, when the connection closes.
        let bytes = Data(wire.utf8)
        XCTAssertEqual(parser.feed(bytes.prefix(bytes.count - 20)), [])
        XCTAssertEqual(parser.feed(bytes.suffix(20)), [])
        XCTAssertEqual(parser.statusCode, 400)
        XCTAssertEqual(parser.finish(), [.error("HTTP 400: live transcription requires a model configured with mode=streaming: r2t2")])
    }

    func testResponseParserReportsEmptyErrorBodyAndMissingResponse() {
        var parser = R2T2ResponseParser()
        XCTAssertEqual(parser.feed(Data("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n".utf8)), [])
        XCTAssertEqual(parser.finish(), [.error("HTTP 503")])

        var silent = R2T2ResponseParser()
        XCTAssertEqual(silent.finish(), [.error("The server closed the connection without a response")])
    }

    func testResponseParserKeepsMultibyteCharactersSplitAcrossPackets() {
        let body = "data: {\"type\":\"transcript.text.delta\",\"delta\":\"你好\"}\n\n"
        let wire = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n" + body
        var parser = R2T2ResponseParser()
        var events: [R2T2Protocol.ServerEvent] = []
        for byte in Data(wire.utf8) {
            events += parser.feed(Data([byte]))
        }
        XCTAssertEqual(events, [.delta("你好")])
        XCTAssertEqual(parser.finish(), [])
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

    func testPluginDefaultsToBuiltInServerWithoutDownloads() throws {
        let host = try PluginTestHostServices()
        let plugin = R2T2Plugin()
        plugin.activate(host: host)
        XCTAssertFalse(plugin.isConfigured)
        XCTAssertEqual(plugin.selectedModelId, "r2t2-q8_0")
        XCTAssertEqual(plugin.availableModels.map(\.id), ["r2t2-q4_k_m", "r2t2-q8_0", "r2t2-f16"])
        XCTAssertTrue(plugin.downloadedModels.isEmpty)
        XCTAssertTrue(plugin.supportedLanguages.contains("zh"))
        XCTAssertTrue(plugin.supportedLanguages.contains("en"))
        XCTAssertTrue(plugin.supportsStreaming)
    }

    func testStoredServerURLKeepsOwnServerMode() throws {
        let host = try PluginTestHostServices(defaults: [R2T2Plugin.serverURLKey: "http://127.0.0.1:8488"])
        let plugin = R2T2Plugin()
        plugin.activate(host: host)
        XCTAssertTrue(plugin.isConfigured)
        XCTAssertEqual(plugin.selectedModelId, "r2t2")
        XCTAssertEqual(plugin.serverURLString, "http://127.0.0.1:8488")
    }

    func testBuiltInModelCountsAsInstalledWithRuntimeGGUFAndLicenses() throws {
        let host = try PluginTestHostServices(defaults: [R2T2Plugin.builtInModelKey: "r2t2-q4_k_m"])
        let assets = R2T2ManagedAssets(pluginDataDirectory: host.pluginDataDirectory)
        let model = R2T2ModelDefinition.q4km
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: assets.runtimeDirectory, withIntermediateDirectories: true)
        fileManager.createFile(atPath: assets.serverExecutableURL.path, contents: Data("#!/bin/sh\n".utf8),
                               attributes: [.posixPermissions: 0o755])
        try fileManager.createDirectory(at: assets.modelDirectory(model), withIntermediateDirectories: true)
        for name in R2T2ModelDefinition.licenseFileNames {
            fileManager.createFile(atPath: assets.modelDirectory(model).appendingPathComponent(name).path, contents: Data("license".utf8))
        }
        // Sparse file with the pinned size; install() verifies the checksum, isModelInstalled only the size.
        fileManager.createFile(atPath: assets.modelFileURL(model).path, contents: nil)
        let handle = try FileHandle(forWritingTo: assets.modelFileURL(model))
        try handle.truncate(atOffset: UInt64(model.fileSize))
        try handle.close()

        let plugin = R2T2Plugin()
        plugin.activate(host: host)
        XCTAssertTrue(plugin.isConfigured)
        XCTAssertEqual(plugin.selectedModelId, "r2t2-q4_k_m")
        XCTAssertEqual(plugin.downloadedModels.map(\.id), ["r2t2-q4_k_m"])

        // The install state is read on activation, after an install and after a delete.
        try fileManager.removeItem(at: assets.modelDirectory(model).appendingPathComponent("NOTICE"))
        let reactivated = R2T2Plugin()
        reactivated.activate(host: host)
        XCTAssertFalse(reactivated.isConfigured, "license files are part of the install")
    }

    func testDeletingTheSelectedModelFallsBackToAnotherInstalledModel() async throws {
        let host = try PluginTestHostServices(defaults: [R2T2Plugin.builtInModelKey: "r2t2-q8_0"])
        let assets = R2T2ManagedAssets(pluginDataDirectory: host.pluginDataDirectory)
        try Self.fakeInstall(assets: assets, models: [.q4km, .q8])
        let plugin = R2T2Plugin()
        plugin.activate(host: host)
        XCTAssertEqual(plugin.selectedModelId, "r2t2-q8_0")

        try await plugin.deleteDownloadedModel("r2t2-q8_0")
        XCTAssertEqual(plugin.downloadedModels.map(\.id), ["r2t2-q4_k_m"])
        XCTAssertEqual(plugin.selectedModelId, "r2t2-q4_k_m")
        XCTAssertTrue(plugin.isConfigured)
    }

    func testInstallCancelledBeforeItStartsReturnsPromptly() async throws {
        let host = try PluginTestHostServices()
        let assets = R2T2ManagedAssets(pluginDataDirectory: host.pluginDataDirectory)
        let task = Task { try await assets.install(.q4km) { _ in } }
        task.cancel()
        let started = Date()
        let result = await task.result
        XCTAssertThrowsError(try result.get())
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "a cancelled download did not resume")
        XCTAssertFalse(assets.isModelInstalled(.q4km))
    }

    func testVerifyRejectsWrongChecksum() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("abc".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        XCTAssertNoThrow(try R2T2ManagedAssets.verify(file, size: 3, sha256: abc))
        XCTAssertThrowsError(try R2T2ManagedAssets.verify(file, size: 3, sha256: String(repeating: "0", count: 64)))
        XCTAssertThrowsError(try R2T2ManagedAssets.verify(file, size: 4, sha256: abc))
    }

    /// Runs the built-in server from a real audio.cpp v0.9.0 binary and GGUF, kills it, and checks that
    /// it comes back. Set R2T2_E2E_SERVER and R2T2_E2E_GGUF (a Q4_K_M file) to enable.
    func testBuiltInServerTranscribesAndRestartsAfterCrash() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let serverPath = environment["R2T2_E2E_SERVER"], let ggufPath = environment["R2T2_E2E_GGUF"] else {
            throw XCTSkip("Set R2T2_E2E_SERVER and R2T2_E2E_GGUF to run the built-in server end to end")
        }
        let host = try PluginTestHostServices(defaults: [R2T2Plugin.builtInModelKey: "r2t2-q4_k_m"])
        let assets = R2T2ManagedAssets(pluginDataDirectory: host.pluginDataDirectory)
        let model = R2T2ModelDefinition.q4km
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: assets.runtimeDirectory, withIntermediateDirectories: true)
        try fileManager.copyItem(atPath: serverPath, toPath: assets.serverExecutableURL.path)
        try fileManager.createDirectory(at: assets.modelDirectory(model), withIntermediateDirectories: true)
        try fileManager.linkItem(atPath: ggufPath, toPath: assets.modelFileURL(model).path)
        for name in R2T2ModelDefinition.licenseFileNames {
            fileManager.createFile(atPath: assets.modelDirectory(model).appendingPathComponent(name).path, contents: Data("license".utf8))
        }

        // Concurrent starts for the same model share one server process.
        let server = R2T2ManagedServer(assets: assets)
        async let firstURL = server.ensureRunning(model: model)
        async let secondURL = server.ensureRunning(model: model)
        let urls = try await [firstURL, secondURL]
        XCTAssertEqual(urls[0], urls[1])
        XCTAssertEqual(Self.serverProcessCount(config: assets.serverConfigURL), 1)
        // A start for a model that is not installed waits for the running start and leaves its server alone.
        async let thirdURL = server.ensureRunning(model: model)
        async let missing: URL? = try? server.ensureRunning(model: .f16)
        let (running, failed) = try await (thirdURL, missing)
        XCTAssertNil(failed)
        XCTAssertEqual(server.baseURL, running)
        XCTAssertEqual(Self.serverProcessCount(config: assets.serverConfigURL), 1)
        // A start for another model waits until the running server's lease is released.
        let copy = R2T2ModelDefinition(id: "r2t2-e2e-copy", displayName: "copy", repositoryId: model.repositoryId,
                                       revision: model.revision, fileName: model.fileName, fileSize: model.fileSize,
                                       sha256: model.sha256)
        try fileManager.createDirectory(at: assets.modelDirectory(copy), withIntermediateDirectories: true)
        try fileManager.linkItem(atPath: ggufPath, toPath: assets.modelFileURL(copy).path)
        for name in R2T2ModelDefinition.licenseFileNames {
            fileManager.createFile(atPath: assets.modelDirectory(copy).appendingPathComponent(name).path, contents: Data("license".utf8))
        }
        let (leasedURL, lease) = try await server.acquire(model: model)
        let switchTask = Task { try await server.ensureRunning(model: copy) }
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(server.baseURL, leasedURL, "the leased server was replaced")
        lease.release()
        let switchedURL = try await switchTask.value
        XCTAssertNotEqual(switchedURL, leasedURL)
        XCTAssertEqual(server.runningModel, copy)
        _ = try await server.ensureRunning(model: model)

        // Stop within the one-second window before a crash restart: the server must stay down.
        try Self.killServer(config: assets.serverConfigURL)
        try await Task.sleep(for: .milliseconds(300))
        server.stop()
        XCTAssertNil(server.baseURL, "stop() returns at once")
        try await Self.waitForServerProcessCount(0, config: assets.serverConfigURL)
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(Self.serverProcessCount(config: assets.serverConfigURL), 0, "crash restart ran after stop()")

        // Stop during an in-flight start: the start fails and leaves no server behind.
        let inFlight = Task { try await server.ensureRunning(model: model) }
        try await Task.sleep(for: .milliseconds(50))
        server.stop()
        let startResult = await inFlight.result
        XCTAssertThrowsError(try startResult.get())
        try await Task.sleep(for: .seconds(1))
        try await Self.waitForServerProcessCount(0, config: assets.serverConfigURL)

        let plugin = R2T2Plugin()
        plugin.activate(host: host)
        defer { plugin.deactivate() }
        XCTAssertTrue(plugin.isConfigured)
        let (samples, wav) = try Self.sampleAudio()
        let audio = AudioData(samples: samples, wavData: wav, duration: Double(samples.count) / 16_000)
        let first = try await plugin.transcribe(audio: audio, language: "en", translate: false, prompt: nil)
        XCTAssertTrue(first.text.lowercased().contains("mother nature"), first.text)

        try Self.killServer(config: assets.serverConfigURL)
        // The supervisor polls its child every 0.25 s; after that the plugin sees the exit and restarts.
        try await Task.sleep(for: .milliseconds(500))

        let second = try await plugin.transcribe(audio: audio, language: "en", translate: false, prompt: nil)
        XCTAssertTrue(second.text.lowercased().contains("mother nature"), second.text)
    }

    /// Downloads audio.cpp and the Q4_K_M model (about 1.2 GB) from their pinned URLs. Set R2T2_E2E_DOWNLOAD to enable.
    func testInstallDownloadsAndVerifiesPinnedAssets() async throws {
        guard ProcessInfo.processInfo.environment["R2T2_E2E_DOWNLOAD"] != nil else {
            throw XCTSkip("Set R2T2_E2E_DOWNLOAD to download the pinned runtime and Q4_K_M model")
        }
        let host = try PluginTestHostServices()
        let assets = R2T2ManagedAssets(pluginDataDirectory: host.pluginDataDirectory)
        let progress = OSAllocatedUnfairLockBox<[Double]>([])
        try await assets.install(.q4km) { fraction in progress.withLock { $0.append(fraction) } }
        XCTAssertTrue(assets.isRuntimeInstalled)
        XCTAssertTrue(assets.isModelInstalled(.q4km))
        XCTAssertEqual(progress.withLock { $0.last }, 1)
        XCTAssertGreaterThan(progress.withLock { $0.count }, 10)
    }

    /// Creates the runtime executable, license files and sparse GGUFs of the pinned sizes.
    private static func fakeInstall(assets: R2T2ManagedAssets, models: [R2T2ModelDefinition]) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: assets.runtimeDirectory, withIntermediateDirectories: true)
        fileManager.createFile(atPath: assets.serverExecutableURL.path, contents: Data("#!/bin/sh\n".utf8),
                               attributes: [.posixPermissions: 0o755])
        for model in models {
            try fileManager.createDirectory(at: assets.modelDirectory(model), withIntermediateDirectories: true)
            for name in R2T2ModelDefinition.licenseFileNames {
                fileManager.createFile(atPath: assets.modelDirectory(model).appendingPathComponent(name).path, contents: Data("license".utf8))
            }
            fileManager.createFile(atPath: assets.modelFileURL(model).path, contents: nil)
            let handle = try FileHandle(forWritingTo: assets.modelFileURL(model))
            try handle.truncate(atOffset: UInt64(model.fileSize))
            try handle.close()
        }
    }

    private static func killServer(config: URL) throws {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-KILL", "-f", "^[^ ]*audiocpp_server --config \(config.path)"]
        try pkill.run()
        pkill.waitUntilExit()
        XCTAssertEqual(pkill.terminationStatus, 0, "server process not found")
    }

    private static func waitForServerProcessCount(_ expected: Int, config: URL) async throws {
        let deadline = Date().addingTimeInterval(10)
        while serverProcessCount(config: config) != expected, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(serverProcessCount(config: config), expected)
    }

    private static func serverProcessCount(config: URL) -> Int {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", "^[^ ]*audiocpp_server --config \(config.path)"]
        let output = Pipe()
        pgrep.standardOutput = output
        try? pgrep.run()
        pgrep.waitUntilExit()
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(whereSeparator: \.isNewline).count
    }

    private static func sampleAudio() throws -> ([Float], Data) {
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
        return (samples, wav)
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
        let (samples, wav) = try Self.sampleAudio()
        let host = try PluginTestHostServices(defaults: [R2T2Plugin.serverURLKey: "http://127.0.0.1:8488"])
        let plugin = R2T2Plugin()
        plugin.activate(host: host)
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
