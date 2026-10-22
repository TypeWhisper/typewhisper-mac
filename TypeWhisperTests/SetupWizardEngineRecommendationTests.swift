import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

final class SetupWizardEngineRecommendationTests: XCTestCase {
    private static let gigabyte: UInt64 = 1 << 30
    private static let pluginEngines: [SetupWizardLocalEngine] = [.gigaAM, .parakeet, .whisperKit, .qwen3]
    private static let fullCatalog = SetupWizardCatalogState.loaded(Set(pluginEngines.map(\.manifestId)))

    // MARK: - Spoken languages

    func testJapaneseRecommendsWhisperKitBecauseParakeetCoversOnlyEuropeanLanguages() {
        let choice = recommend(.specific(["ja"]))

        XCTAssertEqual(choice?.engine, .whisperKit)
        XCTAssertEqual(choice?.modelId, "openai_whisper-large-v3_turbo")
        XCTAssertEqual(choice?.reason, .supportsLanguages(["ja"]))
        XCTAssertEqual(choice?.availability, .available)
    }

    func testChineseRecommendsWhisperKit() {
        XCTAssertEqual(recommend(.specific(["zh"]))?.engine, .whisperKit)
    }

    func testHindiRecommendsWhisperKit() {
        XCTAssertEqual(recommend(.specific(["hi"]))?.engine, .whisperKit)
    }

    func testEnglishRecommendsParakeetUltra() {
        let choice = recommend(.specific(["en"]))

        XCTAssertEqual(choice?.engine, .parakeet)
        XCTAssertEqual(choice?.modelId, "parakeet-ultra")
        XCTAssertEqual(choice?.reason, .supportsLanguages(["en"]))
    }

    func testGermanRecommendsParakeetUltra() {
        let choice = recommend(.specific(["de"]))

        XCTAssertEqual(choice?.engine, .parakeet)
        XCTAssertEqual(choice?.modelId, "parakeet-ultra")
    }

    func testAutomaticDetectionKeepsParakeetAndNamesItsLanguageCount() {
        let choice = recommend(.automatic)

        XCTAssertEqual(choice?.engine, .parakeet)
        XCTAssertEqual(choice?.reason, .detectsLanguages(count: 25))
    }

    func testMixedEuropeanLanguagesRecommendParakeet() {
        let choice = recommend(.specific(["de", "en"]))

        XCTAssertEqual(choice?.engine, .parakeet)
        XCTAssertEqual(choice?.reason, .supportsLanguages(["de", "en"]))
    }

    func testMixedLanguagesNeedAnEngineThatSupportsAllOfThem() {
        let choice = recommend(.specific(["de", "ja"]))

        XCTAssertEqual(choice?.engine, .whisperKit)
        XCTAssertEqual(choice?.reason, .supportsLanguages(["de", "ja"]))
    }

    func testLanguageOnlyQwenSupportsRecommendsQwen() {
        let choice = recommend(.specific(["fil"]))

        XCTAssertEqual(choice?.engine, .qwen3)
        XCTAssertEqual(choice?.modelId, "qwen3-asr-1.7b-6bit")
    }

    func testRussianRecommendsGigaAM() {
        let choice = recommend(.specific(["ru"]))

        XCTAssertEqual(choice?.engine, .gigaAM)
        XCTAssertEqual(choice?.modelId, "gigaam-v3-e2e-rnnt")
        XCTAssertEqual(choice?.reason, .supportsLanguages(["ru"]))
        XCTAssertEqual(choice?.availability, .available)
    }

    func testGigaAMIsOnlyRecommendedWhenRussianIsTheOnlySpokenLanguage() {
        XCTAssertEqual(recommend(.automatic)?.engine, .parakeet, "automatic detection")
        XCTAssertEqual(recommend(.specific(["ru", "en"]))?.engine, .parakeet, "Russian and English")
        XCTAssertEqual(recommend(.specific(["ru", "ja"]))?.engine, .whisperKit, "Russian and Japanese")
    }

