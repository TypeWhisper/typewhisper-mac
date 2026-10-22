import Foundation
import Network
import TypeWhisperPluginSDK

// Issue #1332: the setup wizard recommends a local engine for the language the user
// dictates in, on the hardware at hand. The recommendation is a pure function of the
// inputs below, so every combination can be tested without plugins or a network.

// MARK: - Spoken languages

/// The languages to recommend an engine for, taken from the spoken language setting.
/// The app language is not an input: it does not say which language someone dictates in.
enum SetupWizardSpokenLanguages: Equatable, Sendable {
    /// Automatic detection, so the language is not known.
    case automatic
    /// One or more languages as base language codes, "pt" for "pt-BR".
    case specific([String])

    init(_ selection: LanguageSelection) {
        var codes: [String] = []
        for code in selection.selectedCodes.map(Self.baseLanguageCode) where !code.isEmpty && !codes.contains(code) {
            codes.append(code)
        }
        self = codes.isEmpty ? .automatic : .specific(codes)
    }

    var codes: [String] {
        switch self {
        case .automatic: []
        case .specific(let codes): codes
        }
    }

    static func baseLanguageCode(_ code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? trimmed
    }
}

// MARK: - Engine table

/// Local engines the wizard can recommend, in the order it prefers them when several
/// support the spoken languages. GigaAM transcribes Russian only, with punctuation, so it
/// comes first but only counts when Russian is the only spoken language. Parakeet comes
/// next because it transcribes far faster than the others in the benchmark at similar
/// accuracy in English, German and Russian. WhisperKit covers the most languages. Qwen3
/// adds Filipino. Apple Speech needs no plugin download but was the least accurate where
/// measured. None of them takes language hints: with a mix of languages, each transcribes
/// the first one, and Apple Speech loads the system model for it before each transcription.
enum SetupWizardLocalEngine: String, CaseIterable, Sendable {
    case gigaAM
    case parakeet
    case whisperKit
    case qwen3
    case appleSpeech
}

/// A model the wizard downloads for an engine, with the plugin's own memory requirement.
struct SetupWizardEngineModel: Equatable, Sendable {
    let id: String
    let minimumMemoryGB: Int
}

extension SetupWizardLocalEngine {
    var providerId: String {
        switch self {
        case .gigaAM: "gigaam"
        case .parakeet: SetupWizardParakeetRecommendation.providerId
        case .whisperKit: "whisper"
        case .qwen3: "qwen3"
        case .appleSpeech: AppleSpeechModelSelection.providerId
        }
    }

    var manifestId: String {
        switch self {
        case .gigaAM: "com.typewhisper.gigaam"
        case .parakeet: SetupWizardParakeetRecommendation.manifestId
        case .whisperKit: "com.typewhisper.whisperkit"
        case .qwen3: "com.typewhisper.qwen3"
        case .appleSpeech: AppleSpeechModelSelection.manifestId
        }
    }

    var displayName: String {
        switch self {
        case .gigaAM: "GigaAM"
        case .parakeet: "Parakeet"
        case .whisperKit: "WhisperKit"
        case .qwen3: "Qwen3 ASR"
        case .appleSpeech: "Apple Speech"
        }
    }

    /// From the plugin manifests: GigaAM, Parakeet, WhisperKit and Qwen3 ship for arm64 only.
    var requiresAppleSilicon: Bool {
        self != .appleSpeech
    }

    /// An engine for a single language. It is recommended only when that language is the
    /// only spoken language, never for automatic detection.
    var isSingleLanguageEngine: Bool {
        self == .gigaAM
    }

    /// From the plugin manifests (`minOSVersion`).
    var minimumMacOSMajorVersion: Int {
        self == .appleSpeech ? 26 : 14
    }

