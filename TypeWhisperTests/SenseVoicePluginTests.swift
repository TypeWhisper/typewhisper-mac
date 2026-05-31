import Foundation
import TypeWhisperPluginSDK
import XCTest
@testable import TypeWhisper

final class SenseVoicePluginTests: XCTestCase {
    private final class MockEventBus: EventBusProtocol {
        @discardableResult
        func subscribe(handler: @escaping @Sendable (TypeWhisperEvent) async -> Void) -> UUID { UUID() }
        func unsubscribe(id: UUID) {}
    }

    private final class MockHostServices: HostServices, @unchecked Sendable {
        private var defaults: [String: Any]
        private var secrets: [String: String] = [:]

        let pluginDataDirectory: URL
        let eventBus: EventBusProtocol = MockEventBus()
        var activeAppBundleId: String?
        var activeAppName: String?
        var availableRuleNames: [String] = []
        private(set) var capabilitiesChangedCount = 0

        init(pluginDataDirectory: URL, defaults: [String: Any] = [:]) {
            self.pluginDataDirectory = pluginDataDirectory
            self.defaults = defaults
        }

        func storeSecret(key: String, value: String) throws { secrets[key] = value }
        func loadSecret(key: String) -> String? { secrets[key] }
        func userDefault(forKey key: String) -> Any? { defaults[key] }
        func setUserDefault(_ value: Any?, forKey key: String) { defaults[key] = value }
        func notifyCapabilitiesChanged() { capabilitiesChangedCount += 1 }
        func setStreamingDisplayActive(_ active: Bool) {}
    }

    private final class StubRecognizer: SenseVoiceRecognizing, @unchecked Sendable {
        let text: String

        init(text: String) {
            self.text = text
        }

        func transcribe(samples: [Float], sampleRate: Int) throws -> String {
            text
        }
    }

    private func makeHost(defaults: [String: Any] = [:]) throws -> MockHostServices {
        let directory = try TestSupport.makeTemporaryDirectory(prefix: "SenseVoicePluginTests")
        return MockHostServices(pluginDataDirectory: directory, defaults: defaults)
    }

    func testManifestDeclaresExperimentalLocalTranscriptionPlugin() throws {
        let manifestURL = TestSupport.repoRoot
            .appendingPathComponent("TypeWhisperPluginSDK/Plugins/SenseVoicePlugin/manifest.json")

        let manifest = try JSONDecoder().decode(
            PluginManifest.self,
            from: try Data(contentsOf: manifestURL)
        )

        XCTAssertEqual(manifest.id, "com.typewhisper.sensevoice")
        XCTAssertEqual(manifest.name, "SenseVoice (Experimental)")
        XCTAssertEqual(manifest.category, "transcription")
        XCTAssertEqual(manifest.hosting, .local)
        XCTAssertEqual(manifest.requiresAPIKey, false)
        XCTAssertEqual(manifest.minHostVersion, "1.4.0")
        XCTAssertEqual(manifest.supportedArchitectures, ["arm64"])
        XCTAssertEqual(manifest.principalClass, "SenseVoicePlugin")
    }

    func testDownloadRequiresCurrentModelLicenseAcceptance() throws {
        let host = try makeHost()
        defer { TestSupport.remove(host.pluginDataDirectory) }
        let plugin = SenseVoicePlugin()
        plugin.activate(host: host)

        XCTAssertFalse(plugin.hasAcceptedCurrentModelLicense)
        XCTAssertFalse(plugin.canDownloadModel)

        plugin.acceptCurrentModelLicense(now: Date(timeIntervalSince1970: 1_716_000_000))

        XCTAssertTrue(plugin.hasAcceptedCurrentModelLicense)
        XCTAssertTrue(plugin.canDownloadModel)
        XCTAssertEqual(host.userDefault(forKey: "acceptedModelLicenseId") as? String, SenseVoiceModelLicense.id)
        XCTAssertEqual(host.userDefault(forKey: "acceptedModelLicenseRevision") as? String, SenseVoiceModelLicense.revision)
        XCTAssertEqual(host.userDefault(forKey: "acceptedModelLicenseAt") as? String, "2024-05-18T02:40:00Z")
    }

    func testChangedModelLicenseRevisionInvalidatesPriorAcceptance() throws {
        let host = try makeHost(defaults: [
            "acceptedModelLicenseId": SenseVoiceModelLicense.id,
            "acceptedModelLicenseRevision": "old-revision",
            "acceptedModelLicenseAt": "2024-05-18T08:00:00Z",
        ])
        defer { TestSupport.remove(host.pluginDataDirectory) }
        let plugin = SenseVoicePlugin()
        plugin.activate(host: host)

        XCTAssertFalse(plugin.hasAcceptedCurrentModelLicense)
        XCTAssertFalse(plugin.canDownloadModel)
    }