    func testRussianFallsBackToParakeetWhenGigaAMCannotBeDownloaded() {
        let catalog = SetupWizardCatalogState.loaded(Set([SetupWizardLocalEngine.parakeet, .whisperKit, .qwen3].map(\.manifestId)))

        XCTAssertEqual(recommend(.specific(["ru"]), catalog: catalog)?.engine, .parakeet)
    }

    func testLanguageNoLocalEngineSupportsIsAnExplicitLimitation() {
        let recommendation = SetupWizardEngineRecommendation.recommend(for: input(.specific(["or"])))

        XCTAssertEqual(recommendation, .limitation(.unsupportedLanguages(["or"])))
    }

    func testSpokenLanguagesComeFromTheLanguageSelectionAsBaseCodes() {
        XCTAssertEqual(SetupWizardSpokenLanguages(.auto), .automatic)
        XCTAssertEqual(SetupWizardSpokenLanguages(.exact("pt-BR")), .specific(["pt"]))
        XCTAssertEqual(SetupWizardSpokenLanguages(.hints(["en-US", "en", "zh_Hans"])), .specific(["en", "zh"]))
    }

    // MARK: - Hardware

    func testLowMemoryAppleSiliconStillGetsParakeetAndWhisperKit() {
        XCTAssertEqual(recommend(.specific(["de"]), memoryGB: 8)?.modelId, "parakeet-ultra")
        XCTAssertEqual(recommend(.specific(["ja"]), memoryGB: 8)?.modelId, "openai_whisper-large-v3_turbo")
    }

    func testLowMemoryAppleSiliconGetsTheSmallQwenModel() {
        let choice = recommend(.specific(["fil"]), memoryGB: 8)

        XCTAssertEqual(choice?.engine, .qwen3)
        XCTAssertEqual(choice?.modelId, "qwen3-asr-0.6b-6bit")
    }

    func testTypicalAppleSiliconGetsTheBalancedQwenModel() {
        XCTAssertEqual(recommend(.specific(["fil"]), memoryGB: 16)?.modelId, "qwen3-asr-1.7b-6bit")
    }

    func testMemoryBelowEveryModelLeavesOnlyAppleSpeech() {
        let recommendation = SetupWizardEngineRecommendation.recommend(for: input(
            .specific(["ja"]),
            memoryGB: 4,
            macOS: 26,
            engines: [.appleSpeech: appleSpeech(["en", "ja"])]
        ))

        XCTAssertEqual(recommendation.choice?.engine, .appleSpeech)
        XCTAssertNil(recommendation.choice?.modelId)
    }

    func testIntelBeforeMacOS26HasNoLocalEngine() {
        for languages in [SetupWizardSpokenLanguages.automatic, .specific(["de"]), .specific(["ja"])] {
            let recommendation = SetupWizardEngineRecommendation.recommend(for: input(
                languages,
                architecture: "x86_64",
                macOS: 15,
                engines: [.appleSpeech: SetupWizardEngineState(isInstalled: false)]
            ))
            XCTAssertEqual(recommendation, .limitation(.noLocalEngine), "\(languages)")
        }
    }

    func testIntelOnMacOS26RecommendsAppleSpeechForALanguageItSupports() {
        let choice = recommend(
            .specific(["ja"]),
            architecture: "x86_64",
            macOS: 26,
            engines: [.appleSpeech: appleSpeech(["en", "de", "ja"])]
        )

        XCTAssertEqual(choice?.engine, .appleSpeech)
        XCTAssertNil(choice?.modelId)
        XCTAssertEqual(choice?.reason, .supportsLanguages(["ja"]))
    }

    func testIntelOnMacOS26ExplainsALanguageAppleSpeechDoesNotSupport() {
        let recommendation = SetupWizardEngineRecommendation.recommend(for: input(
            .specific(["pl"]),
            architecture: "x86_64",
            macOS: 26,
            engines: [.appleSpeech: appleSpeech(["en", "de", "ja"])]
        ))

        XCTAssertEqual(recommendation, .limitation(.unsupportedLanguages(["pl"])))
    }