    /// Languages of the models below, as the plugins declare them. Nil for Apple Speech,
    /// whose languages only the installed engine knows, because they depend on the system.
    /// `SetupWizardEngineRecommendationTests` checks these lists against the plugins.
    var knownLanguages: [String]? {
        switch self {
        case .gigaAM:
            // GigaAMPlugin.supportedLanguages
            ["ru"]
        case .parakeet:
            // ParakeetVersion.ultra and .v3
            ["bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it", "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk"]
        case .whisperKit:
            // WhisperKitPlugin.supportedLanguages, the list the language picker also falls back to
            defaultSpokenLanguageCodes
        case .qwen3:
            // Qwen3Plugin.qwenSupportedLanguageCodes
            [
                "zh", "en", "yue", "ar", "de", "fr", "es", "pt", "id", "it",
                "ko", "ru", "th", "vi", "ja", "tr", "hi", "ms", "nl", "sv",
                "da", "fi", "pl", "cs", "fil", "tl", "fa", "el", "ro", "hu",
                "mk",
            ]
        case .appleSpeech:
            nil
        }
    }

    /// Models to download, best first. The first one that fits the Mac's memory is used.
    /// Apple Speech picks a model for the spoken language itself.
    var models: [SetupWizardEngineModel] {
        switch self {
        case .gigaAM:
            [SetupWizardEngineModel(id: "gigaam-v3-e2e-rnnt", minimumMemoryGB: 2)]
        case .parakeet:
            // Ultra is the plugin's default; v3 only for an installed plugin without Ultra.
            [
                SetupWizardEngineModel(id: "parakeet-ultra", minimumMemoryGB: 8),
                SetupWizardEngineModel(id: "parakeet-tdt-0.6b-v3", minimumMemoryGB: 8),
            ]
        case .whisperKit:
            [SetupWizardEngineModel(id: "openai_whisper-large-v3_turbo", minimumMemoryGB: 8)]
        case .qwen3:
            // The plugin's "Best default" and "8 GB pick".
            [
                SetupWizardEngineModel(id: "qwen3-asr-1.7b-6bit", minimumMemoryGB: 16),
                SetupWizardEngineModel(id: "qwen3-asr-0.6b-6bit", minimumMemoryGB: 8),
            ]
        case .appleSpeech:
            []
        }
    }

    static func engine(forProviderId providerId: String) -> SetupWizardLocalEngine? {
        allCases.first { $0.providerId == providerId }
    }

    /// The engines the wizard can set up, in its order. Both editions include all of them.
    static var offered: [SetupWizardLocalEngine] {
        allCases
    }
}

// MARK: - Inputs

/// What the app knows about one engine right now.
struct SetupWizardEngineState: Equatable, Sendable {
    /// The plugin is installed, enabled or not. Apple Speech is built in.
    var isInstalled = false
    /// The engine can transcribe without downloading anything first.
    var isReady = false
    /// Languages the loaded engine reports, nil while it is not loaded.
    var reportedLanguages: [String]?
    /// Models the loaded engine offers, nil while it is not loaded.
    var modelIds: [String]?
    /// The model selected in the engine, nil while none is.
    var selectedModelId: String?
    /// Models whose files are on disk, as the plugin reports them. Empty for a plugin
    /// that does not report them, such as Parakeet, whose model then counts as a download.
    var downloadedModelIds: Set<String> = []
}

/// The plugin marketplace as far as the app could load it.
enum SetupWizardCatalogState: Equatable, Sendable {
    case loading
    /// IDs of the plugins with a download for this Mac and app version.
    case loaded(Set<String>)
    /// The marketplace could not be reached and no copy was cached.
    case unavailable
}

struct SetupWizardEngineRecommendationInput: Equatable, Sendable {
    var spokenLanguages: SetupWizardSpokenLanguages
    /// "arm64" or "x86_64", as `RuntimeArchitecture.current` reports it.
    var architecture: String
    var physicalMemory: UInt64
    var macOSMajorVersion: Int
    var engines: [SetupWizardLocalEngine: SetupWizardEngineState]
    var catalog: SetupWizardCatalogState
    var isOffline: Bool
}

// MARK: - Recommendation

enum SetupWizardEngineRecommendation: Equatable, Sendable {
    /// A local engine that supports the spoken languages and runs on this Mac.
    case engine(SetupWizardEngineChoice)
    /// No local engine can be recommended. The wizard explains why.
    case limitation(SetupWizardEngineLimitation)
    /// Only Apple Speech could still support the languages, and it has not reported its
    /// languages yet. The recommendation follows once it has.
    case pending

    var choice: SetupWizardEngineChoice? {
        if case .engine(let choice) = self { return choice }
        return nil
    }
}

