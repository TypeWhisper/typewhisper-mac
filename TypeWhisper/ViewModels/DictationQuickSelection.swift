import AppKit
import Combine
import Foundation
import TypeWhisperPluginSDK

/// One entry of a dictation quick-selection menu (microphone, language or model).
struct DictationQuickSelectionOption<Value: Hashable>: Identifiable, Hashable {
    let id: String
    let value: Value
    let title: String
    var isSelected = false
    var isEnabled = true
}

enum DictationMicrophoneChoice: Hashable {
    case systemDefault
    case device(uid: String)
}

struct DictationModelChoice: Hashable {
    let providerId: String
    let modelId: String?
}

struct DictationModelGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let options: [DictationQuickSelectionOption<DictationModelChoice>]
    /// Models that need setup in Settings first. Listed separately because local engines
    /// can offer many variants or one model per language.
    var setupRequiredOptions: [DictationQuickSelectionOption<DictationModelChoice>] = []
}

/// The transcription engine facts the model menu needs, decoupled from the plugin
/// instance so the selection rules can be tested without loaded plugins.
struct DictationQuickSelectionEngine {
    let providerId: String
    let displayName: String
    let isAuthAvailable: Bool
    let isConfigured: Bool
    /// Local engines load model weights from disk and may download them on selection.
    let managesLocalModels: Bool
    let selectedModelId: String?
    /// The model the engine last loaded and restores from installed assets.
    let restorableModelId: String?
    let models: [PluginModelInfo]
}

struct DictationQuickSelectionSnapshot: Equatable {
    var isLocked = false

    var microphoneSummary = ""
    var microphoneOptions: [DictationQuickSelectionOption<DictationMicrophoneChoice>] = []

    var languageSummary = ""
    var languageWorkflowNote: String?
    var languageOptions: [DictationQuickSelectionOption<LanguageSelection>] = []
    var moreLanguageOptions: [DictationQuickSelectionOption<LanguageSelection>] = []

    var modelSummary = ""
    var modelWorkflowNote: String?
    var modelGroups: [DictationModelGroup] = []
}

/// Builds the quick-selection menus from the existing selection services. The functions
/// are pure so the selection rules stay testable; `DictationQuickSelectionModel` feeds them.
@MainActor
enum DictationQuickSelection {
    /// Up to this many supported languages are listed directly; larger sets move all
    /// non-featured languages into a "More Languages" submenu.
    static let directLanguageLimit = 12

    // MARK: Lock

    /// Selections are locked while a recording is captured or transcribed. Changing the
    /// model then could unload the model the running session uses, and a microphone or
    /// language change would only partially apply to the current session.
    /// `isTranscribingElsewhere` covers recorder retranscription, file transcription and
    /// recovered recordings.
    static func isLocked(
        dictationState: DictationViewModel.State,
        recorderState: AudioRecorderViewModel.RecorderState,
        isTranscribingElsewhere: Bool = false
    ) -> Bool {
        switch dictationState {
        case .recording, .processing, .inserting, .promptProcessing:
            return true
        case .idle, .promptSelection, .error:
            break
        }
        return recorderState != .idle || isTranscribingElsewhere
    }

    // MARK: Microphone

    static func microphoneOptions(
        devices: [AudioInputDevice],
        deviceTitle: (AudioInputDevice) -> String,
        isDeviceAvailable: (AudioInputDevice) -> Bool = { _ in true },
        priorityList: [AudioInputDevicePriorityItem],
        selectedDeviceUID: String?,
        systemDefaultName: String?
    ) -> [DictationQuickSelectionOption<DictationMicrophoneChoice>] {
        var options: [DictationQuickSelectionOption<DictationMicrophoneChoice>] = [
            DictationQuickSelectionOption(
                id: "system-default",
                value: .systemDefault,
                title: systemDefaultTitle(deviceName: systemDefaultName),
                isSelected: selectedDeviceUID == nil
            )
        ]

        for device in devices {
            // Recording skips devices it cannot use, such as the built-in microphone
            // with the lid closed, so choosing one would only reset the priority list.
            let isAvailable = isDeviceAvailable(device)
            options.append(DictationQuickSelectionOption(
                id: device.uid,
                value: .device(uid: device.uid),
                title: isAvailable
                    ? deviceTitle(device)
                    : localizedAppText(
                        "\(deviceTitle(device)) (unavailable)",
                        de: "\(deviceTitle(device)) (nicht verfügbar)"
                    ),
                isSelected: device.uid == selectedDeviceUID,
                isEnabled: isAvailable
            ))
        }

        // Prioritized microphones that are not connected stay visible so it is clear
        // why recording currently falls back to another input.
        let connectedUIDs = Set(devices.map(\.uid))
        for item in priorityList where !connectedUIDs.contains(item.uid) {
            options.append(DictationQuickSelectionOption(
                id: item.uid,
                value: .device(uid: item.uid),
                title: localizedAppText(
                    "\(item.name) (disconnected)",
                    de: "\(item.name) (getrennt)"
                ),
                isEnabled: false
            ))
        }

        return options
    }

