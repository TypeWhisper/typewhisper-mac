import AppKit
import Combine
import Foundation

/// Semantic state of a key on the visual shortcut keyboard.
/// The view distinguishes these by shape and icon in addition to color,
/// and exposes each state through VoiceOver labels.
enum VisualKeyState: Equatable {
    case available
    case active
    case conflicting(assignment: String?)
    case reserved
}

/// Which physical keyboard variant the key grid renders.
enum VisualKeyboardLayoutKind: String, CaseIterable {
    case ansi
    case iso
}

/// One key in the visual grid. Widths are relative weights inside their row,
/// so rows scale to any sheet width without clipped or overlapping keys.
struct VisualKey: Identifiable, Hashable {
    let keyCode: UInt16
    let weight: Double

    var id: UInt16 { keyCode }
}

/// A modifier entry in the dedicated modifier strip. Modifiers are always
/// side-specific here so left/right variants stay distinguishable.
enum VisualModifierEntry: Hashable {
    case keyCode(UInt16)
    case fn
}

/// Value-type composition of a shortcut. Keeps every rule about how a
/// `UnifiedHotkey` is built in one place so the view model, the preview
/// states, and the tests all share it.
struct VisualShortcutComposition: Equatable {
    var keyCode: UInt16?
    var modifierKeyCodes: Set<UInt16> = []
    var isFnSelected = false
    var isDoubleTap = false

    /// Bare key codes the recorder itself cannot capture. Escape cancels an
    /// in-progress recording, so it can never be stored as a bare hotkey.
    static let reservedBareKeyCodes: Set<UInt16> = [0x35] // ⎋

    /// Whether the current composition is a reserved bare key: Escape with no
    /// modifiers. Deselecting modifiers can strand a reserved key behind, so
    /// the model validates the final composition, not just the key tap.
    var isReservedBareKey: Bool {
        guard let keyCode else { return false }
        return Self.reservedBareKeyCodes.contains(keyCode)
            && modifierKeyCodes.isEmpty && !isFnSelected
    }

    /// Left-side physical key codes used when a stored hotkey only carries
    /// generic modifier flags (legacy data without side information).
    static func leftKeyCode(for flag: NSEvent.ModifierFlags) -> UInt16? {
        switch flag {
        case .command: return 0x37
        case .option: return 0x3A
        case .control: return 0x3B
        case .shift: return 0x38
        default: return nil
        }
    }

    private func combinedFlags() -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags()
        for code in modifierKeyCodes {
            if let flag = HotkeyService.modifierFlagForKeyCode(code) {
                flags.insert(flag)
            }
        }
        if isFnSelected {
            flags.insert(.function)
        }
        return flags
    }

    /// The hotkey this composition represents, mirroring exactly what the
    /// event-driven recorder produces for the same physical input.
    var hotkey: UnifiedHotkey? {
        if isFnSelected, modifierKeyCodes.isEmpty, keyCode == nil {
            return UnifiedHotkey(keyCode: 0, modifierFlags: 0, isFn: true, isDoubleTap: isDoubleTap)
        }
        if let keyCode {
            // Mirrors the recorder's keyDown path: generic flags, no side-specific codes.
            return UnifiedHotkey(
                keyCode: keyCode,
                modifierFlags: combinedFlags().rawValue,
                isFn: false,
                isDoubleTap: isDoubleTap
            )
        }
        guard !modifierKeyCodes.isEmpty else { return nil }
        if modifierKeyCodes.count == 1, !isFnSelected, let code = modifierKeyCodes.first {
            // Mirrors the recorder's single-modifier path: physical key code, no flags.
            return UnifiedHotkey(keyCode: code, modifierFlags: 0, isFn: false, isDoubleTap: isDoubleTap)
        }
        // Mirrors the recorder's modifier-combo path.
        return UnifiedHotkey(
            keyCode: UnifiedHotkey.modifierComboKeyCode,
            modifierFlags: combinedFlags().rawValue,
            isFn: false,
            isDoubleTap: isDoubleTap,
            modifierKeyCodes: modifierKeyCodes
        )
    }

    /// Restores a stored hotkey into selectable state. Mouse-button hotkeys
    /// intentionally load as empty: the visual editor composes keyboard
    /// shortcuts and never alters mouse configuration by itself.
    mutating func load(_ hotkey: UnifiedHotkey) {
        keyCode = nil
        modifierKeyCodes = []
        isFnSelected = false
        isDoubleTap = hotkey.isDoubleTap

        let flags = NSEvent.ModifierFlags(rawValue: hotkey.modifierFlags)
        switch hotkey.kind {
        case .mouseButton:
            break
        case .fn:
            isFnSelected = true
        case .modifierOnly:
            modifierKeyCodes = [hotkey.keyCode]
        case .modifierCombo:
            isFnSelected = flags.contains(.function)
            if hotkey.modifierKeyCodes.isEmpty {
                modifierKeyCodes = Set(sideSpecificKeyCodes(for: flags))
            } else {
                modifierKeyCodes = hotkey.modifierKeyCodes
            }
        case .keyWithModifiers, .bareKey:
            keyCode = hotkey.keyCode
            isFnSelected = flags.contains(.function)
            if hotkey.modifierKeyCodes.isEmpty {
                modifierKeyCodes = Set(sideSpecificKeyCodes(for: flags.subtracting(.function)))
            } else {
                modifierKeyCodes = hotkey.modifierKeyCodes
            }
        }
    }

    private func sideSpecificKeyCodes(for flags: NSEvent.ModifierFlags) -> [UInt16] {
        let pairs: [(NSEvent.ModifierFlags, UInt16)] = [
            (.command, 0x37), (.option, 0x3A), (.control, 0x3B), (.shift, 0x38),
        ]
        return pairs.compactMap { flag, code in flags.contains(flag) ? code : nil }
    }
}