struct SetupWizardEngineChoice: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        /// The engine supports every selected language.
        case supportsLanguages([String])
        /// Automatic detection among this many languages, nil when the count is unknown.
        case detectsLanguages(count: Int?)
    }

    enum Availability: Equatable, Sendable {
        /// Ready, installed with its model on disk, or the plugin or model can be
        /// downloaded now.
        case available
        /// The plugin or model needs a download and the Mac is offline.
        case needsConnection
        /// The marketplace has no download of the plugin for this Mac.
        case notInCatalog
        /// The marketplace could not be reached.
        case catalogUnavailable
    }

    let engine: SetupWizardLocalEngine
    /// The model to load when the engine has none yet. Nil for Apple Speech.
    let modelId: String?
    /// The model that activating the engine loads, the one selected in it or `modelId`,
    /// is on disk, so the engine can be activated offline.
    let modelIsDownloaded: Bool
    let reason: Reason
    let availability: Availability
}

enum SetupWizardEngineLimitation: Equatable, Sendable {
    /// No local engine runs on this Mac: an Intel Mac before macOS 26.
    case noLocalEngine
    /// The local engines that run on this Mac do not support these languages.
    case unsupportedLanguages([String])
}

extension SetupWizardEngineRecommendation {
    static func recommend(for input: SetupWizardEngineRecommendationInput) -> SetupWizardEngineRecommendation {
        let memoryGB = memoryGB(of: input)
        var compatible: [SetupWizardEngineChoice] = []

        for engine in SetupWizardLocalEngine.offered {
            let state = input.engines[engine] ?? SetupWizardEngineState()
            // The languages of the model the wizard would load. An installed engine
            // reports those of the model selected in it, which can be another one.
            guard runs(engine, state: state, input: input, memoryGB: memoryGB),
                  let reason = reason(
                      for: engine,
                      languages: engine.knownLanguages ?? state.reportedLanguages,
                      spokenLanguages: input.spokenLanguages
                  )
            else { continue }

            let modelId = model(for: engine, state: state, memoryGB: memoryGB)?.id
            let modelIsDownloaded = activationModelId(
                selectedModelId: state.selectedModelId,
                reportedLanguages: state.reportedLanguages ?? [],
                recommendedModelId: modelId,
                spokenLanguages: input.spokenLanguages
            ).map(state.downloadedModelIds.contains) ?? false
            compatible.append(SetupWizardEngineChoice(
                engine: engine,
                modelId: modelId,
                modelIsDownloaded: modelIsDownloaded,
                reason: reason,
                availability: availability(of: engine, state: state, modelIsDownloaded: modelIsDownloaded, input: input)
            ))
        }

        // An engine that can be set up now wins over a preferred one that cannot.
        if let choice = compatible.first(where: { $0.availability == .available }) ?? compatible.first {
            return .engine(choice)
        }

        let runnable = SetupWizardLocalEngine.offered.filter {
            runs($0, state: input.engines[$0] ?? SetupWizardEngineState(), input: input, memoryGB: memoryGB)
        }
        // Every runnable engine handles automatic detection, so only specific languages get here.
        guard !runnable.isEmpty, case .specific(let codes) = input.spokenLanguages else {
            return .limitation(.noLocalEngine)
        }
        let languagesUnknown = runnable.contains {
            $0.knownLanguages == nil && input.engines[$0]?.reportedLanguages == nil
        }
        return languagesUnknown ? .pending : .limitation(.unsupportedLanguages(codes))
    }

    /// The first engine, in the wizard's order, that can transcribe the spoken languages
    /// without a download, judged by the model selected in it. The wizard selects it when
    /// nothing else is selected.
    static func readyEngine(for input: SetupWizardEngineRecommendationInput) -> SetupWizardLocalEngine? {
        let memoryGB = memoryGB(of: input)
        return SetupWizardLocalEngine.offered.first { engine in
            let state = input.engines[engine] ?? SetupWizardEngineState()
            return state.isReady
                && runs(engine, state: state, input: input, memoryGB: memoryGB)
                && reason(
                    for: engine,
                    languages: state.reportedLanguages ?? engine.knownLanguages,
                    spokenLanguages: input.spokenLanguages
                ) != nil
        }
    }

