import Foundation

@MainActor
final class DictationSettingsHandler {
    private let hotkeyService: HotkeyService
    private let audioRecordingService: AudioRecordingService
    private let textInsertionService: TextInsertionService
    private let profileService: ProfileService
    private let workflowService: WorkflowService
    private var permissionPollTask: Task<Void, Never>?

    var onObjectWillChange: (() -> Void)?
    var onHotkeyLabelsChanged: (() -> Void)?

    init(
        hotkeyService: HotkeyService,
        audioRecordingService: AudioRecordingService,
        textInsertionService: TextInsertionService,
        profileService: ProfileService,
        workflowService: WorkflowService
    ) {
        self.hotkeyService = hotkeyService
        self.audioRecordingService = audioRecordingService
        self.textInsertionService = textInsertionService
        self.profileService = profileService
        self.workflowService = workflowService
    }

    func requestMicPermission() {
        Task {
            _ = await audioRecordingService.requestMicrophonePermission()
            DispatchQueue.main.async { [weak self] in
                self?.onObjectWillChange?()
            }
            pollPermissionStatus()
        }
    }

    func requestAccessibilityPermission() {
        textInsertionService.requestAccessibilityPermission()
        pollPermissionStatus()
    }

#if APPSTORE
    func requestInputMonitoringPermission() {
        AppStoreInputAccess.requestListenEventAccess()
        pollPermissionStatus()
    }
#endif

    func setHotkey(_ hotkey: UnifiedHotkey, for slot: HotkeySlotType) {
        hotkeyService.updateHotkey(hotkey, for: slot)
        onHotkeyLabelsChanged?()
    }

    func addHotkey(_ hotkey: UnifiedHotkey, for slot: HotkeySlotType) {
        hotkeyService.appendHotkey(hotkey, for: slot)
        onHotkeyLabelsChanged?()
    }

    func replaceHotkey(_ existingHotkey: UnifiedHotkey, with newHotkey: UnifiedHotkey, for slot: HotkeySlotType) {
        hotkeyService.replaceHotkey(existingHotkey, with: newHotkey, for: slot)
        onHotkeyLabelsChanged?()
    }

    func removeHotkey(_ hotkey: UnifiedHotkey, for slot: HotkeySlotType) {
        hotkeyService.removeHotkey(hotkey, for: slot)
        onHotkeyLabelsChanged?()
    }

    func removeConflictingHotkey(_ hotkey: UnifiedHotkey, for slot: HotkeySlotType) {
        hotkeyService.removeConflictingHotkey(hotkey, for: slot)
        onHotkeyLabelsChanged?()
    }

    func clearHotkey(for slot: HotkeySlotType) {
        hotkeyService.clearHotkey(for: slot)
        onHotkeyLabelsChanged?()
    }

    func hotkeys(for slot: HotkeySlotType) -> [UnifiedHotkey] {
        hotkeyService.hotkeys(for: slot)
    }

    func reloadHotkeysFromDefaults() {
        hotkeyService.reloadHotkeysFromDefaults()
        onHotkeyLabelsChanged?()
    }

    func isHotkeyAssigned(_ hotkey: UnifiedHotkey, excluding: HotkeySlotType) -> HotkeySlotType? {
        hotkeyService.isHotkeyAssigned(hotkey, excluding: excluding)
    }

    static func loadHotkeys(for slotType: HotkeySlotType) -> [UnifiedHotkey] {
        if let data = UserDefaults.standard.data(forKey: slotType.hotkeysDefaultsKey),
           let hotkeys = try? JSONDecoder().decode([UnifiedHotkey].self, from: data) {
            return hotkeys
        }

        guard let data = UserDefaults.standard.data(forKey: slotType.defaultsKey),
              let hotkey = try? JSONDecoder().decode(UnifiedHotkey.self, from: data) else {
            return []
        }
        return [hotkey]
    }

    static func loadHotkey(for slotType: HotkeySlotType) -> UnifiedHotkey? {
        loadHotkeys(for: slotType).first
    }

    static func loadHotkeyLabels(for slotType: HotkeySlotType) -> [String] {
        loadHotkeys(for: slotType).map { HotkeyService.displayName(for: $0) }
    }

    static func loadHotkeyLabel(for slotType: HotkeySlotType) -> String {
        loadHotkeyLabels(for: slotType).first ?? ""
    }

    static func loadMenuShortcutDescriptor(for slotType: HotkeySlotType) -> HotkeyService.MenuShortcutDescriptor? {
        loadHotkeys(for: slotType).compactMap { HotkeyService.menuShortcutDescriptor(for: $0) }.first
    }

    func registerInitialTriggerHotkeys() {
        syncWorkflowHotkeys(workflowService.workflows)
    }

    @available(*, deprecated, renamed: "registerInitialTriggerHotkeys")
    func registerInitialProfileHotkeys() {
        registerInitialTriggerHotkeys()
    }

    func syncProfileHotkeys(_: [Profile]) {
        hotkeyService.registerProfileHotkeys([])
    }

    func syncWorkflowHotkeys(_ workflows: [Workflow]) {
        let entries = workflows
            .filter(\.isEnabled)
            .flatMap { workflow -> [(id: UUID, hotkey: UnifiedHotkey, behavior: WorkflowHotkeyBehavior)] in
                guard let trigger = workflow.trigger, !trigger.hotkeys.isEmpty else {
                    return []
                }
                return trigger.hotkeys.map { hotkey in
                    (id: workflow.id, hotkey: hotkey, behavior: trigger.hotkeyBehavior)
                }
            }
        hotkeyService.registerWorkflowHotkeys(entries)
    }

    func pollPermissionStatus() {
        let needsMic = { [weak self] () -> Bool in
            guard let self else { return false }
            return !self.audioRecordingService.hasMicrophonePermission
        }
        let needsAccessibility = { [weak self] () -> Bool in
            guard let self else { return false }
#if APPSTORE
            // Hotkey monitoring depends on Input Monitoring, pasting on PostEvent access.
            return !AppStoreInputAccess.canListenToEvents
                || (AppStoreInputAccess.isAutoPasteEnabled && !self.textInsertionService.isAccessibilityGranted)
#else
            return !self.textInsertionService.isAccessibilityGranted
#endif
        }
        var hasResumedHotkeyMonitoring = !needsAccessibility()
        permissionPollTask?.cancel()
        permissionPollTask = Task { [weak self] in
            #if APPSTORE
            // Granting two permissions in System Settings can take a while.
            let pollSeconds = 120
            #else
            let pollSeconds = 30
            #endif
            for _ in 0..<pollSeconds {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.onObjectWillChange?()
                    if !hasResumedHotkeyMonitoring, !needsAccessibility() {
                        hasResumedHotkeyMonitoring = true
                        self?.hotkeyService.resumeMonitoring()
                    }
                }
                if !needsMic(), !needsAccessibility() { return }
            }
        }
    }
}
