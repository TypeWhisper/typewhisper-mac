import XCTest
import TypeWhisperPluginSDK
import TypeWhisperPluginSDKTesting
@testable import Qwen3Plugin

final class Qwen3PluginTests: XCTestCase {
    func testAutoDetectDoesNotForceEnglish() {
        XCTAssertNil(Qwen3Plugin.resolveLanguageName(nil))
        XCTAssertNil(Qwen3Plugin.resolveLanguageName(""))
        XCTAssertNil(Qwen3Plugin.resolveLanguageName("   "))
    }

    func testFrenchLanguageResolvesToQwenLanguageName() {
        XCTAssertEqual(Qwen3Plugin.resolveLanguageName("fr"), "French")
        XCTAssertEqual(Qwen3Plugin.languageCode(forQwenLanguageName: "French"), "fr")
    }

    func testUnsupportedLanguageDoesNotFallbackToEnglish() {
        XCTAssertNil(Qwen3Plugin.resolveLanguageName("uk"))
        XCTAssertNil(Qwen3Plugin.languageCode(forQwenLanguageName: "French,English"))
    }

    func testSupportedLanguagesMatchQwenASRLanguageSetWithTagalogAlias() {
        XCTAssertEqual(
            Qwen3Plugin.qwenSupportedLanguageCodes,
            [
                "zh", "en", "yue", "ar", "de", "fr", "es", "pt", "id", "it",
                "ko", "ru", "th", "vi", "ja", "tr", "hi", "ms", "nl", "sv",
                "da", "fi", "pl", "cs", "fil", "tl", "fa", "el", "ro", "hu",
                "mk",
            ]
        )
        XCTAssertEqual(Qwen3Plugin.resolveLanguageName("fil"), "Filipino")
        XCTAssertEqual(Qwen3Plugin.resolveLanguageName("tl"), "Filipino")
    }

    func testContextFormatterIncludesExplicitPromptContext() {
        let context = Qwen3Plugin.contextBiasString(from: " Use TypeWhisper and MLX spelling. ")

        XCTAssertTrue(context.contains(Qwen3ContextBiasFormatter.baseInstruction))
        XCTAssertTrue(context.contains("Use TypeWhisper and MLX spelling."))
    }

    func testContextFormatterIncludesBaseInstructionWithoutDictionaryTerms() {
        XCTAssertEqual(
            Qwen3Plugin.contextBiasString(from: nil),
            Qwen3ContextBiasFormatter.baseInstruction
        )
    }

    func testDictionaryTermsAreNotAdvertisedForQwen3Prompting() {
        XCTAssertEqual(Qwen3Plugin().dictionaryTermsSupport, .unsupported)
    }

    func testFrenchTrailingOuiArtifactIsRemovedOnlyAfterSentencePunctuation() {
        XCTAssertEqual(
            QwenTranscriptGuard.removingLikelyTrailingArtifact(
                from: "Je vais envoyer le fichier. oui",
                languageName: "French"
            ),
            "Je vais envoyer le fichier."
        )
        XCTAssertEqual(
            QwenTranscriptGuard.removingLikelyTrailingArtifact(
                from: "Je vais envoyer le fichier. Oui.",
                languageName: "French"
            ),
            "Je vais envoyer le fichier."
        )
    }

    func testFrenchTrailingOuiArtifactIsRemovedAfterLongBarePhrase() {
        XCTAssertEqual(
            QwenTranscriptGuard.removingLikelyTrailingArtifact(
                from: "Je vais envoyer le fichier oui",
                languageName: "French"
            ),
            "Je vais envoyer le fichier"
        )
        XCTAssertEqual(
            QwenTranscriptGuard.removingLikelyTrailingArtifact(
                from: "Je vais envoyer le fichier, oui.",
                languageName: "French"
            ),
            "Je vais envoyer le fichier"
        )
        XCTAssertEqual(
            QwenTranscriptGuard.removingLikelyTrailingArtifact(
                from: "Je vais envoyer le fichier Oui!",
                languageName: "French"
            ),
            "Je vais envoyer le fichier"
        )
    }

