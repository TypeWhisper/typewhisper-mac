import XCTest
@preconcurrency import AVFoundation
import CryptoKit
import TypeWhisperPluginSDK
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

    func testAllowsTranscriptPreviewFallback() throws {
        let fallbackPolicy: any TranscriptPreviewFallbackPolicyProviding = ParakeetPlugin()

        XCTAssertTrue(fallbackPolicy.allowsTranscriptPreviewFallback)
    }

    func testUsesBatchFallbackForLivePreview() throws {
        let plugin = ParakeetPlugin()
        let fallbackPolicy: any TranscriptPreviewFallbackPolicyProviding = plugin

        XCTAssertTrue(plugin.supportsStreaming)
        XCTAssertTrue(fallbackPolicy.allowsTranscriptPreviewFallback)
        XCTAssertNil(plugin as? any LiveTranscriptionCapablePlugin)
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
}
