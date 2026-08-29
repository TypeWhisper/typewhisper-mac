import Darwin
import Foundation
import TypeWhisperPluginSDK
import TypeWhisperPluginSDKTesting
import XCTest

@testable import CohereLocalPlugin

final class CohereLocalPluginTests: XCTestCase {
    private actor RequestRecorder {
        private var request: URLRequest?

        func set(_ request: URLRequest) {
            self.request = request
        }

        func get() -> URLRequest? {
            request
        }
    }

    func testPluginIdentityAndCapabilities() {
        let plugin = CohereLocalPlugin()

        XCTAssertEqual(CohereLocalPlugin.pluginId, "com.typewhisper.cohere-transcribe")
        XCTAssertEqual(plugin.providerId, "cohere-transcribe")
        XCTAssertEqual(
            plugin.providerDisplayName,
            CohereLocalPlugin.localizedString(CohereLocalPlugin.pluginName)
        )
        XCTAssertFalse(plugin.supportsStreaming)
        XCTAssertFalse(plugin.supportsTranslation)
        XCTAssertEqual(plugin.dictionaryTermsSupport, .unsupported)
    }

    func testSupportedLanguagesMatchCohereGGUFPipeline() {
        XCTAssertEqual(
            CohereLocalPlugin.supportedLanguageCodes,
            [
                "en", "fr", "de", "es", "it", "pt", "nl",
                "pl", "el", "ar", "ja", "zh", "vi", "ko",
            ]
        )
        XCTAssertEqual(CohereLocalPlugin.supportedLanguageCodes.count, 14)
    }

    func testLanguageNormalizationAcceptsRegionAndChineseAliases() {
        XCTAssertEqual(CohereLocalPlugin.normalizedLanguageCode(for: "de-DE"), "de")
        XCTAssertEqual(CohereLocalPlugin.normalizedLanguageCode(for: "pt_BR"), "pt")
        XCTAssertEqual(CohereLocalPlugin.normalizedLanguageCode(for: "zh-Hans"), "zh")
        XCTAssertEqual(CohereLocalPlugin.normalizedLanguageCode(for: "cmn_Hans_CN"), "zh")
    }

    func testLanguageNormalizationRejectsAutoRussianAndHindi() {
        XCTAssertNil(CohereLocalPlugin.normalizedLanguageCode(for: nil))
        XCTAssertNil(CohereLocalPlugin.normalizedLanguageCode(for: ""))
        XCTAssertNil(CohereLocalPlugin.normalizedLanguageCode(for: "auto"))
        XCTAssertNil(CohereLocalPlugin.normalizedLanguageCode(for: "und"))
        XCTAssertNil(CohereLocalPlugin.normalizedLanguageCode(for: "ru"))
        XCTAssertNil(CohereLocalPlugin.normalizedLanguageCode(for: "hi"))
    }

    func testDigitalSilenceGuard() {
        XCTAssertTrue(CohereLocalPlugin.isDigitalSilence([]))
        XCTAssertTrue(CohereLocalPlugin.isDigitalSilence(Array(repeating: 0, count: 16_000)))
        XCTAssertFalse(CohereLocalPlugin.isDigitalSilence([0, 0.001, 0]))
    }

    func testRuntimeSupervisorStopsChildWhenHostProcessDisappears() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cohere-runtime-supervisor-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let childPIDFile = temporaryDirectory.appendingPathComponent("child.pid")
        let temporaryParent = Process()
        temporaryParent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        temporaryParent.arguments = ["1"]
        try temporaryParent.run()

