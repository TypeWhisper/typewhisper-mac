import XCTest
@preconcurrency import AVFoundation
import CryptoKit
import FluidAudio
@_spi(FirstPartyPlugins) import TypeWhisperPluginSDK
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import ParakeetPlugin

final class ParakeetPluginTests: XCTestCase {
    private actor RequestRecorder {
        private var request: URLRequest?

        func set(_ request: URLRequest) {
            self.request = request
        }

        func get() -> URLRequest? {
            request
        }
    }

    /// Records CTC download hook calls; the first call can be held until released.
    private actor CtcDownloadRecorder {
        private(set) var events: [String] = []
        private var holdsFirstDownload: Bool
        private var firstDownloadRelease: CheckedContinuation<Void, Never>?
        private var startWaiter: CheckedContinuation<Void, Never>?

        init(holdsFirstDownload: Bool = false) {
            self.holdsFirstDownload = holdsFirstDownload
        }

        func download(loadIntoMemory: Bool) async {
            let kind = loadIntoMemory ? "load" : "files"
            events.append("start \(kind)")
            startWaiter?.resume()
            startWaiter = nil
            if holdsFirstDownload {
                holdsFirstDownload = false
                await withCheckedContinuation { firstDownloadRelease = $0 }
            }
            events.append("end \(kind)")
        }

        func waitForFirstStart() async {
            guard events.isEmpty else { return }
            await withCheckedContinuation { startWaiter = $0 }
        }

        func releaseFirstDownload() {
            firstDownloadRelease?.resume()
            firstDownloadRelease = nil
        }
    }

    private actor VocabularyFetchRecorder {
        private var requests: [(url: URL, description: String)] = []
        private let data: Data?
        private let error: Error?

        init(data: Data) {
            self.data = data
            self.error = nil
        }

        init(error: Error) {
            self.data = nil
            self.error = error
        }

        func fetch(url: URL, description: String) async throws -> Data {
            requests.append((url: url, description: description))
            if let data {
                return data
            }
            throw error ?? URLError(.unknown)
        }

        func requestCount() -> Int {
            requests.count
        }

        func firstRequest() -> (url: URL, description: String)? {
            requests.first
        }
    }

    private func makePlugin(restoresModelOnActivate: Bool = false) -> ParakeetPlugin {
        let plugin = ParakeetPlugin()
        plugin.restoresModelOnActivate = restoresModelOnActivate
        return plugin
    }

    private func makeTemporaryDirectory(prefix: String = "ParakeetPluginTests") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(prefix)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    /// Models the important Core ML state: the manager stays loaded while the
    /// device-specific cache disappears. Both real and warmup inference use it.
    private actor PurgeableInference {
        private var cachePresent = true
        private var release: CheckedContinuation<Void, Never>?
        private(set) var events: [String] = []
        let warmupStarted: XCTestExpectation?
        private(set) var sampleCounts: [Int] = []
        var failsWarmup = false

        init(warmupStarted: XCTestExpectation? = nil) { self.warmupStarted = warmupStarted }

        func purge(failWarmup: Bool = false) {
            cachePresent = false
            failsWarmup = failWarmup
        }

        func infer(_ samples: [Float]) async throws -> ASRResult {
            sampleCounts.append(samples.count)
            let warmup = samples.allSatisfy { $0 == 0 }
            let kind = warmup ? "warmup" : "speech"
            events.append(kind)
            if !cachePresent {
                events.append("compile-\(kind)")
                if warmup {
                    warmupStarted?.fulfill()
                    await withCheckedContinuation { release = $0 }
                    if failsWarmup { throw URLError(.cannotLoadFromNetwork) }
                }
                cachePresent = true
            }
            return ASRResult(text: warmup ? "must not escape" : "actual transcript", confidence: 1,
                             duration: Double(samples.count) / 16_000, processingTime: 0)
        }

        func finishWarmup() { release?.resume(); release = nil }
    }

    private func loadedPluginWithFakeInference(_ inference: PurgeableInference) async throws -> ParakeetPlugin {
        let host = try PluginTestHostServices(defaults: ["loadedModel": "parakeet-tdt-0.6b-v2"])
        let plugin = makePlugin()
        plugin.asrModelLoadOverrideForTests = { _ in }
        plugin.asrTranscriptionOverrideForTests = { try await inference.infer($0) }
        plugin.activate(host: host)
        await plugin.restoreLoadedModel()
        XCTAssertTrue(plugin.isConfigured)
        addTeardownBlock { plugin.deactivate() }
        return plugin
    }

    private var fakeSpeech: AudioData {
        AudioData(samples: [Float](repeating: 0.1, count: 16_000), wavData: Data(), duration: 1)
    }

    func testPrewarmExercisesParallelLongFormInference() async throws {
        let inference = PurgeableInference()
        let plugin = try await loadedPluginWithFakeInference(inference)
        plugin.triggerPrewarmModel()
        await plugin.waitForModelPrewarm()
        let counts = await inference.sampleCounts
        XCTAssertEqual(counts.count, 1)
        let sampleCount = try XCTUnwrap(counts.first)
        XCTAssertGreaterThan(sampleCount, ASRConstants.maxModelSamples, "must enter ChunkProcessor")
        XCTAssertGreaterThanOrEqual(sampleCount, ASRConstants.maxModelSamples * ASRConfig().parallelChunkConcurrency,
                                    "must supply enough chunks for the whole worker pool")
    }

    func testCtcPreparationFinishesBeforeSpeechWithoutChangingVocabulary() async throws {
        let inference = PurgeableInference()
        let plugin = try await loadedPluginWithFakeInference(inference)
        let ctcStarted = expectation(description: "CTC preparation")
        let ctc = CtcDownloadRecorder(holdsFirstDownload: true)
        plugin.ctcPrewarmInference = { samples in
            XCTAssertEqual(samples.count, 16_000)
            XCTAssertTrue(samples.allSatisfy { $0 == 0 })
            ctcStarted.fulfill()
            await ctc.download(loadIntoMemory: true)
        }
        plugin.setBoostingEnabled(true)
        plugin.lastConfiguredPrompt = "existing dictionary"
        plugin.lastBoostingTermCount = 5
        plugin.triggerPrewarmModel()
        await fulfillment(of: [ctcStarted], timeout: 3)
        XCTAssertNotNil(plugin.currentSettingsActivity)
        XCTAssertEqual(plugin.lastConfiguredPrompt, "existing dictionary")
        XCTAssertEqual(plugin.lastBoostingTermCount, 5)

        let speechStarted = expectation(description: "speech requested while CTC is held")
        let audio = fakeSpeech
        let speech = Task {
            speechStarted.fulfill()
            return try await plugin.transcribe(audio: audio, language: nil, translate: false, prompt: nil)
        }
        await fulfillment(of: [speechStarted], timeout: 3)
        let beforeRelease = await inference.events
        XCTAssertEqual(beforeRelease, ["warmup"])
        await ctc.releaseFirstDownload()
        let result = try await speech.value
        XCTAssertEqual(result.text, "actual transcript")
        XCTAssertNil(plugin.currentSettingsActivity)
    }

    func testPrewarmSkipsDisabledOrUnloadedCtcWithoutDownloading() async throws {
        let inference = PurgeableInference()
        let plugin = try await loadedPluginWithFakeInference(inference)
        plugin.ctcModelDownloadOverrideForTests = { _ in XCTFail("prewarm must not download CTC") }
        plugin.ctcPrewarmInference = { _ in XCTFail("disabled CTC must not run") }
        plugin.triggerPrewarmModel()
        await plugin.waitForModelPrewarm()

        plugin.ctcPrewarmInference = nil
        plugin.setBoostingEnabled(true)
        plugin.triggerPrewarmModel()
        await plugin.waitForModelPrewarm()
        XCTAssertEqual(plugin.ctcModelState, .notDownloaded)
    }

    func testFailedCtcPreparationDoesNotBlockRealSpeech() async throws {
        let inference = PurgeableInference()
        let plugin = try await loadedPluginWithFakeInference(inference)
        let ctcStarted = expectation(description: "failing CTC preparation")
        plugin.setBoostingEnabled(true)
        plugin.ctcPrewarmInference = { _ in
            ctcStarted.fulfill()
            throw URLError(.cannotDecodeContentData)
        }
        plugin.triggerPrewarmModel()
        await plugin.waitForModelPrewarm()
        await fulfillment(of: [ctcStarted], timeout: 3)
        let result = try await plugin.transcribe(audio: fakeSpeech, language: nil, translate: false, prompt: nil)
        XCTAssertEqual(result.text, "actual transcript")
        XCTAssertNil(plugin.currentSettingsActivity)
    }

    func testLoadedModelCachePurgeIsRepairedBeforeSpeechAndWarmupIsCoalesced() async throws {
        let started = expectation(description: "cache recompilation during preparation")
        let inference = PurgeableInference(warmupStarted: started)
        let plugin = try await loadedPluginWithFakeInference(inference)
        _ = try await plugin.transcribe(audio: fakeSpeech, language: nil, translate: false, prompt: nil)
        await inference.purge()

        let collector = PluginWordTimingCollector()
        PluginWordTimings.$collector.withValue(collector) {
            plugin.triggerPrewarmModel()
        }
        XCTAssertNotNil(plugin.currentSettingsActivity, "publish before scheduling the warmup task")
        plugin.triggerPrewarmModel()
        let audio = fakeSpeech
        let speech = Task { try await plugin.transcribe(audio: audio, language: nil, translate: false, prompt: nil) }
        await fulfillment(of: [started], timeout: 3)
        let duringPreparation = await inference.events
        XCTAssertEqual(duringPreparation, ["speech", "warmup", "compile-warmup"])
        XCTAssertTrue(plugin.isConfigured)

        await inference.finishWarmup()
        let result = try await speech.value
        XCTAssertEqual(result.text, "actual transcript")
        XCTAssertTrue(collector.words.isEmpty)
        XCTAssertNil(plugin.currentSettingsActivity)
        let events = await inference.events
        XCTAssertEqual(events, ["speech", "warmup", "compile-warmup", "speech"])
    }

    func testFailedCachePreparationAllowsRealTranscriptionToRetry() async throws {
        let started = expectation(description: "failing preparation")
        let inference = PurgeableInference(warmupStarted: started)
        let plugin = try await loadedPluginWithFakeInference(inference)
        await inference.purge(failWarmup: true)
        plugin.triggerPrewarmModel()
        await fulfillment(of: [started], timeout: 3)
        await inference.finishWarmup()
        await plugin.waitForModelPrewarm()

        XCTAssertNil(plugin.currentSettingsActivity)
        XCTAssertTrue(plugin.isConfigured)
        let result = try await plugin.transcribe(audio: fakeSpeech, language: nil, translate: false, prompt: nil)
        XCTAssertEqual(result.text, "actual transcript")
        let events = await inference.events
        XCTAssertEqual(events, ["warmup", "compile-warmup", "speech", "compile-speech"])
    }

