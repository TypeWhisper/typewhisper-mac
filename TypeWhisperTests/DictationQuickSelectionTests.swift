import XCTest
import CoreAudio
import TypeWhisperPluginSDK
@testable import TypeWhisper

@MainActor
final class DictationQuickSelectionTests: XCTestCase {
    // MARK: Lock

    func testSelectionsLockWhileDictationCapturesOrTranscribes() {
        for state: DictationViewModel.State in [.recording, .processing, .inserting, .promptProcessing("Fix")] {
            XCTAssertTrue(
                DictationQuickSelection.isLocked(dictationState: state, recorderState: .idle),
                "\(state)"
            )
        }
        for state: DictationViewModel.State in [.idle, .promptSelection("text"), .error("failed")] {
            XCTAssertFalse(
                DictationQuickSelection.isLocked(dictationState: state, recorderState: .idle),
                "\(state)"
            )
        }
    }

    func testSelectionsLockWhileRecorderIsActive() {
        XCTAssertTrue(DictationQuickSelection.isLocked(dictationState: .idle, recorderState: .recording))
        XCTAssertTrue(DictationQuickSelection.isLocked(dictationState: .idle, recorderState: .finalizing))
    }

    func testSelectionsLockWhileAnotherTranscriptionRuns() {
        XCTAssertTrue(DictationQuickSelection.isLocked(
            dictationState: .idle,
            recorderState: .idle,
            isTranscribingElsewhere: true
        ))
        XCTAssertFalse(DictationQuickSelection.isLocked(
            dictationState: .idle,
            recorderState: .idle,
            isTranscribingElsewhere: false
        ))
    }

    // MARK: Microphone

    func testMicrophoneOptionsMarkSelectionAndListDisconnectedPriorityDevices() {
        let options = DictationQuickSelection.microphoneOptions(
            devices: [
                AudioInputDevice(deviceID: AudioDeviceID(1), name: "MacBook Pro Microphone", uid: "built-in"),
                AudioInputDevice(deviceID: AudioDeviceID(2), name: "USB Mic", uid: "usb"),
            ],
            deviceTitle: \.name,
            priorityList: [
                AudioInputDevicePriorityItem(uid: "headset", name: "Headset"),
                AudioInputDevicePriorityItem(uid: "usb", name: "USB Mic"),
            ],
            selectedDeviceUID: "usb",
            systemDefaultName: "MacBook Pro Microphone"
        )

        XCTAssertEqual(options.map(\.id), ["system-default", "built-in", "usb", "headset"])
        XCTAssertEqual(options.filter(\.isSelected).map(\.id), ["usb"])
        XCTAssertEqual(options.filter { !$0.isEnabled }.map(\.id), ["headset"])
        XCTAssertTrue(options[0].title.contains("MacBook Pro Microphone"))
        XCTAssertTrue(options[3].title.contains("Headset"))
    }

    func testMicrophoneOptionsDisableDevicesRecordingCannotUse() {
        let options = DictationQuickSelection.microphoneOptions(
            devices: [
                AudioInputDevice(deviceID: AudioDeviceID(1), name: "MacBook Pro Microphone", uid: "built-in"),
                AudioInputDevice(deviceID: AudioDeviceID(2), name: "USB Mic", uid: "usb"),
            ],
            deviceTitle: \.name,
            isDeviceAvailable: { $0.uid != "built-in" },
            priorityList: [],
            selectedDeviceUID: "usb",
            systemDefaultName: nil
        )

        let builtIn = options.first { $0.id == "built-in" }
        XCTAssertEqual(builtIn?.isEnabled, false)
        XCTAssertNotEqual(builtIn?.title, "MacBook Pro Microphone", "the reason is shown")
        XCTAssertEqual(options.first { $0.id == "usb" }?.isEnabled, true)
    }

    func testMicrophoneOptionsSelectSystemDefaultWithoutExplicitDevice() {
        let options = DictationQuickSelection.microphoneOptions(
            devices: [AudioInputDevice(deviceID: AudioDeviceID(1), name: "Built-in", uid: "built-in")],
            deviceTitle: \.name,
            priorityList: [],
            selectedDeviceUID: nil,
            systemDefaultName: nil
        )

        XCTAssertEqual(options.filter(\.isSelected).map(\.value), [.systemDefault])
    }

