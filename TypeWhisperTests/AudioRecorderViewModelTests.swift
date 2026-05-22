import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

@MainActor
final class AudioRecorderViewModelTests: XCTestCase {
    func testRecorderSelectionPersistsSeparatelyFromGlobalDefault() throws {
        try preserveStandardDefaults()
        let defaults = try makeDefaults()
        setupPluginManager()
        UserDefaults.standard.set("groq", forKey: UserDefaultsKeys.selectedEngine)

        let viewModel = makeViewModel(defaults: defaults)

        viewModel.selectedEngine = "assemblyai"
        viewModel.selectedModel = "universal-3-pro"

        XCTAssertEqual(defaults.string(forKey: UserDefaultsKeys.recorderTranscriptionEngine), "assemblyai")
        XCTAssertEqual(defaults.string(forKey: UserDefaultsKeys.recorderTranscriptionModel), "universal-3-pro")
        XCTAssertEqual(UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedEngine), "groq")
        XCTAssertEqual(viewModel.effectiveProviderId, "assemblyai")
        XCTAssertEqual(viewModel.effectiveModelId, "universal-3-pro")
    }

    func testRecorderSelectionFallsBackToGlobalDefaultWhenUnset() throws {
        try preserveStandardDefaults()
        let defaults = try makeDefaults()
        setupPluginManager()
        UserDefaults.standard.set("groq", forKey: UserDefaultsKeys.selectedEngine)

        let viewModel = makeViewModel(defaults: defaults)

        XCTAssertNil(viewModel.selectedEngine)
        XCTAssertNil(viewModel.selectedModel)
        XCTAssertEqual(viewModel.effectiveProviderId, "groq")
        XCTAssertEqual(viewModel.effectiveModelId, "whisper-large-v3")
        XCTAssertEqual(viewModel.resolvedEngine?.providerId, "groq")
    }

    func testRecorderSelectionUsesModelOverrideWithDefaultEngine() throws {
        try preserveStandardDefaults()
        let defaults = try makeDefaults()
        setupPluginManager()
        UserDefaults.standard.set("groq", forKey: UserDefaultsKeys.selectedEngine)

        let viewModel = makeViewModel(defaults: defaults)
        viewModel.selectedModel = "whisper-small"

        XCTAssertNil(viewModel.selectedEngine)
        XCTAssertEqual(viewModel.effectiveProviderId, "groq")
        XCTAssertEqual(viewModel.effectiveModelId, "whisper-small")
        XCTAssertEqual(defaults.string(forKey: UserDefaultsKeys.recorderTranscriptionModel), "whisper-small")
        XCTAssertEqual(UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedEngine), "groq")
    }

    func testRecorderSelectionClearsMissingSavedEngineAndModel() throws {
        try preserveStandardDefaults()
        let defaults = try makeDefaults()
        defaults.set("missing-engine", forKey: UserDefaultsKeys.recorderTranscriptionEngine)
        defaults.set("old-model", forKey: UserDefaultsKeys.recorderTranscriptionModel)
        setupPluginManager()
        UserDefaults.standard.set("groq", forKey: UserDefaultsKeys.selectedEngine)

        let viewModel = makeViewModel(defaults: defaults)
        viewModel.reconcileSelectionWithAvailablePlugins()

        XCTAssertNil(viewModel.selectedEngine)
        XCTAssertNil(viewModel.selectedModel)
        XCTAssertNil(defaults.string(forKey: UserDefaultsKeys.recorderTranscriptionEngine))
        XCTAssertNil(defaults.string(forKey: UserDefaultsKeys.recorderTranscriptionModel))
        XCTAssertEqual(viewModel.effectiveProviderId, "groq")
    }

    private func makeViewModel(defaults: UserDefaults) -> AudioRecorderViewModel {
        AudioRecorderViewModel(
            recorderService: AudioRecorderService(),
            modelManager: ModelManagerService(),
            dictionaryService: DictionaryService(appSupportDirectory: makeTemporaryDirectory()),
            defaults: defaults
        )
    }

    private func setupPluginManager() {
        let previousPluginManager = PluginManager.shared
        addTeardownBlock {
            PluginManager.shared = previousPluginManager
        }

        let appSupportDirectory = makeTemporaryDirectory()
        let pluginManager = PluginManager(appSupportDirectory: appSupportDirectory)
        pluginManager.loadedPlugins = [
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.groq",
                    name: "Groq",
                    version: "1.0.0",
                    principalClass: "AudioRecorderMockTranscriptionPlugin"
                ),
                instance: AudioRecorderMockTranscriptionPlugin(
                    providerId: "groq",
                    displayName: "Groq",
                    models: [
                        PluginModelInfo(id: "whisper-large-v3", displayName: "Whisper Large V3"),
                        PluginModelInfo(id: "whisper-small", displayName: "Whisper Small")
                    ],
                    selectedModelId: "whisper-large-v3"
                ),
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            ),
            LoadedPlugin(
                manifest: PluginManifest(
                    id: "com.typewhisper.mock.assemblyai",
                    name: "AssemblyAI",
                    version: "1.0.0",
                    principalClass: "AudioRecorderMockTranscriptionPlugin"
                ),
                instance: AudioRecorderMockTranscriptionPlugin(
                    providerId: "assemblyai",
                    displayName: "AssemblyAI",
                    models: [
                        PluginModelInfo(id: "universal-3-pro", displayName: "Universal-3 Pro"),
                        PluginModelInfo(id: "universal-2", displayName: "Universal-2")
                    ],
                    selectedModelId: "universal-2"
                ),
                bundle: Bundle.main,
                sourceURL: appSupportDirectory,
                isEnabled: true
            )
        ]
        PluginManager.shared = pluginManager
    }

    private func preserveStandardDefaults() throws {
        let keys = [
            UserDefaultsKeys.selectedEngine,
            UserDefaultsKeys.selectedModelId
        ]
        let originals = Dictionary(uniqueKeysWithValues: keys.map { ($0, UserDefaults.standard.object(forKey: $0)) })
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        addTeardownBlock {
            for key in keys {
                if let value = originals[key] {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }
    }

    private func makeDefaults() throws -> UserDefaults {
        let name = "AudioRecorderViewModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
        }
        return defaults
    }

    private func makeTemporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioRecorderViewModelTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}

private final class AudioRecorderMockTranscriptionPlugin: NSObject, TranscriptionEnginePlugin, @unchecked Sendable {
    static let pluginId = "com.typewhisper.mock.audio-recorder"
    static let pluginName = "Audio Recorder Mock"

    let providerId: String
    let providerDisplayName: String
    let transcriptionModels: [PluginModelInfo]
    var selectedModelId: String?
    var isConfigured = true
    var supportsTranslation = true

    required override init() {
        self.providerId = "mock"
        self.providerDisplayName = "Mock"
        self.transcriptionModels = []
        self.selectedModelId = nil
        super.init()
    }

    init(
        providerId: String,
        displayName: String,
        models: [PluginModelInfo],
        selectedModelId: String?
    ) {
        self.providerId = providerId
        self.providerDisplayName = displayName
        self.transcriptionModels = models
        self.selectedModelId = selectedModelId
        super.init()
    }

    func activate(host: HostServices) {}
    func deactivate() {}

    func selectModel(_ modelId: String) {
        selectedModelId = modelId
    }

    func transcribe(
        audio: AudioData,
        language: String?,
        translate: Bool,
        prompt: String?
    ) async throws -> PluginTranscriptionResult {
        PluginTranscriptionResult(text: "mock transcription")
    }
}
