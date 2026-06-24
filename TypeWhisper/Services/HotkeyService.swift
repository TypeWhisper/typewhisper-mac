import Foundation
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine
import os

struct UnifiedHotkey: Equatable, Hashable, Sendable, Codable {
    let keyCode: UInt16
    let modifierFlags: UInt
    let isFn: Bool
    let isDoubleTap: Bool
    /// Physical modifier key codes for side-specific modifier combos.
    /// Empty means legacy/generic matching by modifier flags only.
    let modifierKeyCodes: Set<UInt16>
    /// nil = keyboard hotkey; 0..N = mouse button number (macOS convention: 2=middle, 3=back, 4=forward)
    let mouseButton: UInt16?

    /// Sentinel keyCode for modifier-only combos (e.g. CMD+OPT).
    /// 0x00 is the "A" key, so we use 0xFFFF which is not a real keyCode.
    static let modifierComboKeyCode: UInt16 = 0xFFFF

    enum Kind {
        case fn
        case modifierOnly
        case modifierCombo
        case keyWithModifiers
        case bareKey
        case mouseButton
    }

    var kind: Kind {
        if mouseButton != nil { return .mouseButton }
        if isFn { return .fn }
        if modifierFlags == 0 && HotkeyService.modifierKeyCodes.contains(keyCode) { return .modifierOnly }
        if keyCode == Self.modifierComboKeyCode && modifierFlags != 0 { return .modifierCombo }
        if modifierFlags != 0 { return .keyWithModifiers }
        return .bareKey
    }

    init(
        keyCode: UInt16,
        modifierFlags: UInt,
        isFn: Bool,
        isDoubleTap: Bool = false,
        modifierKeyCodes: Set<UInt16> = []
    ) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
        self.isFn = isFn
        self.isDoubleTap = isDoubleTap
        self.modifierKeyCodes = modifierKeyCodes
        self.mouseButton = nil
    }

    init(mouseButton: UInt16, isDoubleTap: Bool = false) {
        self.keyCode = 0
        self.modifierFlags = 0
        self.isFn = false
        self.isDoubleTap = isDoubleTap
        self.modifierKeyCodes = []
        self.mouseButton = mouseButton
    }

    // Backward-compatible decoding: old hotkeys without isDoubleTap/modifierKeyCodes/mouseButton decode correctly
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decode(UInt16.self, forKey: .keyCode)
        modifierFlags = try container.decode(UInt.self, forKey: .modifierFlags)
        isFn = try container.decode(Bool.self, forKey: .isFn)
        isDoubleTap = try container.decodeIfPresent(Bool.self, forKey: .isDoubleTap) ?? false
        modifierKeyCodes = try container.decodeIfPresent(Set<UInt16>.self, forKey: .modifierKeyCodes) ?? []
        mouseButton = try container.decodeIfPresent(UInt16.self, forKey: .mouseButton)
    }

    func conflicts(with other: UnifiedHotkey) -> Bool {
        if self == other { return true }
        guard keyCode == other.keyCode,
              modifierFlags == other.modifierFlags,
              isFn == other.isFn,
              mouseButton == other.mouseButton else {
            return false
        }

        if kind == .modifierCombo, other.kind == .modifierCombo {
            return modifierKeyCodes.isEmpty
                || other.modifierKeyCodes.isEmpty
                || modifierKeyCodes == other.modifierKeyCodes
        }

        return isDoubleTap != other.isDoubleTap
    }
}

enum HotkeySlotType: String, CaseIterable, Sendable {
    case hybrid
    case pushToTalk
    case toggle
    case promptPalette
    case recentTranscriptions
    case copyLastTranscription
    case recorderToggle

    var defaultsKey: String {
        switch self {
        case .hybrid: return UserDefaultsKeys.hybridHotkey
        case .pushToTalk: return UserDefaultsKeys.pttHotkey
        case .toggle: return UserDefaultsKeys.toggleHotkey
        case .promptPalette: return UserDefaultsKeys.promptPaletteHotkey
        case .recentTranscriptions: return UserDefaultsKeys.recentTranscriptionsHotkey
        case .copyLastTranscription: return UserDefaultsKeys.copyLastTranscriptionHotkey
        case .recorderToggle: return UserDefaultsKeys.recorderToggleHotkey
        }
    }

    var hotkeysDefaultsKey: String {
        switch self {
        case .hybrid: return UserDefaultsKeys.hybridHotkeys
        case .pushToTalk: return UserDefaultsKeys.pttHotkeys
        case .toggle: return UserDefaultsKeys.toggleHotkeys
        case .promptPalette: return UserDefaultsKeys.promptPaletteHotkeys
        case .recentTranscriptions: return UserDefaultsKeys.recentTranscriptionsHotkeys
        case .copyLastTranscription: return UserDefaultsKeys.copyLastTranscriptionHotkeys
        case .recorderToggle: return UserDefaultsKeys.recorderToggleHotkeys
        }
    }
}

private extension HotkeySlotType {
    var startsDictation: Bool {
        switch self {
        case .hybrid, .pushToTalk, .toggle:
            true
        case .promptPalette, .recentTranscriptions, .copyLastTranscription, .recorderToggle:
            false
        }
    }
}

/// Manages global hotkeys for dictation and standalone app actions.
final class HotkeyService: ObservableObject, @unchecked Sendable {
    struct MenuShortcutDescriptor: Equatable, Sendable {
        let keyEquivalent: Character
        let modifiers: NSEvent.ModifierFlags
    }

    enum HotkeyEventSource: Sendable {
        case eventTap
        case monitor
    }

    private enum HotkeyDispatchPhase: Hashable {
        case down
        case up
    }

    private struct HotkeyDispatchKey: Hashable {
        enum Target: Hashable {
            case cancel
            case slot(HotkeySlotType)
            case profile(UUID)
            case workflow(UUID)
        }

        let target: Target
        let phase: HotkeyDispatchPhase
        let hotkey: UnifiedHotkey
    }

    enum HotkeyMode: String {
        case pushToTalk
        case toggle
    }

    private enum FnTriggerMode {
        case pressThenRelease
        case releaseOnly
    }

    @Published private(set) var currentMode: HotkeyMode?
    @Published var dictationHotkeysPaused: Bool = UserDefaults.standard.bool(forKey: UserDefaultsKeys.dictationHotkeysPaused) {
        didSet {
            UserDefaults.standard.set(dictationHotkeysPaused, forKey: UserDefaultsKeys.dictationHotkeysPaused)
            if dictationHotkeysPaused {
                resetPausedDictationHotkeyState()
            }
        }
    }

    var onDictationStart: ((UInt64) -> Void)?
    var onDictationStop: (() -> Void)?
    var onPromptPaletteToggle: (() -> Void)?
    var onRecentTranscriptionsToggle: (() -> Void)?
    var onCopyLastTranscription: (() -> Void)?
    var onRecorderToggle: (() -> Void)?
    var onProfileDictationStart: ((UUID, UInt64) -> Void)?
    var onWorkflowDictationStart: ((UUID, UInt64) -> Void)?
    var onWorkflowTextProcessing: ((UUID) -> Void)?
    var onCancelPressed: (() -> Void)?
    var onPushToTalkInterruption: (() -> Void)?
    var discardPushToTalkRecordingOnExtraKeyPress = false
    var modifierFlagsStateProvider: () -> NSEvent.ModifierFlags = {
        NSEvent.ModifierFlags(rawValue: UInt(CGEventSource.flagsState(.combinedSessionState).rawValue))
    }
    var workflowTextProcessingModifierPollInterval: TimeInterval = 0.05
    var workflowTextProcessingModifierReleaseTimeout: TimeInterval = 2.0
    var workflowTextProcessingPostReleaseDelay: TimeInterval = 0.15

    private var keyDownTime: Date?
    private var isActive = false
    private var activeSlotType: HotkeySlotType?
    private var activeGlobalHotkey: UnifiedHotkey?
    private(set) var activeProfileId: UUID?
    private(set) var activeWorkflowId: UUID?
    private var pushToTalkInterruptionSignaled = false

