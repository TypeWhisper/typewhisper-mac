import Foundation
import AppKit
import Combine

struct UnifiedHotkey: Equatable, Sendable, Codable {
    let keyCode: UInt16
    let modifierFlags: UInt
    let isFn: Bool

    var isModifierOnly: Bool {
        !isFn && modifierFlags == 0 && HotkeyService.modifierKeyCodes.contains(keyCode)
    }

    var hasModifiers: Bool { modifierFlags != 0 }
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

    enum HotkeyMode: String {
        case pushToTalk
        case toggle
    }

    @Published private(set) var currentMode: HotkeyMode?

    var onDictationStart: (() -> Void)?
    var onDictationStop: (() -> Void)?
    var onPromptPaletteToggle: (() -> Void)?
    var onProfileDictationStart: ((UUID) -> Void)?

    private var keyDownTime: Date?
    private var isActive = false
    private var activeSlotType: HotkeySlotType?
    private(set) var activeProfileId: UUID?

    private static let toggleThreshold: TimeInterval = 1.0

    // MARK: - Per-Slot State

    private struct SlotState {
        var hotkey: UnifiedHotkey?
        var fnWasDown = false
        var modifierWasDown = false
        var keyWasDown = false
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
        var modifierWasDown = false
        var keyWasDown = false
    }

    private var profileSlots: [UUID: ProfileHotkeyState] = [:]