    static func microphoneSummary(
        resolvedSelection: ResolvedRecordingInputSelection,
        systemDefaultName: String?
    ) -> String {
        if resolvedSelection.hasExplicitDeviceSelection, let name = resolvedSelection.deviceName {
            return name
        }
        return systemDefaultTitle(deviceName: resolvedSelection.deviceName ?? systemDefaultName)
    }

    private static func systemDefaultTitle(deviceName: String?) -> String {
        let title = localizedAppText("System Default", de: "Systemstandard")
        guard let deviceName, !deviceName.isEmpty else { return title }
        return "\(title) (\(deviceName))"
    }

    // MARK: Language

    /// Lists the languages the selected model supports. The stored selection keeps its
    /// meaning: a language set stays a set, and a language the model does not support
    /// stays visible instead of being rewritten.
    static func languageOptions(
        globalSelection: LanguageSelection,
        supportedCodes: [String]
    ) -> (primary: [DictationQuickSelectionOption<LanguageSelection>], more: [DictationQuickSelectionOption<LanguageSelection>]) {
        var primary: [DictationQuickSelectionOption<LanguageSelection>] = [
            DictationQuickSelectionOption(
                id: "auto",
                value: .auto,
                title: localizedAppText("Auto-detect", de: "Automatische Erkennung"),
                isSelected: globalSelection == .auto
            )
        ]

        if case .hints(let codes) = globalSelection, !codes.isEmpty {
            primary.append(DictationQuickSelectionOption(
                id: "hints:\(codes.joined(separator: ","))",
                value: globalSelection,
                title: workflowInputLanguageSummary(for: globalSelection),
                isSelected: true
            ))
        }

        let supported = Set(supportedCodes)
        let selectedCode = globalSelection.requestedLanguage
        var codes = supported
        if let selectedCode {
            codes.insert(selectedCode)
        }

        let sortedOptions = localizedAppLanguageOptions(for: Array(codes))
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { language in
                DictationQuickSelectionOption(
                    id: language.code,
                    value: LanguageSelection.exact(language.code),
                    title: supported.contains(language.code)
                        ? language.name
                        : localizedAppText(
                            "\(language.name) (not supported by the model)",
                            de: "\(language.name) (vom Modell nicht unterstützt)"
                        ),
                    isSelected: language.code == selectedCode
                )
            }

        let featured = sortedOptions
            .filter { featuredAppLanguageRank(for: $0.id) != nil || $0.isSelected }
            .sorted(by: featuredOrder)
        let remaining = sortedOptions.filter { option in
            !featured.contains(where: { $0.id == option.id })
        }
        guard sortedOptions.count > directLanguageLimit else {
            return (primary + featured + remaining, [])
        }
        return (primary + featured, remaining)
    }

    private static func featuredOrder(
        _ lhs: DictationQuickSelectionOption<LanguageSelection>,
        _ rhs: DictationQuickSelectionOption<LanguageSelection>
    ) -> Bool {
        let lhsRank = featuredAppLanguageRank(for: lhs.id) ?? Int.max
        let rhsRank = featuredAppLanguageRank(for: rhs.id) ?? Int.max
        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }

    /// Describes the language the next recording uses, after the same normalization the
    /// transcription applies for the model.
    static func languageSummary(for selection: LanguageSelection, supportedCodes: [String]) -> String {
        let normalized = supportedCodes.isEmpty
            ? selection
            : selection.normalizedForSupportedLanguages(supportedCodes)
        return workflowInputLanguageSummary(for: normalized == .inheritGlobal ? .auto : normalized)
    }

    // MARK: Model

