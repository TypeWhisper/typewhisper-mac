import XCTest
@preconcurrency import AVFoundation
import FluidAudio
@_spi(FirstPartyPlugins) import TypeWhisperPluginSDK
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import ParakeetPlugin

final class ParakeetNemotronStreamingTests: XCTestCase {
    private static let modelId = "nemotron-3.5-asr-streaming-0.6b"

    // MARK: - Model metadata

    func testNemotronIsAnOfferedStreamingModelThatDoesNotReplaceTheDefault() {
        let version = ParakeetVersion.nemotronStreaming
        XCTAssertEqual(ParakeetVersion.from(modelId: Self.modelId), version)
        XCTAssertEqual(version.modelDef.displayName, "Nemotron 3.5 ASR Streaming")
        XCTAssertEqual(ParakeetVersion.allCases.first, .ultra, "Ultra stays the default")
        XCTAssertEqual(ParakeetVersion.allCases.last, version)
        XCTAssertFalse(ParakeetPlugin().supportsLiveTranscriptionSession(forModelId: nil), "Ultra stays the default")
        XCTAssertEqual(ParakeetPlugin().transcriptionModels.last?.id, Self.modelId)
        XCTAssertEqual(ParakeetPlugin().transcriptionModels.last?.languageCount, 28)
        XCTAssertNil(version.asrModelVersion)
        XCTAssertThrowsError(try version.requiredAsrModelVersion())
        XCTAssertTrue(version.streamsLive)
        XCTAssertFalse(version.supportsVocabularyBoosting)
        XCTAssertTrue(version.acceptsLanguageHint)
        XCTAssertTrue(ParakeetVersion.allCases.filter { $0 != version }.allSatisfy { !$0.streamsLive && $0.supportsVocabularyBoosting })
    }