    private static let toggleThreshold: TimeInterval = 1.0
    private static let doubleTapThreshold: TimeInterval = 0.4
    private static let monitorDedupWindow: TimeInterval = 0.12
    private static let escapeKeyCode: UInt16 = 0x35
    private static let escapeHotkey = UnifiedHotkey(keyCode: escapeKeyCode, modifierFlags: 0, isFn: false)
    private static let capsLockKeyCode: UInt16 = 0x39
    private static let capsLockSuppressionWindow: TimeInterval = 0.25
    private nonisolated static let hotkeyEventTapPlacement: CGEventTapPlacement = .headInsertEventTap

    nonisolated static func requestTimestamp() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    // MARK: - Per-Slot State

    private struct SlotState {
        var hotkey: UnifiedHotkey?
        var fnWasDown = false
        var fnComboKeyPressed = false
        var modifierWasDown = false
        var keyWasDown = false
        var mouseButtonWasDown = false
        // Double-tap tracking
        var lastTapUpTime: Date?
        var tapCount: Int = 0 // 0=idle, 1=first tap released, 2=second tap active

        mutating func resetTransientState() {
            fnWasDown = false
            fnComboKeyPressed = false
            modifierWasDown = false
            keyWasDown = false
            mouseButtonWasDown = false
            lastTapUpTime = nil
            tapCount = 0
        }
    }

    private var slots: [HotkeySlotType: [SlotState]] = HotkeySlotType.allCases.reduce(into: [:]) { result, slotType in
        result[slotType] = []
    }

    // MARK: - Per-Profile Hotkey State

    private struct ProfileHotkeyState {
        let profileId: UUID
        var hotkey: UnifiedHotkey
        var fnWasDown = false
        var fnComboKeyPressed = false
        var modifierWasDown = false
        var keyWasDown = false
        var mouseButtonWasDown = false
        // Double-tap tracking
        var lastTapUpTime: Date?
        var tapCount: Int = 0

        mutating func resetTransientState() {
            fnWasDown = false
            fnComboKeyPressed = false
            modifierWasDown = false
            keyWasDown = false
            mouseButtonWasDown = false
            lastTapUpTime = nil
            tapCount = 0
        }
    }

    private var profileSlots: [UUID: ProfileHotkeyState] = [:]

    private struct WorkflowHotkeyState {
        let workflowId: UUID
        var hotkey: UnifiedHotkey
        var behavior: WorkflowHotkeyBehavior
        var fnWasDown = false
        var fnComboKeyPressed = false
        var modifierWasDown = false
        var keyWasDown = false
        var mouseButtonWasDown = false
        var lastTapUpTime: Date?
        var tapCount: Int = 0

        mutating func resetTransientState() {
            fnWasDown = false
            fnComboKeyPressed = false
            modifierWasDown = false
            keyWasDown = false
            mouseButtonWasDown = false
            lastTapUpTime = nil
            tapCount = 0
        }
    }

    private var workflowSlots: [UUID: [WorkflowHotkeyState]] = [:]

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var recentEventTapDispatches: [HotkeyDispatchKey: Date] = [:]
    private var capsLockOriginSuppressionUntil: Date?

    var accessibilityTrustedProvider: () -> Bool = { AXIsProcessTrusted() }