    func testUnloadDuringCachePreparationDoesNotRestoreTheModel() async throws {
        let started = expectation(description: "preparation")
        let inference = PurgeableInference(warmupStarted: started)
        let plugin = try await loadedPluginWithFakeInference(inference)
        plugin.setBoostingEnabled(true)
        plugin.ctcPrewarmInference = { _ in XCTFail("unload must cancel the remaining CTC preparation") }
        await inference.purge()
        plugin.triggerPrewarmModel()
        await fulfillment(of: [started], timeout: 3)

        plugin.unloadModel()
        XCTAssertNil(plugin.currentSettingsActivity)
        await inference.finishWarmup()
        do {
            _ = try await plugin.transcribe(audio: fakeSpeech, language: nil, translate: false, prompt: nil)
            XCTFail("an unloaded model must not transcribe")
        } catch PluginTranscriptionError.notConfigured {
            // Acquiring the transcription gate also drains the old inference.
        }
        XCTAssertFalse(plugin.isConfigured)
        XCTAssertEqual(plugin.modelState, .notLoaded)
    }

    func testPrewarmDoesNotLoadAnUnloadedModel() {
        let plugin = makePlugin()
        plugin.triggerPrewarmModel()
        XCTAssertFalse(plugin.isConfigured)
        XCTAssertNil(plugin.currentSettingsActivity)
    }

    func testCancelledQueuedPreparationNeverRunsInference() async throws {
        let gate = AsyncTranscriptionGate()
        let active = CtcDownloadRecorder(holdsFirstDownload: true)
        let queued = CtcDownloadRecorder()
        let transcription = Task { try await gate.withLock { await active.download(loadIntoMemory: true) } }
        await active.waitForFirstStart()

        let controller = ParakeetModelPrewarm()
        controller.start {
            try await gate.withLock { await queued.download(loadIntoMemory: true) }
        }
        let preparation = controller.task
        let deadline = ContinuousClock.now + .seconds(3)
        while await gate.waitingCount == 0, ContinuousClock.now < deadline { await Task.yield() }
        let waiting = await gate.waitingCount
        XCTAssertEqual(waiting, 1)
        controller.cancel()
        await active.releaseFirstDownload()
        try await transcription.value
        await preparation?.value

        let events = await queued.events
        XCTAssertTrue(events.isEmpty, "unload must invalidate warmup queued behind real transcription")
        XCTAssertFalse(controller.isRunning)
    }

    func testOldPreparationCompletionCannotClearNewPreparation() async {
        let controller = ParakeetModelPrewarm()
        let first = CtcDownloadRecorder(holdsFirstDownload: true)
        let second = CtcDownloadRecorder(holdsFirstDownload: true)
        controller.start { await first.download(loadIntoMemory: true) }
        await first.waitForFirstStart()
        let oldTask = controller.task
        controller.cancel()
        controller.start { await second.download(loadIntoMemory: true) }
        await second.waitForFirstStart()
        await first.releaseFirstDownload()
        await oldTask?.value
        // The second preparation remains active regardless of the first completion.
        XCTAssertTrue(controller.isRunning)
        await second.releaseFirstDownload()
        await controller.wait()
        XCTAssertFalse(controller.isRunning)
    }