    func testIntelOnMacOS26WaitsUntilAppleSpeechReportsItsLanguages() {
        let recommendation = SetupWizardEngineRecommendation.recommend(for: input(
            .specific(["ja"]),
            architecture: "x86_64",
            macOS: 26,
            engines: [.appleSpeech: SetupWizardEngineState(isInstalled: true, isReady: true)]
        ))

        XCTAssertEqual(recommendation, .pending)
    }

    func testIntelOnMacOS26RecommendsAppleSpeechForAutomaticDetection() {
        let choice = recommend(
            .automatic,
            architecture: "x86_64",
            macOS: 26,
            engines: [.appleSpeech: appleSpeech(["en", "de"])]
        )

        XCTAssertEqual(choice?.engine, .appleSpeech)
        XCTAssertEqual(choice?.reason, .detectsLanguages(count: 2))
    }

    func testMacOS15DoesNotConsiderAppleSpeech() {
        let recommendation = SetupWizardEngineRecommendation.recommend(for: input(
            .specific(["or"]),
            macOS: 15,
            engines: [.appleSpeech: appleSpeech(["or"])]
        ))

        XCTAssertEqual(recommendation, .limitation(.unsupportedLanguages(["or"])))
    }

    func testAppleSpeechCoversALanguageOnlyItSupportsOnMacOS26() {
        let choice = recommend(.specific(["or"]), macOS: 26, engines: [.appleSpeech: appleSpeech(["en", "or"])])

        XCTAssertEqual(choice?.engine, .appleSpeech)
    }

    func testIntelOnMacOS26RecommendsAppleSpeechForAMixOfLanguagesItSupports() {
        // Like every local engine, Apple Speech transcribes the first language of a mix;
        // the app loads its model for the requested language before each transcription.
        let choice = recommend(
            .specific(["de", "ja"]),
            architecture: "x86_64",
            macOS: 26,
            engines: [.appleSpeech: appleSpeech(["en", "de", "ja"])]
        )

        XCTAssertEqual(choice?.engine, .appleSpeech)
        XCTAssertEqual(choice?.reason, .supportsLanguages(["de", "ja"]))
    }

    // MARK: - Plugins, catalog and network

    func testUnavailablePluginFallsBackToTheNextCompatibleEngine() {
        let catalog = SetupWizardCatalogState.loaded([
            SetupWizardLocalEngine.parakeet.manifestId,
            SetupWizardLocalEngine.qwen3.manifestId,
        ])

        let choice = recommend(.specific(["ja"]), catalog: catalog)

        XCTAssertEqual(choice?.engine, .qwen3)
        XCTAssertEqual(choice?.availability, .available)
    }

    func testMissingCatalogEntryKeepsTheRecommendationAndSaysItCannotBeDownloaded() {
        let choice = recommend(.specific(["de"]), catalog: .loaded([]))

        XCTAssertEqual(choice?.engine, .parakeet)
        XCTAssertEqual(choice?.availability, .notInCatalog)
    }

    func testMissingCatalogEntryDoesNotMatterForAnInstalledPlugin() {
        let choice = recommend(
            .specific(["de"]),
            engines: [.parakeet: SetupWizardEngineState(isInstalled: true)],
            catalog: .loaded([])
        )

        XCTAssertEqual(choice?.engine, .parakeet)
        XCTAssertEqual(choice?.availability, .available)
    }

    func testLoadingCatalogKeepsThePreferredEngine() {
        let choice = recommend(.specific(["ja"]), catalog: .loading)

        XCTAssertEqual(choice?.engine, .whisperKit)
        XCTAssertEqual(choice?.availability, .available)
    }

    func testUnreachableCatalogPrefersAnEngineThatNeedsNoDownload() {
        let choice = recommend(
            .specific(["ja"]),
            macOS: 26,
            engines: [.appleSpeech: appleSpeech(["en", "ja"])],
            catalog: .unavailable
        )

        XCTAssertEqual(choice?.engine, .appleSpeech)
        XCTAssertEqual(choice?.availability, .available)
    }