/// Headless view model for the visual shortcut keyboard. All composition,
/// validation, and key-state rules live here; the SwiftUI view only renders.
final class VisualShortcutKeyboardModel: ObservableObject {
    @Published var composition = VisualShortcutComposition()
    @Published var layoutKind: VisualKeyboardLayoutKind = .ansi

    /// The hotkey being replaced, if the editor was opened for an existing assignment.
    let editingHotkey: UnifiedHotkey?

    /// Same conflict-detection source of truth the recorder validates against.
    /// Returns a user-facing description of the existing assignment, or nil when free.
    var existingAssignmentDescription: (UnifiedHotkey) -> String?

    /// Resolves the display label for a key code. Defaults to the same
    /// resolver the recorder display uses; injectable for tests.
    var keyLabel: (UInt16) -> String

    init(
        editingHotkey: UnifiedHotkey? = nil,
        existingAssignmentDescription: ((UnifiedHotkey) -> String?)? = nil,
        keyLabel: @escaping (UInt16) -> String = HotkeyService.keyName(for:)
    ) {
        self.editingHotkey = editingHotkey
        self.existingAssignmentDescription = existingAssignmentDescription ?? { _ in nil }
        self.keyLabel = keyLabel
        if let editingHotkey {
            composition.load(editingHotkey)
        }
    }

    // MARK: - Layout

    /// Dedicated modifier strip: every modifier as its own side-specific key plus Fn.
    static let modifierStrip: [VisualModifierEntry] = [
        .keyCode(0x3B), // Left Control
        .keyCode(0x3A), // Left Option
        .keyCode(0x37), // Left Command
        .fn,
        .keyCode(0x38), // Left Shift
        .keyCode(0x3C), // Right Shift
        .keyCode(0x36), // Right Command
        .keyCode(0x3D), // Right Option
        .keyCode(0x3E), // Right Control
    ]

    static let arrowKeys: [VisualKey] = [
        VisualKey(keyCode: 0x7B, weight: 1), // ←
        VisualKey(keyCode: 0x7D, weight: 1), // ↓
        VisualKey(keyCode: 0x7E, weight: 1), // ↑
        VisualKey(keyCode: 0x7C, weight: 1), // →
    ]

    /// Data-driven ANSI/ISO rows. Adding a layout only means adding rows here.
    static func mainRows(for kind: VisualKeyboardLayoutKind) -> [[VisualKey]] {
        let k: (UInt16, Double) -> VisualKey = VisualKey.init
        var rows: [[VisualKey]] = [
            // Function row
            [0x35, 0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F].map { k($0, 1) },
            // Number row
            [k(0x32, 1), k(0x12, 1), k(0x13, 1), k(0x14, 1), k(0x15, 1), k(0x17, 1), k(0x16, 1), k(0x1A, 1), k(0x1C, 1), k(0x19, 1), k(0x1D, 1), k(0x1B, 1), k(0x18, 1), k(0x33, 1.5)],
            // QWERTY row
            [k(0x30, 1.5), k(0x0C, 1), k(0x0D, 1), k(0x0E, 1), k(0x0F, 1), k(0x11, 1), k(0x10, 1), k(0x20, 1), k(0x22, 1), k(0x1F, 1), k(0x23, 1), k(0x21, 1), k(0x1E, 1), k(0x2A, 1.5)],
            // Home row
            [k(0x00, 1), k(0x01, 1), k(0x02, 1), k(0x03, 1), k(0x05, 1), k(0x04, 1), k(0x26, 1), k(0x28, 1), k(0x25, 1), k(0x29, 1), k(0x27, 1), k(0x24, 2)],
        ]
        // Bottom row: ISO adds the extra key left of Z.
        var bottomRow: [VisualKey] = []
        if kind == .iso {
            bottomRow.append(k(0x0A, 1))
        }
        bottomRow += [k(0x06, 1), k(0x07, 1), k(0x08, 1), k(0x09, 1), k(0x0B, 1), k(0x2D, 1), k(0x2E, 1), k(0x2B, 1), k(0x2F, 1), k(0x2C, 1)]
        rows.append(bottomRow)
        // Space row
        rows.append([k(0x31, 8)])
        return rows
    }