    private let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "HotkeyService")

    // Modifier keyCodes that generate flagsChanged instead of keyDown/keyUp
    nonisolated static let modifierKeyCodes: Set<UInt16> = [
        0x37, // Left Command
        0x36, // Right Command
        0x38, // Left Shift
        0x3C, // Right Shift
        0x3A, // Left Option
        0x3D, // Right Option
        0x3B, // Left Control
        0x3E, // Right Control
    ]

    func setup() {
        loadHotkeys()
        setupMonitor()
    }

    func hotkeys(for slotType: HotkeySlotType) -> [UnifiedHotkey] {
        slots[slotType]?.compactMap(\.hotkey) ?? []
    }

    func updateHotkey(_ hotkey: UnifiedHotkey, for slotType: HotkeySlotType) {
        setHotkeys([hotkey], for: slotType)
    }

    func appendHotkey(_ hotkey: UnifiedHotkey, for slotType: HotkeySlotType) {
        var existing = hotkeys(for: slotType)
        guard !existing.contains(where: { $0.conflicts(with: hotkey) }) else { return }
        existing.append(hotkey)
        setHotkeys(existing, for: slotType)
    }

    func replaceHotkey(_ existingHotkey: UnifiedHotkey, with newHotkey: UnifiedHotkey, for slotType: HotkeySlotType) {
        var existing = hotkeys(for: slotType)
        guard let index = existing.firstIndex(of: existingHotkey) else {
            appendHotkey(newHotkey, for: slotType)
            return
        }

        existing[index] = newHotkey
        let updated = existing.enumerated().compactMap { offset, hotkey -> UnifiedHotkey? in
            if offset == index { return hotkey }
            return hotkey.conflicts(with: newHotkey) ? nil : hotkey
        }
        setHotkeys(updated, for: slotType)
    }

    func removeHotkey(_ hotkey: UnifiedHotkey, for slotType: HotkeySlotType) {
        let updated = hotkeys(for: slotType).filter { $0 != hotkey }
        setHotkeys(updated, for: slotType)
    }

    func removeConflictingHotkey(_ hotkey: UnifiedHotkey, for slotType: HotkeySlotType) {
        let updated = hotkeys(for: slotType).filter { !$0.conflicts(with: hotkey) }
        setHotkeys(updated, for: slotType)
    }

    func clearHotkey(for slotType: HotkeySlotType) {
        setHotkeys([], for: slotType)
    }

    /// Returns which slot already has this hotkey assigned, excluding a given slot.
    /// Also detects conflicts between single-tap and double-tap variants of the same key.
    func isHotkeyAssigned(_ hotkey: UnifiedHotkey, excluding: HotkeySlotType) -> HotkeySlotType? {
        for slotType in HotkeySlotType.allCases where slotType != excluding {
            if hotkeys(for: slotType).contains(where: { $0.conflicts(with: hotkey) }) {
                return slotType
            }
        }
        return nil
    }

    /// Resets keyDownTime to now, so hybrid toggle/PTT threshold counts from
    /// when recording actually started (not from key press). Call after slow device init.
    func resetKeyDownTime() {
        keyDownTime = Date()
    }

    func cancelDictation() {
        isActive = false
        activeSlotType = nil
        activeGlobalHotkey = nil
        activeProfileId = nil
        activeWorkflowId = nil
        currentMode = nil
        keyDownTime = nil
        pushToTalkInterruptionSignaled = false
    }

    private func resetPausedDictationHotkeyState() {
        for slotType in HotkeySlotType.allCases where slotType.startsDictation {
            guard var states = slots[slotType] else { continue }
            for index in states.indices {
                states[index].resetTransientState()
            }
            slots[slotType] = states
        }

        for profileId in Array(profileSlots.keys) {
            profileSlots[profileId]?.resetTransientState()
        }

        for workflowId in Array(workflowSlots.keys) {
            guard var states = workflowSlots[workflowId] else { continue }
            for index in states.indices where states[index].behavior == .startDictation {
                states[index].resetTransientState()
            }
            workflowSlots[workflowId] = states
        }
    }

    // MARK: - Profile Hotkeys

    func registerProfileHotkeys(_: [(id: UUID, hotkey: UnifiedHotkey)]) {
        profileSlots.removeAll()
        tearDownMonitor()
        setupMonitor()
    }

    func registerWorkflowHotkeys(_ entries: [(id: UUID, hotkey: UnifiedHotkey, behavior: WorkflowHotkeyBehavior)]) {
        workflowSlots.removeAll()
        for entry in entries {
            workflowSlots[entry.id, default: []].append(
                WorkflowHotkeyState(workflowId: entry.id, hotkey: entry.hotkey, behavior: entry.behavior)
            )
        }
        tearDownMonitor()
        setupMonitor()
    }

    func isHotkeyAssignedToProfile(_: UnifiedHotkey, excludingProfileId _: UUID?) -> UUID? {
        return nil
    }

    func isHotkeyAssignedToWorkflow(_ hotkey: UnifiedHotkey, excludingWorkflowId: UUID?) -> UUID? {
        for (id, states) in workflowSlots where id != excludingWorkflowId {
            for state in states {
                if state.hotkey.conflicts(with: hotkey) {
                    return id
                }
            }
        }
        return nil
    }

    func isHotkeyAssignedToGlobalSlot(_ hotkey: UnifiedHotkey) -> HotkeySlotType? {
        for slotType in HotkeySlotType.allCases {
            if hotkeys(for: slotType).contains(where: { $0.conflicts(with: hotkey) }) {
                return slotType
            }
        }
        return nil
    }

    private func loadHotkeys() {
        let defaults = UserDefaults.standard
        for slotType in HotkeySlotType.allCases {
            if let data = defaults.data(forKey: slotType.hotkeysDefaultsKey),
               let hotkeys = try? JSONDecoder().decode([UnifiedHotkey].self, from: data) {
                let uniqueHotkeys = Self.uniqueHotkeys(hotkeys)
                slots[slotType] = uniqueHotkeys.map { SlotState(hotkey: $0) }
                persistHotkeys(uniqueHotkeys, for: slotType)
                continue
            }

            if let data = defaults.data(forKey: slotType.defaultsKey),
               let hotkey = try? JSONDecoder().decode(UnifiedHotkey.self, from: data) {
                slots[slotType] = [SlotState(hotkey: hotkey)]
                persistHotkeys([hotkey], for: slotType)
                continue
            }

            slots[slotType] = []
        }
    }

    private func setHotkeys(_ hotkeys: [UnifiedHotkey], for slotType: HotkeySlotType) {
        let uniqueHotkeys = Self.uniqueHotkeys(hotkeys)
        slots[slotType] = uniqueHotkeys.map { SlotState(hotkey: $0) }
        persistHotkeys(uniqueHotkeys, for: slotType)
        tearDownMonitor()
        setupMonitor()
    }

    private func persistHotkeys(_ hotkeys: [UnifiedHotkey], for slotType: HotkeySlotType) {
        let defaults = UserDefaults.standard
        guard !hotkeys.isEmpty else {
            defaults.removeObject(forKey: slotType.hotkeysDefaultsKey)
            defaults.removeObject(forKey: slotType.defaultsKey)
            return
        }

        if let data = try? JSONEncoder().encode(hotkeys) {
            defaults.set(data, forKey: slotType.hotkeysDefaultsKey)
        }
        if let first = hotkeys.first,
           let data = try? JSONEncoder().encode(first) {
            defaults.set(data, forKey: slotType.defaultsKey)
        }
    }

    private nonisolated static func uniqueHotkeys(_ hotkeys: [UnifiedHotkey]) -> [UnifiedHotkey] {
        hotkeys.reduce(into: []) { uniqueHotkeys, hotkey in
            guard !uniqueHotkeys.contains(where: { $0.conflicts(with: hotkey) }) else { return }
            uniqueHotkeys.append(hotkey)
        }
    }

    // MARK: - Event Monitor

    private func setupMonitor() {
        tearDownMonitor()
        let includeMouse = needsMouseEventMonitoring

        guard accessibilityTrustedProvider() else {
            logger.info("Accessibility permission not granted, installing local hotkey monitor only")
            installLocalEventMonitor(includeMouse: includeMouse)
            return
        }

        // Try CGEventTap first - it can suppress hotkey events from reaching other apps
        if setupEventTap(includeMouse: needsSuppressingMouseEventTap) {
            logger.info("Using head-inserted CGEventTap for hotkey monitoring with NSEvent compatibility fallback")
            installEventMonitors(includeMouse: includeMouse)
            return
        }

        // Fallback: NSEvent monitors (no event suppression)
        logger.info("CGEventTap unavailable, falling back to NSEvent monitors (hotkey events will pass through)")
        installEventMonitors(includeMouse: includeMouse)
    }

    private var needsMouseEventMonitoring: Bool {
        slots.values.contains { states in
            states.contains { $0.hotkey?.mouseButton != nil }
        } || workflowSlots.values.contains { states in
            states.contains { $0.hotkey.mouseButton != nil }
        }
    }

    private var needsSuppressingMouseEventTap: Bool {
        slots.values.contains { states in
            states.contains { state in
                guard let button = state.hotkey?.mouseButton else { return false }
                return Self.shouldSuppressMouseButtonHotkey(button)
            }
        } || workflowSlots.values.contains { states in
            states.contains { state in
                guard let button = state.hotkey.mouseButton else { return false }
                return Self.shouldSuppressMouseButtonHotkey(button)
            }
        }
    }

    private func installLocalEventMonitor(includeMouse: Bool) {
        let mask = eventMonitorMask(includeMouse: includeMouse)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            _ = self?.handleEvent(event, source: .monitor)
            return event
        }
    }

    private func installEventMonitors(includeMouse: Bool) {
        let mask = eventMonitorMask(includeMouse: includeMouse)

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            _ = self?.handleEvent(event, source: .monitor)
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            _ = self?.handleEvent(event, source: .monitor)
            return event
        }
    }

    private func eventMonitorMask(includeMouse: Bool) -> NSEvent.EventTypeMask {
        var mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp]
        if includeMouse {
            mask.insert(.otherMouseDown)
            mask.insert(.otherMouseUp)
        }
        return mask
    }

    private func tearDownMonitor() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            // Invalidate the source so it is fully unregistered, not just removed
            // from the main run loop.
            CFRunLoopSourceInvalidate(source)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            // Disabling a tap leaves its Mach port registered with the system, so
            // each setup/teardown cycle (settings changes, recorder open/close,
            // wake) would otherwise leak a stale session-level flagsChanged filter
            // tap. Those linger in the modifier-event path and can break the
            // system's double-tap-modifier detection (e.g. Apple Dictation).
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
        recentEventTapDispatches.removeAll()
        capsLockOriginSuppressionUntil = nil
    }

    func suspendMonitoring() {
        tearDownMonitor()
    }

    func resumeMonitoring() {
        setupMonitor()
    }

    // MARK: - CGEventTap (suppresses hotkey events)

    /// Creates a CGEventTap to intercept and suppress hotkey events before they reach other apps.
    /// Requires Accessibility permission. Returns true if the tap was successfully created.
    private func setupEventTap(includeMouse: Bool) -> Bool {
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // @convention(c) callback - must not capture context. Uses userInfo to access HotkeyService.
        // The tap source is attached to the main run loop, but this callback does not execute as a
        // MainActor task. Avoid MainActor runtime assumptions and route through unsafe main-thread-only helpers.
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let userInfo {
                    let service = Unmanaged<HotkeyService>.fromOpaque(userInfo).takeUnretainedValue()
                    service.reenableEventTapAfterSystemDisable()
                }
                return Unmanaged.passUnretained(event)
            }

            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let service = Unmanaged<HotkeyService>.fromOpaque(userInfo).takeUnretainedValue()
            let shouldSuppress = service.handleEventTapCallback(event)
            return shouldSuppress ? nil : Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: Self.hotkeyEventTapPlacement,
            options: .defaultTap,
            eventsOfInterest: Self.suppressingEventTapMask(includeMouse: includeMouse),
            callback: callback,
            userInfo: selfPtr
        ) else {
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private nonisolated static func suppressingEventTapMask(includeMouse: Bool) -> CGEventMask {
        var mask: CGEventMask =
            (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)

        if includeMouse {
            mask |= (CGEventMask(1) << CGEventType.otherMouseDown.rawValue)
            mask |= (CGEventMask(1) << CGEventType.otherMouseUp.rawValue)
        }

        return mask
    }

    private nonisolated static func shouldSuppressMouseButtonHotkey(_ button: UInt16) -> Bool {
        button != 2
    }

    private func reenableEventTapAfterSystemDisable() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        logger.warning("CGEventTap was disabled by system, re-enabling")
    }

    private func handleEventTapCallback(_ event: CGEvent) -> Bool {
        guard let nsEvent = NSEvent(cgEvent: event) else { return false }
        return handleEventTapEvent(nsEvent)
    }

    /// Processes event for CGEventTap: matches hotkeys synchronously, dispatches handling asynchronously.
    /// Returns true if the event should be suppressed (consumed by TypeWhisper).
    private func handleEventTapEvent(_ event: NSEvent) -> Bool {
        handleEvent(event, source: .eventTap)
    }

    // MARK: - NSEvent Fallback

    @discardableResult
    private func handleEvent(_ event: NSEvent, source: HotkeyEventSource) -> Bool {
        // Escape key cancels active recording/transcription
        if event.type == .keyDown && event.keyCode == Self.escapeKeyCode {
            if shouldDispatch(
                target: .cancel,
                phase: .down,
                hotkey: Self.escapeHotkey,
                source: source
            ) {
                onCancelPressed?()
            }
            return false
        }

        signalPushToTalkInterruptionIfNeeded(for: event)
        updateCapsLockOriginTracker(for: event)
        var shouldSuppress = false

        // Global slots
        for slotType in HotkeySlotType.allCases {
            guard var states = slots[slotType] else { continue }
            for index in states.indices {
                var state = states[index]
                guard let hotkey = state.hotkey else { continue }
                if dictationHotkeysPaused, slotType.startsDictation {
                    state.resetTransientState()
                    states[index] = state
                    continue
                }
                let fnTriggerMode: FnTriggerMode = slotType == .toggle ? .releaseOnly : .pressThenRelease
                if shouldSuppressForCapsLockOrigin(event, hotkey: hotkey, keyWasDown: state.keyWasDown) {
                    state.resetTransientState()
                    states[index] = state
                    continue
                }
                let (keyDown, keyUp, isMatch) = processKeyEvent(
                    event,
                    hotkey: hotkey,
                    state: &state,
                    fnTriggerMode: fnTriggerMode
                )
                states[index] = state
                if isMatch { shouldSuppress = true }
                dispatchGlobalMatch(
                    slotType: slotType,
                    hotkey: hotkey,
                    keyDown: keyDown,
                    keyUp: keyUp,
                    source: source
                )
            }
            slots[slotType] = states
        }

        // Profile slots
        for profileId in Array(profileSlots.keys) {
            guard var pState = profileSlots[profileId] else { continue }
            if dictationHotkeysPaused {
                pState.resetTransientState()
                profileSlots[profileId] = pState
                continue
            }
            if shouldSuppressForCapsLockOrigin(event, hotkey: pState.hotkey, keyWasDown: pState.keyWasDown) {
                pState.resetTransientState()
                profileSlots[profileId] = pState
                continue
            }
            var state = SlotState(hotkey: pState.hotkey, fnWasDown: pState.fnWasDown,
                                  fnComboKeyPressed: pState.fnComboKeyPressed,
                                  modifierWasDown: pState.modifierWasDown, keyWasDown: pState.keyWasDown,
                                  mouseButtonWasDown: pState.mouseButtonWasDown,
                                  lastTapUpTime: pState.lastTapUpTime, tapCount: pState.tapCount)
            let (keyDown, keyUp, isMatch) = processKeyEvent(
                event,
                hotkey: pState.hotkey,
                state: &state,
                fnTriggerMode: .pressThenRelease
            )
            pState.fnWasDown = state.fnWasDown
            pState.fnComboKeyPressed = state.fnComboKeyPressed
            pState.modifierWasDown = state.modifierWasDown
            pState.keyWasDown = state.keyWasDown
            pState.mouseButtonWasDown = state.mouseButtonWasDown
            pState.lastTapUpTime = state.lastTapUpTime
            pState.tapCount = state.tapCount
            profileSlots[profileId] = pState
            if isMatch { shouldSuppress = true }
            dispatchProfileMatch(
                profileId: profileId,
                hotkey: pState.hotkey,
                keyDown: keyDown,
                keyUp: keyUp,
                source: source
            )
        }

        // Workflow slots
        for workflowId in Array(workflowSlots.keys) {
            guard var states = workflowSlots[workflowId] else { continue }
            for index in states.indices {
                var wState = states[index]
                if dictationHotkeysPaused, wState.behavior == .startDictation {
                    wState.resetTransientState()
                    states[index] = wState
                    continue
                }
                if shouldSuppressForCapsLockOrigin(event, hotkey: wState.hotkey, keyWasDown: wState.keyWasDown) {
                    wState.resetTransientState()
                    states[index] = wState
                    continue
                }
                var state = SlotState(
                    hotkey: wState.hotkey,
                    fnWasDown: wState.fnWasDown,
                    fnComboKeyPressed: wState.fnComboKeyPressed,
                    modifierWasDown: wState.modifierWasDown,
                    keyWasDown: wState.keyWasDown,
                    mouseButtonWasDown: wState.mouseButtonWasDown,
                    lastTapUpTime: wState.lastTapUpTime,
                    tapCount: wState.tapCount
                )
                let (keyDown, keyUp, isMatch) = processKeyEvent(
                    event,
                    hotkey: wState.hotkey,
                    state: &state,
                    fnTriggerMode: .pressThenRelease
                )
                wState.fnWasDown = state.fnWasDown
                wState.fnComboKeyPressed = state.fnComboKeyPressed
                wState.modifierWasDown = state.modifierWasDown
                wState.keyWasDown = state.keyWasDown
                wState.mouseButtonWasDown = state.mouseButtonWasDown
                wState.lastTapUpTime = state.lastTapUpTime
                wState.tapCount = state.tapCount
                states[index] = wState
                if isMatch { shouldSuppress = true }
                dispatchWorkflowMatch(
                    workflowId: workflowId,
                    hotkey: wState.hotkey,
                    behavior: wState.behavior,
                    event: event,
                    keyDown: keyDown,
                    keyUp: keyUp,
                    source: source
                )
            }
            workflowSlots[workflowId] = states
        }

        return shouldSuppress
    }

    private func updateCapsLockOriginTracker(for event: NSEvent) {
        let now = Date()
        if let until = capsLockOriginSuppressionUntil, now >= until {
            capsLockOriginSuppressionUntil = nil
        }

        guard event.type == .flagsChanged, event.keyCode == Self.capsLockKeyCode else { return }
        capsLockOriginSuppressionUntil = now.addingTimeInterval(Self.capsLockSuppressionWindow)
    }

    private func shouldSuppressForCapsLockOrigin(
        _ event: NSEvent,
        hotkey: UnifiedHotkey,
        keyWasDown: Bool
    ) -> Bool {
        guard let until = capsLockOriginSuppressionUntil, Date() < until else {
            capsLockOriginSuppressionUntil = nil
            return false
        }

        switch hotkey.kind {
        case .modifierCombo:
            return event.type == .flagsChanged
        case .keyWithModifiers:
            if event.type == .keyDown || event.type == .keyUp {
                return event.keyCode == hotkey.keyCode
            }
            if event.type == .flagsChanged {
                return keyWasDown || event.keyCode == Self.capsLockKeyCode
            }
            return false
        case .fn, .modifierOnly, .bareKey, .mouseButton:
            return false
        }
    }

    private func dispatchGlobalMatch(
        slotType: HotkeySlotType,
        hotkey: UnifiedHotkey,
        keyDown: Bool,
        keyUp: Bool,
        source: HotkeyEventSource
    ) {
        if keyDown, shouldDispatch(
            target: .slot(slotType),
            phase: .down,
            hotkey: hotkey,
            source: source
        ) {
            if source != .eventTap {
                logFallbackMatchIfNeeded(hotkey: hotkey, source: source)
            }
            handleKeyDown(slotType: slotType, hotkey: hotkey)
        } else if keyUp, shouldDispatch(
            target: .slot(slotType),
            phase: .up,
            hotkey: hotkey,
            source: source
        ) {
            handleKeyUp(slotType: slotType)
        }
    }

    private func dispatchProfileMatch(
        profileId: UUID,
        hotkey: UnifiedHotkey,
        keyDown: Bool,
        keyUp: Bool,
        source: HotkeyEventSource
    ) {
        if keyDown, shouldDispatch(
            target: .profile(profileId),
            phase: .down,
            hotkey: hotkey,
            source: source
        ) {
            if source != .eventTap {
                logFallbackMatchIfNeeded(hotkey: hotkey, source: source)
            }
            handleProfileKeyDown(profileId: profileId)
        } else if keyUp, shouldDispatch(
            target: .profile(profileId),
            phase: .up,
            hotkey: hotkey,
            source: source
        ) {
            handleProfileKeyUp(profileId: profileId)
        }
    }

    private func dispatchWorkflowMatch(
        workflowId: UUID,
        hotkey: UnifiedHotkey,
        behavior: WorkflowHotkeyBehavior,
        event: NSEvent,
        keyDown: Bool,
        keyUp: Bool,
        source: HotkeyEventSource
    ) {
        let isTextProcessingModifierRelease = behavior != .startDictation
            && keyUp
            && event.type == .flagsChanged
            && hotkey.kind == .keyWithModifiers
        if keyDown, shouldDispatch(
            target: .workflow(workflowId),
            phase: .down,
            hotkey: hotkey,
            source: source
        ) {
            if source != .eventTap {
                logFallbackMatchIfNeeded(hotkey: hotkey, source: source)
            }
            handleWorkflowKeyDown(workflowId: workflowId, behavior: behavior)
        } else if keyUp, !isTextProcessingModifierRelease, shouldDispatch(
            target: .workflow(workflowId),
            phase: .up,
            hotkey: hotkey,
            source: source
        ) {
            handleWorkflowKeyUp(workflowId: workflowId, behavior: behavior)
        }
    }

    private func signalPushToTalkInterruptionIfNeeded(for event: NSEvent) {
        guard discardPushToTalkRecordingOnExtraKeyPress,
              !pushToTalkInterruptionSignaled,
              isActive,
              activeSlotType == .pushToTalk,
              activeProfileId == nil,
              activeWorkflowId == nil,
              event.type == .keyDown,
              let hotkey = activeGlobalHotkey,
              isExtraKeyDuringActivePushToTalk(event, hotkey: hotkey) else {
            return
        }

        pushToTalkInterruptionSignaled = true
        onPushToTalkInterruption?()
    }

    private func isExtraKeyDuringActivePushToTalk(_ event: NSEvent, hotkey: UnifiedHotkey) -> Bool {
        switch hotkey.kind {
        case .modifierCombo, .modifierOnly, .fn:
            return true
        case .keyWithModifiers, .bareKey:
            return event.keyCode != hotkey.keyCode
        case .mouseButton:
            return false
        }
    }

    private func shouldDispatch(
        target: HotkeyDispatchKey.Target,
        phase: HotkeyDispatchPhase,
        hotkey: UnifiedHotkey,
        source: HotkeyEventSource
    ) -> Bool {
        let now = Date()
        recentEventTapDispatches = recentEventTapDispatches.filter {
            now.timeIntervalSince($0.value) < Self.monitorDedupWindow
        }

        let dispatchKey = HotkeyDispatchKey(target: target, phase: phase, hotkey: hotkey)
        if source == .eventTap {
            recentEventTapDispatches[dispatchKey] = now
            return true
        }

        return recentEventTapDispatches[dispatchKey] == nil
    }

    private func logFallbackMatchIfNeeded(hotkey: UnifiedHotkey, source: HotkeyEventSource) {
        guard source == .monitor, eventTap != nil, hotkey.mouseButton == nil else { return }
        logger.info("Matched hotkey via NSEvent compatibility fallback: \(Self.displayName(for: hotkey), privacy: .public)")
    }

