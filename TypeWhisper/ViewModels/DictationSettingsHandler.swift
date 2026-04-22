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

    func setHotkey(_ hotkey: UnifiedHotkey, for slot: HotkeySlotType) {
        hotkeyService.updateHotkey(hotkey, for: slot)
        onHotkeyLabelsChanged?()
    }

    func clearHotkey(for slot: HotkeySlotType) {
        hotkeyService.clearHotkey(for: slot)
        onHotkeyLabelsChanged?()
    }

    func isHotkeyAssigned(_ hotkey: UnifiedHotkey, excluding: HotkeySlotType) -> HotkeySlotType? {
        hotkeyService.isHotkeyAssigned(hotkey, excluding: excluding)
    }

    static func loadHotkeyLabel(for slotType: HotkeySlotType) -> String {
        if let data = UserDefaults.standard.data(forKey: slotType.defaultsKey),
           let hotkey = try? JSONDecoder().decode(UnifiedHotkey.self, from: data) {
            return HotkeyService.displayName(for: hotkey)
        }
        return ""
    }

    func registerInitialTriggerHotkeys() {
        syncProfileHotkeys(profileService.profiles)
        syncWorkflowHotkeys(workflowService.workflows)
    }

    @available(*, deprecated, renamed: "registerInitialTriggerHotkeys")
    func registerInitialProfileHotkeys() {
        registerInitialTriggerHotkeys()
    }

    func syncProfileHotkeys(_ profiles: [Profile]) {
        let entries = profiles
            .filter { $0.isEnabled }
            .compactMap { profile -> (id: UUID, hotkey: UnifiedHotkey)? in
                guard let hotkey = profile.hotkey else { return nil }
                return (id: profile.id, hotkey: hotkey)
            }
        hotkeyService.registerProfileHotkeys(entries)
    }

    func syncWorkflowHotkeys(_ workflows: [Workflow]) {
        let entries = workflows
            .filter(\.isEnabled)
            .flatMap { workflow -> [(id: UUID, hotkey: UnifiedHotkey)] in
                guard let trigger = workflow.trigger, trigger.kind == .hotkey else {
                    return []
                }
                return trigger.hotkeys.map { hotkey in
                    (id: workflow.id, hotkey: hotkey)
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
            return !self.textInsertionService.isAccessibilityGranted
        }
        permissionPollTask?.cancel()
        permissionPollTask = Task { [weak self] in
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.onObjectWillChange?()
                }
                if !needsMic(), !needsAccessibility() { return }
            }
        }
    }
}