    static func modelGroups(
        engines: [DictationQuickSelectionEngine],
        selectedProviderId: String?
    ) -> [DictationModelGroup] {
        engines.map { engine in
            let options = modelOptions(for: engine, isSelectedProvider: engine.providerId == selectedProviderId)
            guard options.contains(where: { $0.value.modelId != nil }) else {
                return DictationModelGroup(id: engine.providerId, title: engine.displayName, options: options)
            }
            return DictationModelGroup(
                id: engine.providerId,
                title: engine.displayName,
                options: options.filter { $0.isEnabled || $0.isSelected },
                setupRequiredOptions: options.filter { !$0.isEnabled && !$0.isSelected }
            )
        }
    }

    private static func modelOptions(
        for engine: DictationQuickSelectionEngine,
        isSelectedProvider: Bool
    ) -> [DictationQuickSelectionOption<DictationModelChoice>] {
        guard engine.isAuthAvailable else {
            return [DictationQuickSelectionOption(
                id: engine.providerId,
                value: DictationModelChoice(providerId: engine.providerId, modelId: nil),
                title: localizedAppText(
                    "\(engine.displayName) (unavailable)",
                    de: "\(engine.displayName) (nicht verfügbar)"
                ),
                isSelected: isSelectedProvider,
                isEnabled: false
            )]
        }

        guard !engine.models.isEmpty, engine.managesLocalModels || engine.isConfigured else {
            let detail = setupDetail(for: engine, model: nil)
            return [DictationQuickSelectionOption(
                id: engine.providerId,
                value: DictationModelChoice(providerId: engine.providerId, modelId: nil),
                title: titleWithDetail(engine.displayName, detail: detail),
                isSelected: isSelectedProvider,
                isEnabled: detail == nil
            )]
        }

        return engine.models.map { model in
            let detail = setupDetail(for: engine, model: model)
            return DictationQuickSelectionOption(
                id: "\(engine.providerId)/\(model.id)",
                value: DictationModelChoice(providerId: engine.providerId, modelId: model.id),
                title: titleWithDetail(model.displayName, detail: detail),
                isSelected: isSelectedProvider && model.id == engine.selectedModelId,
                isEnabled: detail == nil
            )
        }
    }

    /// Explains why a model cannot be chosen from the menu, or nil when it can.
    /// Local models are offered only when choosing them cannot start a download:
    /// some engines download a missing model as soon as it is selected.
    private static func setupDetail(for engine: DictationQuickSelectionEngine, model: PluginModelInfo?) -> String? {
        guard engine.managesLocalModels else {
            guard engine.isConfigured else {
                return localizedAppText("not set up", de: "nicht eingerichtet")
            }
            return nil
        }

        guard let model else {
            return engine.isConfigured ? nil : localizedAppText("load in Settings", de: "in den Einstellungen laden")
        }
        if model.loaded == true || model.downloaded == true {
            return nil
        }
        // A failed switch can leave the selection on a model that was never loaded, so the
        // selection is only restorable when it matches the model the engine restores.
        if model.id == engine.selectedModelId,
           engine.isConfigured || model.id == engine.restorableModelId {
            return nil
        }
        if model.downloaded == false {
            return localizedAppText("not downloaded", de: "nicht heruntergeladen")
        }
        return localizedAppText("load in Settings", de: "in den Einstellungen laden")
    }

    /// Uses the manifest's declared hosting only: remote engines such as Cloudflare ASR or
    /// OpenAI-compatible servers declare neither hosting nor an API key, and the resolved
    /// fallback would count them as local.
    static func managesLocalModels(isLifecycleAware: Bool, declaredHosting: PluginHosting?) -> Bool {
        isLifecycleAware || declaredHosting == .local
    }

    private static func titleWithDetail(_ title: String, detail: String?) -> String {
        guard let detail else { return title }
        return "\(title) (\(detail))"
    }

    /// Prefixes the model name with its provider/engine (e.g. "Groq • whisper-large-v3") so the
    /// menu bar shows which provider handles transcription. Skips the prefix when it would be
    /// redundant — e.g. local engines whose model name already contains the provider ("Parakeet").
    static func modelLabel(engine: String?, model: String) -> String {
        guard let engine, !engine.isEmpty, engine != model,
              !model.localizedCaseInsensitiveContains(engine) else {
            return model
        }
        return "\(engine) • \(model)"
    }

    // MARK: Workflow overrides