    // MARK: - Key states

    func state(forKey keyCode: UInt16) -> VisualKeyState {
        if keyCode == composition.keyCode {
            return .active
        }
        if VisualShortcutComposition.reservedBareKeyCodes.contains(keyCode),
           composition.modifierKeyCodes.isEmpty,
           !composition.isFnSelected {
            return .reserved
        }
        var trial = composition
        trial.keyCode = keyCode
        if let candidate = trial.hotkey, let assignment = conflictDescription(for: candidate) {
            return .conflicting(assignment: assignment)
        }
        return .available
    }

    func state(forModifier entry: VisualModifierEntry) -> VisualKeyState {
        switch entry {
        case .fn:
            if composition.isFnSelected { return .active }
            var trial = composition
            trial.isFnSelected = true
            if let candidate = trial.hotkey, let assignment = conflictDescription(for: candidate) {
                return .conflicting(assignment: assignment)
            }
            return .available
        case .keyCode(let code):
            if composition.modifierKeyCodes.contains(code) { return .active }
            var trial = composition
            trial.modifierKeyCodes.insert(code)
            // A lone modifier key is itself a valid single-modifier hotkey.
            if let candidate = trial.hotkey, let assignment = conflictDescription(for: candidate) {
                return .conflicting(assignment: assignment)
            }
            return .available
        }
    }

    /// The hotkey the current composition represents, if any.
    var composedHotkey: UnifiedHotkey? {
        composition.hotkey
    }

    var canSave: Bool {
        composedHotkey != nil && !composition.isReservedBareKey
    }

    /// User-facing description of what the composed hotkey conflicts with, if anything.
    var conflictNotice: String? {
        guard let candidate = composedHotkey else { return nil }
        return conflictDescription(for: candidate)
    }

    var composedDisplayName: String {
        guard let candidate = composedHotkey else { return "" }
        return HotkeyService.displayName(for: candidate)
    }

    private func conflictDescription(for candidate: UnifiedHotkey) -> String? {
        // The hotkey being edited never conflicts with itself. Only an exact
        // match is suppressed: a conflicting-but-different candidate (e.g. the
        // other tap mode of the same combo) still reports its real assignment
        // instead of being silently hidden.
        if candidate == editingHotkey {
            return nil
        }
        return existingAssignmentDescription(candidate)
    }

    // MARK: - Editing actions

    /// Tapping a main-grid key selects it (replacing any previous key).
    /// Reserved bare keys are ignored.
    func toggleKey(_ keyCode: UInt16) {
        if state(forKey: keyCode) == .reserved {
            return
        }
        if composition.keyCode == keyCode {
            composition.keyCode = nil
        } else {
            composition.keyCode = keyCode
        }
    }

    func toggleModifier(_ entry: VisualModifierEntry) {
        switch entry {
        case .fn:
            composition.isFnSelected.toggle()
        case .keyCode(let code):
            if composition.modifierKeyCodes.contains(code) {
                composition.modifierKeyCodes.remove(code)
            } else {
                composition.modifierKeyCodes.insert(code)
            }
        }
        // Removing a modifier can strand a bare Escape the recorder could
        // never have captured: drop it rather than offer it for saving.
        if composition.isReservedBareKey {
            composition.keyCode = nil
        }
    }

    func toggleDoubleTap() {
        composition.isDoubleTap.toggle()
    }

    func clear() {
        composition = VisualShortcutComposition()
    }

    func label(forModifier entry: VisualModifierEntry) -> String {
        switch entry {
        case .fn: return "Fn"
        case .keyCode(let code): return keyLabel(code)
        }
    }
}