    func testMicrophoneSummaryShowsDeviceUsedForNextRecording() {
        let explicit = ResolvedRecordingInputSelection(
            deviceUID: "usb",
            deviceID: AudioDeviceID(2),
            deviceName: "USB Mic",
            usesBluetoothTransport: false
        )
        XCTAssertEqual(
            DictationQuickSelection.microphoneSummary(resolvedSelection: explicit, systemDefaultName: "Built-in"),
            "USB Mic"
        )

        let fallback = DictationQuickSelection.microphoneSummary(
            resolvedSelection: .systemDefault,
            systemDefaultName: "Built-in"
        )
        XCTAssertTrue(fallback.contains("Built-in"))
        XCTAssertNotEqual(fallback, "Built-in")
    }

    // MARK: Language

    func testLanguageOptionsListOnlyModelLanguages() {
        let menu = DictationQuickSelection.languageOptions(
            globalSelection: .exact("en"),
            supportedCodes: ["en", "el"]
        )

        XCTAssertEqual(Set(menu.primary.map(\.id)), ["auto", "en", "el"])
        XCTAssertTrue(menu.more.isEmpty)
        XCTAssertEqual(menu.primary.filter(\.isSelected).map(\.value), [.exact("en")])
        XCTAssertTrue(menu.primary.allSatisfy(\.isEnabled))
    }

    func testLanguageOptionsKeepUnsupportedSelectionVisible() {
        let menu = DictationQuickSelection.languageOptions(
            globalSelection: .exact("de"),
            supportedCodes: ["en"]
        )

        let german = menu.primary.first { $0.id == "de" }
        XCTAssertEqual(german?.isSelected, true)
        XCTAssertNotEqual(german?.title, localizedAppLanguageName(for: "de"))
    }

    func testLanguageOptionsKeepLanguageSetAsSelectedEntry() {
        let selection = LanguageSelection.hints(["de", "en"])
        let menu = DictationQuickSelection.languageOptions(
            globalSelection: selection,
            supportedCodes: ["de", "en", "fr"]
        )

        XCTAssertEqual(menu.primary.filter(\.isSelected).map(\.value), [selection])
        XCTAssertEqual(menu.primary.first { $0.id == "auto" }?.isSelected, false)
    }

    func testLargeLanguageListsMoveNonFeaturedLanguagesIntoMoreMenu() {
        let menu = DictationQuickSelection.languageOptions(
            globalSelection: .exact("sv"),
            supportedCodes: defaultSpokenLanguageCodes
        )

        XCTAssertEqual(menu.primary.first?.id, "auto")
        XCTAssertEqual(menu.primary.dropFirst().first?.id, "de", "featured languages come first")
        XCTAssertTrue(menu.primary.contains { $0.id == "sv" && $0.isSelected }, "selection stays visible")
        XCTAssertTrue(menu.more.contains { $0.id == "nl" })
        XCTAssertFalse(menu.more.contains { $0.id == "sv" })
        XCTAssertEqual(menu.primary.count + menu.more.count, defaultSpokenLanguageCodes.count + 1)
    }

    func testLanguageSummaryAppliesModelNormalization() {
        XCTAssertEqual(
            DictationQuickSelection.languageSummary(for: .exact("de"), supportedCodes: ["en"]),
            DictationQuickSelection.languageSummary(for: .auto, supportedCodes: ["en"])
        )
        XCTAssertEqual(
            DictationQuickSelection.languageSummary(for: .exact("de"), supportedCodes: []),
            localizedAppLanguageName(for: "de")
        )
    }

    // MARK: Model

    func testLocalModelsThatNeedDownloadAreShownButNotSelectable() {
        let engine = DictationQuickSelectionEngine(
            providerId: "whisperkit",
            displayName: "WhisperKit",
            isAuthAvailable: true,
            isConfigured: true,
            managesLocalModels: true,
            selectedModelId: "large",
            restorableModelId: "large",
            models: [
                PluginModelInfo(id: "large", displayName: "Large", downloaded: true, loaded: true),
                PluginModelInfo(id: "small", displayName: "Small", downloaded: true, loaded: false),
                PluginModelInfo(id: "turbo", displayName: "Turbo", downloaded: false, loaded: false),
                PluginModelInfo(id: "unknown", displayName: "Unknown"),
            ]
        )

        let group = DictationQuickSelection.modelGroups(engines: [engine], selectedProviderId: "whisperkit")[0]

        XCTAssertEqual(group.options.map(\.id), ["whisperkit/large", "whisperkit/small"])
        XCTAssertEqual(group.options.filter(\.isSelected).map(\.id), ["whisperkit/large"])
        XCTAssertTrue(group.options.allSatisfy(\.isEnabled))
        XCTAssertEqual(group.setupRequiredOptions.map(\.id), ["whisperkit/turbo", "whisperkit/unknown"])
        XCTAssertTrue(group.setupRequiredOptions.allSatisfy { !$0.isEnabled })
        XCTAssertNotEqual(group.setupRequiredOptions[0].title, "Turbo", "download state is disclosed")
        XCTAssertNotEqual(group.setupRequiredOptions[1].title, "Unknown")
    }