    /// Dictation fails instead of falling back when a workflow names an engine that is
    /// disabled, uninstalled or lacks access, so the menu says so.
    static func unavailableEngineSummary(engineName: String) -> String {
        localizedAppText("\(engineName) (unavailable)", de: "\(engineName) (nicht verfügbar)")
    }

    static func workflowNote(workflowName: String, summary: String) -> String {
        localizedAppText(
            "Workflow “\(workflowName)” uses \(summary) here",
            de: "Workflow „\(workflowName)“ verwendet hier \(summary)"
        )
    }
}

/// Live quick-selection state for dictation surfaces such as the menu bar. It reads and
/// writes the same services as Settings, so both always show the same selection.
@MainActor
final class DictationQuickSelectionModel: ObservableObject {
    @Published private(set) var snapshot = DictationQuickSelectionSnapshot()

    private var cancellables = Set<AnyCancellable>()
    /// Browser URL of the frontmost app, needed to match website workflows.
    private var frontmostBrowserURL: (bundleId: String, url: String?)?
    private var browserURLTask: (bundleId: String, task: Task<Void, Never>)?

    init() {
        rebuild()
        observeChanges()
    }

    // MARK: Actions

    func selectMicrophone(_ choice: DictationMicrophoneChoice) {
        guard !isLockedNow else { return }
        let audioDeviceService = ServiceContainer.shared.audioDeviceService
        switch choice {
        case .systemDefault:
            audioDeviceService.clearInputDevicePriorityList()
        case .device(let uid):
            guard let device = audioDeviceService.inputDevices.first(where: { $0.uid == uid }),
                  Self.isAvailable(device, in: audioDeviceService) else { return }
            audioDeviceService.selectInputDeviceAsPrimary(uid)
        }
    }

    func selectLanguage(_ selection: LanguageSelection) {
        guard !isLockedNow else { return }
        SettingsViewModel.shared.languageSelection = selection
    }

    func selectModel(_ choice: DictationModelChoice) {
        guard !isLockedNow else { return }
        rebuild()
        let option = snapshot.modelGroups
            .first { $0.id == choice.providerId }?
            .options.first { $0.value == choice }
        // Options that need setup are never chosen here, so no model download can start.
        guard let option, option.isEnabled else { return }

        let modelManager = ServiceContainer.shared.modelManagerService
        guard let modelId = choice.modelId,
              modelId != modelManager.selectedModelId(for: choice.providerId) else {
            // Keep the engine's own model: selecting it again would make some engines reload it.
            modelManager.selectProvider(choice.providerId)
            return
        }
        modelManager.selectModel(choice.providerId, modelId: modelId)
    }

    func openDictationSettings() {
        SettingsNavigationCoordinator.shared?.navigate(to: .dictation)
        ManagedAppWindowOpener.shared.open(id: "settings")
    }

    // MARK: State

    private static func isAvailable(_ device: AudioInputDevice, in audioDeviceService: AudioDeviceService) -> Bool {
        audioDeviceService.isInputDevicePriorityItemAvailable(
            AudioInputDevicePriorityItem(uid: device.uid, name: device.name)
        )
    }

    private var isLockedNow: Bool {
        let recorder = AudioRecorderViewModel.shared
        return DictationQuickSelection.isLocked(
            dictationState: DictationViewModel.shared.state,
            recorderState: recorder.state,
            isTranscribingElsewhere: recorder.isTranscribing
                || recorder.retranscribingRecordingURL != nil
                || FileTranscriptionViewModel.shared.batchState == .processing
                || DictationRecoveryViewModel.shared.recoveries.contains(where: \.isProcessing)
        )
    }