    func testNemotronDownloadsAPinnedRevisionOfTheRegistryRepositoryIntoItsOwnFolder() {
        XCTAssertEqual(NemotronStreaming.repository, Repo.nemotronMultilingual.remotePath)
        XCTAssertEqual(ParakeetVersion.nemotronStreaming.huggingFaceRepository, Repo.nemotronMultilingual.remotePath)
        XCTAssertNotNil(NemotronStreaming.revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression))
        XCTAssertEqual(NemotronStreaming.variantFolder, "multilingual/1120ms")
        XCTAssertTrue(NemotronStreaming.filePatterns.allSatisfy { $0.hasPrefix("multilingual/1120ms/") })
        let directories = ParakeetVersion.allCases.map(\.installDirectory)
        XCTAssertEqual(Set(directories).count, directories.count, "Every model has its own folder")
        XCTAssertEqual(
            ParakeetVersion.nemotronStreaming.installDirectory.deletingLastPathComponent(),
            FluidSpeechMini.directory.deletingLastPathComponent()
        )
    }

    func testNemotronOffersTheLanguagesTheModelCardListsAsTranscriptionReady() {
        let languages = ParakeetVersion.nemotronStreaming.supportedLanguages
        XCTAssertEqual(languages.count, 28)
        XCTAssertEqual(languages, languages.sorted())
        for code in ["en", "de", "es", "fr", "it", "pt", "nl", "ja", "zh", "ko", "ar", "hi", "ru", "uk", "no", "et"] {
            XCTAssertTrue(languages.contains(code), code)
        }
        // Adaptation-ready locales need fine-tuning first.
        for code in ["el", "lt", "lv", "mt", "sl", "he", "th", "nn"] {
            XCTAssertFalse(languages.contains(code), code)
        }
        XCTAssertEqual(ParakeetVersion.nemotronStreaming.languageCount, 28)
    }

    func testLanguagePromptsUseTheModelCardLocales() {
        XCTAssertNil(ParakeetPlugin.nemotronLanguagePrompt(for: nil))
        XCTAssertNil(ParakeetPlugin.nemotronLanguagePrompt(for: ""))
        XCTAssertNil(ParakeetPlugin.nemotronLanguagePrompt(for: "auto"))
        XCTAssertNil(ParakeetPlugin.nemotronLanguagePrompt(for: "el"), "Not transcription-ready, so detected")
        XCTAssertEqual(ParakeetPlugin.nemotronLanguagePrompt(for: "de"), "de-DE")
        XCTAssertEqual(ParakeetPlugin.nemotronLanguagePrompt(for: "en"), "en-US")
        XCTAssertEqual(ParakeetPlugin.nemotronLanguagePrompt(for: "en-GB"), "en-GB")
        XCTAssertEqual(ParakeetPlugin.nemotronLanguagePrompt(for: "en_gb"), "en-GB")
        XCTAssertEqual(ParakeetPlugin.nemotronLanguagePrompt(for: "de-AT"), "de-DE")
        XCTAssertEqual(ParakeetPlugin.nemotronLanguagePrompt(for: "pt"), "pt-BR")
        XCTAssertEqual(ParakeetPlugin.nemotronLanguagePrompt(for: "pt-PT"), "pt-PT")
        XCTAssertEqual(ParakeetPlugin.nemotronLanguagePrompt(for: "no"), "nb-NO")
        XCTAssertEqual(ParakeetPlugin.nemotronLanguagePrompt(for: "nb"), "nb-NO")
        XCTAssertEqual(ParakeetPlugin.nemotronLanguagePrompt(for: "zh-Hans"), "zh-CN")
        XCTAssertEqual(ParakeetPlugin.nemotronLanguagePrompt(for: " JA "), "ja-JP")

        XCTAssertEqual(ParakeetPlugin.nemotronLanguageCode(forTag: "de-DE"), "de")
        XCTAssertEqual(ParakeetPlugin.nemotronLanguageCode(forTag: "<nb-NO>"), "no")
        XCTAssertNil(ParakeetPlugin.nemotronLanguageCode(forTag: ""))
    }

    func testNemotronTakesNoDictionaryTermsAndOffersNoVocabularyBoosting() throws {
        for (modelId, support) in [(Self.modelId, DictionaryTermsSupport.unsupported), ("parakeet-ultra", .requiresPluginSetting)] {
            let host = try PluginTestHostServices(defaults: [
                "vocabularyBoostingEnabled": false,
                "selectedModel": modelId,
            ])
            let plugin = makePlugin()
            plugin.activate(host: host)
            defer { plugin.deactivate() }

            XCTAssertEqual(plugin.selectedModelId, modelId)
            XCTAssertEqual(plugin.dictionaryTermsSupport, support, modelId)
        }
    }

    // MARK: - Download

    func testInstallMovesTheVariantFolderIntoPlace() async throws {
        let directory = try makeTemporaryDirectory().appendingPathComponent("nemotron")
        let download = NemotronStreaming.download(into: directory)
        let files = Self.variantFiles

        try await download.install(
            listFiles: { files },
            downloadFile: { path, destination in try Self.writeFile(of: files, path: path, to: destination) },
            progress: { _ in }
        )

        XCTAssertTrue(NemotronStreaming.isInstalled(at: directory))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("encoder.mlmodelc/weights/weight.bin").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: download.stagingDirectory.path))
    }

    func testInstallResumesFromTheStagedRepositoryLayout() async throws {
        let directory = try makeTemporaryDirectory().appendingPathComponent("nemotron")
        let download = NemotronStreaming.download(into: directory)
        let files = Self.variantFiles
        let finished = files[0]
        let staged = download.stagingDirectory.appendingPathComponent(finished.path)
        try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.writeFile(of: files, path: finished.path, to: staged)
        let downloads = Transfers()

        try await download.install(
            listFiles: { files },
            downloadFile: { path, destination in
                await downloads.record(path)
                try Self.writeFile(of: files, path: path, to: destination)
            },
            progress: { _ in }
        )

        let downloaded = await downloads.paths
        XCTAssertFalse(downloaded.contains(finished.path))
        XCTAssertEqual(downloaded.count, files.count - 1)
        XCTAssertTrue(NemotronStreaming.isInstalled(at: directory))
    }

    func testInstallRejectsFilesOutsideTheVariantFolder() async throws {
        let directory = try makeTemporaryDirectory().appendingPathComponent("nemotron")
        let files = [PluginHuggingFaceDownloadSize.RemoteFile(path: "latin/1120ms/encoder.mlmodelc/coremldata.bin", size: 4)]

        do {
            try await NemotronStreaming.download(into: directory).install(
                listFiles: { files },
                downloadFile: { _, _ in XCTFail("A file outside the variant folder must not be downloaded") },
                progress: { _ in }
            )
            XCTFail("Expected an error")
        } catch is PinnedModelDownload.DownloadError {}
        XCTAssertFalse(NemotronStreaming.isInstalled(at: directory))
    }

    func testInstallRejectsAVariantWithoutTheTokenizer() async throws {
        let directory = try makeTemporaryDirectory().appendingPathComponent("nemotron")
        let files = Self.variantFiles.filter { !$0.path.hasSuffix("tokenizer.json") }

        do {
            try await NemotronStreaming.download(into: directory).install(
                listFiles: { files },
                downloadFile: { path, destination in try Self.writeFile(of: files, path: path, to: destination) },
                progress: { _ in }
            )
            XCTFail("Expected an error")
        } catch is PinnedModelDownload.DownloadError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testRefusedDownloadReportsReasonWithoutDownloadingNemotron() async throws {
        guard !NemotronStreaming.isInstalled(at: NemotronStreaming.directory) else {
            throw XCTSkip("Nemotron is installed on this Mac, so a refused download still loads it")
        }
        let refusal = "Your organization does not allow model downloads."
        let host = try PluginTestHostServices(
            defaults: ["vocabularyBoostingEnabled": false],
            modelDownloadRefusal: refusal
        )
        let plugin = makePlugin()
        let loads = Counter()
        plugin.asrModelLoadOverrideForTests = { _ in loads.increment() }
        plugin.activate(host: host)
        defer { plugin.deactivate() }

        await plugin.loadModel(version: .nemotronStreaming)

        XCTAssertEqual(plugin.modelState, .error(refusal))
        XCTAssertEqual(loads.value, 0)
        XCTAssertFalse(plugin.isConfigured)
        XCTAssertFalse(FileManager.default.fileExists(atPath: NemotronStreaming.download.stagingDirectory.path))
    }

    // MARK: - Live sessions

    func testLiveSessionReportsTheRunningTranscriptAndFinishesWithTheWholeOne() async throws {
        let streams = StreamRecorder(output: Self.output(text: " Hallo Welt.", tag: "de-DE"), partials: ["Hallo", "Hallo Welt"])
        let plugin = try await loadedNemotronPlugin(streams: streams)
        defer { plugin.deactivate() }
        let progress = Texts()

        let session = try await plugin.createLiveTranscriptionSession(
            language: "de",
            translate: false,
            prompt: "TypeWhisper",
            onProgress: { progress.append($0); return true }
        )
        try await session.appendAudio(samples: [0.1, 0.2])
        try await session.appendAudio(samples: [0.3])
        let collector = PluginWordTimingCollector()
        let result = try await PluginWordTimings.$collector.withValue(collector) {
            try await session.finish()
        }

        let stream = try XCTUnwrap(streams.opened.first)
        XCTAssertEqual(stream.languagePrompt, "de-DE")
        XCTAssertEqual(stream.samples, [[0.1, 0.2], [0.3]])
        XCTAssertEqual(progress.values, ["Hallo", "Hallo Welt"])
        XCTAssertEqual(result.text, "Hallo Welt.")
        XCTAssertEqual(result.detectedLanguage, "de")
        XCTAssertEqual(result.segments.map(\.text), ["Hallo Welt."])
        XCTAssertEqual(collector.words.map(\.text), ["Hallo", "Welt."])

        // Text the stream reports after the session finished never reaches the host.
        stream.emit("late")
        XCTAssertEqual(progress.values, ["Hallo", "Hallo Welt"])
        do {
            try await session.appendAudio(samples: [0.4])
            XCTFail("A finished session takes no more audio")
        } catch is CancellationError {}
    }

    func testCancelledLiveSessionStopsProgressAndHasNoResult() async throws {
        let streams = StreamRecorder(output: Self.output(text: "unused", tag: nil), partials: ["one"])
        let plugin = try await loadedNemotronPlugin(streams: streams)
        defer { plugin.deactivate() }
        let progress = Texts()

        let session = try await plugin.createLiveTranscriptionSession(
            language: nil,
            translate: false,
            prompt: nil,
            onProgress: { progress.append($0); return true }
        )
        try await session.appendAudio(samples: [0.1])
        let stream = try XCTUnwrap(streams.opened.first)
        await session.cancel()
        stream.emit("after cancel")

        XCTAssertEqual(progress.values, ["one"])
        XCTAssertNil(stream.languagePrompt, "No language means detection")
        do {
            _ = try await session.finish()
            XCTFail("A cancelled session has no result")
        } catch is CancellationError {}
        do {
            try await session.appendAudio(samples: [0.2])
            XCTFail("A cancelled session takes no more audio")
        } catch is CancellationError {}
        XCTAssertFalse(stream.didFinish)
        XCTAssertEqual(stream.samples, [[0.1]])
    }

    func testCancelledLiveSessionDoesNotKeepItsStream() async throws {
        let streams = StreamRecorder(output: Self.output(text: "unused", tag: nil), partials: [])
        let plugin = try await loadedNemotronPlugin(streams: streams)
        defer { plugin.deactivate() }

        let session = try await plugin.createLiveTranscriptionSession(language: "en", translate: false, prompt: nil, onProgress: { _ in true })
        weak var releasedStream = streams.opened.first
        streams.forgetStreams()
        XCTAssertNotNil(releasedStream, "The open session holds its stream")
        await session.cancel()
        XCTAssertNil(releasedStream, "Cancelling releases the stream and its decoder state")
    }

    func testLiveSessionStopsReportingWhenTheHostDeclinesProgress() async throws {
        let streams = StreamRecorder(output: Self.output(text: "a b", tag: nil), partials: ["a", "a b"])
        let plugin = try await loadedNemotronPlugin(streams: streams)
        defer { plugin.deactivate() }
        let progress = Texts()

        let session = try await plugin.createLiveTranscriptionSession(
            language: "en",
            translate: false,
            prompt: nil,
            onProgress: { progress.append($0); return false }
        )
        try await session.appendAudio(samples: [0.1])
        try await session.appendAudio(samples: [0.2])
        let result = try await session.finish()

        XCTAssertEqual(progress.values, ["a"])
        XCTAssertEqual(result.text, "a b")
    }

    func testLiveSessionsNeedTheLoadedNemotronModelAndNoTranslation() async throws {
        let plugin = makePlugin()
        let host = try PluginTestHostServices(defaults: ["vocabularyBoostingEnabled": false])
        plugin.asrModelLoadOverrideForTests = { _ in }
        plugin.nemotronStreamFactoryForTests = StreamRecorder(output: Self.output(text: "", tag: nil), partials: []).factory
        plugin.activate(host: host)
        defer { plugin.deactivate() }

        await plugin.loadModel(version: .ultra)
        XCTAssertTrue(plugin.isConfigured)
        await assertNoLiveSession(plugin, translate: false)

        await plugin.loadModel(version: .nemotronStreaming)
        XCTAssertTrue(plugin.isConfigured)
        XCTAssertTrue(plugin.supportsLiveTranscriptionSession(forModelId: nil))
        await assertNoLiveSession(plugin, translate: true)

        plugin.unloadModel()
        await assertNoLiveSession(plugin, translate: false)
    }

    func testUnloadingKeepsAnOpenLiveSessionUntilItFinishes() async throws {
        let streams = StreamRecorder(output: Self.output(text: "still here", tag: nil), partials: [])
        let plugin = try await loadedNemotronPlugin(streams: streams)
        defer { plugin.deactivate() }

        let session = try await plugin.createLiveTranscriptionSession(language: "en", translate: false, prompt: nil, onProgress: { _ in true })
        plugin.unloadModel()
        XCTAssertFalse(plugin.isConfigured)
        try await session.appendAudio(samples: [0.1])
        let result = try await session.finish()

        XCTAssertEqual(result.text, "still here")
    }

    // MARK: - Batch transcription

    func testBatchTranscriptionFeedsTheWholeRecordingThroughAFreshStream() async throws {
        let streams = StreamRecorder(output: Self.output(text: "Long recording.", tag: "en-US"), partials: ["Long"])
        let plugin = try await loadedNemotronPlugin(streams: streams)
        defer { plugin.deactivate() }
        let samples = [Float](repeating: 0, count: 400_000)
        let audio = AudioData(samples: samples, wavData: Data(), duration: 25)
        let progress = Texts()
        let sourceProgress = Durations()

        let result = try await plugin.transcribe(
            audio: audio,
            language: "en",
            translate: false,
            prompt: "TypeWhisper",
            dictionaryTermHints: [],
            onProgress: { progress.append($0); return true },
            onSourceProgress: { sourceProgress.append($0.processedDuration); return true }
        )

        let stream = try XCTUnwrap(streams.opened.first)
        XCTAssertEqual(stream.samples.map(\.count), [160_000, 160_000, 80_000])
        XCTAssertEqual(stream.languagePrompt, "en-US")
        XCTAssertTrue(stream.didFinish)
        XCTAssertEqual(result.text, "Long recording.")
        XCTAssertEqual(result.detectedLanguage, "en")
        XCTAssertEqual(progress.values, ["Long recording."], "Running text of a batch stays internal")
        XCTAssertEqual(sourceProgress.values, [10, 20, 25])

        _ = try await plugin.transcribe(audio: audio, language: nil, translate: false, prompt: nil)
        XCTAssertEqual(streams.opened.count, 2, "Every transcription decodes from a fresh stream")
        XCTAssertNil(streams.opened[1].languagePrompt)
    }

    func testBatchTranscriptionStopsWhenCancelled() async throws {
        let streams = StreamRecorder(output: Self.output(text: "never", tag: nil), partials: [])
        streams.processGate = BlockingGate()
        let plugin = try await loadedNemotronPlugin(streams: streams)
        defer { plugin.deactivate() }
        let audio = AudioData(samples: [Float](repeating: 0, count: 480_000), wavData: Data(), duration: 30)

        let task = Task {
            try await plugin.transcribe(audio: audio, language: "en", translate: false, prompt: nil)
        }
        await streams.processGate?.waitUntilEntered()
        task.cancel()
        streams.processGate?.open()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        let stream = try XCTUnwrap(streams.opened.first)
        XCTAssertEqual(stream.samples.count, 1, "No audio after cancellation")
        XCTAssertFalse(stream.didFinish)
    }

    func testNemotronLoadsWithoutTheVocabularyBoostingModel() async throws {
        let host = try PluginTestHostServices(defaults: ["vocabularyBoostingEnabled": true])
        let plugin = makePlugin()
        let ctcDownloads = Counter()
        plugin.asrModelLoadOverrideForTests = { _ in }
        plugin.nemotronStreamFactoryForTests = StreamRecorder(output: Self.output(text: "", tag: nil), partials: []).factory
        plugin.ctcModelDownloadOverrideForTests = { _ in ctcDownloads.increment() }
        plugin.activate(host: host)
        defer { plugin.deactivate() }

        await plugin.loadModel(version: .nemotronStreaming)

        XCTAssertTrue(plugin.isConfigured)
        XCTAssertEqual(ctcDownloads.value, 0)
        XCTAssertEqual(plugin.ctcModelState, .notDownloaded)
        XCTAssertEqual(host.userDefault(forKey: "loadedModel") as? String, Self.modelId)
    }

    // MARK: - Installed model

    /// Opt-in: a 16 kHz mono WAV in `TYPEWHISPER_NEMOTRON_WAV`, its language in
    /// `TYPEWHISPER_NEMOTRON_LANGUAGE` (optional), and Nemotron installed or downloadable.
    func testInstalledNemotronStreamsTheSameTranscriptAsABatchTranscription() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["TYPEWHISPER_NEMOTRON_WAV"] else {
            throw XCTSkip("Set TYPEWHISPER_NEMOTRON_WAV to run Nemotron Core ML inference (downloads about 665 MB if missing)")
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        let audio = AudioData(samples: samples, wavData: Data(), duration: Double(samples.count) / 16_000)
        let language = environment["TYPEWHISPER_NEMOTRON_LANGUAGE"]

        let host = try PluginTestHostServices(defaults: ["vocabularyBoostingEnabled": false])
        let plugin = makePlugin()
        plugin.activate(host: host)
        defer { plugin.deactivate() }
        await plugin.loadModel(version: .nemotronStreaming)
        guard plugin.isConfigured else {
            XCTFail("Nemotron failed to load: \(plugin.modelState)")
            return
        }

        let batch = try await plugin.transcribe(audio: audio, language: language, translate: false, prompt: nil)
        let progress = Texts()
        let session = try await plugin.createLiveTranscriptionSession(
            language: language,
            translate: false,
            prompt: nil,
            onProgress: { progress.append($0); return true }
        )
        // 100 ms of audio per call, as the host appends while recording.
        var offset = 0
        while offset < samples.count {
            let end = min(offset + 1_600, samples.count)
            try await session.appendAudio(samples: Array(samples[offset..<end]))
            offset = end
        }
        let live = try await session.finish()

        print("Nemotron batch: \(batch.text)")
        print("Nemotron live (\(progress.values.count) updates): \(live.text)")
        XCTAssertFalse(batch.text.isEmpty)
        XCTAssertEqual(live.text, batch.text)
        XCTAssertFalse(progress.values.isEmpty, "The live session reports text before it finishes")
        XCTAssertFalse(live.segments.isEmpty)
    }

    // MARK: - Helpers

    private func assertNoLiveSession(_ plugin: ParakeetPlugin, translate: Bool, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await plugin.createLiveTranscriptionSession(language: "en", translate: translate, prompt: nil, onProgress: { _ in true })
            XCTFail("Expected no live session", file: file, line: line)
        } catch {}
    }

    private func loadedNemotronPlugin(streams: StreamRecorder) async throws -> ParakeetPlugin {
        let host = try PluginTestHostServices(defaults: ["vocabularyBoostingEnabled": false])
        let plugin = makePlugin()
        plugin.asrModelLoadOverrideForTests = { _ in }
        plugin.nemotronStreamFactoryForTests = streams.factory
        plugin.activate(host: host)
        await plugin.loadModel(version: .nemotronStreaming)
        XCTAssertTrue(plugin.isConfigured, "\(plugin.modelState)")
        return plugin
    }

    private func makePlugin() -> ParakeetPlugin {
        let plugin = ParakeetPlugin()
        plugin.restoresModelOnActivate = false
        return plugin
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ParakeetNemotronStreamingTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private static func output(text: String, tag: String?) -> ParakeetNemotronStreamOutput {
        let words = text.split(separator: " ").map(String.init)
        let timings = words.enumerated().map { index, word in
            TokenTiming(
                token: "\u{2581}\(word)",
                tokenId: index,
                startTime: Double(index) * 0.5,
                endTime: Double(index) * 0.5 + 0.4,
                confidence: 1
            )
        }
        return ParakeetNemotronStreamOutput(text: text, tokenTimings: timings, detectedLanguage: tag)
    }

    private static let variantFiles: [PluginHuggingFaceDownloadSize.RemoteFile] =
        NemotronStreaming.modelFolders.sorted().flatMap { folder in
            [
                PluginHuggingFaceDownloadSize.RemoteFile(path: "multilingual/1120ms/\(folder)/coremldata.bin", size: 8),
                PluginHuggingFaceDownloadSize.RemoteFile(path: "multilingual/1120ms/\(folder)/weights/weight.bin", size: 16),
            ]
        } + NemotronStreaming.configurationFiles.map {
            PluginHuggingFaceDownloadSize.RemoteFile(path: "multilingual/1120ms/\($0)", size: 12)
        }

    private static func writeFile(
        of files: [PluginHuggingFaceDownloadSize.RemoteFile],
        path: String,
        to destination: URL
    ) throws {
        let size = try XCTUnwrap(files.first { $0.path == path }?.size)
        try Data(repeating: 7, count: Int(size)).write(to: destination)
    }
}