    func testUnreachableCatalogWithoutAlternativeIsExplicit() {
        let choice = recommend(.specific(["ja"]), catalog: .unavailable)

        XCTAssertEqual(choice?.engine, .whisperKit)
        XCTAssertEqual(choice?.availability, .catalogUnavailable)
    }

    func testOfflineWithoutInstalledEngineSaysTheDownloadNeedsAConnection() {
        let choice = recommend(.specific(["de"]), isOffline: true)

        XCTAssertEqual(choice?.engine, .parakeet)
        XCTAssertEqual(choice?.availability, .needsConnection)
    }

    func testOfflinePrefersADownloadedEngineThatSupportsTheLanguage() {
        let choice = recommend(
            .specific(["de"]),
            engines: [.whisperKit: SetupWizardEngineState(isInstalled: true, isReady: true)],
            isOffline: true
        )

        XCTAssertEqual(choice?.engine, .whisperKit)
        XCTAssertEqual(choice?.availability, .available)
    }

    func testOfflineDoesNotCountAnInstalledPluginWithoutModel() {
        let choice = recommend(
            .specific(["de"]),
            macOS: 26,
            engines: [
                .parakeet: SetupWizardEngineState(isInstalled: true),
                .appleSpeech: appleSpeech(["de"]),
            ],
            isOffline: true
        )

        XCTAssertEqual(choice?.engine, .appleSpeech)
    }

    func testOfflineKeepsAReadyParakeet() {
        let choice = recommend(
            .specific(["en"]),
            engines: [.parakeet: SetupWizardEngineState(isInstalled: true, isReady: true)],
            isOffline: true
        )

        XCTAssertEqual(choice?.engine, .parakeet)
        XCTAssertEqual(choice?.availability, .available)
    }

    func testOfflineActivatesAnInstalledEngineWhoseModelIsDownloaded() {
        let choice = recommend(
            .specific(["ja"]),
            engines: [.whisperKit: SetupWizardEngineState(
                isInstalled: true,
                downloadedModelIds: ["openai_whisper-large-v3_turbo"]
            )],
            isOffline: true
        )

        XCTAssertEqual(choice?.engine, .whisperKit)
        XCTAssertEqual(choice?.modelIsDownloaded, true)
        XCTAssertEqual(choice?.availability, .available)
    }

    func testOfflineInstalledEngineNeedsAConnectionForAModelThatIsNotDownloaded() {
        let choice = recommend(
            .specific(["ja"]),
            engines: [.whisperKit: SetupWizardEngineState(
                isInstalled: true,
                downloadedModelIds: ["openai_whisper-small"]
            )],
            isOffline: true
        )

        XCTAssertEqual(choice?.engine, .whisperKit)
        XCTAssertEqual(choice?.modelIsDownloaded, false)
        XCTAssertEqual(choice?.availability, .needsConnection)
    }

    func testOfflinePrefersAnInstalledEngineWhoseModelIsDownloaded() {
        // Parakeet does not report its downloaded models, so its model counts as a download.
        let choice = recommend(
            .specific(["de"]),
            engines: [
                .parakeet: SetupWizardEngineState(isInstalled: true),
                .whisperKit: SetupWizardEngineState(
                    isInstalled: true,
                    downloadedModelIds: ["openai_whisper-large-v3_turbo"]
                ),
            ],
            isOffline: true
        )

        XCTAssertEqual(choice?.engine, .whisperKit)
        XCTAssertEqual(choice?.availability, .available)
    }

    func testOfflineDownloadIsJudgedByTheModelTheActivationLoads() {
        // Activation keeps the model selected in the engine when it supports the language.
        let selectedModelOnDisk = recommend(
            .specific(["ja"]),
            engines: [.whisperKit: SetupWizardEngineState(
                isInstalled: true,
                selectedModelId: "openai_whisper-small",
                downloadedModelIds: ["openai_whisper-small"]
            )],
            isOffline: true
        )
        let otherModelOnDisk = recommend(
            .specific(["ja"]),
            engines: [.whisperKit: SetupWizardEngineState(
                isInstalled: true,
                selectedModelId: "openai_whisper-small",
                downloadedModelIds: ["openai_whisper-large-v3_turbo"]
            )],
            isOffline: true
        )

        XCTAssertEqual(selectedModelOnDisk?.availability, .available)
        XCTAssertEqual(otherModelOnDisk?.availability, .needsConnection)
    }