#if DEBUG
    func setHotkeyForTesting(_ hotkey: UnifiedHotkey, for slotType: HotkeySlotType) {
        slots[slotType] = [SlotState(hotkey: hotkey)]
    }

    func setHotkeysForTesting(_ hotkeys: [UnifiedHotkey], for slotType: HotkeySlotType) {
        slots[slotType] = Self.uniqueHotkeys(hotkeys).map { SlotState(hotkey: $0) }
    }

    func loadHotkeysForTesting() {
        loadHotkeys()
    }

    @discardableResult
    func processEventForTesting(_ event: NSEvent, source: HotkeyEventSource) -> Bool {
        handleEvent(event, source: source)
    }

    func needsMouseEventMonitoringForTesting() -> Bool {
        needsMouseEventMonitoring
    }

    func needsSuppressingMouseEventTapForTesting() -> Bool {
        needsSuppressingMouseEventTap
    }

    static func suppressingEventTapMaskForTesting(includeMouse: Bool = false) -> CGEventMask {
        suppressingEventTapMask(includeMouse: includeMouse)
    }

    static func eventTapPlacementForTesting() -> CGEventTapPlacement {
        hotkeyEventTapPlacement
    }
#endif

    private enum KeyEventResult {
        case none
        case down
        case up
        case repeatDown
        case modifierRelease // Modifiers no longer match, but key is still physically down
    }

    private func processKeyEvent(
        _ event: NSEvent,
        hotkey: UnifiedHotkey,
        state: inout SlotState,
        fnTriggerMode: FnTriggerMode
    ) -> (keyDown: Bool, keyUp: Bool, shouldSuppress: Bool) {
        // Mouse button hotkeys - self-contained path (no modifier interplay)
        if hotkey.kind == .mouseButton {
            guard event.type == .otherMouseDown || event.type == .otherMouseUp else {
                return (false, false, false)
            }
            guard let button = hotkey.mouseButton, event.buttonNumber == Int(button) else {
                return (false, false, false)
            }
            let shouldSuppress = Self.shouldSuppressMouseButtonHotkey(button)

            let isDown = event.type == .otherMouseDown
            let wasDown = state.mouseButtonWasDown

            if isDown && !wasDown {
                state.mouseButtonWasDown = true
                guard hotkey.isDoubleTap else { return (true, false, shouldSuppress) }
                if state.tapCount == 1,
                   let lastUp = state.lastTapUpTime,
                   Date().timeIntervalSince(lastUp) < Self.doubleTapThreshold {
                    state.tapCount = 2
                    state.lastTapUpTime = nil
                    return (true, false, shouldSuppress)
                } else {
                    state.tapCount = 0
                    state.lastTapUpTime = nil
                    return (false, false, shouldSuppress)
                }
            } else if !isDown && wasDown {
                state.mouseButtonWasDown = false
                guard hotkey.isDoubleTap else { return (false, true, shouldSuppress) }
                if state.tapCount == 2 {
                    state.tapCount = 0
                    return (false, true, shouldSuppress)
                } else {
                    state.tapCount = 1
                    state.lastTapUpTime = Date()
                    return (false, false, shouldSuppress)
                }
            }
            return (false, false, shouldSuppress)
        }

        // Fn hotkeys can run in two modes:
        // - releaseOnly: keep current toggle behavior (start on release)
        // - pressThenRelease: Hybrid/PTT/profiles should start on press and stop on release
        if hotkey.kind == .fn {
            switch fnTriggerMode {
            case .pressThenRelease:
                if state.fnWasDown && event.type == .keyDown {
                    state.fnComboKeyPressed = true
                    return (false, false, false)
                }

                guard event.type == .flagsChanged else {
                    return (false, false, false)
                }

                let fnDown = event.modifierFlags.contains(.function)
                if fnDown, !state.fnWasDown {
                    state.fnWasDown = true
                    state.fnComboKeyPressed = false
                    return (true, false, true)
                }
                guard !fnDown, state.fnWasDown else {
                    return (false, false, false)
                }
                state.fnWasDown = false
                let wasComboed = state.fnComboKeyPressed
                state.fnComboKeyPressed = false
                if wasComboed { return (false, false, false) }
                if hotkey.isDoubleTap {
                    return (false, false, true)
                }
                return (false, true, true)

            case .releaseOnly:
                if state.fnWasDown && event.type == .keyDown {
                    state.fnComboKeyPressed = true
                    return (false, false, false)
                }
                guard event.type == .flagsChanged else { return (false, false, false) }
                let fnDown = event.modifierFlags.contains(.function)
                if fnDown, !state.fnWasDown {
                    state.fnWasDown = true
                    state.fnComboKeyPressed = false
                    return (false, false, false)
                }
                guard !fnDown, state.fnWasDown else { return (false, false, false) }
                state.fnWasDown = false
                let wasComboed = state.fnComboKeyPressed
                state.fnComboKeyPressed = false
                if wasComboed { return (false, false, false) }
                guard hotkey.isDoubleTap else { return (true, false, true) }
                if state.tapCount == 1,
                   let lastUp = state.lastTapUpTime,
                   Date().timeIntervalSince(lastUp) < Self.doubleTapThreshold {
                    state.tapCount = 0
                    state.lastTapUpTime = nil
                    return (true, false, true)
                }
                state.tapCount = 1
                state.lastTapUpTime = Date()
                return (false, false, true)
            }
        }

        let result = detectKeyEvent(
            event, hotkey: hotkey,
            fnWasDown: state.fnWasDown,
            modifierWasDown: state.modifierWasDown,
            keyWasDown: state.keyWasDown
        )

        let value: Bool?
        switch result {
        case .down, .repeatDown, .modifierRelease: value = true
        case .up: value = false
        case .none: value = nil
        }

        if let value {
            switch hotkey.kind {
            case .fn: state.fnWasDown = value
            case .modifierOnly, .modifierCombo: state.modifierWasDown = value
            case .keyWithModifiers, .bareKey: state.keyWasDown = value
            case .mouseButton: state.mouseButtonWasDown = value
            }
        }

        let rawKeyDown = result == .down
        let rawKeyUp = result == .up || result == .modifierRelease
        let isMatch = result != .none

        // For non-double-tap hotkeys, pass through directly
        guard hotkey.isDoubleTap else {
            return (rawKeyDown, rawKeyUp, isMatch)
        }

        // Double-tap state machine: layer on top of single-tap detection
        if rawKeyDown {
            if state.tapCount == 1,
               let lastUp = state.lastTapUpTime,
               Date().timeIntervalSince(lastUp) < Self.doubleTapThreshold {
                // Second tap within threshold - fire
                state.tapCount = 2
                state.lastTapUpTime = nil
                return (true, false, true)
            } else {
                // First tap (or threshold expired) - don't fire yet
                state.tapCount = 0
                state.lastTapUpTime = nil
                return (false, false, true)
            }
        }

        if result == .repeatDown {
            // Suppress repeats if we are in the middle of a double-tap or it's already active
            return (false, false, true)
        }

        if rawKeyUp {
            if state.tapCount == 2 {
                // Release after second tap - real keyUp
                state.tapCount = 0
                return (false, true, true)
            } else {
                // Release after first tap - start waiting for second
                state.tapCount = 1
                state.lastTapUpTime = Date()
                return (false, false, true)
            }
        }

        return (false, false, false)
    }

    /// Generic key event detection: returns a KeyEventResult for a given hotkey configuration.
    private func detectKeyEvent(
        _ event: NSEvent,
        hotkey: UnifiedHotkey,
        fnWasDown: Bool,
        modifierWasDown: Bool,
        keyWasDown: Bool
    ) -> KeyEventResult {
        switch hotkey.kind {
        case .fn:
            guard event.type == .flagsChanged else { return .none }
            let fnDown = event.modifierFlags.contains(.function)
            if fnDown, !fnWasDown { return .down }
            if !fnDown, fnWasDown { return .up }
            if fnDown, fnWasDown { return .repeatDown }

        case .modifierOnly:
            guard event.type == .flagsChanged, event.keyCode == hotkey.keyCode else { return .none }
            let flag = Self.modifierFlagForKeyCode(hotkey.keyCode)
            guard let flag else { return .none }
            let isDown = event.modifierFlags.contains(flag)
            if isDown, !modifierWasDown { return .down }
            if !isDown, modifierWasDown { return .up }
            if isDown, modifierWasDown { return .repeatDown }

        case .modifierCombo:
            guard event.type == .flagsChanged else { return .none }
            let requiredFlags = NSEvent.ModifierFlags(rawValue: hotkey.modifierFlags)
            let relevantMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]
            let current = event.modifierFlags.intersection(relevantMask)
            let activeModifierKeyCodes = Self.modifierKeyCodes(from: event.modifierFlags)
            let physicalModifiersMatch = hotkey.modifierKeyCodes.isEmpty
                || activeModifierKeyCodes == hotkey.modifierKeyCodes
            let allDown = current == requiredFlags && physicalModifiersMatch
            let anyRequiredStillDown = hotkey.modifierKeyCodes.isEmpty
                ? !current.intersection(requiredFlags).isEmpty
                : !activeModifierKeyCodes.intersection(hotkey.modifierKeyCodes).isEmpty
            if allDown, !modifierWasDown { return .down }
            if allDown, modifierWasDown { return .repeatDown }
            if modifierWasDown {
                return anyRequiredStillDown ? .repeatDown : .up
            }

        case .keyWithModifiers:
            let requiredFlags = NSEvent.ModifierFlags(rawValue: hotkey.modifierFlags)
            let relevantMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]
            let currentRelevant = event.modifierFlags.intersection(relevantMask)

            if event.type == .keyDown, event.keyCode == hotkey.keyCode {
                if currentRelevant == requiredFlags {
                    return keyWasDown ? .repeatDown : .down
                } else if keyWasDown {
                    return .repeatDown // Modifiers released but key held -> still ours
                }
            } else if event.type == .keyUp, event.keyCode == hotkey.keyCode {
                if keyWasDown { return .up }
            } else if event.type == .flagsChanged, keyWasDown {
                if !currentRelevant.contains(requiredFlags) {
                    return .modifierRelease
                }
            }

        case .bareKey:
            guard event.keyCode == hotkey.keyCode else { return .none }
            let ignoredModifiers: NSEvent.ModifierFlags = [.command, .option, .control]
            if !event.modifierFlags.intersection(ignoredModifiers).isEmpty { return .none }

            if event.type == .keyDown {
                return keyWasDown ? .repeatDown : .down
            }
            if event.type == .keyUp {
                return .up
            }

        case .mouseButton:
            return .none // Handled directly in processKeyEvent
        }
        return .none
    }

    // MARK: - Key Down / Up (Global Slots)

    private func handleKeyDown(slotType: HotkeySlotType, hotkey: UnifiedHotkey) {
        if slotType == .promptPalette {
            onPromptPaletteToggle?()
            return
        }
        if slotType == .recentTranscriptions {
            onRecentTranscriptionsToggle?()
            return
        }
        if slotType == .copyLastTranscription {
            onCopyLastTranscription?()
            return
        }
        if slotType == .recorderToggle {
            onRecorderToggle?()
            return
        }

        if isActive {
            // Any hotkey stops active recording
            isActive = false
            activeSlotType = nil
            activeGlobalHotkey = nil
            activeProfileId = nil
            activeWorkflowId = nil
            currentMode = nil
            keyDownTime = nil
            pushToTalkInterruptionSignaled = false
            onDictationStop?()
        } else {
            let requestTimestamp = Self.requestTimestamp()
            activeSlotType = slotType
            activeGlobalHotkey = hotkey
            activeProfileId = nil
            activeWorkflowId = nil
            keyDownTime = Date()
            isActive = true
            pushToTalkInterruptionSignaled = false
            currentMode = slotType == .toggle ? .toggle : .pushToTalk
            onDictationStart?(requestTimestamp)
        }
    }

    private func handleKeyUp(slotType: HotkeySlotType) {
        guard isActive, slotType == activeSlotType, activeProfileId == nil, activeWorkflowId == nil else { return }

        switch slotType {
        case .hybrid:
            guard let downTime = keyDownTime else { return }
            if Date().timeIntervalSince(downTime) < Self.toggleThreshold {
                currentMode = .toggle
            } else {
                isActive = false
                activeSlotType = nil
                activeGlobalHotkey = nil
                currentMode = nil
                keyDownTime = nil
                pushToTalkInterruptionSignaled = false
                onDictationStop?()
            }
        case .pushToTalk:
            isActive = false
            activeSlotType = nil
            activeGlobalHotkey = nil
            currentMode = nil
            keyDownTime = nil
            pushToTalkInterruptionSignaled = false
            onDictationStop?()
        case .toggle:
            break
        case .promptPalette:
            break // handled on keyDown only
        case .recentTranscriptions:
            break // handled on keyDown only
        case .copyLastTranscription:
            break // handled on keyDown only
        case .recorderToggle:
            break // handled on keyDown only
        }
    }

    // MARK: - Key Down / Up (Profile Slots)

    private func handleProfileKeyDown(profileId: UUID) {
        if isActive {
            // Any hotkey stops active recording
            isActive = false
            activeSlotType = nil
            activeGlobalHotkey = nil
            activeProfileId = nil
            activeWorkflowId = nil
            currentMode = nil
            keyDownTime = nil
            pushToTalkInterruptionSignaled = false
            onDictationStop?()
        } else {
            let requestTimestamp = Self.requestTimestamp()
            activeProfileId = profileId
            activeWorkflowId = nil
            activeSlotType = nil
            activeGlobalHotkey = nil
            keyDownTime = Date()
            isActive = true
            pushToTalkInterruptionSignaled = false
            currentMode = .pushToTalk // hybrid behavior
            onProfileDictationStart?(profileId, requestTimestamp)
        }
    }

    private func handleProfileKeyUp(profileId: UUID) {
        guard isActive, activeProfileId == profileId else { return }

        // Hybrid behavior: short press = toggle, long press = PTT
        guard let downTime = keyDownTime else { return }
        if Date().timeIntervalSince(downTime) < Self.toggleThreshold {
            currentMode = .toggle
        } else {
            isActive = false
            activeSlotType = nil
            activeGlobalHotkey = nil
            activeProfileId = nil
            activeWorkflowId = nil
            currentMode = nil
            keyDownTime = nil
            pushToTalkInterruptionSignaled = false
            onDictationStop?()
        }
    }

    // MARK: - Key Down / Up (Workflow Slots)

    private func handleWorkflowKeyDown(workflowId: UUID, behavior: WorkflowHotkeyBehavior) {
        guard behavior == .startDictation else {
            guard !isActive else {
                isActive = false
                activeSlotType = nil
                activeGlobalHotkey = nil
                activeProfileId = nil
                activeWorkflowId = nil
                currentMode = nil
                keyDownTime = nil
                pushToTalkInterruptionSignaled = false
                onDictationStop?()
                return
            }
            activeWorkflowId = workflowId
            return
        }

        if isActive {
            isActive = false
            activeSlotType = nil
            activeGlobalHotkey = nil
            activeProfileId = nil
            activeWorkflowId = nil
            currentMode = nil
            keyDownTime = nil
            pushToTalkInterruptionSignaled = false
            onDictationStop?()
        } else {
            let requestTimestamp = Self.requestTimestamp()
            activeProfileId = nil
            activeWorkflowId = workflowId
            activeSlotType = nil
            activeGlobalHotkey = nil
            keyDownTime = Date()
            isActive = true
            pushToTalkInterruptionSignaled = false
            currentMode = .pushToTalk
            onWorkflowDictationStart?(workflowId, requestTimestamp)
        }
    }

    private func handleWorkflowKeyUp(workflowId: UUID, behavior: WorkflowHotkeyBehavior) {
        guard behavior == .startDictation else {
            guard activeWorkflowId == workflowId else { return }
            activeWorkflowId = nil
            dispatchWorkflowTextProcessingWhenInputSettles(workflowId: workflowId)
            return
        }
        guard isActive, activeWorkflowId == workflowId else { return }

        guard let downTime = keyDownTime else { return }
        if Date().timeIntervalSince(downTime) < Self.toggleThreshold {
            currentMode = .toggle
        } else {
            isActive = false
            activeSlotType = nil
            activeGlobalHotkey = nil
            activeProfileId = nil
            activeWorkflowId = nil
            currentMode = nil
            keyDownTime = nil
            pushToTalkInterruptionSignaled = false
            onDictationStop?()
        }
    }

    private func dispatchWorkflowTextProcessingWhenInputSettles(
        workflowId: UUID,
        deadline: Date? = nil,
        postReleaseDelayApplied: Bool = false
    ) {
        let deadline = deadline ?? Date().addingTimeInterval(workflowTextProcessingModifierReleaseTimeout)
        guard workflowTextProcessingModifiersReleased() || Date() >= deadline else {
            DispatchQueue.main.asyncAfter(deadline: .now() + workflowTextProcessingModifierPollInterval) { [weak self] in
                self?.dispatchWorkflowTextProcessingWhenInputSettles(
                    workflowId: workflowId,
                    deadline: deadline,
                    postReleaseDelayApplied: false
                )
            }
            return
        }

        if !postReleaseDelayApplied, Date() < deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + workflowTextProcessingPostReleaseDelay) { [weak self] in
                self?.dispatchWorkflowTextProcessingWhenInputSettles(
                    workflowId: workflowId,
                    deadline: deadline,
                    postReleaseDelayApplied: true
                )
            }
            return
        }

        onWorkflowTextProcessing?(workflowId)
    }

    private func workflowTextProcessingModifiersReleased() -> Bool {
        let relevantMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]
        let currentFlags = modifierFlagsStateProvider().intersection(relevantMask)
        return currentFlags.isEmpty
    }

    // MARK: - Display Name

    nonisolated static func menuShortcutDescriptor(for hotkey: UnifiedHotkey) -> MenuShortcutDescriptor? {
        guard !hotkey.isDoubleTap,
              hotkey.mouseButton == nil,
              !hotkey.isFn,
              hotkey.kind == .keyWithModifiers || hotkey.kind == .bareKey,
              let keyEquivalent = menuKeyEquivalent(for: hotkey.keyCode) else {
            return nil
        }

        let relevantModifiers = NSEvent.ModifierFlags(rawValue: hotkey.modifierFlags)
            .intersection([.command, .option, .control, .shift, .function])

        return MenuShortcutDescriptor(
            keyEquivalent: keyEquivalent,
            modifiers: relevantModifiers
        )
    }

    nonisolated static func displayName(for hotkey: UnifiedHotkey) -> String {
        if let button = hotkey.mouseButton {
            let baseName = mouseButtonName(for: button)
            return hotkey.isDoubleTap ? "\(baseName) x2" : baseName
        }
        if hotkey.isFn { return hotkey.isDoubleTap ? "Fn x2" : "Fn" }

        if hotkey.kind == .modifierCombo, !hotkey.modifierKeyCodes.isEmpty {
            let baseName = displayName(
                forModifierKeyCodes: hotkey.modifierKeyCodes,
                modifierFlags: NSEvent.ModifierFlags(rawValue: hotkey.modifierFlags)
            )
            return hotkey.isDoubleTap ? "\(baseName) x2" : baseName
        }

        var parts: [String] = []

        let flags = NSEvent.ModifierFlags(rawValue: hotkey.modifierFlags)
        if flags.contains(.function) { parts.append("Fn") }
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }

        if hotkey.kind != .modifierCombo {
            parts.append(keyName(for: hotkey.keyCode))
        }

        let baseName = parts.joined()
        return hotkey.isDoubleTap ? "\(baseName) x2" : baseName
    }

    nonisolated static func keyName(for keyCode: UInt16) -> String {
        // Special keys that don't produce meaningful characters via UCKeyTranslate
        let specialKeys: [UInt16: String] = [
            0x24: "⏎", 0x30: "⇥", 0x31: "␣", 0x33: "⌫", 0x35: "⎋",
            0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4",
            0x60: "F5", 0x61: "F6", 0x62: "F7", 0x64: "F8",
            0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
            0x69: "F13", 0x6B: "F14", 0x71: "F15",
            0x7E: "↑", 0x7D: "↓", 0x7B: "←", 0x7C: "→",
        ]
        if let name = specialKeys[keyCode] { return name }

        let modifierNames: [UInt16: String] = [
            0x37: "Left Command", 0x36: "Right Command",
            0x38: "Left Shift", 0x3C: "Right Shift",
            0x3A: "Left Option", 0x3D: "Right Option",
            0x3B: "Left Control", 0x3E: "Right Control",
        ]
        if let name = modifierNames[keyCode] { return name }

        // Use the current keyboard layout to resolve the character for this keyCode
        if let character = characterForKeyCode(keyCode) {
            return character.uppercased()
        }

        // QWERTY fallback for when layout resolution fails
        let qwertyFallback: [UInt16: String] = [
            0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H",
            0x05: "G", 0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V",
            0x0A: "§", 0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E",
            0x0F: "R", 0x10: "Y", 0x11: "T", 0x12: "1", 0x13: "2",
            0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=",
            0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0",
            0x1E: "]", 0x1F: "O", 0x20: "U", 0x21: "[", 0x22: "I",
            0x23: "P", 0x25: "L", 0x26: "J", 0x27: "'",
            0x28: "K", 0x29: ";", 0x2A: "\\", 0x2B: ",", 0x2C: "/",
            0x2D: "N", 0x2E: "M", 0x2F: ".", 0x32: "`",
        ]
        if let name = qwertyFallback[keyCode] { return name }

        return "Key \(keyCode)"
    }

    private nonisolated static func menuKeyEquivalent(for keyCode: UInt16) -> Character? {
        let specialKeys: [UInt16: UInt32] = [
            0x24: 0x000D,
            0x30: 0x0009,
            0x31: 0x0020,
            0x33: 0x0008,
            0x35: 0x001B,
            0x60: UInt32(NSF5FunctionKey),
            0x61: UInt32(NSF6FunctionKey),
            0x62: UInt32(NSF7FunctionKey),
            0x63: UInt32(NSF3FunctionKey),
            0x64: UInt32(NSF8FunctionKey),
            0x65: UInt32(NSF9FunctionKey),
            0x67: UInt32(NSF11FunctionKey),
            0x69: UInt32(NSF13FunctionKey),
            0x6B: UInt32(NSF14FunctionKey),
            0x6D: UInt32(NSF10FunctionKey),
            0x6F: UInt32(NSF12FunctionKey),
            0x71: UInt32(NSF15FunctionKey),
            0x76: UInt32(NSF4FunctionKey),
            0x78: UInt32(NSF2FunctionKey),
            0x7A: UInt32(NSF1FunctionKey),
            0x7B: UInt32(NSLeftArrowFunctionKey),
            0x7C: UInt32(NSRightArrowFunctionKey),
            0x7D: UInt32(NSDownArrowFunctionKey),
            0x7E: UInt32(NSUpArrowFunctionKey),
        ]
        if let scalarValue = specialKeys[keyCode], let scalar = UnicodeScalar(scalarValue) {
            return Character(scalar)
        }

        guard let character = characterForKeyCode(keyCode),
              character.count == 1,
              let scalar = character.unicodeScalars.first else {
            return nil
        }

        if CharacterSet.letters.contains(scalar) {
            return Character(character.lowercased())
        }

        return Character(String(scalar))
    }

    /// Resolves the character for a keyCode using the current keyboard input source.
    private nonisolated static func characterForKeyCode(_ keyCode: UInt16) -> String? {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let layoutDataRef = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = unsafeBitCast(layoutDataRef, to: CFData.self)
        let keyLayoutPtr = unsafeBitCast(CFDataGetBytePtr(layoutData), to: UnsafePointer<UCKeyboardLayout>.self)

        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0

        let status = UCKeyTranslate(
            keyLayoutPtr,
            keyCode,
            UInt16(kUCKeyActionDown),
            0, // no modifiers
            UInt32(LMGetKbdType()),
            UInt32(kUCKeyTranslateNoDeadKeysMask),
            &deadKeyState,
            chars.count,
            &length,
            &chars
        )

        guard status == noErr, length > 0 else { return nil }
        let result = String(utf16CodeUnits: chars, count: length)
        // Filter out control characters (e.g. from non-printable keys)
        if result.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) }) {
            return nil
        }
        return result
    }

    nonisolated static func mouseButtonName(for button: UInt16) -> String {
        switch button {
        case 2: return String(localized: "Middle Click")
        case 3: return String(localized: "Mouse Button 4")
        case 4: return String(localized: "Mouse Button 5")
        default: return String(localized: "Mouse Button \(button + 1)")
        }
    }

    // MARK: - Helpers

    nonisolated static func displayName(forModifierKeyCodes keyCodes: Set<UInt16>) -> String {
        keyCodes
            .sorted(by: modifierKeyCodeComesBefore)
            .map(keyName(for:))
            .joined(separator: " + ")
    }

    nonisolated static func displayName(
        forModifierKeyCodes keyCodes: Set<UInt16>,
        modifierFlags: NSEvent.ModifierFlags
    ) -> String {
        var parts: [String] = []
        if modifierFlags.contains(.function) { parts.append("Fn") }
        parts.append(contentsOf: keyCodes.sorted(by: modifierKeyCodeComesBefore).map(keyName(for:)))
        return parts.joined(separator: " + ")
    }

    nonisolated static func modifierKeyCodes(from flags: NSEvent.ModifierFlags) -> Set<UInt16> {
        let rawValue = flags.rawValue
        return Set(deviceModifierKeyMasks.compactMap { entry in
            rawValue & entry.mask == entry.mask ? entry.keyCode : nil
        })
    }

    nonisolated static func modifierFlagForKeyCode(_ keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 0x37, 0x36: return .command
        case 0x38, 0x3C: return .shift
        case 0x3A, 0x3D: return .option
        case 0x3B, 0x3E: return .control
        default: return nil
        }
    }

    private nonisolated static let deviceModifierKeyMasks: [(mask: UInt, keyCode: UInt16)] = [
        (0x00000008, 0x37), // Left Command
        (0x00000010, 0x36), // Right Command
        (0x00000002, 0x38), // Left Shift
        (0x00000004, 0x3C), // Right Shift
        (0x00000020, 0x3A), // Left Option
        (0x00000040, 0x3D), // Right Option
        (0x00000001, 0x3B), // Left Control
        (0x00002000, 0x3E), // Right Control
    ]

    private nonisolated static func modifierKeyCodeComesBefore(_ lhs: UInt16, _ rhs: UInt16) -> Bool {
        modifierKeyCodeSortIndex(lhs) < modifierKeyCodeSortIndex(rhs)
    }

    private nonisolated static func modifierKeyCodeSortIndex(_ keyCode: UInt16) -> Int {
        switch keyCode {
        case 0x37: return 0 // Left Command
        case 0x36: return 1 // Right Command
        case 0x3A: return 2 // Left Option
        case 0x3D: return 3 // Right Option
        case 0x3B: return 4 // Left Control
        case 0x3E: return 5 // Right Control
        case 0x38: return 6 // Left Shift
        case 0x3C: return 7 // Right Shift
        default: return Int(keyCode) + 100
        }
    }
}
