import Foundation
import AppKit
import Carbon.HIToolbox
import Combine
import os

struct UnifiedHotkey: Equatable, Hashable, Sendable, Codable {
    let keyCode: UInt16
    let modifierFlags: UInt
    let isFn: Bool
    let isDoubleTap: Bool
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

    init(keyCode: UInt16, modifierFlags: UInt, isFn: Bool, isDoubleTap: Bool = false) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
        self.isFn = isFn
        self.isDoubleTap = isDoubleTap
        self.mouseButton = nil
    }

    init(mouseButton: UInt16, isDoubleTap: Bool = false) {
        self.keyCode = 0
        self.modifierFlags = 0
        self.isFn = false
        self.isDoubleTap = isDoubleTap
        self.mouseButton = mouseButton
    }

    // Backward-compatible decoding: old hotkeys without isDoubleTap/mouseButton decode correctly
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decode(UInt16.self, forKey: .keyCode)
        modifierFlags = try container.decode(UInt.self, forKey: .modifierFlags)
        isFn = try container.decode(Bool.self, forKey: .isFn)
        isDoubleTap = try container.decodeIfPresent(Bool.self, forKey: .isDoubleTap) ?? false
        mouseButton = try container.decodeIfPresent(UInt16.self, forKey: .mouseButton)
    }
}

enum HotkeySlotType: String, CaseIterable, Sendable {
    case hybrid
    case pushToTalk
    case toggle
    case promptPalette

    var defaultsKey: String {
        switch self {
        case .hybrid: return UserDefaultsKeys.hybridHotkey
        case .pushToTalk: return UserDefaultsKeys.pttHotkey
        case .toggle: return UserDefaultsKeys.toggleHotkey
        case .promptPalette: return UserDefaultsKeys.promptPaletteHotkey
        }
    }
}