        let process = CrispAsrServer.makeSupervisedProcess(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "echo $$ > \"$1\"; exec /bin/sleep 60",
                "cohere-runtime-child",
                childPIDFile.path,
            ],
            currentDirectoryURL: temporaryDirectory,
            environment: ProcessInfo.processInfo.environment,
            parentProcessIdentifier: temporaryParent.processIdentifier
        )
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
        }

        XCTAssertFalse(process.isRunning)
        let childPIDText = try String(contentsOf: childPIDFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let childPID = try XCTUnwrap(pid_t(childPIDText))
        XCTAssertEqual(kill(childPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testPortBindingFailureDetectionOnlyRetriesAddressConflicts() {
        XCTAssertTrue(
            CrispAsrServer.isPortBindingFailure(
                CohereLocalPluginError.runtimeExited("bind() failed: Address already in use")
            )
        )
        XCTAssertFalse(
            CrispAsrServer.isPortBindingFailure(
                CohereLocalPluginError.runtimeExited("Model file is invalid")
            )
        )
        XCTAssertFalse(
            CrispAsrServer.isPortBindingFailure(
                CohereLocalPluginError.runtimeStartupTimedOut("")
            )
        )
    }

    func testStableHostCompatibilityAvoidsPost16NetworkGuardSDKSymbol() throws {
        let pluginDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURLs = try FileManager.default.contentsOfDirectory(
            at: pluginDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }

        for sourceURL in sourceURLs {
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            XCTAssertFalse(
                source.contains("PluginHTTPClient.ensureNetworkAccessIsAllowed"),
                "\(sourceURL.lastPathComponent) must remain loadable by the declared TypeWhisper 1.6.0 host"
            )
        }
    }

    func testLocalNetworkPolicyAllowsNormalRuntime() {
        XCTAssertNoThrow(
            try CohereLocalNetworkAccessPolicy.ensureAccessIsAllowed(arguments: ["TypeWhisper"])
        )
    }

    func testLocalNetworkPolicyBlocksScreenshotAutomation() {
        XCTAssertThrowsError(
            try CohereLocalNetworkAccessPolicy.ensureAccessIsAllowed(
                arguments: ["TypeWhisper", "--store-screenshots"]
            )
        ) { error in
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
    }

    func testSelectingAnotherModelStopsServerThatIsStillStarting() async throws {
        let host = try PluginTestHostServices(shouldRestoreLoadedModelsPassively: false)
        let plugin = CohereLocalPlugin()
        plugin.activate(host: host)
        defer { plugin.deactivate() }

        let assets = CohereLocalModelAssets(
            pluginDataDirectory: host.pluginDataDirectory,
            model: CohereLocalPlugin.fastModel
        )
        for relativePath in [CohereLocalPlugin.fastModel.fileName]
            + CohereLocalModelAssets.sharedRequiredRelativePaths {
            let url = assets.rootDirectory.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("test".utf8).write(to: url)
        }

        let childPIDFile = assets.cacheDirectory.appendingPathComponent("test-child.pid")
        let runtimeScript = """
            #!/bin/sh
            echo $$ > "$CRISPASR_CACHE_DIR/test-child.pid"
            exec /bin/sleep 60
            """
        try Data(runtimeScript.utf8).write(to: assets.runtimeExecutableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: assets.runtimeExecutableURL.path
        )

        let loadTask = Task {
            await plugin.loadModel(allowDownloads: false)
        }
        let startupDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: childPIDFile.path),
              Date() < startupDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: childPIDFile.path))

        plugin.selectModel(CohereLocalPlugin.compactModel.id)
        await loadTask.value

        XCTAssertEqual(plugin.selectedModelId, CohereLocalPlugin.compactModel.id)
        XCTAssertEqual(plugin.modelState, .notLoaded)
        let childPIDText = try String(contentsOf: childPIDFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let childPID = try XCTUnwrap(pid_t(childPIDText))
        XCTAssertEqual(kill(childPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testDownloadedModelRequiresEveryPinnedAsset() throws {
        let host = try PluginTestHostServices(shouldRestoreLoadedModelsPassively: false)
        let assets = CohereLocalModelAssets(
            pluginDataDirectory: host.pluginDataDirectory,
            model: CohereLocalPlugin.fastModel
        )
        XCTAssertFalse(assets.isInstalled)

        for relativePath in [CohereLocalPlugin.fastModel.fileName]
            + CohereLocalModelAssets.sharedRequiredRelativePaths {
            let url = assets.rootDirectory.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("test".utf8).write(to: url)
        }

        XCTAssertTrue(assets.isInstalled)

        try FileManager.default.removeItem(
            at: assets.runtimeLibraryURL
        )
        XCTAssertFalse(assets.isInstalled)
    }

    func testLegacySharedModelDirectoryMigratesToNeutralDirectory() throws {
        let host = try PluginTestHostServices(shouldRestoreLoadedModelsPassively: false)
        let assets = CohereLocalModelAssets(
            pluginDataDirectory: host.pluginDataDirectory,
            model: CohereLocalPlugin.fastModel
        )
        try FileManager.default.createDirectory(
            at: assets.legacyRootDirectory,
            withIntermediateDirectories: true
        )
        let legacyMarker = assets.legacyRootDirectory.appendingPathComponent("marker")
        try Data("legacy".utf8).write(to: legacyMarker)

        XCTAssertFalse(FileManager.default.fileExists(atPath: assets.rootDirectory.path))
        XCTAssertFalse(assets.isInstalled)

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: assets.rootDirectory.appendingPathComponent("marker").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: assets.legacyRootDirectory.path)
        )
    }

    func testDownloadedModelCatalogAndDeletion() async throws {
        let host = try PluginTestHostServices(shouldRestoreLoadedModelsPassively: false)
        let plugin = CohereLocalPlugin()
        plugin.activate(host: host)
        let assets = CohereLocalModelAssets(
            pluginDataDirectory: host.pluginDataDirectory,
            model: CohereLocalPlugin.fastModel
        )

        for relativePath in [CohereLocalPlugin.fastModel.fileName]
            + CohereLocalModelAssets.sharedRequiredRelativePaths {
            let url = assets.rootDirectory.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("test".utf8).write(to: url)
        }

        XCTAssertEqual(plugin.downloadedModels.map(\.id), [CohereLocalPlugin.fastModel.id])

        try await plugin.deleteDownloadedModel(CohereLocalPlugin.fastModel.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: assets.rootDirectory.path))
        XCTAssertTrue(plugin.downloadedModels.isEmpty)
        XCTAssertEqual(plugin.selectedModelId, CohereLocalPlugin.fastModel.id)
        XCTAssertEqual(
            host.userDefault(forKey: "selectedModel") as? String,
            CohereLocalPlugin.fastModel.id
        )
        XCTAssertNil(host.userDefault(forKey: "loadedModel"))
    }

    func testCatalogOffersAllQuantizationModels() throws {
        let host = try PluginTestHostServices(shouldRestoreLoadedModelsPassively: false)
        let plugin = CohereLocalPlugin()
        plugin.activate(host: host)

        XCTAssertEqual(plugin.availableModels.map(\.id), CohereLocalPlugin.models.map(\.id))
        XCTAssertEqual(plugin.selectedModelId, CohereLocalPlugin.fastModel.id)

        plugin.selectModel(CohereLocalPlugin.compactModel.id)

        XCTAssertEqual(plugin.selectedModelId, CohereLocalPlugin.compactModel.id)
        XCTAssertEqual(
            host.userDefault(forKey: "selectedModel") as? String,
            CohereLocalPlugin.compactModel.id
        )
    }

    func testDeletingOneVariantPreservesOtherModelAndSharedRuntime() async throws {
        let host = try PluginTestHostServices(shouldRestoreLoadedModelsPassively: false)
        let plugin = CohereLocalPlugin()
        plugin.activate(host: host)
        let fastAssets = CohereLocalModelAssets(
            pluginDataDirectory: host.pluginDataDirectory,
            model: CohereLocalPlugin.fastModel
        )
        let compactAssets = CohereLocalModelAssets(
            pluginDataDirectory: host.pluginDataDirectory,
            model: CohereLocalPlugin.compactModel
        )

        for relativePath in CohereLocalModelAssets.sharedRequiredRelativePaths {
            let url = fastAssets.rootDirectory.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("test".utf8).write(to: url)
        }
        try Data("fast".utf8).write(to: fastAssets.modelFileURL)
        try Data("compact".utf8).write(to: compactAssets.modelFileURL)
        XCTAssertTrue(fastAssets.isInstalled)
        XCTAssertTrue(compactAssets.isInstalled)

        try await plugin.deleteDownloadedModel(CohereLocalPlugin.compactModel.id)

        XCTAssertTrue(fastAssets.isInstalled)
        XCTAssertFalse(compactAssets.isInstalled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fastAssets.runtimeExecutableURL.path))
    }

    func testPassiveRestorePolicyIsDeclaredForExternalPlugin() throws {
        let plugin = CohereLocalPlugin()
        let lifecycleAwarePlugin: any HostModelLifecyclePolicyAwarePlugin = plugin
        XCTAssertEqual(type(of: lifecycleAwarePlugin).pluginId, CohereLocalPlugin.pluginId)

        let host = try PluginTestHostServices(
            defaults: ["loadedModel": CohereLocalPlugin.fastModel.id],
            shouldRestoreLoadedModelsPassively: false
        )
        plugin.activate(host: host)

        XCTAssertFalse(plugin.isConfigured)
        XCTAssertEqual(plugin.modelState, .notLoaded)
    }

    func testPinnedModelRevisionAndFiles() {
        XCTAssertEqual(
            CohereLocalModelAssets.modelRevision,
            "2242638d5dfecc6f1dbe6c3a8713b97deb2e150f"
        )
        XCTAssertEqual(CohereLocalPlugin.models.map(\.id), [
            "cohere-transcribe-03-2026-q4_k",
            "cohere-transcribe-03-2026-q5_0",
            "cohere-transcribe-03-2026-q6_k",
            "cohere-transcribe-03-2026-q8_0",
        ])
        XCTAssertEqual(
            CohereLocalPlugin.compactModel.sha256,
            "2931fc0ac6d6708eef5389aadf1ebd5eec7b8e764bac385be585e910c0e7b410"
        )
        XCTAssertEqual(
            CohereLocalPlugin.fastModel.sha256,
            "a09696c5cc2ed5052bf290c4f2beb35abc69c0d6986842042d92bebb22c9184e"
        )
        XCTAssertEqual(
            CohereLocalPlugin.q6Model.sha256,
            "0ad2634e0ba34efa38a47d4fd4cf34d7a2d738d8486d83b8d5a178f823109c52"
        )
        XCTAssertEqual(
            CohereLocalPlugin.q8Model.sha256,
            "c8620cb182a7c04e311e6c24e478b94f7ecd7f1b5230bf39fffa8daf94644f51"
        )
        XCTAssertEqual(
            CohereLocalModelAssets.vadRevision,
            "9ffd54a1e1ee413ddf265af9913beaf518d1639b"
        )
        XCTAssertEqual(
            CohereLocalModelAssets.runtimeArchiveSHA256,
            "78397afd5aef2dbd6fa73f8d60800dd4d5725589fb4b04800efd2fb3ff88930c"
        )
        XCTAssertEqual(CohereLocalModelAssets.crispAsrVersion, "0.8.24")
    }

    func testLoadsStoredHuggingFaceTokenOnActivation() throws {
        let host = try PluginTestHostServices(
            secrets: [PluginHuggingFaceTokenHelper.storageKey: "hf_cohere_saved"],
            shouldRestoreLoadedModelsPassively: false
        )
        let plugin = CohereLocalPlugin()

        plugin.activate(host: host)

        XCTAssertEqual(plugin.huggingFaceToken, "hf_cohere_saved")
    }

    func testStoresAndClearsHuggingFaceTokenSecret() throws {
        let host = try PluginTestHostServices(shouldRestoreLoadedModelsPassively: false)
        let plugin = CohereLocalPlugin()
        plugin.activate(host: host)

        plugin.setHuggingFaceToken("  hf_cohere_saved  ")
        XCTAssertEqual(plugin.huggingFaceToken, "hf_cohere_saved")
        XCTAssertEqual(
            host.loadSecret(key: PluginHuggingFaceTokenHelper.storageKey),
            "hf_cohere_saved"
        )

        plugin.clearHuggingFaceToken()
        XCTAssertNil(plugin.huggingFaceToken)
        XCTAssertEqual(
            host.loadSecret(key: PluginHuggingFaceTokenHelper.storageKey),
            ""
        )
    }

    func testValidatesHuggingFaceTokenAgainstWhoAmIEndpoint() async throws {
        let plugin = CohereLocalPlugin()
        let requestRecorder = RequestRecorder()

        let isValid = await plugin.validateHuggingFaceToken("hf_cohere_test") { request in
            await requestRecorder.set(request)
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(#"{"name":"typewhisper","type":"user"}"#.utf8), response)
        }

        XCTAssertTrue(isValid)
        let recordedRequest = await requestRecorder.get()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer hf_cohere_test"
        )
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://huggingface.co/api/whoami-v2"
        )
        XCTAssertEqual(request.httpMethod, "GET")
    }

    func testGermanLocalizationCoversCurrentSourceAndModelMetadata() throws {
        let pluginDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: pluginDirectory.appendingPathComponent("CohereLocalPlugin.swift"),
            encoding: .utf8
        )
        let catalogData = try Data(
            contentsOf: pluginDirectory.appendingPathComponent("Localizable.xcstrings")
        )
        let catalog = try XCTUnwrap(
            JSONSerialization.jsonObject(with: catalogData) as? [String: Any]
        )
        let catalogStrings = try XCTUnwrap(catalog["strings"] as? [String: Any])

        var requiredKeys = Set(
            CohereLocalPlugin.models.flatMap(\.localizationKeys)
        )
        requiredKeys.insert(CohereLocalPlugin.pluginName)

        let patterns = [
            #"String\(localized:\s*"([^"]+)""#,
            #"Text\(\s*"([^"]+)"\s*,\s*bundle:\s*bundle"#,
            #"localizedString\(\s*"([^"]+)""#,
        ]
        for pattern in patterns {
            let expression = try NSRegularExpression(pattern: pattern)
            let range = NSRange(source.startIndex..., in: source)
            for match in expression.matches(in: source, range: range) {
                guard let captureRange = Range(match.range(at: 1), in: source) else {
                    continue
                }
                requiredKeys.insert(String(source[captureRange]))
            }
        }

        let missingKeys = requiredKeys.filter { catalogStrings[$0] == nil }.sorted()
        XCTAssertEqual(missingKeys, [], "Missing localization keys: \(missingKeys)")

        let incompleteGermanKeys = requiredKeys.filter { key in
            guard
                let entry = catalogStrings[key] as? [String: Any],
                let localizations = entry["localizations"] as? [String: Any],
                let german = localizations["de"] as? [String: Any],
                let stringUnit = german["stringUnit"] as? [String: Any],
                stringUnit["state"] as? String == "translated",
                let value = stringUnit["value"] as? String,
                !value.isEmpty
            else {
                return true
            }
            return false
        }.sorted()
        XCTAssertEqual(
            incompleteGermanKeys,
            [],
            "Missing German translations: \(incompleteGermanKeys)"
        )

        let directUserFacingLiteralPatterns = [
            #"onProgress\(\s*""#,
            #"message:\s*""#,
        ]
        for pattern in directUserFacingLiteralPatterns {
            let expression = try NSRegularExpression(pattern: pattern)
            let range = NSRange(source.startIndex..., in: source)
            XCTAssertNil(
                expression.firstMatch(in: source, range: range),
                "User-facing status strings must use the plugin localization bundle"
            )
        }
    }

}