// MARK: - Test doubles

/// Records the streams a plugin opens and hands each the same scripted output.
private final class StreamRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var streams: [FakeNemotronStream] = []
    private let output: ParakeetNemotronStreamOutput
    private let partials: [String]
    var processGate: BlockingGate?

    init(output: ParakeetNemotronStreamOutput, partials: [String]) {
        self.output = output
        self.partials = partials
    }

    var opened: [FakeNemotronStream] { lock.withLock { streams } }

    func forgetStreams() {
        lock.withLock { streams.removeAll() }
    }

    var factory: ParakeetNemotronStreamFactory {
        ParakeetNemotronStreamFactory { [self] languagePrompt, onPartial in
            let stream = FakeNemotronStream(
                languagePrompt: languagePrompt,
                output: output,
                partials: partials,
                processGate: processGate,
                onPartial: onPartial
            )
            lock.withLock { streams.append(stream) }
            return stream
        }
    }
}

private final class FakeNemotronStream: ParakeetNemotronStream, @unchecked Sendable {
    let languagePrompt: String?
    private let output: ParakeetNemotronStreamOutput
    private let processGate: BlockingGate?
    private let onPartial: @Sendable (String) -> Void
    private let lock = NSLock()
    private var pendingPartials: [String]
    private var receivedSamples: [[Float]] = []
    private var finished = false