    private func observeChanges() {
        let container = ServiceContainer.shared
        let audioDeviceService = container.audioDeviceService
        let modelManager = container.modelManagerService

        var signals: [AnyPublisher<Void, Never>] = [
            audioDeviceService.$inputDevices.map { _ in () }.eraseToAnyPublisher(),
            audioDeviceService.$selectedDeviceUID.map { _ in () }.eraseToAnyPublisher(),
            audioDeviceService.$inputDevicePriorityList.map { _ in () }.eraseToAnyPublisher(),
            SettingsViewModel.shared.$languageSelection.map { _ in () }.eraseToAnyPublisher(),
            modelManager.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            container.workflowService.$workflows.map { _ in () }.eraseToAnyPublisher(),
            DictationViewModel.shared.$state.map { _ in () }.eraseToAnyPublisher(),
            AudioRecorderViewModel.shared.$state.map { _ in () }.eraseToAnyPublisher(),
            AudioRecorderViewModel.shared.$isTranscribing.map { _ in () }.eraseToAnyPublisher(),
            AudioRecorderViewModel.shared.$retranscribingRecordingURL.map { _ in () }.eraseToAnyPublisher(),
            FileTranscriptionViewModel.shared.$batchState.map { _ in () }.eraseToAnyPublisher(),
            DictationRecoveryViewModel.shared.$recoveries.map { _ in () }.eraseToAnyPublisher(),
            // The effective workflow depends on the app that receives the next dictation.
            NSWorkspace.shared.notificationCenter
                .publisher(for: NSWorkspace.didActivateApplicationNotification)
                .map { _ in () }
                .eraseToAnyPublisher(),
        ]
        if let pluginManager = PluginManager.shared {
            signals.append(pluginManager.objectWillChange.map { _ in () }.eraseToAnyPublisher())
        }

        Publishers.MergeMany(signals)
            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuild()
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshFrontmostBrowserURL()
            }
            .store(in: &cancellables)