    func testActivationKeepsTheSelectedModelOnlyWhenItSupportsTheLanguages() {
        typealias Recommendation = SetupWizardEngineRecommendation

        XCTAssertEqual(
            Recommendation.activationModelId(
                selectedModelId: "parakeet-tdt-0.6b-v3",
                reportedLanguages: ["de", "en"],
                recommendedModelId: "parakeet-ultra",
                spokenLanguages: .specific(["de"])
            ),
            "parakeet-tdt-0.6b-v3"
        )
        // Parakeet v2 transcribes English only.
        XCTAssertEqual(
            Recommendation.activationModelId(
                selectedModelId: "parakeet-tdt-0.6b-v2",
                reportedLanguages: ["en"],
                recommendedModelId: "parakeet-ultra",
                spokenLanguages: .specific(["de"])
            ),
            "parakeet-ultra"
        )
        XCTAssertEqual(
            Recommendation.activationModelId(
                selectedModelId: nil,
                reportedLanguages: [],
                recommendedModelId: "parakeet-ultra",
                spokenLanguages: .specific(["de"])
            ),
            "parakeet-ultra"
        )
    }

    func testInstalledPluginWithoutTheRecommendedModelGetsAModelItOffers() {
        let choice = recommend(
            .specific(["de"]),
            engines: [.parakeet: SetupWizardEngineState(
                isInstalled: true,
                modelIds: ["parakeet-tdt-0.6b-v2", "parakeet-tdt-0.6b-v3"]
            )]
        )

        XCTAssertEqual(choice?.modelId, "parakeet-tdt-0.6b-v3")
    }

    // MARK: - Ready engine and selected engine

    func testReadyEngineFollowsTheRecommendationOrderAndTheLanguage() {
        let engines: [SetupWizardLocalEngine: SetupWizardEngineState] = [
            .parakeet: SetupWizardEngineState(isInstalled: true, isReady: true),
            .whisperKit: SetupWizardEngineState(isInstalled: true, isReady: true),
        ]

        XCTAssertEqual(SetupWizardEngineRecommendation.readyEngine(for: input(.automatic, engines: engines)), .parakeet)
        XCTAssertEqual(SetupWizardEngineRecommendation.readyEngine(for: input(.specific(["ja"]), engines: engines)), .whisperKit)
    }

    func testReadyGigaAMIsOnlyPickedForRussianAlone() {
        let engines: [SetupWizardLocalEngine: SetupWizardEngineState] = [
            .gigaAM: SetupWizardEngineState(isInstalled: true, isReady: true, reportedLanguages: ["ru"]),
            .parakeet: SetupWizardEngineState(isInstalled: true, isReady: true),
        ]

        XCTAssertEqual(SetupWizardEngineRecommendation.readyEngine(for: input(.specific(["ru"]), engines: engines)), .gigaAM)
        XCTAssertEqual(SetupWizardEngineRecommendation.readyEngine(for: input(.automatic, engines: engines)), .parakeet)
        XCTAssertEqual(SetupWizardEngineRecommendation.readyEngine(for: input(.specific(["ru", "en"]), engines: engines)), .parakeet)
    }

    func testReadyEngineIgnoresAnEngineWithoutTheLanguage() {
        let engines: [SetupWizardLocalEngine: SetupWizardEngineState] = [
            .parakeet: SetupWizardEngineState(isInstalled: true, isReady: true),
        ]

        XCTAssertNil(SetupWizardEngineRecommendation.readyEngine(for: input(.specific(["ja"]), engines: engines)))
    }