    func testLocalEngineCanSwitchBackToItsRestorableModel() {
        let engine = DictationQuickSelectionEngine(
            providerId: "parakeet",
            displayName: "Parakeet",
            isAuthAvailable: true,
            isConfigured: false,
            managesLocalModels: true,
            selectedModelId: "v3",
            restorableModelId: "v3",
            models: [
                PluginModelInfo(id: "v2", displayName: "Parakeet v2"),
                PluginModelInfo(id: "v3", displayName: "Parakeet v3"),
            ]
        )

        let group = DictationQuickSelection.modelGroups(engines: [engine], selectedProviderId: "groq")[0]

        XCTAssertEqual(group.options.map(\.id), ["parakeet/v3"])
        XCTAssertTrue(group.options.allSatisfy { $0.isEnabled && !$0.isSelected })
        XCTAssertEqual(group.setupRequiredOptions.map(\.id), ["parakeet/v2"])
    }

    func testLocalEngineWithoutRestorableModelOffersNothingThatCouldDownload() {
        let engine = DictationQuickSelectionEngine(
            providerId: "parakeet",
            displayName: "Parakeet",
            isAuthAvailable: true,
            isConfigured: false,
            managesLocalModels: true,
            selectedModelId: "v3",
            restorableModelId: nil,
            models: [PluginModelInfo(id: "v3", displayName: "Parakeet v3")]
        )

        let group = DictationQuickSelection.modelGroups(engines: [engine], selectedProviderId: nil)[0]

        XCTAssertTrue(group.options.isEmpty)
        XCTAssertEqual(group.setupRequiredOptions.map(\.id), ["parakeet/v3"])
        XCTAssertFalse(group.setupRequiredOptions[0].isEnabled)
    }

    func testCloudEnginesNeedSetupAndAvailability() {
        let ready = DictationQuickSelectionEngine(
            providerId: "groq",
            displayName: "Groq",
            isAuthAvailable: true,
            isConfigured: true,
            managesLocalModels: false,
            selectedModelId: "whisper-large-v3",
            restorableModelId: nil,
            models: [
                PluginModelInfo(id: "whisper-large-v3", displayName: "Whisper Large v3"),
                PluginModelInfo(id: "whisper-large-v3-turbo", displayName: "Whisper Large v3 Turbo"),
            ]
        )
        let missingKey = DictationQuickSelectionEngine(
            providerId: "openai",
            displayName: "OpenAI",
            isAuthAvailable: true,
            isConfigured: false,
            managesLocalModels: false,
            selectedModelId: nil,
            restorableModelId: nil,
            models: [PluginModelInfo(id: "whisper-1", displayName: "Whisper")]
        )
        let unavailable = DictationQuickSelectionEngine(
            providerId: "cloud",
            displayName: "TypeWhisper Cloud",
            isAuthAvailable: false,
            isConfigured: true,
            managesLocalModels: false,
            selectedModelId: nil,
            restorableModelId: nil,
            models: [PluginModelInfo(id: "default", displayName: "Default")]
        )

        let groups = DictationQuickSelection.modelGroups(
            engines: [ready, missingKey, unavailable],
            selectedProviderId: "groq"
        )

        XCTAssertEqual(groups.map(\.id), ["groq", "openai", "cloud"])
        XCTAssertTrue(groups[0].options.allSatisfy(\.isEnabled))
        XCTAssertEqual(groups[0].options.filter(\.isSelected).map(\.value.modelId), ["whisper-large-v3"])
        XCTAssertEqual(groups[1].options.count, 1, "an engine that is not set up is one entry")
        XCTAssertNil(groups[1].options[0].value.modelId)
        XCTAssertFalse(groups[1].options[0].isEnabled)
        XCTAssertTrue(groups[1].setupRequiredOptions.isEmpty)
        XCTAssertEqual(groups[2].options.count, 1)
        XCTAssertNil(groups[2].options[0].value.modelId)
        XCTAssertFalse(groups[2].options[0].isEnabled)
    }