    func testFrenchTrailingOuiGuardPreservesRealOuiUsages() {
        XCTAssertEqual(
            QwenTranscriptGuard.removingLikelyTrailingArtifact(from: "Oui.", languageName: "French"),
            "Oui."
        )
        XCTAssertEqual(
            QwenTranscriptGuard.removingLikelyTrailingArtifact(from: "Je pense que oui.", languageName: "French"),
            "Je pense que oui."
        )
        XCTAssertEqual(
            QwenTranscriptGuard.removingLikelyTrailingArtifact(from: "Je suis certain que oui.", languageName: "French"),
            "Je suis certain que oui."
        )
        XCTAssertEqual(
            QwenTranscriptGuard.removingLikelyTrailingArtifact(from: "Je confirme oui.", languageName: "French"),
            "Je confirme oui."
        )
        XCTAssertEqual(
            QwenTranscriptGuard.removingLikelyTrailingArtifact(from: "I will send it. oui", languageName: "English"),
            "I will send it. oui"
        )
    }

    func testModelCatalogIncludesRefreshedMLXVariants() {
        XCTAssertEqual(
            Qwen3Plugin.availableModels.map(\.id),
            [
                "qwen3-asr-0.6b-4bit",
                "qwen3-asr-0.6b-5bit",
                "qwen3-asr-0.6b-6bit",
                "qwen3-asr-0.6b-8bit",
                "qwen3-asr-0.6b-bf16",
                "qwen3-asr-1.7b-4bit",
                "qwen3-asr-1.7b-5bit",
                "qwen3-asr-1.7b-6bit",
                "qwen3-asr-1.7b-8bit",
                "qwen3-asr-1.7b-bf16",
            ]
        )
    }

    func testModelCatalogIncludesRecommendationGuidance() {
        let modelsById = Dictionary(
            uniqueKeysWithValues: Qwen3Plugin.availableModels.map { ($0.id, $0) }
        )

        XCTAssertEqual(modelsById["qwen3-asr-0.6b-6bit"]?.recommendation, .lowMemory)
        XCTAssertEqual(modelsById["qwen3-asr-1.7b-6bit"]?.recommendation, .balanced)
        XCTAssertEqual(modelsById["qwen3-asr-1.7b-8bit"]?.recommendation, .highQuality)
        XCTAssertTrue(Qwen3Plugin.availableModels.allSatisfy { !$0.usageHint.isEmpty })
        XCTAssertEqual(
            Qwen3Plugin.availableModels.filter { $0.recommendation != nil }.map(\.id),
            [
                "qwen3-asr-0.6b-6bit",
                "qwen3-asr-1.7b-6bit",
                "qwen3-asr-1.7b-8bit",
            ]
        )
    }

    func testRestoreCandidatesUseDownloadedSelectedModelWithoutLoadedModel() throws {
        let model = try XCTUnwrap(Qwen3Plugin.availableModels.first { $0.id == "qwen3-asr-1.7b-8bit" })
        let host = try PluginTestHostServices(
            defaults: ["selectedModel": model.id],
            shouldRestoreLoadedModelsPassively: false
        )
        let plugin = Qwen3Plugin()

        plugin.activate(host: host)
        try makeDownloadedModelDirectory(model, host: host)

        XCTAssertNil(host.userDefault(forKey: "loadedModel"))
        XCTAssertEqual(plugin.selectedModelId, model.id)
        XCTAssertEqual(plugin.downloadedModels.map(\.id), [model.id])
        XCTAssertEqual(plugin.restoreCandidateModelIds(allowDownloads: false), [model.id])
    }