    func testReadyEngineIsJudgedByTheModelSelectedInIt() {
        // Parakeet with Fluid Speech Mini selected reports English only.
        let engines: [SetupWizardLocalEngine: SetupWizardEngineState] = [
            .parakeet: SetupWizardEngineState(isInstalled: true, isReady: true, reportedLanguages: ["en"]),
        ]

        XCTAssertNil(SetupWizardEngineRecommendation.readyEngine(for: input(.specific(["de"]), engines: engines)))
        XCTAssertEqual(SetupWizardEngineRecommendation.readyEngine(for: input(.specific(["en"]), engines: engines)), .parakeet)
    }

    func testRecommendationIsJudgedByTheModelItLoads() {
        let choice = recommend(
            .specific(["de"]),
            engines: [.parakeet: SetupWizardEngineState(isInstalled: true, isReady: true, reportedLanguages: ["en"])]
        )

        XCTAssertEqual(choice?.engine, .parakeet)
        XCTAssertEqual(choice?.modelId, "parakeet-ultra")
    }

    func testReadyEngineCanBeAppleSpeech() {
        let engines: [SetupWizardLocalEngine: SetupWizardEngineState] = [.appleSpeech: appleSpeech(["ja"])]

        XCTAssertEqual(
            SetupWizardEngineRecommendation.readyEngine(for: input(.specific(["ja"]), macOS: 26, engines: engines)),
            .appleSpeech
        )
    }

    func testUnsupportedLanguagesOfTheSelectedEngine() {
        XCTAssertEqual(
            SetupWizardEngineRecommendation.unsupportedLanguages(.specific(["de", "en"]), reportedLanguages: ["en"]),
            ["de"]
        )
        XCTAssertEqual(
            SetupWizardEngineRecommendation.unsupportedLanguages(.specific(["pt"]), reportedLanguages: ["pt-BR"]),
            []
        )
        XCTAssertEqual(SetupWizardEngineRecommendation.unsupportedLanguages(.automatic, reportedLanguages: ["en"]), [])
        // Engines that report no languages, such as most cloud engines, are not judged.
        XCTAssertEqual(SetupWizardEngineRecommendation.unsupportedLanguages(.specific(["ja"]), reportedLanguages: []), [])
    }

    func testSelectionKeepsAReadyEngineChosenBeforeEvenForAnotherLanguage() {
        let providerId = SetupWizardEngineSelection.preferredProviderId(
            selectedProviderId: SetupWizardLocalEngine.parakeet.providerId,
            selectedEngineReady: true,
            readyLocalProviderId: SetupWizardLocalEngine.whisperKit.providerId,
            appleSpeechAvailable: true
        )

        XCTAssertEqual(providerId, SetupWizardLocalEngine.parakeet.providerId)
    }

    func testSelectionReplacesTheAppleSpeechFallbackWithADownloadedEngineForTheLanguage() {
        let providerId = SetupWizardEngineSelection.preferredProviderId(
            selectedProviderId: SetupWizardAppleSpeechFallback.providerId,
            selectedEngineReady: true,
            readyLocalProviderId: SetupWizardLocalEngine.whisperKit.providerId,
            appleSpeechAvailable: true
        )

        XCTAssertEqual(providerId, SetupWizardLocalEngine.whisperKit.providerId)
    }

    func testSelectionDoesNotFallBackToAppleSpeechForALanguageItLacks() {
        let providerId = SetupWizardEngineSelection.preferredProviderId(
            selectedProviderId: nil,
            selectedEngineReady: false,
            readyLocalProviderId: nil,
            appleSpeechAvailable: false
        )

        XCTAssertNil(providerId)
    }

    func testAppleSpeechModelFollowsTheSpokenLanguage() {
        let models = [
            PluginModelInfo(id: "speechanalyzer-en_US", displayName: "English"),
            PluginModelInfo(id: "speechanalyzer-ja_JP", displayName: "Japanese"),
        ]

        XCTAssertEqual(
            SetupWizardAppleSpeechFallback.preferredModelId(
                from: models,
                spokenLanguage: "ja",
                localeIdentifier: "en_US",
                languageCode: "en"
            ),
            "speechanalyzer-ja_JP"
        )
    }