        // Download and device state can change without a published signal; refresh
        // whenever a menu opens so the selectors never show stale availability.
        NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuild()
                self?.refreshFrontmostBrowserURL()
            }
            .store(in: &cancellables)
    }

    /// Resolves the frontmost browser's URL the same way dictation does, so website
    /// workflows show up in the menu. Only runs when such workflows exist, because
    /// it asks the browser through AppleScript.
    private func refreshFrontmostBrowserURL() {
        let container = ServiceContainer.shared
        guard let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              container.workflowService.workflows.contains(where: { workflow in
                  workflow.isEnabled && workflow.trigger?.websitePatterns.isEmpty == false
              }) else {
            browserURLTask?.task.cancel()
            browserURLTask = nil
            frontmostBrowserURL = nil
            return
        }
        guard browserURLTask?.bundleId != bundleId else { return }

        browserURLTask?.task.cancel()
        let task = Task { [weak self] in
            let url = await container.textInsertionService.resolveBrowserURL(bundleId: bundleId)
            guard let self, !Task.isCancelled else { return }
            self.browserURLTask = nil
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleId else { return }
            if self.frontmostBrowserURL?.bundleId != bundleId || self.frontmostBrowserURL?.url != url {
                self.frontmostBrowserURL = (bundleId, url)
                self.rebuild()
            }
        }
        browserURLTask = (bundleId, task)
    }

    private func rebuild() {
        let container = ServiceContainer.shared
        let audioDeviceService = container.audioDeviceService
        let modelManager = container.modelManagerService
        let settings = SettingsViewModel.shared
        let engines = PluginManager.shared?.transcriptionEngines ?? []

        let frontmostBundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let workflow = container.workflowService.matchWorkflow(
            bundleIdentifier: frontmostBundleId,
            url: frontmostBrowserURL?.bundleId == frontmostBundleId ? frontmostBrowserURL?.url : nil
        )?.workflow

        var next = DictationQuickSelectionSnapshot()
        next.isLocked = isLockedNow

        // Microphone
        let systemDefaultName = audioDeviceService.systemDefaultInputDeviceName
        next.microphoneOptions = DictationQuickSelection.microphoneOptions(
            devices: audioDeviceService.inputDevices,
            deviceTitle: { audioDeviceService.displayName(for: $0) },
            isDeviceAvailable: { Self.isAvailable($0, in: audioDeviceService) },
            priorityList: audioDeviceService.inputDevicePriorityList,
            selectedDeviceUID: audioDeviceService.selectedDeviceUID,
            systemDefaultName: systemDefaultName
        )
        next.microphoneSummary = DictationQuickSelection.microphoneSummary(
            resolvedSelection: audioDeviceService.resolvedRecordingInputSelection(),
            systemDefaultName: systemDefaultName
        )

        // Model, including a workflow's engine override for the frontmost app
        let globalEngine = modelManager.selectedProviderId.flatMap { providerId in
            engines.first { $0.providerId == providerId }
        }
        next.modelGroups = DictationQuickSelection.modelGroups(
            engines: engines.map { quickSelectionEngine(for: $0, modelManager: modelManager) },
            selectedProviderId: modelManager.selectedProviderId
        )
        let globalModelSummary = modelManager.activeModelName.map {
            DictationQuickSelection.modelLabel(engine: modelManager.activeEngineName, model: $0)
        } ?? localizedAppText("No model selected", de: "Kein Modell ausgewählt")
        next.modelSummary = globalModelSummary

        var effectiveEngine = globalEngine
        var effectiveModelId: String?
        if let workflow,
           let engineId = DictationTranscriptionOverrideResolver.engineId(for: workflow) {
            let overrideEngine = engines.first { $0.providerId == engineId }
            let summary: String
            if let overrideEngine, modelManager.canUseForTranscription(overrideEngine) {
                let modelId = DictationTranscriptionOverrideResolver.modelId(for: workflow)
                let modelName = modelManager.resolvedModelDisplayName(
                    engineOverrideId: engineId,
                    cloudModelOverride: modelId
                ) ?? overrideEngine.providerDisplayName
                summary = DictationQuickSelection.modelLabel(engine: overrideEngine.providerDisplayName, model: modelName)
                effectiveEngine = overrideEngine
                effectiveModelId = modelId
            } else {
                summary = DictationQuickSelection.unavailableEngineSummary(
                    engineName: overrideEngine?.providerDisplayName ?? Self.engineName(for: engineId)
                )
                effectiveEngine = nil
            }
            if summary != globalModelSummary {
                next.modelSummary = summary
                next.modelWorkflowNote = DictationQuickSelection.workflowNote(
                    workflowName: workflow.name,
                    summary: summary
                )
            }
        }

        // Language
        let globalSupportedCodes = globalEngine?.supportedLanguages ?? []
        let languageMenu = DictationQuickSelection.languageOptions(
            globalSelection: settings.languageSelection,
            supportedCodes: globalSupportedCodes.isEmpty
                ? settings.availableLanguages.map(\.code)
                : globalSupportedCodes
        )
        next.languageOptions = languageMenu.primary
        next.moreLanguageOptions = languageMenu.more

        let effectiveSupportedCodes = effectiveEngine?.supportedLanguages(forModel: effectiveModelId) ?? []
        let effectiveLanguage = DictationLanguageResolver.resolve(
            workflow: workflow,
            globalLanguageSelection: settings.languageSelection
        )
        next.languageSummary = DictationQuickSelection.languageSummary(
            for: effectiveLanguage,
            supportedCodes: effectiveSupportedCodes
        )
        if let workflow, workflow.inputLanguageSelection != .inheritGlobal {
            next.languageWorkflowNote = DictationQuickSelection.workflowNote(
                workflowName: workflow.name,
                summary: next.languageSummary
            )
        }

        if next != snapshot {
            snapshot = next
        }
    }

    /// Names an engine whose plugin is disabled, falling back to its ID once uninstalled.
    private static func engineName(for providerId: String) -> String {
        for plugin in PluginManager.shared?.loadedPlugins ?? [] {
            var engines = (plugin.instance as? AdditionalTranscriptionEnginesProviding)?
                .additionalTranscriptionEngines ?? []
            if let engine = plugin.instance as? TranscriptionEnginePlugin {
                engines.append(engine)
            }
            if let match = engines.first(where: { $0.providerId == providerId }) {
                return match.providerDisplayName
            }
        }
        return providerId
    }

    private func quickSelectionEngine(
        for engine: TranscriptionEnginePlugin,
        modelManager: ModelManagerService
    ) -> DictationQuickSelectionEngine {
        let manifest = PluginManager.shared?.loadedTranscriptionPlugin(for: engine.providerId)?.manifest
        let pluginId = manifest?.id
        return DictationQuickSelectionEngine(
            providerId: engine.providerId,
            displayName: engine.providerDisplayName,
            isAuthAvailable: modelManager.canUseForTranscription(engine),
            isConfigured: engine.isConfigured,
            managesLocalModels: DictationQuickSelection.managesLocalModels(
                isLifecycleAware: engine is HostModelLifecyclePolicyAwarePlugin,
                declaredHosting: manifest?.hosting
            ),
            selectedModelId: engine.selectedModelId,
            restorableModelId: pluginId.flatMap {
                TranscriptionEngineReadiness.persistedRestorableModelId(pluginId: $0)
            },
            models: engine.modelCatalog
        )
    }
}