    /// The model that activating an engine loads: the one selected in it when that model
    /// supports the spoken languages, otherwise the recommended one.
    static func activationModelId(
        selectedModelId: String?,
        reportedLanguages: [String],
        recommendedModelId: String?,
        spokenLanguages: SetupWizardSpokenLanguages
    ) -> String? {
        guard unsupportedLanguages(spokenLanguages, reportedLanguages: reportedLanguages).isEmpty else {
            return recommendedModelId
        }
        return selectedModelId ?? recommendedModelId
    }

    /// The spoken languages missing from the languages an engine reports. Engines that
    /// report no languages are not judged.
    static func unsupportedLanguages(
        _ spokenLanguages: SetupWizardSpokenLanguages,
        reportedLanguages: [String]
    ) -> [String] {
        guard !reportedLanguages.isEmpty else { return [] }
        let supported = Set(reportedLanguages.map(SetupWizardSpokenLanguages.baseLanguageCode))
        return spokenLanguages.codes.filter { !supported.contains($0) }
    }

    private static func memoryGB(of input: SetupWizardEngineRecommendationInput) -> Int {
        Int((Double(input.physicalMemory) / 1_073_741_824).rounded())
    }

    private static func runs(
        _ engine: SetupWizardLocalEngine,
        state: SetupWizardEngineState,
        input: SetupWizardEngineRecommendationInput,
        memoryGB: Int
    ) -> Bool {
        if engine.requiresAppleSilicon, input.architecture != "arm64" { return false }
        if input.macOSMajorVersion < engine.minimumMacOSMajorVersion { return false }
        // Apple Speech is built into the app and the system.
        if engine == .appleSpeech { return state.isInstalled }
        return model(for: engine, state: state, memoryGB: memoryGB) != nil
    }

    private static func model(
        for engine: SetupWizardLocalEngine,
        state: SetupWizardEngineState,
        memoryGB: Int
    ) -> SetupWizardEngineModel? {
        let fitting = engine.models.filter { $0.minimumMemoryGB <= memoryGB }
        // An installed plugin may be older than this table and lack a model.
        if let offered = state.modelIds, !offered.isEmpty,
           let model = fitting.first(where: { offered.contains($0.id) }) {
            return model
        }
        return fitting.first
    }

    private static func reason(
        for engine: SetupWizardLocalEngine,
        languages: [String]?,
        spokenLanguages: SetupWizardSpokenLanguages
    ) -> SetupWizardEngineChoice.Reason? {
        let languages = languages?.map(SetupWizardSpokenLanguages.baseLanguageCode)

        switch spokenLanguages {
        case .automatic:
            guard !engine.isSingleLanguageEngine else { return nil }
            return .detectsLanguages(count: languages.map { Set($0).count })
        case .specific(let codes):
            // Apple Speech's languages are unknown until its engine is loaded.
            guard let languages, Set(codes).isSubset(of: Set(languages)) else { return nil }
            return .supportsLanguages(codes)
        }
    }

    private static func availability(
        of engine: SetupWizardLocalEngine,
        state: SetupWizardEngineState,
        modelIsDownloaded: Bool,
        input: SetupWizardEngineRecommendationInput
    ) -> SetupWizardEngineChoice.Availability {
        // Apple Speech comes with the app; the system manages its language assets.
        if state.isReady || engine == .appleSpeech { return .available }
        // An installed engine loads a model that is already on disk without a connection.
        if state.isInstalled, modelIsDownloaded { return .available }
        if input.isOffline { return .needsConnection }
        if state.isInstalled { return .available }

        switch input.catalog {
        case .loading:
            return .available
        case .loaded(let manifestIds):
            return manifestIds.contains(engine.manifestId) ? .available : .notInCatalog
        case .unavailable:
            return .catalogUnavailable
        }
    }
}

// MARK: - Network status

/// Whether the Mac has a network connection, so the setup wizard can say before a
/// download starts that it cannot finish. Follows the path while the wizard is open.
@MainActor
final class SetupWizardNetworkStatus: ObservableObject {
    @Published private(set) var isOffline = false

    private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let isOffline = path.status != .satisfied
            Task { @MainActor [weak self] in
                guard let self, self.isOffline != isOffline else { return }
                self.isOffline = isOffline
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.typewhisper.setup-wizard.network-status"))
    }

    deinit {
        monitor.cancel()
    }
}