    func testAppleSpeechModelKeepsTheMacsLocaleForItsOwnLanguage() {
        let models = [
            PluginModelInfo(id: "speechanalyzer-de_DE", displayName: "German"),
            PluginModelInfo(id: "speechanalyzer-de_CH", displayName: "German (Switzerland)"),
        ]

        XCTAssertEqual(
            SetupWizardAppleSpeechFallback.preferredModelId(
                from: models,
                spokenLanguage: "de",
                localeIdentifier: "de_CH",
                languageCode: "de"
            ),
            "speechanalyzer-de_CH"
        )
    }

    func testAppleSpeechModelUsesTheMacsLocaleForALanguageItLacks() {
        let models = [
            PluginModelInfo(id: "speechanalyzer-en_US", displayName: "English"),
            PluginModelInfo(id: "speechanalyzer-de_DE", displayName: "German"),
        ]

        XCTAssertEqual(
            SetupWizardAppleSpeechFallback.preferredModelId(
                from: models,
                spokenLanguage: "hi",
                localeIdentifier: "de_DE",
                languageCode: "de"
            ),
            "speechanalyzer-de_DE"
        )
    }

    // MARK: - The table follows the plugins

    func testParakeetLanguagesAndModelsMatchThePlugin() throws {
        let languages = try XCTUnwrap(SetupWizardLocalEngine.parakeet.knownLanguages)
        XCTAssertEqual(Set(languages), Set(ParakeetVersion.ultra.supportedLanguages))
        XCTAssertEqual(Set(languages), Set(ParakeetVersion.v3.supportedLanguages))
        XCTAssertEqual(ParakeetPlugin().providerId, SetupWizardLocalEngine.parakeet.providerId)

        for model in SetupWizardLocalEngine.parakeet.models {
            let version = try XCTUnwrap(ParakeetVersion.from(modelId: model.id), model.id)
            XCTAssertEqual(Set(version.supportedLanguages), Set(languages), model.id)
            XCTAssertEqual(Self.gigabytes(version.modelDef.ramRequirement), model.minimumMemoryGB, model.id)
        }
        XCTAssertEqual(SetupWizardLocalEngine.parakeet.models.first?.id, ParakeetVersion.allCases.first?.modelDef.id)
    }

    func testWhisperKitLanguagesAndModelsMatchThePlugin() throws {
        let plugin = WhisperKitPlugin()
        XCTAssertEqual(SetupWizardLocalEngine.whisperKit.knownLanguages, plugin.supportedLanguages)
        XCTAssertEqual(plugin.providerId, SetupWizardLocalEngine.whisperKit.providerId)

        for model in SetupWizardLocalEngine.whisperKit.models {
            let definition = try XCTUnwrap(WhisperKitPlugin.availableModels.first { $0.id == model.id }, model.id)
            XCTAssertEqual(Self.gigabytes(definition.ramRequirement), model.minimumMemoryGB, model.id)
        }
    }

    func testQwenLanguagesAndModelsMatchThePlugin() throws {
        XCTAssertEqual(SetupWizardLocalEngine.qwen3.knownLanguages, Qwen3Plugin.qwenSupportedLanguageCodes)
        XCTAssertEqual(Qwen3Plugin().providerId, SetupWizardLocalEngine.qwen3.providerId)

        let models = SetupWizardLocalEngine.qwen3.models
        XCTAssertEqual(models.map(\.id), [
            Qwen3Plugin.availableModels.first { $0.recommendation == .balanced }?.id,
            Qwen3Plugin.availableModels.first { $0.recommendation == .lowMemory }?.id,
        ])
        for model in models {
            let definition = try XCTUnwrap(Qwen3Plugin.availableModels.first { $0.id == model.id }, model.id)
            XCTAssertEqual(Self.gigabytes(definition.ramRequirement), model.minimumMemoryGB, model.id)
        }
    }