    func testLocalEngineDoesNotRestoreASelectionThatNeverLoaded() {
        // A v3-to-v2 switch failed: the selection moved to v2, but the engine restores v3.
        let engine = DictationQuickSelectionEngine(
            providerId: "parakeet",
            displayName: "Parakeet",
            isAuthAvailable: true,
            isConfigured: false,
            managesLocalModels: true,
            selectedModelId: "v2",
            restorableModelId: "v3",
            models: [
                PluginModelInfo(id: "v2", displayName: "Parakeet v2"),
                PluginModelInfo(id: "v3", displayName: "Parakeet v3"),
            ]
        )

        let group = DictationQuickSelection.modelGroups(engines: [engine], selectedProviderId: "groq")[0]

        XCTAssertTrue(group.options.isEmpty)
        XCTAssertEqual(group.setupRequiredOptions.map(\.id), ["parakeet/v2", "parakeet/v3"])
    }

    func testLocalEngineDoesNotRestoreAModelWhoseFilesAreGone() {
        // The plugin was reinstalled without its data, but the persisted IDs remain.
        let engine = DictationQuickSelectionEngine(
            providerId: "whisperkit",
            displayName: "WhisperKit",
            isAuthAvailable: true,
            isConfigured: false,
            managesLocalModels: true,
            selectedModelId: "large",
            restorableModelId: "large",
            models: [PluginModelInfo(id: "large", displayName: "Large", downloaded: false, loaded: false)]
        )

        let group = DictationQuickSelection.modelGroups(engines: [engine], selectedProviderId: "groq")[0]

        XCTAssertTrue(group.options.isEmpty)
        XCTAssertEqual(group.setupRequiredOptions.map(\.id), ["whisperkit/large"])
    }

    func testOnlyLifecycleAwareOrDeclaredLocalEnginesManageLocalModels() {
        XCTAssertTrue(DictationQuickSelection.managesLocalModels(isLifecycleAware: true, declaredHosting: nil))
        XCTAssertTrue(DictationQuickSelection.managesLocalModels(isLifecycleAware: false, declaredHosting: .local))
        XCTAssertFalse(
            DictationQuickSelection.managesLocalModels(isLifecycleAware: false, declaredHosting: nil),
            "remote engines like Cloudflare ASR declare no hosting"
        )
        XCTAssertFalse(DictationQuickSelection.managesLocalModels(isLifecycleAware: false, declaredHosting: .cloud))
    }

    func testRemoteEngineWithoutHostingMetadataKeepsFetchedModelsSelectable() {
        let engine = DictationQuickSelectionEngine(
            providerId: "cloudflare-asr",
            displayName: "Cloudflare ASR",
            isAuthAvailable: true,
            isConfigured: true,
            managesLocalModels: DictationQuickSelection.managesLocalModels(
                isLifecycleAware: false,
                declaredHosting: nil
            ),
            selectedModelId: "whisper-large-v3",
            restorableModelId: nil,
            models: [
                PluginModelInfo(id: "whisper-large-v3", displayName: "Whisper Large v3"),
                PluginModelInfo(id: "whisper-small", displayName: "Whisper Small"),
            ]
        )

        let group = DictationQuickSelection.modelGroups(engines: [engine], selectedProviderId: "cloudflare-asr")[0]

        XCTAssertEqual(group.options.map(\.id), ["cloudflare-asr/whisper-large-v3", "cloudflare-asr/whisper-small"])
        XCTAssertTrue(group.options.allSatisfy(\.isEnabled))
        XCTAssertTrue(group.setupRequiredOptions.isEmpty)
    }

    func testUnavailableWorkflowEngineIsNamed() {
        let summary = DictationQuickSelection.unavailableEngineSummary(engineName: "Groq")
        XCTAssertTrue(summary.hasPrefix("Groq"))
        XCTAssertNotEqual(summary, "Groq")
    }

    func testModelLabelSkipsRedundantProviderPrefix() {
        XCTAssertEqual(DictationQuickSelection.modelLabel(engine: "Groq", model: "whisper-large-v3"), "Groq • whisper-large-v3")
        XCTAssertEqual(DictationQuickSelection.modelLabel(engine: "Parakeet", model: "Parakeet v3"), "Parakeet v3")
        XCTAssertEqual(DictationQuickSelection.modelLabel(engine: nil, model: "Model"), "Model")
    }
}