    func testDownloadWithoutAcceptedLicenseDoesNotCreateModelDirectory() async throws {
        let host = try makeHost()
        defer { TestSupport.remove(host.pluginDataDirectory) }
        let plugin = SenseVoicePlugin()
        plugin.activate(host: host)

        await plugin.downloadModel()

        XCTAssertEqual(plugin.modelState, .error(SenseVoicePluginError.licenseNotAccepted.localizedDescription))
        let modelDirectory = SenseVoiceModelAssetManager(rootDirectory: host.pluginDataDirectory).modelDirectory
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelDirectory.path))
    }

    func testPluginAdvertisesLimitedExperimentalCapabilities() throws {
        let plugin = SenseVoicePlugin()

        XCTAssertEqual(plugin.providerId, "sensevoice")
        XCTAssertEqual(plugin.providerDisplayName, "SenseVoice (Experimental)")
        XCTAssertFalse(plugin.supportsTranslation)
        XCTAssertFalse(plugin.supportsStreaming)
        XCTAssertEqual(plugin.dictionaryTermsSupport, .unsupported)
        XCTAssertEqual(plugin.supportedLanguages, ["zh", "en", "ja", "ko", "yue"])
        XCTAssertEqual(plugin.availableModels.first?.id, SenseVoiceModelAssetManager.modelId)
        XCTAssertEqual(plugin.availableModels.first?.languageCount, 5)
    }

    func testLanguageResolverUsesSupportedPrimaryLanguageOrAuto() {
        XCTAssertEqual(SenseVoiceLanguageResolver.runtimeLanguage(for: "en-US"), "en")
        XCTAssertEqual(SenseVoiceLanguageResolver.runtimeLanguage(for: "zh-Hans"), "zh")
        XCTAssertEqual(SenseVoiceLanguageResolver.runtimeLanguage(for: "yue"), "yue")
        XCTAssertEqual(SenseVoiceLanguageResolver.runtimeLanguage(for: "de-DE"), "auto")
        XCTAssertEqual(SenseVoiceLanguageResolver.runtimeLanguage(for: nil), "auto")
    }

    func testModelInstallerRequiresSafeCompleteAssetSet() throws {
        let root = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: FileManager.default.temporaryDirectory,
            create: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let installer = SenseVoiceModelAssetManager(rootDirectory: root)
        let files = [
            "model.int8.onnx": Data("model".utf8),
            "tokens.txt": Data("tokens".utf8),
        ]

        try installer.install(files: files, licenseAccepted: true)

        XCTAssertTrue(installer.hasDownloadedModel())
        XCTAssertTrue(FileManager.default.fileExists(atPath: installer.modelDirectory.appendingPathComponent("model.int8.onnx").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: installer.modelDirectory.appendingPathComponent("tokens.txt").path))
    }

    func testModelInstallerDoesNotWriteFinalDirectoryWhenRequiredFileIsMissing() throws {
        let root = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: FileManager.default.temporaryDirectory,
            create: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let installer = SenseVoiceModelAssetManager(rootDirectory: root)
        let files = [
            "model.int8.onnx": Data("model".utf8),
        ]

        XCTAssertThrowsError(try installer.install(files: files, licenseAccepted: true)) { error in
            XCTAssertEqual(error as? SenseVoicePluginError, .incompleteModelAssets)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: installer.modelDirectory.path))
    }

    func testSafeRelativePathRejectsTraversalAndAbsolutePaths() {
        XCTAssertTrue(SenseVoiceModelAssetManager.isSafeRelativePath("model.int8.onnx"))
        XCTAssertTrue(SenseVoiceModelAssetManager.isSafeRelativePath("nested/file.txt"))
        XCTAssertFalse(SenseVoiceModelAssetManager.isSafeRelativePath("/tmp/model.onnx"))
        XCTAssertFalse(SenseVoiceModelAssetManager.isSafeRelativePath("../model.onnx"))
        XCTAssertFalse(SenseVoiceModelAssetManager.isSafeRelativePath("nested/../model.onnx"))
        XCTAssertFalse(SenseVoiceModelAssetManager.isSafeRelativePath(""))
    }

    func testTranscribeUsesInjectedRuntimeAndRejectsTranslation() async throws {
        let host = try makeHost()
        defer { TestSupport.remove(host.pluginDataDirectory) }
        let installer = SenseVoiceModelAssetManager(rootDirectory: host.pluginDataDirectory)
        try installer.install(files: [
            "model.int8.onnx": Data("model".utf8),
            "tokens.txt": Data("tokens".utf8),
        ], licenseAccepted: true)

        let plugin = SenseVoicePlugin { _, language in
            XCTAssertEqual(language, "en")
            return StubRecognizer(text: "Recovered text")
        }
        plugin.activate(host: host)

        let audio = AudioData(samples: [0, 0, 0], wavData: Data(), duration: 0.0001875)
        let result = try await plugin.transcribe(audio: audio, language: "en-US", translate: false, prompt: nil)

        XCTAssertEqual(result.text, "Recovered text")
        XCTAssertEqual(result.detectedLanguage, "en")

        do {
            _ = try await plugin.transcribe(audio: audio, language: "en", translate: true, prompt: nil)
            XCTFail("Expected translation to fail")
        } catch {
            XCTAssertEqual(error as? SenseVoicePluginError, .unsupportedTranslation)
        }
    }
}