    private var globalMonitor: Any?
    private var localMonitor: Any?

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
        migrateIfNeeded()
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
    func isHotkeyAssigned(_ hotkey: UnifiedHotkey, excluding: HotkeySlotType) -> HotkeySlotType? {
        for slotType in HotkeySlotType.allCases where slotType != excluding {
            if slots[slotType]?.hotkey == hotkey {
                return slotType
            }
        }
        return nil
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
        }
        return nil
    }

    func isHotkeyAssignedToGlobalSlot(_ hotkey: UnifiedHotkey) -> HotkeySlotType? {
        for slotType in HotkeySlotType.allCases {
            if slots[slotType]?.hotkey == hotkey { return slotType }
        }
        return nil
    }

    // MARK: - Migration

    private func migrateIfNeeded() {
        let defaults = UserDefaults.standard

        // Migration from v1 (3 separate keys) to v2 (JSON-encoded per slot)
        if defaults.object(forKey: "hotkeyKeyCode") != nil,
           defaults.data(forKey: UserDefaultsKeys.hybridHotkey) == nil {
            let code = UInt16(defaults.integer(forKey: "hotkeyKeyCode"))
            let flags = UInt(defaults.integer(forKey: "hotkeyModifierFlags"))
            let isFn = defaults.bool(forKey: "hotkeyIsFn")
            let hotkey = UnifiedHotkey(keyCode: code, modifierFlags: flags, isFn: isFn)
            defaults.set(try? JSONEncoder().encode(hotkey), forKey: UserDefaultsKeys.hybridHotkey)
            defaults.removeObject(forKey: "hotkeyKeyCode")
            defaults.removeObject(forKey: "hotkeyModifierFlags")
            defaults.removeObject(forKey: "hotkeyIsFn")
            cleanupLegacyKeys()
            return
        }

        // Migration from v0 (legacy keys) to v2
        if defaults.data(forKey: UserDefaultsKeys.hybridHotkey) != nil {
            cleanupLegacyKeys()
            return
        }

        let useSingleKey = defaults.bool(forKey: "hotkeyUseSingleKey")

        if useSingleKey {
            let code = UInt16(defaults.integer(forKey: "singleKeyCode"))
            let isFn = defaults.bool(forKey: "singleKeyIsFn")
            let hotkey = UnifiedHotkey(keyCode: code, modifierFlags: 0, isFn: isFn)
            defaults.set(try? JSONEncoder().encode(hotkey), forKey: UserDefaultsKeys.hybridHotkey)
        } else {
            if let data = defaults.data(forKey: "KeyboardShortcuts_toggleDictation"),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let carbonKeyCode = json["carbonKeyCode"] as? Int,
               let carbonModifiers = json["carbonModifiers"] as? Int {

                var cocoaFlags: UInt = 0
                if carbonModifiers & 0x100 != 0 { cocoaFlags |= NSEvent.ModifierFlags.command.rawValue }
                if carbonModifiers & 0x200 != 0 { cocoaFlags |= NSEvent.ModifierFlags.shift.rawValue }
                if carbonModifiers & 0x800 != 0 { cocoaFlags |= NSEvent.ModifierFlags.option.rawValue }
                if carbonModifiers & 0x1000 != 0 { cocoaFlags |= NSEvent.ModifierFlags.control.rawValue }

                let hotkey = UnifiedHotkey(keyCode: UInt16(carbonKeyCode), modifierFlags: cocoaFlags, isFn: false)
                defaults.set(try? JSONEncoder().encode(hotkey), forKey: UserDefaultsKeys.hybridHotkey)
            }
        }

        cleanupLegacyKeys()
    }

    private func cleanupLegacyKeys() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "hotkeyUseSingleKey")
        defaults.removeObject(forKey: "singleKeyCode")
        defaults.removeObject(forKey: "singleKeyIsFn")
        defaults.removeObject(forKey: "singleKeyIsModifier")
        defaults.removeObject(forKey: "KeyboardShortcuts_toggleDictation")
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

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleEvent(event)
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleEvent(event)
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
    }

    func suspendMonitoring() {
        tearDownMonitor()
    }

    func resumeMonitoring() {
        setupMonitor()
    }

    private func handleEvent(_ event: NSEvent) {
        // Global slots
        for slotType in HotkeySlotType.allCases {
            guard var state = slots[slotType], let hotkey = state.hotkey else { continue }
            let (keyDown, keyUp) = detectKeyEvent(
                event, hotkey: hotkey,
                fnWasDown: state.fnWasDown,
                modifierWasDown: state.modifierWasDown,
                keyWasDown: state.keyWasDown
            )
            if keyDown {
                if hotkey.isFn { state.fnWasDown = true }
                if hotkey.isModifierOnly { state.modifierWasDown = true }
                if !hotkey.isFn && !hotkey.isModifierOnly { state.keyWasDown = true }
                slots[slotType] = state
                handleKeyDown(slotType: slotType)
            } else if keyUp {
                if hotkey.isFn { state.fnWasDown = false }
                if hotkey.isModifierOnly { state.modifierWasDown = false }
                if !hotkey.isFn && !hotkey.isModifierOnly { state.keyWasDown = false }
                slots[slotType] = state
                handleKeyUp(slotType: slotType)
            }
        }

        // Profile slots
        let profileIds = Array(profileSlots.keys)
        for profileId in profileIds {
            guard var state = profileSlots[profileId] else { continue }
            let (keyDown, keyUp) = detectKeyEvent(
                event, hotkey: state.hotkey,
                fnWasDown: state.fnWasDown,
                modifierWasDown: state.modifierWasDown,
                keyWasDown: state.keyWasDown
            )
            if keyDown {
                if state.hotkey.isFn { state.fnWasDown = true }
                if state.hotkey.isModifierOnly { state.modifierWasDown = true }
                if !state.hotkey.isFn && !state.hotkey.isModifierOnly { state.keyWasDown = true }
                profileSlots[profileId] = state
                handleProfileKeyDown(profileId: profileId)
            } else if keyUp {
                if state.hotkey.isFn { state.fnWasDown = false }
                if state.hotkey.isModifierOnly { state.modifierWasDown = false }
                if !state.hotkey.isFn && !state.hotkey.isModifierOnly { state.keyWasDown = false }
                profileSlots[profileId] = state
                handleProfileKeyUp(profileId: profileId)
            }
        }
    }

    /// Generic key event detection: returns (isKeyDown, isKeyUp) for a given hotkey configuration.
    private func detectKeyEvent(
        _ event: NSEvent,
        hotkey: UnifiedHotkey,
        fnWasDown: Bool,
        modifierWasDown: Bool,
        keyWasDown: Bool
    ) -> (keyDown: Bool, keyUp: Bool) {
        if hotkey.isFn {
            guard event.type == .flagsChanged else { return (false, false) }
            let fnDown = event.modifierFlags.contains(.function)
            if fnDown, !fnWasDown { return (true, false) }
            if !fnDown, fnWasDown { return (false, true) }
        } else if hotkey.isModifierOnly {
            guard event.type == .flagsChanged, event.keyCode == hotkey.keyCode else { return (false, false) }
            let flag = Self.modifierFlagForKeyCode(hotkey.keyCode)
            guard let flag else { return (false, false) }
            let isDown = event.modifierFlags.contains(flag)
            if isDown, !modifierWasDown { return (true, false) }
            if !isDown, modifierWasDown { return (false, true) }
        } else if hotkey.hasModifiers {
            let requiredFlags = NSEvent.ModifierFlags(rawValue: hotkey.modifierFlags)
            let relevantMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
            let currentRelevant = event.modifierFlags.intersection(relevantMask)

            if event.type == .keyDown, event.keyCode == hotkey.keyCode, !keyWasDown {
                if currentRelevant == requiredFlags { return (true, false) }
            } else if event.type == .keyUp, event.keyCode == hotkey.keyCode, keyWasDown {
                return (false, true)
            } else if event.type == .flagsChanged, keyWasDown, !currentRelevant.contains(requiredFlags) {
                return (false, true)
            }
        } else {
            guard event.keyCode == hotkey.keyCode else { return (false, false) }
            let ignoredModifiers: NSEvent.ModifierFlags = [.command, .option, .control]
            if !event.modifierFlags.intersection(ignoredModifiers).isEmpty { return (false, false) }

            if event.type == .keyDown, !keyWasDown { return (true, false) }
            if event.type == .keyUp { return (false, true) }
        }
        return (false, false)
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
        if hotkey.isFn { return "Fn" }

        var parts: [String] = []

        let flags = NSEvent.ModifierFlags(rawValue: hotkey.modifierFlags)
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }

        parts.append(keyName(for: hotkey.keyCode))

        return parts.joined()
    }

    nonisolated static func keyName(for keyCode: UInt16) -> String {
        let knownKeys: [UInt16: String] = [
            0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H",
            0x05: "G", 0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V",
            0x0A: "§", 0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E",
            0x0F: "R", 0x10: "Y", 0x11: "T", 0x12: "1", 0x13: "2",
            0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=",
            0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0",
            0x1E: "]", 0x1F: "O", 0x20: "U", 0x21: "[", 0x22: "I",
            0x23: "P", 0x24: "⏎", 0x25: "L", 0x26: "J", 0x27: "'",
            0x28: "K", 0x29: ";", 0x2A: "\\", 0x2B: ",", 0x2C: "/",
            0x2D: "N", 0x2E: "M", 0x2F: ".", 0x30: "⇥", 0x31: "␣",
            0x32: "`", 0x33: "⌫", 0x35: "⎋", 0x7A: "F1", 0x78: "F2",
            0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6", 0x62: "F7",
            0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
            0x69: "F13", 0x6B: "F14", 0x71: "F15",
            0x7E: "↑", 0x7D: "↓", 0x7B: "←", 0x7C: "→",
        ]

        if let name = knownKeys[keyCode] { return name }

        let modifierNames: [UInt16: String] = [
            0x37: "Left Command", 0x36: "Right Command",
            0x38: "Left Shift", 0x3C: "Right Shift",
            0x3A: "Left Option", 0x3D: "Right Option",
            0x3B: "Left Control", 0x3E: "Right Control",
        ]
        if let name = modifierNames[keyCode] { return name }

        return "Key \(keyCode)"
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