/// Manages global hotkeys for dictation with three independent slots:
/// hybrid (short=toggle, long=push-to-talk), push-to-talk, and toggle.
@MainActor
final class HotkeyService: ObservableObject {
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
            case slot(HotkeySlotType)
            case profile(UUID)
        }

        let target: Target
        let phase: HotkeyDispatchPhase
        let hotkey: UnifiedHotkey
    }

    enum HotkeyMode: String {
        case pushToTalk
        case toggle
    }

    @Published private(set) var currentMode: HotkeyMode?

    var onDictationStart: (() -> Void)?
    var onDictationStop: (() -> Void)?
    var onPromptPaletteToggle: (() -> Void)?
    var onProfileDictationStart: ((UUID) -> Void)?
    var onCancelPressed: (() -> Void)?

    private var keyDownTime: Date?
    private var isActive = false
    private var activeSlotType: HotkeySlotType?
    private(set) var activeProfileId: UUID?

    private static let toggleThreshold: TimeInterval = 1.0
    private static let doubleTapThreshold: TimeInterval = 0.4
    private static let monitorDedupWindow: TimeInterval = 0.12

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
    }

    private var slots: [HotkeySlotType: SlotState] = [
        .hybrid: SlotState(),
        .pushToTalk: SlotState(),
        .toggle: SlotState(),
        .promptPalette: SlotState(),
    ]

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
    }

    private var profileSlots: [UUID: ProfileHotkeyState] = [:]

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var recentEventTapDispatches: [HotkeyDispatchKey: Date] = [:]

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

    func updateHotkey(_ hotkey: UnifiedHotkey, for slotType: HotkeySlotType) {
        slots[slotType] = SlotState(hotkey: hotkey)
        UserDefaults.standard.set(try? JSONEncoder().encode(hotkey), forKey: slotType.defaultsKey)
        tearDownMonitor()
        setupMonitor()
    }

    func clearHotkey(for slotType: HotkeySlotType) {
        slots[slotType] = SlotState()
        UserDefaults.standard.removeObject(forKey: slotType.defaultsKey)
        tearDownMonitor()
        setupMonitor()
    }

    /// Returns which slot already has this hotkey assigned, excluding a given slot.
    /// Also detects conflicts between single-tap and double-tap variants of the same key.
    func isHotkeyAssigned(_ hotkey: UnifiedHotkey, excluding: HotkeySlotType) -> HotkeySlotType? {
        for slotType in HotkeySlotType.allCases where slotType != excluding {
            guard let existing = slots[slotType]?.hotkey else { continue }
            if existing == hotkey { return slotType }
            if existing.keyCode == hotkey.keyCode
                && existing.modifierFlags == hotkey.modifierFlags
                && existing.isFn == hotkey.isFn
                && existing.mouseButton == hotkey.mouseButton
                && existing.isDoubleTap != hotkey.isDoubleTap {
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
        activeProfileId = nil
        currentMode = nil
        keyDownTime = nil
    }

    // MARK: - Profile Hotkeys

    func registerProfileHotkeys(_ entries: [(id: UUID, hotkey: UnifiedHotkey)]) {
        profileSlots.removeAll()
        for entry in entries {
            profileSlots[entry.id] = ProfileHotkeyState(profileId: entry.id, hotkey: entry.hotkey)
        }
        tearDownMonitor()
        setupMonitor()
    }

    func isHotkeyAssignedToProfile(_ hotkey: UnifiedHotkey, excludingProfileId: UUID?) -> UUID? {
        for (id, state) in profileSlots where id != excludingProfileId {
            if state.hotkey == hotkey { return id }
            if state.hotkey.keyCode == hotkey.keyCode
                && state.hotkey.modifierFlags == hotkey.modifierFlags
                && state.hotkey.isFn == hotkey.isFn
                && state.hotkey.mouseButton == hotkey.mouseButton
                && state.hotkey.isDoubleTap != hotkey.isDoubleTap {
                return id
            }
        }
        return nil
    }

    func isHotkeyAssignedToGlobalSlot(_ hotkey: UnifiedHotkey) -> HotkeySlotType? {
        for slotType in HotkeySlotType.allCases {
            guard let existing = slots[slotType]?.hotkey else { continue }
            if existing == hotkey { return slotType }
            if existing.keyCode == hotkey.keyCode
                && existing.modifierFlags == hotkey.modifierFlags
                && existing.isFn == hotkey.isFn
                && existing.mouseButton == hotkey.mouseButton
                && existing.isDoubleTap != hotkey.isDoubleTap {
                return slotType
            }
        }
        return nil
    }

    private func loadHotkeys() {
        let defaults = UserDefaults.standard
        for slotType in HotkeySlotType.allCases {
            if let data = defaults.data(forKey: slotType.defaultsKey),
               let hotkey = try? JSONDecoder().decode(UnifiedHotkey.self, from: data) {
                slots[slotType] = SlotState(hotkey: hotkey)
            }
        }
    }

    // MARK: - Event Monitor

    private func setupMonitor() {
        tearDownMonitor()

        // Try CGEventTap first - it can suppress hotkey events from reaching other apps
        if setupEventTap() {
            logger.info("Using tail-appended CGEventTap for hotkey monitoring with NSEvent compatibility fallback")
            installEventMonitors(includeMouse: false)
            return
        }

        // Fallback: NSEvent monitors (no event suppression)
        logger.info("CGEventTap unavailable, falling back to NSEvent monitors (hotkey events will pass through)")
        installEventMonitors(includeMouse: true)
    }

    private func installEventMonitors(includeMouse: Bool) {
        var mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp]
        if includeMouse {
            mask.insert(.otherMouseDown)
            mask.insert(.otherMouseUp)
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor [weak self] in
                _ = self?.handleEvent(event, source: .monitor)
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            Task { @MainActor [weak self] in
                _ = self?.handleEvent(event, source: .monitor)
            }
            return event
        }
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
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        recentEventTapDispatches.removeAll()
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
    private func setupEventTap() -> Bool {
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.otherMouseUp.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // @convention(c) callback - must not capture context. Uses userInfo to access HotkeyService.
        // Runs on the main thread (tap is added to main run loop), so MainActor.assumeIsolated is safe.
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let userInfo {
                    MainActor.assumeIsolated {
                        let service = Unmanaged<HotkeyService>.fromOpaque(userInfo).takeUnretainedValue()
                        if let tap = service.eventTap {
                            CGEvent.tapEnable(tap: tap, enable: true)
                        }
                        service.logger.warning("CGEventTap was disabled by system, re-enabling")
                    }
                }
                return Unmanaged.passUnretained(event)
            }

            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let shouldSuppress: Bool = MainActor.assumeIsolated {
                guard let nsEvent = NSEvent(cgEvent: event) else { return false }
                let service = Unmanaged<HotkeyService>.fromOpaque(userInfo).takeUnretainedValue()
                return service.handleEventTapEvent(nsEvent)
            }

            return shouldSuppress ? nil : Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
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

    /// Processes event for CGEventTap: matches hotkeys synchronously, dispatches handling asynchronously.
    /// Returns true if the event should be suppressed (consumed by TypeWhisper).
    private func handleEventTapEvent(_ event: NSEvent) -> Bool {
        handleEvent(event, source: .eventTap)
    }

    // MARK: - NSEvent Fallback

    @discardableResult
    private func handleEvent(_ event: NSEvent, source: HotkeyEventSource) -> Bool {
        // Escape key cancels active recording/transcription
        if event.type == .keyDown && event.keyCode == 0x35 {
            if source == .eventTap {
                Task { @MainActor [weak self] in
                    self?.onCancelPressed?()
                }
            } else {
                onCancelPressed?()
            }
            return false
        }

        var shouldSuppress = false

        // Global slots
        for slotType in HotkeySlotType.allCases {
            guard var state = slots[slotType], let hotkey = state.hotkey else { continue }
            let (keyDown, keyUp, isMatch) = processKeyEvent(event, hotkey: hotkey, state: &state)
            slots[slotType] = state
            if isMatch { shouldSuppress = true }
            dispatchGlobalMatch(
                slotType: slotType,
                hotkey: hotkey,
                keyDown: keyDown,
                keyUp: keyUp,
                source: source
            )
        }

        // Profile slots
        for profileId in Array(profileSlots.keys) {
            guard var pState = profileSlots[profileId] else { continue }
            var state = SlotState(hotkey: pState.hotkey, fnWasDown: pState.fnWasDown,
                                  fnComboKeyPressed: pState.fnComboKeyPressed,
                                  modifierWasDown: pState.modifierWasDown, keyWasDown: pState.keyWasDown,
                                  mouseButtonWasDown: pState.mouseButtonWasDown,
                                  lastTapUpTime: pState.lastTapUpTime, tapCount: pState.tapCount)
            let (keyDown, keyUp, isMatch) = processKeyEvent(event, hotkey: pState.hotkey, state: &state)
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

        return shouldSuppress
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
            if source == .eventTap {
                Task { @MainActor [weak self] in self?.handleKeyDown(slotType: slotType) }
            } else {
                logFallbackMatchIfNeeded(hotkey: hotkey, source: source)
                handleKeyDown(slotType: slotType)
            }
        } else if keyUp, shouldDispatch(
            target: .slot(slotType),
            phase: .up,
            hotkey: hotkey,
            source: source
        ) {
            if source == .eventTap {
                Task { @MainActor [weak self] in self?.handleKeyUp(slotType: slotType) }
            } else {
                handleKeyUp(slotType: slotType)
            }
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
            if source == .eventTap {
                Task { @MainActor [weak self] in self?.handleProfileKeyDown(profileId: profileId) }
            } else {
                logFallbackMatchIfNeeded(hotkey: hotkey, source: source)
                handleProfileKeyDown(profileId: profileId)
            }
        } else if keyUp, shouldDispatch(
            target: .profile(profileId),
            phase: .up,
            hotkey: hotkey,
            source: source
        ) {
            if source == .eventTap {
                Task { @MainActor [weak self] in self?.handleProfileKeyUp(profileId: profileId) }
            } else {
                handleProfileKeyUp(profileId: profileId)
            }
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
        slots[slotType] = SlotState(hotkey: hotkey)
    }

    @discardableResult
    func processEventForTesting(_ event: NSEvent, source: HotkeyEventSource) -> Bool {
        handleEvent(event, source: source)
    }
#endif

    private enum KeyEventResult {
        case none
        case down
        case up
        case repeatDown
        case modifierRelease // Modifiers no longer match, but key is still physically down
    }

    /// Processes a key event against a hotkey, updating state booleans.
    /// Returns (keyDown, keyUp, shouldSuppress) flags.
    private func processKeyEvent(_ event: NSEvent, hotkey: UnifiedHotkey, state: inout SlotState) -> (keyDown: Bool, keyUp: Bool, shouldSuppress: Bool) {
        // Mouse button hotkeys - self-contained path (no modifier interplay)
        if hotkey.kind == .mouseButton {
            guard event.type == .otherMouseDown || event.type == .otherMouseUp else {
                return (false, false, false)
            }
            guard let button = hotkey.mouseButton, event.buttonNumber == Int(button) else {
                return (false, false, false)
            }

            let isDown = event.type == .otherMouseDown
            let wasDown = state.mouseButtonWasDown

            if isDown && !wasDown {
                state.mouseButtonWasDown = true
                guard hotkey.isDoubleTap else { return (true, false, true) }
                if state.tapCount == 1,
                   let lastUp = state.lastTapUpTime,
                   Date().timeIntervalSince(lastUp) < Self.doubleTapThreshold {
                    state.tapCount = 2
                    state.lastTapUpTime = nil
                    return (true, false, true)
                } else {
                    state.tapCount = 0
                    state.lastTapUpTime = nil
                    return (false, false, true)
                }
            } else if !isDown && wasDown {
                state.mouseButtonWasDown = false
                guard hotkey.isDoubleTap else { return (false, true, true) }
                if state.tapCount == 2 {
                    state.tapCount = 0
                    return (false, true, true)
                } else {
                    state.tapCount = 1
                    state.lastTapUpTime = Date()
                    return (false, false, true)
                }
            }
            return (false, false, false)
        }

        // Fn hotkeys fire on release to avoid conflicts with Fn+key combos
        // (e.g. Fn+Backspace = forward delete, Fn+Arrow = page navigation)
        if hotkey.kind == .fn {
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
            if state.tapCount == 1, let lastUp = state.lastTapUpTime,
               Date().timeIntervalSince(lastUp) < Self.doubleTapThreshold {
                state.tapCount = 0; state.lastTapUpTime = nil
                return (true, false, true)
            }
            state.tapCount = 1; state.lastTapUpTime = Date()
            return (false, false, true)
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
            let allDown = current.contains(requiredFlags)
            if allDown, !modifierWasDown { return .down }
            if !allDown, modifierWasDown {
                // If the sentinel keyCode (0xFFFF) is used, we have no physical key to track.
                // Otherwise, we'd need to track which modifiers are still down.
                // For now, modifier-only combos don't have a 'base key'.
                return .up
            }
            if allDown, modifierWasDown { return .repeatDown }

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

    private func handleKeyDown(slotType: HotkeySlotType) {
        if slotType == .promptPalette {
            onPromptPaletteToggle?()
            return
        }

        if isActive {
            // Any hotkey stops active recording
            isActive = false
            activeSlotType = nil
            activeProfileId = nil
            currentMode = nil
            keyDownTime = nil
            onDictationStop?()
        } else {
            activeSlotType = slotType
            activeProfileId = nil
            keyDownTime = Date()
            isActive = true
            currentMode = slotType == .toggle ? .toggle : .pushToTalk
            onDictationStart?()
        }
    }

    private func handleKeyUp(slotType: HotkeySlotType) {
        guard isActive, slotType == activeSlotType, activeProfileId == nil else { return }

        switch slotType {
        case .hybrid:
            guard let downTime = keyDownTime else { return }
            if Date().timeIntervalSince(downTime) < Self.toggleThreshold {
                currentMode = .toggle
            } else {
                isActive = false
                activeSlotType = nil
                currentMode = nil
                keyDownTime = nil
                onDictationStop?()
            }
        case .pushToTalk:
            isActive = false
            activeSlotType = nil
            currentMode = nil
            keyDownTime = nil
            onDictationStop?()
        case .toggle:
            break
        case .promptPalette:
            break // handled on keyDown only
        }
    }

    // MARK: - Key Down / Up (Profile Slots)

    private func handleProfileKeyDown(profileId: UUID) {
        if isActive {
            // Any hotkey stops active recording
            isActive = false
            activeSlotType = nil
            activeProfileId = nil
            currentMode = nil
            keyDownTime = nil
            onDictationStop?()
        } else {
            activeProfileId = profileId
            activeSlotType = nil
            keyDownTime = Date()
            isActive = true
            currentMode = .pushToTalk // hybrid behavior
            onProfileDictationStart?(profileId)
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
            activeProfileId = nil
            currentMode = nil
            keyDownTime = nil
            onDictationStop?()
        }
    }

    // MARK: - Display Name

    nonisolated static func displayName(for hotkey: UnifiedHotkey) -> String {
        if let button = hotkey.mouseButton {
            let baseName = mouseButtonName(for: button)
            return hotkey.isDoubleTap ? "\(baseName) x2" : baseName
        }
        if hotkey.isFn { return hotkey.isDoubleTap ? "Fn x2" : "Fn" }

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

    private static func modifierFlagForKeyCode(_ keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 0x37, 0x36: return .command
        case 0x38, 0x3C: return .shift
        case 0x3A, 0x3D: return .option
        case 0x3B, 0x3E: return .control
        default: return nil
        }
    }
}