    /// Opt-in hardware smoke test. CFFIXED_USER_HOME must point to a disposable
    /// test home with installed models linked into Library/Application Support.
    /// Only that home's Core ML cache can be purged, never the user's app cache.
    /// Core ML may retain live execution resources after unlinking the files, so
    /// disk deletion does not guarantee the slow recompilation from #1605. The
    /// deterministic purge fixture above covers that blocking interleaving.
    func testInstalledModelsPreserveTranscriptAfterCoreMLCachePurge() async throws {
        guard ProcessInfo.processInfo.environment["TYPEWHISPER_PARAKEET_CACHE_PURGE"] == "1",
              let homePath = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] else {
            throw XCTSkip("Requires TYPEWHISPER_PARAKEET_CACHE_PURGE=1 and an isolated CFFIXED_USER_HOME")
        }
        let home = URL(fileURLWithPath: homePath).resolvingSymlinksInPath()
        guard home.lastPathComponent.hasPrefix("typewhisper-coreml-1605-"),
              URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath() == home else {
            XCTFail("Refusing to purge outside the dedicated regression home")
            return
        }
        let caches = try XCTUnwrap(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
        guard caches.resolvingSymlinksInPath().path.hasPrefix(home.path + "/") else {
            XCTFail("Core ML caches are not isolated")
            return
        }
        func cacheBundles() throws -> [URL] {
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: caches, includingPropertiesForKeys: nil))
            var paths: [URL] = []
            for case let url as URL in enumerator where url.lastPathComponent == "com.apple.e5rt.e5bundlecache" {
                guard url.resolvingSymlinksInPath().path.hasPrefix(home.path + "/") else {
                    throw NSError(domain: "UnsafeCachePath", code: 1)
                }
                paths.append(url)
                enumerator.skipDescendants()
            }
            return paths
        }
        func purge() throws {
            let paths = try cacheBundles()
            XCTAssertFalse(paths.isEmpty, "No isolated E5 cache was created; no purge was performed")
            for path in paths { try FileManager.default.removeItem(at: path) }
        }

        let fixture = try regressionAudio()
        // Match the issue's ~59-second recording and exercise the full pool.
        let audio = AudioData(samples: Array(repeating: fixture.samples, count: 3).flatMap { $0 },
                              wavData: Data(), duration: fixture.duration * 3)
        let ctcDirectory = CtcModels.defaultCacheDirectory(for: .ctc110m)
        // Direct loading never repairs/downloads files in the linked model root.
        let ctcModels = try await CtcModels.loadDirect(from: ctcDirectory)
        let ctcTokenizer = try await CtcTokenizer.load(from: ctcDirectory)
        for version in ["parakeet-tdt-0.6b-v2", "parakeet-tdt-0.6b-v3"] {
            let host = try PluginTestHostServices(defaults: ["loadedModel": version, "vocabularyBoostingEnabled": true])
            let plugin = makePlugin()
            plugin.activate(host: host)
            defer { plugin.deactivate() }
            func installCtc() {
                plugin.ctcModels = ctcModels
                plugin.ctcTokenizer = ctcTokenizer
                plugin.ctcModelState = .ready
            }
            await plugin.restoreLoadedModel(allowDownloads: false, passively: true)
            guard plugin.isConfigured else { XCTFail("Installed \(version) failed to load"); return }
            installCtc()
            let baseline = try await plugin.transcribe(audio: audio, language: nil, translate: false, prompt: "TypeWhisper")
            XCTAssertFalse(baseline.text.isEmpty)
            XCTAssertEqual(plugin.lastBoostingTermCount, 1, "CTC rescoring must be configured")

            // Core ML may keep an already-created execution stream alive even
            // after unlinking its cache. Also exercise a fresh model instance
            // whose first prediction occurs after the purge.
            plugin.unloadModel(clearPersistence: false)
            await plugin.restoreLoadedModel(allowDownloads: false, passively: true)
            XCTAssertTrue(plugin.isConfigured)
            installCtc()
            try purge()
            let coldStart = ContinuousClock.now
            let cold = try await plugin.transcribe(audio: audio, language: nil, translate: false, prompt: "TypeWhisper")
            let coldDuration = ContinuousClock.now - coldStart
            XCTAssertEqual(cold.text, baseline.text)

            plugin.unloadModel(clearPersistence: false)
            await plugin.restoreLoadedModel(allowDownloads: false, passively: true)
            XCTAssertTrue(plugin.isConfigured)
            installCtc()
            let prepareCtc = try XCTUnwrap(plugin.ctcPrewarmInference)
            let ctcPrepared = expectation(description: "real CTC preparation for \(version)")
            ctcPrepared.expectedFulfillmentCount = 3
            plugin.ctcPrewarmInference = { samples in
                let start = ContinuousClock.now
                do { try await prepareCtc(samples) }
                catch { XCTFail("Real CTC preparation failed: \(error)"); throw error }
                print("Core ML CTC preparation \(version): \(ContinuousClock.now - start)")
                ctcPrepared.fulfill()
            }
            try purge()
            let warmupStart = ContinuousClock.now
            plugin.triggerPrewarmModel()
            await plugin.waitForModelPrewarm()
            let warmupDuration = ContinuousClock.now - warmupStart
            let cacheDirectoryRecreated = !(try cacheBundles()).isEmpty
            XCTAssertNil(plugin.currentSettingsActivity)
            let speechStart = ContinuousClock.now
            let recovered = try await plugin.transcribe(audio: audio, language: nil, translate: false, prompt: "TypeWhisper")
            let speechDuration = ContinuousClock.now - speechStart
            XCTAssertEqual(recovered.text, baseline.text)
            XCTAssertEqual(plugin.lastBoostingTermCount, 1)
            print("Core ML purge smoke \(version): unprepared speech=\(coldDuration), preparation=\(warmupDuration), prepared speech=\(speechDuration), cache directory recreated=\(cacheDirectoryRecreated)")
            // Measure the ordinary per-recording cost with caches already warm.
            for _ in 0..<2 {
                let start = ContinuousClock.now
                let signature = plugin.lastConfiguredPrompt
                plugin.triggerPrewarmModel()
                await plugin.waitForModelPrewarm()
                XCTAssertEqual(plugin.lastConfiguredPrompt, signature)
                XCTAssertEqual(plugin.lastBoostingTermCount, 1)
                print("Core ML repeated preparation \(version): \(ContinuousClock.now - start)")
            }
            await fulfillment(of: [ctcPrepared], timeout: 3)
        }
    }

    /// Opt-in Core ML regression using FluidAudio 0.15.7's published fixture:
    /// Tests/FluidAudioTests/ASR/Parakeet/SlidingWindow/Fixtures/02-release-readiness-19.8s.wav.
    /// Requires an installed Parakeet v3 model; passive restore never downloads it.
    func testInstalledV3ModelPreservesLongFormQuestionPunctuation() async throws {
        let audio = try regressionAudio()

        let host = try PluginTestHostServices(defaults: [
            "loadedModel": "parakeet-tdt-0.6b-v3",
            "vocabularyBoostingEnabled": false,
        ])
        let plugin = makePlugin()
        plugin.activate(host: host)
        defer { plugin.deactivate() }
        // Await the production restore/load path directly to avoid an activation-task race.
        await plugin.restoreLoadedModel(allowDownloads: false, passively: true)
        guard plugin.isConfigured else {
            XCTFail("Installed Parakeet v3 failed to load: \(plugin.modelState)")
            return
        }
        let result = try await plugin.transcribe(audio: audio, language: nil, translate: false, prompt: nil)
        XCTAssertTrue(result.text.contains("work we've done?"), result.text)
        XCTAssertTrue(result.text.hasSuffix("cutting a release?"), result.text)
    }

    /// Opt-in: any 16 kHz mono WAV in `TYPEWHISPER_PARAKEET_WORD_TIMING_WAV`
    /// and an installed Parakeet v3 model.
    func testInstalledV3ModelReportsWordTimingsToTheHostCollector() async throws {
        guard let path = ProcessInfo.processInfo.environment["TYPEWHISPER_PARAKEET_WORD_TIMING_WAV"] else {
            throw XCTSkip("Set TYPEWHISPER_PARAKEET_WORD_TIMING_WAV and install Parakeet v3 to run Core ML inference")
        }
        let url = URL(fileURLWithPath: path)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ))
        try file.read(into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        let audio = AudioData(samples: samples, wavData: try Data(contentsOf: url), duration: Double(samples.count) / 16_000)

        let host = try PluginTestHostServices(defaults: [
            "loadedModel": "parakeet-tdt-0.6b-v3",
            "vocabularyBoostingEnabled": false,
        ])
        let plugin = makePlugin()
        plugin.activate(host: host)
        defer { plugin.deactivate() }
        await plugin.restoreLoadedModel(allowDownloads: false, passively: true)
        guard plugin.isConfigured else {
            XCTFail("Installed Parakeet v3 failed to load: \(plugin.modelState)")
            return
        }

        let collector = PluginWordTimingCollector()
        let result = try await PluginWordTimings.$collector.withValue(collector) {
            try await plugin.transcribe(audio: audio, language: nil, translate: false, prompt: nil)
        }
        let words = collector.words

        XCTAssertFalse(words.isEmpty)
        XCTAssertEqual(words.map(\.text).joined(separator: " "), result.segments.map(\.text).joined(separator: " "))
        XCTAssertTrue(zip(words, words.dropFirst()).allSatisfy { $0.start <= $1.start })
        XCTAssertTrue(words.allSatisfy { $0.end >= $0.start && $0.end <= audio.duration + 0.5 })
        print("Parakeet reported \(words.count) words in \(result.segments.count) segments")
        if let dump = ProcessInfo.processInfo.environment["TYPEWHISPER_PARAKEET_WORD_TIMING_DUMP"] {
            let lines = result.segments.map { "S\t\($0.start)\t\($0.end)\t\($0.text)" }
                + words.map { "W\t\($0.start)\t\($0.end)\t\($0.text)" }
            try lines.joined(separator: "\n").write(toFile: dump, atomically: true, encoding: .utf8)
        }
    }

    func testInstalledV3ModelPreservesTextWithUnrelatedDictionaryTerms() async throws {
        let audio = try regressionAudio()
        let host = try PluginTestHostServices(defaults: [
            "loadedModel": "parakeet-tdt-0.6b-v3",
            "vocabularyBoostingEnabled": true,
        ])
        let plugin = makePlugin()
        plugin.activate(host: host)
        defer { plugin.deactivate() }
        await plugin.restoreLoadedModel(allowDownloads: false, passively: true)
        guard plugin.isConfigured else {
            XCTFail("Installed Parakeet v3 failed to load: \(plugin.modelState)")
            return
        }
        let plain = try await plugin.transcribe(audio: audio, language: nil, translate: false, prompt: nil)
        let boosted = try await plugin.transcribe(
            audio: audio,
            language: nil,
            translate: false,
            prompt: nil,
            dictionaryTermHints: ["Docker", "Postgres", "Redis", "TypeWhisper", "Kubernetes"].map {
                PluginDictionaryTermHint(text: $0, ctcMinSimilarity: nil)
            },
            onProgress: { _ in true },
            onSourceProgress: { _ in true }
        )
        // A failed CTC load must not turn this into a vacuous no-op success.
        XCTAssertEqual(plugin.lastBoostingTermCount, 5)
        XCTAssertEqual(boosted.text, plain.text)
        XCTAssertTrue(boosted.text.hasSuffix("cutting a release?"), boosted.text)
    }

    /// Opt-in paired inference over six pinned German/English technical recordings.
    func testInstalledV3DictionaryCorrectsMisspellingAndPreservesSurroundingWords() async throws {
        guard let directory = ProcessInfo.processInfo.environment["TYPEWHISPER_PARAKEET_DICTIONARY_FIXTURES"] else {
            throw XCTSkip("Set TYPEWHISPER_PARAKEET_DICTIONARY_FIXTURES to the pinned technical recordings")
        }
        let fixtures = [
            ("de-hard-tech-02", "78167b2f5e72c723a3dc66965647dce071ec2600e6d724419a05454ca10d1c69"),
            ("de-hard-tech-03", "e1032e7861218fc545be20b540428dbbf77445112a4871ece8cd86d7b5c6ea17"),
            ("de-tech-01", "1dc0901dceb470b1abb721f7b0a3647da35019caf5caff849c23bccd1ec18718"),
            ("en-hard-tech-02", "627581e9af1c1f3021c4c7a33e79edc6627fa6d8a983d96ec0539bf0fdbee677"),
            ("en-hard-tech-03", "cefc041dd906c0f39506f744d889f642795e78d0a93a84a5d927d4ad57b4b97e"),
            ("en-tech-01", "37c94932e545f87eca27988f89af1dc491e0464f5d00393c7d2439e89b04a077"),
        ]
        let host = try PluginTestHostServices(defaults: [
            "loadedModel": "parakeet-tdt-0.6b-v3",
            "vocabularyBoostingEnabled": true,
        ])
        let plugin = makePlugin()
        plugin.activate(host: host)
        defer { plugin.deactivate() }
        await plugin.restoreLoadedModel(allowDownloads: false, passively: true)
        guard plugin.isConfigured else {
            XCTFail("Installed Parakeet v3 failed to load: \(plugin.modelState)")
            return
        }
        let hints = ["Kubernetes", "nginx", "gRPC", "PostgreSQL", "GitHub Actions", "Docker Compose"].map {
            PluginDictionaryTermHint(text: $0, ctcMinSimilarity: nil)
        }
        for (name, checksum) in fixtures {
            let audio = try regressionAudio(
                at: URL(fileURLWithPath: directory).appendingPathComponent(name + ".wav"),
                sha256: checksum
            )
            let plain = try await plugin.transcribe(audio: audio, language: nil, translate: false, prompt: nil)
            let boosted = try await plugin.transcribe(
                audio: audio, language: nil, translate: false, prompt: nil,
                dictionaryTermHints: hints,
                onProgress: { _ in true }, onSourceProgress: { _ in true }
            )
            XCTAssertEqual(plugin.lastBoostingTermCount, hints.count)
            if name == "en-hard-tech-02" {
                XCTAssertTrue(plain.text.contains("PostGur SQL"), plain.text)
                XCTAssertEqual(boosted.text, plain.text.replacingOccurrences(of: "PostGur SQL", with: "PostgreSQL"))
                XCTAssertNotEqual(boosted.text, plain.text, "The dictionary must still correct the misspelling")
            } else {
                XCTAssertEqual(boosted.text, plain.text, name)
            }
        }
    }

    func testDictionaryCorrectionsDoNotConsumeTextAroundExistingTerms() {
        for (original, replacement) in [
            ("uses GitHub actions", "GitHub Actions"),
            ("Docker Compose for", "Docker Compose"),
            ("Kubernetes-Cluster", "Kubernetes"),
            ("Redisdiensten.", "Redis"),
            ("Café-Straße", "Café"),
            ("Cafe services", "Café"),
            ("CAFÉ services", "cafe"),
        ] {
            XCTAssertTrue(ParakeetPlugin.removesTextAroundExistingTerm(
                original: original, replacement: replacement
            ), original)
        }
    }

    func testDictionaryCorrectionsAllowMisspellingsAndFormatting() {
        for (original, replacement) in [
            ("PostGur SQL", "PostgreSQL"),
            ("type whisper", "TypeWhisper"),
            ("Github actions.", "GitHub Actions"),
            ("dockr", "Docker"),
            ("Cafe", "Café"),
            ("CAFÉ", "cafe"),
            ("anything", ""),
        ] {
            XCTAssertFalse(ParakeetPlugin.removesTextAroundExistingTerm(
                original: original, replacement: replacement
            ), original)
        }
    }

    private static let knownWords: Set<String> = [
        "the", "army", "built", "a", "super", "base", "in", "desert", "my", "grandpa", "now", "lives",
        "Sie", "hat", "sich", "entschieden", "sent", "final", "files", "SQL", "Postgres", "and", "whisper",
        "type", "to", "invoice", "forward", "please", "Configure", "connection", "pool", "I", "can't", "go", "Das", "ist", "schon", "gut",
    ]

    private func guarded(_ original: String, _ rescored: String) -> String {
        ParakeetVocabularyGuard.filter(original: original, rescored: rescored) { Self.knownWords.contains($0) }
    }

    func testVocabularyGuardRefusesTermsInPlaceOfKnownWords() {
        for (original, rescored) in [
            ("The army built a super base in the desert.", "The army built a Supabase in the desert."),
            ("My grandpa now lives in a small town.", "My Grafana now lives in a small town."),
            ("Sie hat sich entschieden.", "Siobhan sich entschieden."),
            ("Type quietly and whisper so nobody wakes up.", "Type quietly and WhisperKit so nobody wakes up."),
            ("Docker with Postgres and Redis.", "Docker with PostgreSQL and Redis."),
            ("Tasmine sent the final design files.", "Tasmeen the final design files."),
            ("I can't go.", "I cant go."),
            ("Das ist schon gut.", "Das ist schön gut."),
        ] {
            XCTAssertEqual(guarded(original, rescored), original, original)
        }
    }

    func testVocabularyGuardKeepsCorrectionsOfUnknownWords() {
        for (original, rescored) in [
            ("We moved the table to superbase.", "We moved the table to Supabase."),
            ("Configure the PostGur SQL connection pool.", "Configure the PostgreSQL connection pool."),
            ("Open type whisper and pick a model.", "Open TypeWhisper and pick a model."),
            ("Install dockr first.", "Install Docker first."),
        ] {
            XCTAssertEqual(guarded(original, rescored), rescored, original)
        }
    }

    func testVocabularyGuardKeepsGoodChangesNextToRefusedOnes() {
        XCTAssertEqual(
            guarded("My grandpa uses superbase daily.", "My Grafana uses Supabase daily."),
            "My grandpa uses Supabase daily."
        )
    }

    func testVocabularyGuardKeepsPunctuationTheRescorerDropped() {
        XCTAssertEqual(
            guarded("Please forward the invoice to Tasmine.", "Please forward the invoice to Tasmeen"),
            "Please forward the invoice to Tasmeen."
        )
    }

    func testVocabularyGuardKeepsSymbolsThatBelongToTerms() {
        for (original, rescored, expected) in [
            ("Use C today.", "Use C++ today.", "Use C++ today."),
            ("Write it in C.", "Write it in C#", "Write it in C#."),
            ("Port it to NET first.", "Port it to .NET first.", "Port it to .NET first."),
            ("Ask Tasmine, then send it.", "Ask Tasmeen, then send it.", "Ask Tasmeen, then send it."),
            ("He said \"write it in C.\"", "He said \"write it in C++", "He said \"write it in C++.\""),
            ("(Port it to NET.)", "(Port it to .NET", "(Port it to .NET.)"),
            ("Use \"C.\" today.", "Use C++ today.", "Use \"C++.\" today."),
            ("Use C++ today.", "Use C today.", "Use C++ today."),
            ("Port it to .NET first.", "Port it to NET first.", "Port it to .NET first."),
        ] {
            XCTAssertEqual(guarded(original, rescored), expected, original)
        }
    }

    func testVocabularyGuardRefusesDeletionsAndInsertions() {
        XCTAssertEqual(guarded("Please forward the invoice.", "Please the invoice."), "Please forward the invoice.")
        XCTAssertEqual(guarded("Please forward the invoice.", "Please forward Tasmeen the invoice."), "Please forward the invoice.")
    }

    @MainActor
    func testVocabularyGuardUsesTheSystemSpellChecker() {
        let languages = ParakeetVocabularyGuard.spellCheckLanguages(for: "de-DE")
        XCTAssertEqual(languages.first, "de")
        XCTAssertTrue(languages.contains("en"))
        XCTAssertTrue(ParakeetVocabularyGuard.isKnownWord("house", languages: ["en"]))
        XCTAssertFalse(ParakeetVocabularyGuard.isKnownWord("superbase", languages: ["en"]))
    }

    private func regressionAudio() throws -> AudioData {
        guard let path = ProcessInfo.processInfo.environment["TYPEWHISPER_PARAKEET_REGRESSION_WAV"] else {
            throw XCTSkip("Set TYPEWHISPER_PARAKEET_REGRESSION_WAV and install Parakeet v3 to run Core ML inference")
        }
        return try regressionAudio(
            at: URL(fileURLWithPath: path),
            sha256: "8802fabce33b67d3093d3ac2a2c3fdc77bfd00ef69c98dde5d161564ee95747e"
        )
    }

    private func regressionAudio(at url: URL, sha256: String) throws -> AudioData {
        let wavData = try Data(contentsOf: url)
        let checksum = SHA256.hash(data: wavData).map { String(format: "%02x", $0) }.joined()
        guard checksum == sha256 else {
            throw NSError(domain: "ParakeetRegressionFixture", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The recording does not match the pinned regression fixture: \(url.lastPathComponent)",
            ])
        }
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ))
        try file.read(into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        return AudioData(samples: samples, wavData: wavData, duration: Double(samples.count) / 16_000)
    }

    func testPassiveLocalLoaderPreservesCorruptCacheAndDoesNotRepairIt() throws {
        let directory = try makeTemporaryDirectory()
        let vocabulary = directory.appendingPathComponent(ParakeetPlugin.vocabularyAssetFileName)
        try Data(#"{"0":"test"}"#.utf8).write(to: vocabulary)
        let corruptModel = directory.appendingPathComponent("Encoder.mlmodelc")
        try FileManager.default.createDirectory(at: corruptModel, withIntermediateDirectories: true)
        let marker = corruptModel.appendingPathComponent("keep-me")
        try Data("incomplete model".utf8).write(to: marker)

        for version in ParakeetVersion.allCases {
            XCTAssertThrowsError(try ParakeetPlugin.loadInstalledModels(version: version, directory: directory))
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: vocabulary.path))
        }
    }

    func testVocabularyAssetURLsMapToVersionRepositories() {
        XCTAssertEqual(
            ParakeetPlugin.vocabularyAssetURL(for: .v2).absoluteString,
            "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml/resolve/main/parakeet_vocab.json"
        )
        XCTAssertEqual(
            ParakeetPlugin.vocabularyAssetURL(for: .v3).absoluteString,
            "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/resolve/main/parakeet_vocab.json"
        )
        XCTAssertEqual(
            ParakeetPlugin.vocabularyAssetURL(for: .ultra).absoluteString,
            "https://huggingface.co/FluidInference/parakeet-ultra-coreml/resolve/main/parakeet_vocab.json"
        )
    }

    func testUltraIsOfferedFirstWithV3LanguagesAndFiles() throws {
        let plugin = makePlugin()
        XCTAssertEqual(
            plugin.transcriptionModels.map(\.id),
            ["parakeet-ultra", "parakeet-tdt-0.6b-v3", "fluid-speech-mini", "parakeet-tdt-0.6b-v2", "nemotron-3.5-asr-streaming-0.6b"]
        )
        XCTAssertEqual(ParakeetVersion.from(modelId: "parakeet-ultra"), .ultra)
        XCTAssertEqual(ParakeetVersion.ultra.supportedLanguages, ParakeetVersion.v3.supportedLanguages)
        XCTAssertEqual(ParakeetVersion.ultra.requiredModelFiles, ParakeetVersion.v3.requiredModelFiles)
    }

    func testUltraLoadsWhenNoModelWasChosenYet() async throws {
        let host = try PluginTestHostServices(defaults: [:], shouldRestoreLoadedModelsPassively: false)
        let plugin = makePlugin()
        let loaded = LoadedVersions()
        plugin.asrModelLoadOverrideForTests = { version in await loaded.append(version) }
        plugin.activate(host: host)
        defer { plugin.deactivate() }

        await plugin.loadModel()

        let versions = await loaded.versions
        XCTAssertEqual(versions, [.ultra])
        XCTAssertEqual(plugin.loadedModelId, "parakeet-ultra")
    }

    func testSavedV3SelectionStaysV3() async throws {
        let host = try PluginTestHostServices(
            defaults: ["selectedModel": "parakeet-tdt-0.6b-v3", "selectedVersion": "v3"],
            shouldRestoreLoadedModelsPassively: false
        )
        let plugin = makePlugin()
        let loaded = LoadedVersions()
        plugin.asrModelLoadOverrideForTests = { version in await loaded.append(version) }
        plugin.activate(host: host)
        defer { plugin.deactivate() }

        await plugin.loadModel()

        let versions = await loaded.versions
        XCTAssertEqual(versions, [.v3])
    }

    /// The host switches models per request with `selectModel` and transcribes as soon as the
    /// plugin reports the new selection as configured. The previous model must not count.
    func testSelectingAnotherModelUnloadsTheLoadedOneImmediately() async throws {
        let host = try PluginTestHostServices(
            defaults: ["selectedModel": "parakeet-ultra", "selectedVersion": "ultra"],
            shouldRestoreLoadedModelsPassively: false
        )
        let plugin = makePlugin()
        let loaded = LoadedVersions()
        plugin.asrModelLoadOverrideForTests = { version in await loaded.append(version) }
        plugin.activate(host: host)
        defer { plugin.deactivate() }
        await plugin.loadModel()
        XCTAssertEqual(plugin.loadedModelId, "parakeet-ultra")

        plugin.selectModel("parakeet-tdt-0.6b-v3")

        XCTAssertEqual(plugin.selectedModelId, "parakeet-tdt-0.6b-v3")
        XCTAssertFalse(plugin.isConfigured)
        XCTAssertNil(plugin.loadedModelId)
        XCTAssertEqual(plugin.supportedLanguages, ParakeetVersion.v3.supportedLanguages)
        XCTAssertEqual(host.userDefault(forKey: "selectedVersion") as? String, "v3")

        for _ in 0..<200 where plugin.loadedModelId == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(plugin.loadedModelId, "parakeet-tdt-0.6b-v3")
        XCTAssertTrue(plugin.isConfigured)
        let versions = await loaded.versions
        XCTAssertEqual(versions, [.ultra, .v3])
    }

    /// A model that finishes loading after another was selected must not become the loaded
    /// one: the host, waiting for the new model, would see the old one ready and fail.
    func testLoadThatFinishesAfterAnotherModelWasSelectedIsDropped() async throws {
        let host = try PluginTestHostServices(
            defaults: ["selectedModel": "parakeet-ultra", "selectedVersion": "ultra"],
            shouldRestoreLoadedModelsPassively: false
        )
        let plugin = makePlugin()
        let loads = HeldLoads()
        plugin.asrModelLoadOverrideForTests = { version in await loads.load(version) }
        plugin.activate(host: host)
        defer { plugin.deactivate() }
        // The host restores Ultra, as after a request that used another model.
        plugin.triggerRestoreModel(forModel: "parakeet-ultra" as NSString)
        await loads.waitForLoads(1)

        plugin.selectModel("parakeet-tdt-0.6b-v3")
        await loads.releaseNext()
        await loads.waitForLoads(2)

        XCTAssertNil(plugin.loadedModelId, "Ultra finished loading after v3 was selected")
        XCTAssertFalse(plugin.isConfigured)
        XCTAssertEqual(plugin.selectedModelId, "parakeet-tdt-0.6b-v3")

        await loads.releaseNext()
        for _ in 0..<200 where plugin.loadedModelId == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(plugin.loadedModelId, "parakeet-tdt-0.6b-v3")
        XCTAssertEqual(plugin.selectedModelId, "parakeet-tdt-0.6b-v3")
        XCTAssertEqual(host.userDefault(forKey: "loadedModel") as? String, "parakeet-tdt-0.6b-v3")
        let versions = await loads.versions
        XCTAssertEqual(versions, [.ultra, .v3])
    }

    func testLoadForAnOlderSelectionDoesNotReplaceTheNewestOne() async throws {
        let host = try PluginTestHostServices(
            defaults: ["selectedModel": "parakeet-ultra", "selectedVersion": "ultra"],
            shouldRestoreLoadedModelsPassively: false
        )
        let plugin = makePlugin()
        let loads = HeldLoads()
        plugin.asrModelLoadOverrideForTests = { version in await loads.load(version) }
        plugin.activate(host: host)
        defer { plugin.deactivate() }
        let ultraLoad = Task { await plugin.loadModel() }
        await loads.waitForLoads(1)

        plugin.selectModel("parakeet-tdt-0.6b-v3")
        plugin.selectModel("parakeet-ultra")
        await loads.releaseNext()
        await ultraLoad.value
        XCTAssertEqual(plugin.loadedModelId, "parakeet-ultra", "Ultra is the newest selection")

        // The v3 selection's load still runs but must not install v3, so Ultra needs no reload.
        for _ in 0..<20 {
            await loads.releaseNext()
            try await Task.sleep(for: .milliseconds(10))
        }
        await plugin.loadModel(version: .ultra)
        XCTAssertEqual(plugin.loadedModelId, "parakeet-ultra")
        XCTAssertEqual(plugin.selectedModelId, "parakeet-ultra")
        XCTAssertEqual(host.userDefault(forKey: "loadedModel") as? String, "parakeet-ultra")
        let versions = await loads.versions
        XCTAssertEqual(versions, [.ultra, .v3])
    }

    // MARK: - Unknown tokens

    func testUnknownTokensBecomeAmpersandsBetweenCapitalsAndAreDroppedElsewhere() {
        let cases: [(String, String)] = [
            ("whether that's an M<unk>A or supporting new products", "whether that's an M&A or supporting new products"),
            ("booked directly into P<unk>L, into the selling cost line.", "booked directly into P&L, into the selling cost line."),
            ("die Ä<unk>Ö-Regel", "die Ä&Ö-Regel"),
            ("hello <unk>… world", "hello… world"),
            ("{set <unk>} done", "{set} done"),
            ("compared by infrared spectroscopy <unk> FTIR.", "compared by infrared spectroscopy FTIR."),
            ("alongside the word <unk>say<unk> for you", "alongside the word say for you"),
            ("is the 'pay amolai<unk>, bred with olive oil", "is the 'pay amolai, bred with olive oil"),
            ("<unk>Hello there<unk>", "Hello there"),
            ("no markers here", "no markers here"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(ParakeetPlugin.removingUnknownTokens(from: input), expected, input)
        }
    }

    func testTranscriptIsTrimmedWithAndWithoutUnknownTokens() async throws {
        for (raw, expected) in [("\nhello world\n", "hello world"), ("\n<unk>hello world \n", "hello world")] {
            let host = try PluginTestHostServices(defaults: ["loadedModel": "parakeet-ultra"])
            let plugin = makePlugin()
            plugin.asrModelLoadOverrideForTests = { _ in }
            plugin.asrTranscriptionOverrideForTests = { samples in
                ASRResult(text: raw, confidence: 1, duration: Double(samples.count) / 16_000, processingTime: 0)
            }
            plugin.activate(host: host)
            await plugin.restoreLoadedModel()

            let result = try await plugin.transcribe(audio: fakeSpeech, language: nil, translate: false, prompt: nil)

            XCTAssertEqual(result.text, expected, raw)
            plugin.deactivate()
        }
    }

    func testPunctuationLeftByADroppedMarkerJoinsThePreviousWord() {
        let timings = [
            TokenTiming(token: "▁hello", tokenId: 1, startTime: 0.0, endTime: 0.3, confidence: 1),
            TokenTiming(token: "▁<unk>", tokenId: 0, startTime: 0.3, endTime: 0.4, confidence: 1),
            TokenTiming(token: ",", tokenId: 2, startTime: 0.4, endTime: 0.5, confidence: 1),
            TokenTiming(token: "▁world.", tokenId: 3, startTime: 0.6, endTime: 1.0, confidence: 1),
        ]

        let words = ParakeetPlugin.groupTokensIntoWords(timings)

        XCTAssertEqual(words.map(\.text), ["hello,", "world."])
        XCTAssertEqual(words.first?.end, 0.5)
        XCTAssertEqual(ParakeetPlugin.groupWordsIntoSegments(words).map(\.text), ["hello, world."])
    }

    func testOpeningPunctuationLeftByADroppedMarkerJoinsTheNextWord() {
        let timings = [
            TokenTiming(token: "▁hello", tokenId: 1, startTime: 0.0, endTime: 0.3, confidence: 1),
            TokenTiming(token: "▁<unk>(", tokenId: 0, startTime: 0.3, endTime: 0.4, confidence: 1),
            TokenTiming(token: "▁world", tokenId: 2, startTime: 0.4, endTime: 0.7, confidence: 1),
            TokenTiming(token: "▁<unk>)", tokenId: 0, startTime: 0.7, endTime: 0.8, confidence: 1),
            TokenTiming(token: "▁now.", tokenId: 3, startTime: 0.9, endTime: 1.2, confidence: 1),
        ]

        let words = ParakeetPlugin.groupTokensIntoWords(timings)

        XCTAssertEqual(words.map(\.text), ["hello", "(world)", "now."])
        XCTAssertEqual(words[1].start, 0.3)
        XCTAssertEqual(words[1].end, 0.8)
        XCTAssertEqual(ParakeetPlugin.groupWordsIntoSegments(words).map(\.text), ["hello (world) now."])
    }

    func testTranscriptAndWordTimingsNeverContainUnknownTokens() async throws {
        let host = try PluginTestHostServices(defaults: ["loadedModel": "parakeet-ultra"])
        let plugin = makePlugin()
        plugin.asrModelLoadOverrideForTests = { _ in }
        let timings = [
            TokenTiming(token: "▁an", tokenId: 1, startTime: 0.0, endTime: 0.2, confidence: 1),
            TokenTiming(token: "▁M", tokenId: 2, startTime: 0.3, endTime: 0.4, confidence: 1),
            TokenTiming(token: "<unk>", tokenId: 0, startTime: 0.4, endTime: 0.5, confidence: 1),
            TokenTiming(token: "A", tokenId: 3, startTime: 0.5, endTime: 0.6, confidence: 1),
            TokenTiming(token: "▁<unk>", tokenId: 0, startTime: 0.7, endTime: 0.8, confidence: 1),
            TokenTiming(token: "▁deal.", tokenId: 4, startTime: 0.9, endTime: 1.0, confidence: 1),
        ]
        plugin.asrTranscriptionOverrideForTests = { samples in
            ASRResult(text: "an M<unk>A <unk> deal.", confidence: 1, duration: Double(samples.count) / 16_000,
                      processingTime: 0, tokenTimings: timings)
        }
        plugin.activate(host: host)
        defer { plugin.deactivate() }
        await plugin.restoreLoadedModel()

        let result = try await plugin.transcribe(audio: fakeSpeech, language: nil, translate: false, prompt: nil)

        XCTAssertEqual(result.text, "an M&A deal.")
        let words = result.segments.map(\.text).joined(separator: " ")
        XCTAssertFalse(words.contains("<unk>"), words)
        XCTAssertEqual(words, "an M&A deal.")
    }

    // MARK: - Fluid Speech Mini

    func testFluidSpeechMiniIsAnEnglishUltraFineTuneWithoutLanguageHint() {
        let version = ParakeetVersion.fluidSpeechMini
        XCTAssertEqual(ParakeetVersion.from(modelId: "fluid-speech-mini"), version)
        XCTAssertEqual(version.supportedLanguages, ["en"])
        XCTAssertEqual(version.asrModelVersion, .ultra)
        XCTAssertFalse(version.acceptsLanguageHint, "Its joint network has no top-K outputs")
        XCTAssertTrue(ParakeetVersion.ultra.acceptsLanguageHint)
        XCTAssertEqual(version.jointFileName, ModelNames.ASR.jointFile)
        XCTAssertEqual(ParakeetVersion.ultra.jointFileName, ModelNames.ASR.jointV3File)
        XCTAssertEqual(version.huggingFaceRepository, "FluidVoice-Labs/fluid-speech-mini-coreml")
        XCTAssertNotNil(FluidSpeechMini.revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression))
        XCTAssertEqual(version.installDirectory.lastPathComponent, "fluid-speech-mini-coreml")
        XCTAssertNotEqual(version.installDirectory, ParakeetVersion.ultra.installDirectory)
        XCTAssertTrue(
            version.settingsDescription(bundle: Bundle(for: ParakeetPlugin.self))
                .contains("Fluid Speech Mini by FluidVoice, built on NVIDIA Parakeet TDT 0.6B v3 and Moondream Parakeet Ultra"),
            "CC BY 4.0 attribution"
        )
    }

    func testFluidSpeechMiniInstallMovesACompleteDownloadIntoPlace() async throws {
        let directory = try makeTemporaryDirectory().appendingPathComponent("fluid-speech-mini-coreml")
        let files = Self.fluidSpeechMiniFiles
        let downloads = FluidSpeechMiniTransfers()
        let progress = ProgressValues()

        try await FluidSpeechMini.install(
            into: directory,
            listFiles: { files },
            downloadFile: { path, destination in
                await downloads.record(path)
                try Self.writeFile(of: files, path: path, to: destination)
            },
            progress: { progress.append($0) }
        )

        XCTAssertTrue(FluidSpeechMini.isInstalled(at: directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: FluidSpeechMini.stagingDirectory(for: directory).path))
        let downloaded = await downloads.paths
        XCTAssertEqual(downloaded, files.map(\.path))
        XCTAssertEqual(progress.values.last, 1)
    }

    func testFluidSpeechMiniInstallResumesWithoutRefetchingFinishedFiles() async throws {
        let directory = try makeTemporaryDirectory().appendingPathComponent("fluid-speech-mini-coreml")
        let files = Self.fluidSpeechMiniFiles
        let finished = files[0]
        let staged = FluidSpeechMini.stagingDirectory(for: directory).appendingPathComponent(finished.path)
        try FileManager.default.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.writeFile(of: files, path: finished.path, to: staged)
        let downloads = FluidSpeechMiniTransfers()

        try await FluidSpeechMini.install(
            into: directory,
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
        XCTAssertTrue(FluidSpeechMini.isInstalled(at: directory))
    }

    func testFluidSpeechMiniInstallRejectsPathsOutsideTheModelFolder() async throws {
        let directory = try makeTemporaryDirectory().appendingPathComponent("fluid-speech-mini-coreml")
        let files = [PluginHuggingFaceDownloadSize.RemoteFile(path: "../escaped.bin", size: 4)]

        do {
            try await FluidSpeechMini.install(
                into: directory,
                listFiles: { files },
                downloadFile: { _, _ in XCTFail("An unsafe path must not be downloaded") },
                progress: { _ in }
            )
            XCTFail("Expected an error")
        } catch is FluidSpeechMini.DownloadError {}
        XCTAssertFalse(FluidSpeechMini.isInstalled(at: directory))
    }

    func testFluidSpeechMiniInstallRejectsATruncatedFile() async throws {
        let directory = try makeTemporaryDirectory().appendingPathComponent("fluid-speech-mini-coreml")
        let files = Self.fluidSpeechMiniFiles

        do {
            try await FluidSpeechMini.install(
                into: directory,
                listFiles: { files },
                downloadFile: { _, destination in try Data([1]).write(to: destination) },
                progress: { _ in }
            )
            XCTFail("Expected an error")
        } catch is FluidSpeechMini.DownloadError {}
        XCTAssertFalse(FluidSpeechMini.isInstalled(at: directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    private static let fluidSpeechMiniFiles: [PluginHuggingFaceDownloadSize.RemoteFile] =
        FluidSpeechMini.modelFolders.sorted().flatMap { folder in
            [
                PluginHuggingFaceDownloadSize.RemoteFile(path: "\(folder)/coremldata.bin", size: 8),
                PluginHuggingFaceDownloadSize.RemoteFile(path: "\(folder)/weights/weight.bin", size: 16),
            ]
        } + [PluginHuggingFaceDownloadSize.RemoteFile(path: ModelNames.ASR.vocabularyFile, size: 12)]

    private static func writeFile(
        of files: [PluginHuggingFaceDownloadSize.RemoteFile],
        path: String,
        to destination: URL
    ) throws {
        let size = try XCTUnwrap(files.first { $0.path == path }?.size)
        try Data(repeating: 7, count: Int(size)).write(to: destination)
    }

    private actor FluidSpeechMiniTransfers {
        private(set) var paths: [String] = []
        func record(_ path: String) { paths.append(path) }
    }

    private final class ProgressValues: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Double] = []
        var values: [Double] { lock.withLock { stored } }
        func append(_ value: Double) { lock.withLock { stored.append(value) } }
    }

    private actor LoadedVersions {
        private(set) var versions: [ParakeetVersion] = []
        func append(_ version: ParakeetVersion) { versions.append(version) }
    }

    /// Holds every model load until the test releases it.
    private actor HeldLoads {
        private(set) var versions: [ParakeetVersion] = []
        private var held: [CheckedContinuation<Void, Never>] = []
        private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

        func load(_ version: ParakeetVersion) async {
            versions.append(version)
            countWaiters.removeAll { count, waiter in
                guard versions.count >= count else { return false }
                waiter.resume()
                return true
            }
            await withCheckedContinuation { held.append($0) }
        }

        func waitForLoads(_ count: Int) async {
            guard versions.count < count else { return }
            await withCheckedContinuation { countWaiters.append((count, $0)) }
        }

        func releaseNext() {
            guard !held.isEmpty else { return }
            held.removeFirst().resume()
        }
    }

    func testEnsureVocabularyAssetSkipsExistingFile() async throws {
        let directory = try makeTemporaryDirectory()
        let targetURL = directory.appendingPathComponent(ParakeetPlugin.vocabularyAssetFileName)
        let existingData = Data(#"{"0":"existing"}"#.utf8)
        try existingData.write(to: targetURL)
        let recorder = VocabularyFetchRecorder(data: Data(#"{"0":"downloaded"}"#.utf8))
        let plugin = makePlugin()

        try await plugin.ensureVocabularyAsset(
            for: .v3,
            targetDirectory: directory,
            fetcher: { url, description in
                try await recorder.fetch(url: url, description: description)
            }
        )

        let requestCount = await recorder.requestCount()
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(try Data(contentsOf: targetURL), existingData)
    }

    func testEnsureVocabularyAssetRepairsEmptyExistingFile() async throws {
        let directory = try makeTemporaryDirectory()
        let targetURL = directory.appendingPathComponent(ParakeetPlugin.vocabularyAssetFileName)
        try Data().write(to: targetURL)
        let downloadedData = Data(#"{"0":"downloaded"}"#.utf8)
        let recorder = VocabularyFetchRecorder(data: downloadedData)
        let plugin = makePlugin()

        try await plugin.ensureVocabularyAsset(
            for: .v3,
            targetDirectory: directory,
            fetcher: { url, description in
                try await recorder.fetch(url: url, description: description)
            }
        )

        XCTAssertEqual(try Data(contentsOf: targetURL), downloadedData)
        let requestCount = await recorder.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testEnsureVocabularyAssetDownloadsMissingFile() async throws {
        let directory = try makeTemporaryDirectory()
        let targetURL = directory.appendingPathComponent(ParakeetPlugin.vocabularyAssetFileName)
        let downloadedData = Data(#"{"0":"<blank>"}"#.utf8)
        let recorder = VocabularyFetchRecorder(data: downloadedData)
        let plugin = makePlugin()

        try await plugin.ensureVocabularyAsset(
            for: .v3,
            targetDirectory: directory,
            fetcher: { url, description in
                try await recorder.fetch(url: url, description: description)
            }
        )

        XCTAssertEqual(try Data(contentsOf: targetURL), downloadedData)
        let requestCount = await recorder.requestCount()
        XCTAssertEqual(requestCount, 1)
        let recordedRequest = await recorder.firstRequest()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.url, ParakeetPlugin.vocabularyAssetURL(for: .v3))
        XCTAssertEqual(request.description, "Parakeet TDT v3 vocabulary")
    }

    func testEnsureVocabularyAssetCreatesMissingTargetDirectory() async throws {
        let parentDirectory = try makeTemporaryDirectory()
        let directory = parentDirectory.appendingPathComponent("missing-cache", isDirectory: true)
        let targetURL = directory.appendingPathComponent(ParakeetPlugin.vocabularyAssetFileName)
        let downloadedData = Data(#"{"0":"created-directory"}"#.utf8)
        let recorder = VocabularyFetchRecorder(data: downloadedData)
        let plugin = makePlugin()

        try await plugin.ensureVocabularyAsset(
            for: .v2,
            targetDirectory: directory,
            fetcher: { url, description in
                try await recorder.fetch(url: url, description: description)
            }
        )

        var isDirectory = ObjCBool(false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(try Data(contentsOf: targetURL), downloadedData)
        let requestCount = await recorder.requestCount()
        XCTAssertEqual(requestCount, 1)
        let recordedRequest = await recorder.firstRequest()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.url, ParakeetPlugin.vocabularyAssetURL(for: .v2))
    }

    func testEnsureVocabularyAssetSurfacesFailedFetch() async throws {
        let directory = try makeTemporaryDirectory()
        let targetURL = directory.appendingPathComponent(ParakeetPlugin.vocabularyAssetFileName)
        let recorder = VocabularyFetchRecorder(
            error: NSError(
                domain: "ParakeetVocabularyAssetTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "network unavailable"]
            )
        )
        let plugin = makePlugin()

        do {
            try await plugin.ensureVocabularyAsset(
                for: .v2,
                targetDirectory: directory,
                fetcher: { url, description in
                    try await recorder.fetch(url: url, description: description)
                }
            )
            XCTFail("Expected vocabulary download to fail")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains(
                    "Failed to download Parakeet vocabulary file for Parakeet TDT v2"
                )
            )
            XCTAssertTrue(error.localizedDescription.contains("network unavailable"))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: targetURL.path))
        let requestCount = await recorder.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testActivationPromotesPersistedLoadedModelToSelectedModelWhenSelectionMissing() throws {
        let host = try PluginTestHostServices(defaults: [
            "loadedModel": "parakeet-tdt-0.6b-v3",
        ])
        let plugin = makePlugin()

        plugin.activate(host: host)

        XCTAssertEqual(plugin.selectedModelId, "parakeet-tdt-0.6b-v3")
        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, "parakeet-tdt-0.6b-v3")
        XCTAssertEqual(host.userDefault(forKey: "loadedModel") as? String, "parakeet-tdt-0.6b-v3")
        XCTAssertFalse(plugin.isConfigured)
        XCTAssertEqual(host.capabilitiesChangedCount, 0)
    }

    func testActivationKeepsPersistedSelectedModelVisibleBeforeRestoreCompletes() throws {
        let host = try PluginTestHostServices(defaults: [
            "selectedModel": "parakeet-tdt-0.6b-v2",
            "loadedModel": "parakeet-tdt-0.6b-v2",
        ])
        let plugin = makePlugin()

        plugin.activate(host: host)

        XCTAssertEqual(plugin.selectedModelId, "parakeet-tdt-0.6b-v2")
        XCTAssertFalse(plugin.isConfigured)
        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, "parakeet-tdt-0.6b-v2")
        XCTAssertEqual(host.userDefault(forKey: "loadedModel") as? String, "parakeet-tdt-0.6b-v2")
    }

    func testActivationDoesNotMarkPluginConfiguredBeforeRestoreSucceeds() throws {
        let host = try PluginTestHostServices(defaults: [
            "selectedModel": "parakeet-tdt-0.6b-v3",
            "loadedModel": "parakeet-tdt-0.6b-v3",
        ])
        let plugin = makePlugin()

        plugin.activate(host: host)

        XCTAssertFalse(plugin.isConfigured)
        XCTAssertEqual(plugin.selectedModelId, "parakeet-tdt-0.6b-v3")
    }

    func testUnloadWithoutClearingPersistenceKeepsSelectedAndLoadedModelMarkers() throws {
        let host = try PluginTestHostServices(defaults: [
            "selectedModel": "parakeet-tdt-0.6b-v3",
            "loadedModel": "parakeet-tdt-0.6b-v3",
        ])
        let plugin = makePlugin()
        plugin.activate(host: host)

        plugin.unloadModel(clearPersistence: false)

        XCTAssertFalse(plugin.isConfigured)
        XCTAssertEqual(plugin.selectedModelId, "parakeet-tdt-0.6b-v3")
        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, "parakeet-tdt-0.6b-v3")
        XCTAssertEqual(host.userDefault(forKey: "loadedModel") as? String, "parakeet-tdt-0.6b-v3")
    }

    func testUnloadClearingPersistenceKeepsSelectedModelAndRemovesLoadedModelMarker() throws {
        let host = try PluginTestHostServices(defaults: [
            "selectedModel": "parakeet-tdt-0.6b-v3",
            "loadedModel": "parakeet-tdt-0.6b-v3",
        ])
        let plugin = makePlugin()
        plugin.activate(host: host)

        plugin.unloadModel(clearPersistence: true)

        XCTAssertFalse(plugin.isConfigured)
        XCTAssertEqual(plugin.selectedModelId, "parakeet-tdt-0.6b-v3")
        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, "parakeet-tdt-0.6b-v3")
        XCTAssertNil(host.userDefault(forKey: "loadedModel"))
    }

    func testActivationLoadsStoredHuggingFaceToken() throws {
        let host = try PluginTestHostServices(secrets: ["hf-token": "hf_parakeet_saved"])
        let plugin = makePlugin()

        plugin.activate(host: host)

        XCTAssertEqual(plugin.huggingFaceToken, "hf_parakeet_saved")
    }

    func testKeepsTheHostDefaultTranscriptPreviewPolicy() throws {
        // Hosts read a declared policy for a model override by selecting that model, which
        // reloads Parakeet models; without one they allow the preview, as Parakeet always did.
        XCTAssertNil(ParakeetPlugin() as Any as? any TranscriptPreviewFallbackPolicyProviding)
    }

    func testUsesBatchFallbackForLivePreviewExceptWithNemotron() throws {
        let plugin = ParakeetPlugin()

        XCTAssertTrue(plugin.supportsStreaming)
        XCTAssertEqual(plugin.liveTranscriptionProgressMode, .completeSnapshot)
        for version in ParakeetVersion.allCases {
            XCTAssertEqual(
                plugin.supportsLiveTranscriptionSession(forModelId: version.modelDef.id),
                version == .nemotronStreaming,
                version.modelDef.id
            )
        }
        XCTAssertFalse(plugin.supportsLiveTranscriptionSession(forModelId: "unknown-model"))
        // The selected model, Ultra by default, previews in batches.
        XCTAssertNil(plugin.liveTranscriptionPlugin(forModelId: nil))
        XCTAssertNotNil(plugin.liveTranscriptionPlugin(forModelId: ParakeetVersion.nemotronStreaming.modelDef.id))
    }

    func testSourceProgressMapsProgressFractionToAudioDuration() {
        let progress = ParakeetPlugin.sourceProgress(fromFraction: 0.25, totalDuration: 240)

        XCTAssertEqual(progress?.processedDuration, 60)
        XCTAssertEqual(progress?.totalDuration, 240)
        XCTAssertEqual(progress?.fractionCompleted, 0.25)
    }

    func testSourceProgressClampsAndRejectsInvalidDurations() {
        XCTAssertEqual(
            ParakeetPlugin.sourceProgress(fromFraction: 1.5, totalDuration: 10)?.processedDuration,
            10
        )
        XCTAssertEqual(
            ParakeetPlugin.sourceProgress(fromFraction: -0.5, totalDuration: 10)?.processedDuration,
            0
        )
        XCTAssertNil(ParakeetPlugin.sourceProgress(fromFraction: .nan, totalDuration: 10))
        XCTAssertNil(ParakeetPlugin.sourceProgress(fromFraction: 0.5, totalDuration: 0))
    }

    func testDownloadProgressFollowsDownloadWithinLoadingBand() {
        XCTAssertEqual(ParakeetPlugin.downloadProgress(after: 0.1, downloadFraction: 0.25), 0.4, accuracy: 0.0001)
        XCTAssertEqual(ParakeetPlugin.downloadProgress(after: 0.1, downloadFraction: 0.5), 0.7, accuracy: 0.0001)
        XCTAssertEqual(ParakeetPlugin.downloadProgress(after: 0.1, downloadFraction: 1), 0.7, accuracy: 0.0001)
    }

    func testDownloadProgressNeverMovesBackwards() {
        XCTAssertEqual(ParakeetPlugin.downloadProgress(after: 0.55, downloadFraction: 0), 0.55)
        XCTAssertEqual(ParakeetPlugin.downloadProgress(after: 0.55, downloadFraction: -1), 0.55)
        XCTAssertEqual(ParakeetPlugin.downloadProgress(after: 0.3, downloadFraction: .nan), 0.3)
    }

    func testSourceProgressObservationOnlyStartsForFluidAudioProgressRange() {
        XCTAssertFalse(ParakeetPlugin.shouldObserveSourceProgress(sampleCount: 160_000))
        XCTAssertFalse(ParakeetPlugin.shouldObserveSourceProgress(sampleCount: 240_000))
        XCTAssertTrue(ParakeetPlugin.shouldObserveSourceProgress(sampleCount: 240_001))
    }

    func testDictionaryTermsSupportReflectsStoredBoostingPreference() throws {
        let defaultHost = try PluginTestHostServices()
        let defaultPlugin = makePlugin()
        defaultPlugin.activate(host: defaultHost)
        XCTAssertEqual(defaultPlugin.dictionaryTermsSupport, .requiresPluginSetting)

        let enabledHost = try PluginTestHostServices(defaults: ["vocabularyBoostingEnabled": true])
        let enabledPlugin = makePlugin()
        enabledPlugin.activate(host: enabledHost)
        XCTAssertEqual(enabledPlugin.dictionaryTermsSupport, .supported)
    }

    func testVocabularyHintsPreferStructuredHintsOverPrompt() throws {
        let hints = ParakeetPlugin.vocabularyHints(
            prompt: "PromptTerm",
            dictionaryTermHints: [
                PluginDictionaryTermHint(text: " Caivex ", ctcMinSimilarity: 0.5),
                PluginDictionaryTermHint(text: "caivex", ctcMinSimilarity: 0.8),
                PluginDictionaryTermHint(text: "Reson8", ctcMinSimilarity: nil),
            ]
        )

        XCTAssertEqual(hints, [
            PluginDictionaryTermHint(text: "Caivex", ctcMinSimilarity: 0.5),
            PluginDictionaryTermHint(text: "Reson8", ctcMinSimilarity: nil),
        ])
    }

    func testVocabularyHintsFallbackToPromptAndEncodeThresholdSignature() throws {
        XCTAssertEqual(
            ParakeetPlugin.vocabularyHints(prompt: " Alpha, Beta, alpha ", dictionaryTermHints: []),
            [
                PluginDictionaryTermHint(text: "Alpha", ctcMinSimilarity: nil),
                PluginDictionaryTermHint(text: "Beta", ctcMinSimilarity: nil),
            ]
        )

        let signature = ParakeetPlugin.vocabularySignature(from: [
            PluginDictionaryTermHint(text: "Alpha", ctcMinSimilarity: nil),
            PluginDictionaryTermHint(text: "Beta", ctcMinSimilarity: 0.65),
        ])

        XCTAssertEqual(signature, "Alpha|auto\u{1F}Beta|0.6500")
    }

    func testFluidVocabularyTermReceivesIndividualThreshold() {
        let term = ParakeetPlugin.customVocabularyTerm(
            from: PluginDictionaryTermHint(
                text: "Caivex",
                ctcMinSimilarity: 0.9
            ),
            ctcTokenIds: [1, 2, 3]
        )

        XCTAssertEqual(term.text, "Caivex")
        XCTAssertEqual(term.minSimilarity, 0.9)
    }

    func testSettingsDismissalRequiresOnlyBaseModelReadiness() throws {
        let host = try PluginTestHostServices(defaults: ["vocabularyBoostingEnabled": true])
        let plugin = makePlugin()
        plugin.activate(host: host)

        XCTAssertFalse(plugin.canDismissSettingsAfterSetup)

        plugin.ctcModelState = .ready
        XCTAssertFalse(plugin.canDismissSettingsAfterSetup)

        plugin.modelState = .ready
        plugin.ctcModelState = .downloading
        XCTAssertTrue(plugin.canDismissSettingsAfterSetup)
    }

    func testEnablingVocabularyBoostingPersistsAndNotifiesCapabilityChange() throws {
        let host = try PluginTestHostServices()
        let plugin = makePlugin()
        plugin.activate(host: host)

        plugin.setBoostingEnabled(true)

        XCTAssertEqual(host.userDefault(forKey: "vocabularyBoostingEnabled") as? Bool, true)
        XCTAssertEqual(plugin.dictionaryTermsSupport, .supported)
        XCTAssertEqual(host.capabilitiesChangedCount, 1)

        plugin.setBoostingEnabled(true)

        XCTAssertEqual(host.capabilitiesChangedCount, 1)
    }

    func testEnablingDictionaryTermsSettingTurnsOnBoostingAndDownloadsFilesOnlyWhileUnloaded() async throws {
        let host = try PluginTestHostServices()
        let plugin = makePlugin()
        plugin.activate(host: host)
        let recorder = CtcDownloadRecorder()
        plugin.ctcModelDownloadOverrideForTests = { loadIntoMemory in
            XCTAssertEqual(plugin.dictionaryTermsSupport, .supported)
            await recorder.download(loadIntoMemory: loadIntoMemory)
        }

        XCTAssertTrue((plugin as Any) is any DictionaryTermsSettingEnabling)
        XCTAssertFalse(plugin.dictionaryTermsSettingSummary.isEmpty)
        XCTAssertEqual(plugin.dictionaryTermsSupport, .requiresPluginSetting)

        try await plugin.enableDictionaryTermsSetting()

        let events = await recorder.events
        XCTAssertEqual(events, ["start files", "end files"])
        XCTAssertEqual(plugin.dictionaryTermsSupport, .supported)
        XCTAssertEqual(host.userDefault(forKey: "vocabularyBoostingEnabled") as? Bool, true)
        XCTAssertEqual(host.capabilitiesChangedCount, 2)
    }

    func testEnablingDictionaryTermsSettingThrowsDownloadFailureAndKeepsBoostingOn() async throws {
        let host = try PluginTestHostServices()
        let plugin = makePlugin()
        plugin.activate(host: host)
        plugin.ctcModelDownloadOverrideForTests = { _ in
            plugin.ctcModelState = .error("Not enough disk space")
        }

        do {
            try await plugin.enableDictionaryTermsSetting()
            XCTFail("Expected the download failure to be thrown")
        } catch let error as ParakeetVocabularyBoostingError {
            XCTAssertEqual(error.localizedDescription, "Not enough disk space")
        }

        // Same as the settings toggle: boosting stays on and the download is retried later.
        XCTAssertEqual(plugin.dictionaryTermsSupport, .supported)
        XCTAssertEqual(plugin.currentSettingsActivity?.isError, true)
        XCTAssertEqual(host.capabilitiesChangedCount, 1)

        plugin.ctcModelDownloadOverrideForTests = { _ in
            plugin.ctcModelState = .notDownloaded
        }
        try await plugin.enableDictionaryTermsSetting()
        XCTAssertEqual(host.capabilitiesChangedCount, 2)
    }

    func testCtcDownloadsFromEnablingAndFirstUseRunOneAfterAnother() async throws {
        let host = try PluginTestHostServices()
        let plugin = makePlugin()
        plugin.activate(host: host)
        let recorder = CtcDownloadRecorder(holdsFirstDownload: true)
        plugin.ctcModelDownloadOverrideForTests = { loadIntoMemory in
            await recorder.download(loadIntoMemory: loadIntoMemory)
        }

        let enabling = Task { try await plugin.enableDictionaryTermsSetting() }
        await recorder.waitForFirstStart()

        // A first transcription asks for the in-memory model while the files download.
        let firstUse = Task { await plugin.downloadCtcModel() }
        var yields = 0
        while await plugin.ctcDownloadGate.waitingCount == 0, yields < 10_000 {
            await Task.yield()
            yields += 1
        }
        let waitingCount = await plugin.ctcDownloadGate.waitingCount
        XCTAssertEqual(waitingCount, 1)
        let eventsWhileHeld = await recorder.events
        XCTAssertEqual(eventsWhileHeld, ["start files"])

        await recorder.releaseFirstDownload()
        try await enabling.value
        await firstUse.value

        let events = await recorder.events
        XCTAssertEqual(events, ["start files", "end files", "start load", "end load"])
    }

    func testModelSwitchDoesNotWaitForPreviousModelsCtcLoad() async throws {
        let host = try PluginTestHostServices(defaults: ["vocabularyBoostingEnabled": true])
        let plugin = makePlugin()
        plugin.activate(host: host)
        defer { plugin.deactivate() }
        plugin.asrModelLoadOverrideForTests = { _ in }
        let recorder = CtcDownloadRecorder(holdsFirstDownload: true)
        plugin.ctcModelDownloadOverrideForTests = { loadIntoMemory in
            await recorder.download(loadIntoMemory: loadIntoMemory)
        }

        // Ultra is loaded and its CTC model is still loading.
        plugin.triggerRestoreModel(forModel: "parakeet-ultra")
        await recorder.waitForFirstStart()
        XCTAssertEqual(plugin.modelState, .ready)

        plugin.triggerRestoreModel(forModel: "parakeet-tdt-0.6b-v2")
        XCTAssertFalse(plugin.isConfigured)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !plugin.isConfigured, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(plugin.isConfigured, "The switch waited for the CTC model: \(plugin.modelState)")
        XCTAssertEqual(host.userDefault(forKey: "loadedModel") as? String, "parakeet-tdt-0.6b-v2")
        let eventsWhileHeld = await recorder.events
        XCTAssertEqual(eventsWhileHeld, ["start load"])

        // v2 then loads its CTC model after the held one.
        await recorder.releaseFirstDownload()
        while await recorder.events.count < 4, ContinuousClock.now < deadline.advanced(by: .seconds(5)) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await recorder.events
        XCTAssertEqual(events, ["start load", "end load", "start load", "end load"])
    }

    func testCtcLoadAfterModelLoadSkipsWhenModelUnloadsWhileWaiting() async throws {
        let host = try PluginTestHostServices()
        let plugin = makePlugin()
        plugin.activate(host: host)
        defer { plugin.deactivate() }
        plugin.asrModelLoadOverrideForTests = { _ in }
        let recorder = CtcDownloadRecorder(holdsFirstDownload: true)
        plugin.ctcModelDownloadOverrideForTests = { loadIntoMemory in
            await recorder.download(loadIntoMemory: loadIntoMemory)
        }

        // Enabling while nothing is loaded downloads the files and holds the CTC gate.
        let enabling = Task { try await plugin.enableDictionaryTermsSetting() }
        await recorder.waitForFirstStart()

        // The model load then waits for that download before loading the CTC model.
        plugin.triggerRestoreModel(forModel: "parakeet-ultra")
        try await waitForCtcGateWaiters(1, in: plugin)
        XCTAssertTrue(plugin.isConfigured)

        plugin.unloadModel()
        // Queued behind the waiting step, so it returns once that step is done.
        let afterWaitingStep = Task { try await plugin.ctcDownloadGate.withLock {} }
        try await waitForCtcGateWaiters(2, in: plugin)
        await recorder.releaseFirstDownload()
        try await enabling.value
        try await afterWaitingStep.value

        let events = await recorder.events
        XCTAssertEqual(events, ["start files", "end files"])
    }

    private func waitForCtcGateWaiters(_ count: Int, in plugin: ParakeetPlugin) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await plugin.ctcDownloadGate.waitingCount < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let waitingCount = await plugin.ctcDownloadGate.waitingCount
        XCTAssertEqual(waitingCount, count)
    }

    func testDisablingVocabularyBoostingPersistsClearsVocabularyAndHidesCtcActivity() throws {
        let host = try PluginTestHostServices(defaults: ["vocabularyBoostingEnabled": true])
        let plugin = makePlugin()
        plugin.activate(host: host)
        plugin.lastConfiguredPrompt = "TypeWhisper Madison"
        plugin.lastBoostingTermCount = 2
        plugin.ctcModelState = .downloading
        XCTAssertEqual(plugin.currentSettingsActivity?.message, "Downloading vocabulary model")

        plugin.setBoostingEnabled(false)

        XCTAssertEqual(host.userDefault(forKey: "vocabularyBoostingEnabled") as? Bool, false)
        XCTAssertEqual(plugin.dictionaryTermsSupport, .requiresPluginSetting)
        XCTAssertNil(plugin.lastConfiguredPrompt)
        XCTAssertEqual(plugin.lastBoostingTermCount, 0)
        XCTAssertNil(plugin.currentSettingsActivity)
        plugin.ctcModelState = .error("Vocabulary model failed")
        XCTAssertNil(plugin.currentSettingsActivity)
        XCTAssertEqual(host.capabilitiesChangedCount, 1)

        plugin.setBoostingEnabled(false)

        XCTAssertEqual(host.capabilitiesChangedCount, 1)
    }

    func testStoresAndClearsHuggingFaceTokenSecret() throws {
        let host = try PluginTestHostServices()
        let plugin = makePlugin()
        plugin.activate(host: host)

        plugin.setHuggingFaceToken("  hf_parakeet_saved  ")
        XCTAssertEqual(plugin.huggingFaceToken, "hf_parakeet_saved")
        XCTAssertEqual(host.loadSecret(key: "hf-token"), "hf_parakeet_saved")

        plugin.clearHuggingFaceToken()
        XCTAssertNil(plugin.huggingFaceToken)
        XCTAssertEqual(host.loadSecret(key: "hf-token"), "")
    }

    func testValidatesHuggingFaceTokenAgainstWhoAmIEndpoint() async throws {
        let plugin = makePlugin()
        let requestRecorder = RequestRecorder()

        let isValid = await plugin.validateHuggingFaceToken("hf_parakeet_test") { request in
            await requestRecorder.set(request)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let data = Data(#"{"name":"typewhisper","type":"user"}"#.utf8)
            return (data, response)
        }

        XCTAssertTrue(isValid)
        let maybeRequest = await requestRecorder.get()
        let request = try XCTUnwrap(maybeRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://huggingface.co/api/whoami-v2")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer hf_parakeet_test")
        XCTAssertEqual(request.httpMethod, "GET")
    }

    func testAppliesStoredHuggingFaceTokenToEnvironment() throws {
        let envKeys = [
            "HF_TOKEN",
            "HUGGING_FACE_HUB_TOKEN",
            "HUGGINGFACEHUB_API_TOKEN",
        ]
        let originalTokens = Dictionary(
            uniqueKeysWithValues: envKeys.map { key in
                (key, getenv(key).map { String(cString: $0) })
            }
        )
        defer {
            for key in envKeys {
                if let originalToken = originalTokens[key] ?? nil {
                    setenv(key, originalToken, 1)
                } else {
                    unsetenv(key)
                }
            }
        }

        let host = try PluginTestHostServices()
        let plugin = makePlugin()
        plugin.activate(host: host)
        plugin.setHuggingFaceToken("hf_env_parakeet")

        plugin.applyHuggingFaceTokenToEnvironment()

        for key in envKeys {
            XCTAssertEqual(getenv(key).map { String(cString: $0) }, "hf_env_parakeet")
        }
    }

    // MARK: - Restore trigger activity (issue #840)

    func testTriggerRestoreModelPublishesActivitySynchronously() throws {
        let host = try PluginTestHostServices()
        let plugin = makePlugin()
        plugin.activate(host: host)
        // Suppress the async restore task: with nothing persisted it can finish
        // and flip the mark to the "nothing to restore" error before the
        // assertion below reads it, which made this test flaky in CI.
        plugin.suppressAsyncRestoreForTests = true

        XCTAssertNil(plugin.currentSettingsActivity)

        plugin.triggerRestoreModel()

        // The activity must be visible synchronously: the host only extends its
        // restore wait past the base window while an activity is reported, and
        // task scheduling can delay the async restore task before it publishes
        // its first state update.
        let activity = try XCTUnwrap(plugin.currentSettingsActivity)
        XCTAssertFalse(activity.isError)
    }

    func testTriggerRestoreModelWithoutPersistedModelSurfacesError() async throws {
        let host = try PluginTestHostServices()
        let plugin = makePlugin()
        plugin.activate(host: host)

        // No `loadedModel` persisted, so the async restore has nothing to load.
        plugin.triggerRestoreModel()

        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var errorActivity: PluginSettingsActivity?
        while ContinuousClock.now < deadline {
            if let current = plugin.currentSettingsActivity, current.isError {
                errorActivity = current
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        let activity = try XCTUnwrap(
            errorActivity,
            "a restore with nothing persisted must surface an error, not stay silent"
        )
        XCTAssertTrue(activity.message.contains("No previously loaded model"))
    }

    /// Opt-in Core ML regression through the user-facing restore trigger: seeds the
    /// persisted `loadedModel` marker, goes through `triggerRestoreModel()`, and verifies
    /// the plugin configures and transcribes. Without this, a regression in the generic
    /// trigger could leave the persisted model unloaded while the suite stays green,
    /// because every other Parakeet restore test calls `restoreLoadedModel(...)` directly.
    func testTriggerRestoreModelRestoresPersistedModelBeforeTranscription() async throws {
        let audio = try regressionAudio()

        let host = try PluginTestHostServices(defaults: [
            "loadedModel": "parakeet-tdt-0.6b-v3",
        ])
        let plugin = makePlugin()
        plugin.activate(host: host)
        defer { plugin.deactivate() }

        plugin.triggerRestoreModel()

        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !plugin.isConfigured && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard plugin.isConfigured else {
            XCTFail("triggerRestoreModel() left the persisted model unloaded: \(plugin.modelState)")
            return
        }
        let result = try await plugin.transcribe(
            audio: audio,
            language: nil,
            translate: false,
            prompt: nil
        )
        XCTAssertFalse(result.text.isEmpty, "the restored persisted model must transcribe")
    }

    func testTriggerRestoreModelForModelPublishesActivitySynchronously() throws {
        let host = try PluginTestHostServices()
        let plugin = makePlugin()
        plugin.activate(host: host)
        // Same suppression as above: assert on the synchronous mark only.
        plugin.suppressAsyncRestoreForTests = true

        plugin.triggerRestoreModel(forModel: "parakeet-tdt-0.6b-v3")

        // Same synchronous-activity contract as the parameterless trigger.
        XCTAssertNotNil(plugin.currentSettingsActivity)
    }

    // MARK: - Managed download refusal

    private let downloadRefusal = "Your organization does not allow model downloads."

    func testRefusedDownloadReportsReasonWithoutDownloadingTheModel() async throws {
        // Models live in the user's FluidAudio cache, so use a version that is not installed there.
        guard let version = ParakeetVersion.allCases.first(where: { version in
            guard let asrModelVersion = version.asrModelVersion else { return false }
            return !AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: asrModelVersion), version: asrModelVersion)
        }) else {
            throw XCTSkip("Every Parakeet version is installed, so loading one downloads nothing")
        }
        let host = try PluginTestHostServices(
            defaults: ["loadedModel": version.modelDef.id],
            modelDownloadRefusal: downloadRefusal
        )
        let plugin = makePlugin()
        plugin.asrModelLoadOverrideForTests = { _ in XCTFail("A refused download must not start") }
        plugin.activate(host: host)
        defer { plugin.deactivate() }

        await plugin.restoreLoadedModel(allowDownloads: true)

        XCTAssertFalse(plugin.isConfigured)
        XCTAssertEqual(plugin.modelState, .error(downloadRefusal))
        XCTAssertEqual(plugin.currentSettingsActivity?.message, downloadRefusal)
        XCTAssertEqual(plugin.currentSettingsActivity?.isError, true)
        XCTAssertEqual(host.userDefault(forKey: "loadedModel") as? String, version.modelDef.id)
    }

    func testRefusedDownloadDoesNotFetchTheVocabularyBoostingModel() async throws {
        guard !CtcModels.modelsExist(at: CtcModels.defaultCacheDirectory(for: .ctc110m)) else {
            throw XCTSkip("The CTC model is installed, so Vocabulary Boosting downloads nothing")
        }
        let host = try PluginTestHostServices(modelDownloadRefusal: downloadRefusal)
        let plugin = makePlugin()
        plugin.activate(host: host)
        plugin.ctcModelDownloadOverrideForTests = { _ in XCTFail("A refused download must not start") }

        do {
            try await plugin.enableDictionaryTermsSetting()
            XCTFail("Expected the refusal to be thrown")
        } catch let error as ParakeetVocabularyBoostingError {
            XCTAssertEqual(error.localizedDescription, downloadRefusal)
        }
        XCTAssertEqual(plugin.ctcModelState, .error(downloadRefusal))
        XCTAssertEqual(plugin.currentSettingsActivity?.message, downloadRefusal)

        // The settings view's Download Now and Retry buttons take this path.
        plugin.ctcModelState = .notDownloaded
        await plugin.downloadCtcModel()
        XCTAssertEqual(plugin.ctcModelState, .error(downloadRefusal))
    }

    /// Opt-in Core ML regression: an installed Parakeet v3 model keeps loading through the
    /// explicit load path, which otherwise lets FluidAudio repair the cache by downloading.
    func testInstalledV3ModelLoadsAndTranscribesWhileDownloadsAreRefused() async throws {
        let audio = try regressionAudio()

        let host = try PluginTestHostServices(
            defaults: [
                "loadedModel": "parakeet-tdt-0.6b-v3",
                "vocabularyBoostingEnabled": false,
            ],
            modelDownloadRefusal: downloadRefusal
        )
        let plugin = makePlugin()
        plugin.activate(host: host)
        defer { plugin.deactivate() }

        await plugin.restoreLoadedModel(allowDownloads: true)
        guard plugin.isConfigured else {
            XCTFail("Installed Parakeet v3 failed to load: \(plugin.modelState)")
            return
        }
        let result = try await plugin.transcribe(audio: audio, language: nil, translate: false, prompt: nil)
        XCTAssertFalse(result.text.isEmpty)
    }
}