    func testDownloadedModelSelectionIsRestoreableWithoutDownloadingFallbacks() throws {
        let model = try XCTUnwrap(Qwen3Plugin.availableModels.first { $0.id == "qwen3-asr-1.7b-8bit" })
        let host = try PluginTestHostServices(shouldRestoreLoadedModelsPassively: false)
        let plugin = Qwen3Plugin()

        plugin.activate(host: host)
        try makeDownloadedModelDirectory(model, host: host)

        XCTAssertTrue(plugin.shouldRestoreDownloadedSelection(model.id, previousLoadedModelId: nil))
        XCTAssertFalse(plugin.shouldRestoreDownloadedSelection(model.id, previousLoadedModelId: model.id))
        XCTAssertEqual(plugin.restoreCandidateModelIds(preferredModelId: model.id, allowDownloads: false), [model.id])
    }

    func testRestoreCandidatesFallBackToSoleDownloadedModelWithoutSelection() throws {
        let model = try XCTUnwrap(Qwen3Plugin.availableModels.first { $0.id == "qwen3-asr-1.7b-8bit" })
        let host = try PluginTestHostServices(shouldRestoreLoadedModelsPassively: false)
        let plugin = Qwen3Plugin()

        plugin.activate(host: host)
        try makeDownloadedModelDirectory(model, host: host)

        XCTAssertNil(plugin.selectedModelId)
        XCTAssertEqual(plugin.downloadedModels.map(\.id), [model.id])
        XCTAssertEqual(plugin.restoreCandidateModelIds(allowDownloads: false), [model.id])
    }

    func testUndownloadedModelSelectionDoesNotRestoreOrDownload() throws {
        let model = try XCTUnwrap(Qwen3Plugin.availableModels.first { $0.id == "qwen3-asr-1.7b-8bit" })
        let host = try PluginTestHostServices(shouldRestoreLoadedModelsPassively: false)
        let plugin = Qwen3Plugin()

        plugin.activate(host: host)
        plugin.selectModel(model.id)

        XCTAssertEqual(plugin.selectedModelId, model.id)
        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, model.id)
        XCTAssertFalse(plugin.shouldRestoreDownloadedSelection(model.id, previousLoadedModelId: nil))
        XCTAssertTrue(plugin.restoreCandidateModelIds(preferredModelId: model.id, allowDownloads: false).isEmpty)
        XCTAssertNil(host.userDefault(forKey: "loadedModel"))
    }

    func testRestoreCandidatesDoNotDefaultToUndownloadedModel() throws {
        let host = try PluginTestHostServices(shouldRestoreLoadedModelsPassively: false)
        let plugin = Qwen3Plugin()

        plugin.activate(host: host)

        XCTAssertNil(plugin.selectedModelId)
        XCTAssertTrue(plugin.downloadedModels.isEmpty)
        XCTAssertTrue(plugin.restoreCandidateModelIds(allowDownloads: false).isEmpty)
    }

    func testDeleteDownloadedModelRemovesCacheAndClearsSelection() async throws {
        let model = try XCTUnwrap(Qwen3Plugin.availableModels.first)
        let host = try PluginTestHostServices(
            defaults: ["selectedModel": model.id],
            shouldRestoreLoadedModelsPassively: false
        )
        let plugin = Qwen3Plugin()

        plugin.activate(host: host)
        host.setUserDefault(model.id, forKey: "loadedModel")

        let modelDirectory = try makeDownloadedModelDirectory(model, host: host)

        XCTAssertEqual(plugin.downloadedModels.map(\.id), [model.id])

        try await plugin.deleteDownloadedModel(model.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: modelDirectory.path))
        XCTAssertNil(plugin.selectedModelId)
        XCTAssertNil(host.userDefault(forKey: "selectedModel"))
        XCTAssertNil(host.userDefault(forKey: "loadedModel"))
    }

    @discardableResult
    private func makeDownloadedModelDirectory(
        _ model: Qwen3ModelDef,
        host: PluginTestHostServices
    ) throws -> URL {
        let modelDirectory = host.pluginDataDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("mlx-audio", isDirectory: true)
            .appendingPathComponent(model.repoId.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: modelDirectory.appendingPathComponent("model.safetensors"))
        return modelDirectory
    }
}