    init(
        languagePrompt: String?,
        output: ParakeetNemotronStreamOutput,
        partials: [String],
        processGate: BlockingGate?,
        onPartial: @escaping @Sendable (String) -> Void
    ) {
        self.languagePrompt = languagePrompt
        self.output = output
        self.processGate = processGate
        self.onPartial = onPartial
        self.pendingPartials = partials
    }

    var samples: [[Float]] { lock.withLock { receivedSamples } }
    var didFinish: Bool { lock.withLock { finished } }

    func emit(_ text: String) {
        onPartial(text)
    }

    func process(_ samples: [Float]) async throws {
        let partial = lock.withLock {
            receivedSamples.append(samples)
            return pendingPartials.isEmpty ? nil : pendingPartials.removeFirst()
        }
        await processGate?.enterAndWait()
        if let partial {
            onPartial(partial)
        }
    }

    func finish() async throws -> ParakeetNemotronStreamOutput {
        lock.withLock { finished = true }
        return output
    }
}

/// Holds the first caller until the test opens it.
private actor BlockingGate {
    private var entered = false
    private var isOpen = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        guard !isOpen else { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    nonisolated func open() {
        Task { await self.openNow() }
    }

    private func openNow() {
        isOpen = true
        openWaiters.forEach { $0.resume() }
        openWaiters.removeAll()
    }
}

private final class Texts: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var values: [String] { lock.withLock { stored } }
    func append(_ value: String) { lock.withLock { stored.append(value) } }
}

private final class Durations: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [TimeInterval] = []
    var values: [TimeInterval] { lock.withLock { stored } }
    func append(_ value: TimeInterval) { lock.withLock { stored.append(value) } }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private actor Transfers {
    private(set) var paths: [String] = []
    func record(_ path: String) { paths.append(path) }
}