    /// GigaAM is not part of the app's test target, so its source is read instead.
    func testGigaAMLanguagesAndModelsMatchThePlugin() throws {
        let url = TestSupport.repoRoot.appendingPathComponent("TypeWhisperPluginSDK/Plugins/GigaAMPlugin/GigaAMPlugin.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        XCTAssertEqual(SetupWizardLocalEngine.gigaAM.knownLanguages, ["ru"])
        XCTAssertTrue(source.contains(#"var supportedLanguages: [String] { ["ru"] }"#))
        XCTAssertTrue(source.contains(#"var providerId: String { "gigaam" }"#))
        XCTAssertEqual(SetupWizardLocalEngine.gigaAM.providerId, "gigaam")

        let model = try XCTUnwrap(SetupWizardLocalEngine.gigaAM.models.first)
        XCTAssertEqual(SetupWizardLocalEngine.gigaAM.models.count, 1)
        let definition = try XCTUnwrap(source.range(of: #"id: "\#(model.id)""#).map { String(source[$0.lowerBound...].prefix(400)) })
        let requirement = try XCTUnwrap(definition.range(of: #"ramRequirement: ""#).map { String(definition[$0.upperBound...]) })
        XCTAssertEqual(Self.gigabytes(requirement), model.minimumMemoryGB)
    }

    func testEngineRequirementsMatchThePluginManifests() throws {
        let directories: [SetupWizardLocalEngine: String] = [
            .gigaAM: "GigaAMPlugin",
            .parakeet: "ParakeetPlugin",
            .whisperKit: "WhisperKitPlugin",
            .qwen3: "Qwen3Plugin",
            .appleSpeech: "SpeechAnalyzerPlugin",
        ]

        for engine in SetupWizardLocalEngine.allCases {
            let directory = try XCTUnwrap(directories[engine])
            let url = TestSupport.repoRoot.appendingPathComponent("TypeWhisperPluginSDK/Plugins/\(directory)/manifest.json")
            let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: url))

            XCTAssertEqual(manifest.id, engine.manifestId, directory)
            XCTAssertEqual(manifest.name, engine.displayName, directory)
            XCTAssertEqual(manifest.supportedArchitectures == ["arm64"], engine.requiresAppleSilicon, directory)
            let minimumMajorVersion = manifest.minOSVersion?.split(separator: ".").first.flatMap { Int($0) }
            XCTAssertEqual(minimumMajorVersion, engine.minimumMacOSMajorVersion, directory)
        }
    }

    // MARK: - Helpers

    private func recommend(
        _ languages: SetupWizardSpokenLanguages,
        architecture: String = "arm64",
        memoryGB: UInt64 = 16,
        macOS: Int = 15,
        engines: [SetupWizardLocalEngine: SetupWizardEngineState] = [:],
        catalog: SetupWizardCatalogState = fullCatalog,
        isOffline: Bool = false
    ) -> SetupWizardEngineChoice? {
        SetupWizardEngineRecommendation.recommend(for: input(
            languages,
            architecture: architecture,
            memoryGB: memoryGB,
            macOS: macOS,
            engines: engines,
            catalog: catalog,
            isOffline: isOffline
        )).choice
    }

    private func input(
        _ languages: SetupWizardSpokenLanguages,
        architecture: String = "arm64",
        memoryGB: UInt64 = 16,
        macOS: Int = 15,
        engines: [SetupWizardLocalEngine: SetupWizardEngineState] = [:],
        catalog: SetupWizardCatalogState = fullCatalog,
        isOffline: Bool = false
    ) -> SetupWizardEngineRecommendationInput {
        SetupWizardEngineRecommendationInput(
            spokenLanguages: languages,
            architecture: architecture,
            physicalMemory: memoryGB * Self.gigabyte,
            macOSMajorVersion: macOS,
            engines: engines,
            catalog: catalog,
            isOffline: isOffline
        )
    }

    private func appleSpeech(_ languages: [String]) -> SetupWizardEngineState {
        SetupWizardEngineState(isInstalled: true, isReady: true, reportedLanguages: languages)
    }

    /// "8 GB+" as the plugins write their RAM requirements.
    private static func gigabytes(_ requirement: String) -> Int? {
        Int(requirement.prefix { $0.isNumber })
    }
}
