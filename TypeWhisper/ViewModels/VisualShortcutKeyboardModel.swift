import AppKit
import Combine
import Carbon.HIToolbox
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
    case jis

    static func detected(keyboardType: UInt32) -> Self {
        switch KBGetLayoutType(Int16(truncatingIfNeeded: keyboardType)) {
        case UInt32(kKeyboardISO): .iso
        case UInt32(kKeyboardJIS): .jis
        default: .ansi
        }
    }
}

/// Captures one coherent macOS input source, including an IME's underlying layout.
struct VisualKeyboardInputSource: Equatable {
    let layoutKind: VisualKeyboardLayoutKind
    let name: String
    let keyLabels: [UInt16: String]

    static func current() -> Self {
        let keyboardType = UInt32(LMGetKbdType())
        let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        let name = source.flatMap { TISGetInputSourceProperty($0, kTISPropertyLocalizedName) }
            .map { unsafeBitCast($0, to: CFString.self) as String } ?? ""
        // Input methods (e.g. Japanese and Chinese) usually have no uchr data
        // themselves. macOS supplies the actual layout used by the input method.
        let layout = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        let data = layout.flatMap { TISGetInputSourceProperty($0, kTISPropertyUnicodeKeyLayoutData) }
            .map { unsafeBitCast($0, to: CFData.self) }
        let labels = Dictionary(uniqueKeysWithValues: (UInt16(0)..<128).map { code in
            (code, HotkeyService.keycapName(for: code, layoutData: data, keyboardType: keyboardType))
        })
        return Self(layoutKind: .detected(keyboardType: keyboardType), name: name, keyLabels: labels)
    }
}

/// Keycap positions share a 15-unit coordinate system, so every row keeps
/// the same key pitch and the stagger of a physical Mac keyboard.
struct VisualKey: Identifiable, Hashable {
    enum Content: Hashable {
        case key(UInt16)
        case modifier(VisualModifierEntry)
        case capsLock
        case touchID
    }

    let content: Content
    let x: Double
    let y: Double
    let width: Double
    var height: Double = 1
    var isTallReturn = false

    var id: Content { content }
    var keyCode: UInt16? {
        if case .key(let code) = content { return code }
        return nil
    }
}

/// A physical modifier key. Modifiers are always
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
    /// Whether the physical modifier selection was explicitly set — loaded
    /// from a stored side-specific set or changed by the user. A legacy
    /// stored combo carries generic flags with no side information; until
    /// the user touches the selection, saving must keep those generic
    /// semantics instead of persisting the left-side codes shown in the UI.
    var modifierSelectionEdited = false

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
        // Mirrors the recorder's modifier-combo path. A legacy generic combo
        // keeps its side-agnostic semantics until the user explicitly changes
        // the physical modifier selection.
        return UnifiedHotkey(
            keyCode: UnifiedHotkey.modifierComboKeyCode,
            modifierFlags: combinedFlags().rawValue,
            isFn: false,
            isDoubleTap: isDoubleTap,
            modifierKeyCodes: modifierSelectionEdited ? modifierKeyCodes : []
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
            // The stored key code already identifies the physical modifier,
            // so further edits keep it side-specific instead of dropping it
            // to a generic combo.
            modifierSelectionEdited = true
        case .modifierCombo:
            isFnSelected = flags.contains(.function)
            if hotkey.modifierKeyCodes.isEmpty {
                // Legacy generic combo: display left-side codes but keep the
                // stored side-agnostic semantics until the user changes them.
                modifierKeyCodes = Set(sideSpecificKeyCodes(for: flags))
                modifierSelectionEdited = false
            } else {
                modifierKeyCodes = hotkey.modifierKeyCodes
                modifierSelectionEdited = true
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
    @Published private(set) var inputSource: VisualKeyboardInputSource
    var layoutKind: VisualKeyboardLayoutKind { inputSource.layoutKind }
    private let inputSourceProvider: () -> VisualKeyboardInputSource

    /// The hotkey being replaced, if the editor was opened for an existing assignment.
    let editingHotkey: UnifiedHotkey?

    /// Same conflict-detection source of truth the recorder validates against.
    /// Returns a user-facing description of the existing assignment, or nil when free.
    var existingAssignmentDescription: (UnifiedHotkey) -> String?

    /// Resolves the display label for a key code. Defaults to the same
    /// resolver the recorder display uses; injectable for tests.
    private let keyLabelOverride: ((UInt16) -> String)?

    func keyLabel(_ code: UInt16) -> String {
        keyLabelOverride?(code) ?? inputSource.keyLabels[code] ?? HotkeyService.keyName(for: code)
    }

    init(
        editingHotkey: UnifiedHotkey? = nil,
        existingAssignmentDescription: ((UnifiedHotkey) -> String?)? = nil,
        keyLabel: ((UInt16) -> String)? = nil,
        inputSourceProvider: @escaping () -> VisualKeyboardInputSource = VisualKeyboardInputSource.current
    ) {
        self.editingHotkey = editingHotkey
        self.existingAssignmentDescription = existingAssignmentDescription ?? { _ in nil }
        self.keyLabelOverride = keyLabel
        self.inputSourceProvider = inputSourceProvider
        self.inputSource = inputSourceProvider()
        if let editingHotkey {
            composition.load(editingHotkey)
        }
    }

    func refreshInputSource() {
        let updated = inputSourceProvider()
        if updated != inputSource {
            inputSource = updated
        }
    }

    // MARK: - Layout

    static let keyboardWidth = 15.0
    static let keyboardHeight = 5.85

    static func keyLayout(for kind: VisualKeyboardLayoutKind) -> [VisualKey] {
        var keys: [VisualKey] = []
        func row(_ entries: [(VisualKey.Content, Double)], y: Double, height: Double = 1) {
            var x = 0.0
            for (content, width) in entries {
                keys.append(VisualKey(content: content, x: x, y: y, width: width, height: height))
                x += width
            }
        }
        func letters(_ codes: [UInt16]) -> [(VisualKey.Content, Double)] {
            codes.map { (.key($0), 1) }
        }

        row([(.key(0x35), 1.5)]
            + letters([0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F])
            + [(.touchID, 1.5)], y: 0, height: 0.65)
        if kind == .jis {
            row(letters([0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19, 0x1D, 0x1B, 0x18, 0x5D])
                + [(.key(0x33), 2)], y: 0.85)
            row([(.key(0x30), 1)]
                + letters([0x0C, 0x0D, 0x0E, 0x0F, 0x11, 0x10, 0x20, 0x22, 0x1F, 0x23, 0x21, 0x1E]), y: 1.85)
            row([(.modifier(.keyCode(0x3B)), 1.25)]
                + letters([0x00, 0x01, 0x02, 0x03, 0x05, 0x04, 0x26, 0x28, 0x25, 0x29, 0x27, 0x2A]), y: 2.85)
            keys.append(VisualKey(content: .key(0x24), x: 13, y: 1.85,
                                  width: 2, height: 2, isTallReturn: true))
            row([(.modifier(.keyCode(0x38)), 1.75)]
                + letters([0x06, 0x07, 0x08, 0x09, 0x0B, 0x2D, 0x2E, 0x2B, 0x2F, 0x2C, 0x5E])
                + [(.modifier(.keyCode(0x3C)), 2.25)], y: 3.85)
            row([(.capsLock, 1), (.modifier(.keyCode(0x3A)), 1), (.modifier(.keyCode(0x37)), 1.25),
                 (.key(0x66), 1.25), (.key(0x31), 3), (.key(0x68), 1.25),
                 (.modifier(.keyCode(0x36)), 1.25), (.modifier(.fn), 1)], y: 4.85)
        } else {
            // On a Mac ISO keyboard the upper-left key is kVK_ISO_Section;
            // kVK_ANSI_Grave moves beside left Shift.
            row(letters([kind == .iso ? 0x0A : 0x32, 0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19, 0x1D, 0x1B, 0x18])
                + [(.key(0x33), 2)], y: 0.85)
            let top: [(VisualKey.Content, Double)] = [(.key(0x30), 1.5)]
                + letters([0x0C, 0x0D, 0x0E, 0x0F, 0x11, 0x10, 0x20, 0x22, 0x1F, 0x23, 0x21, 0x1E])
            let home: [(VisualKey.Content, Double)] = [(.capsLock, 1.75)]
                + letters([0x00, 0x01, 0x02, 0x03, 0x05, 0x04, 0x26, 0x28, 0x25, 0x29, 0x27])
            if kind == .iso {
                row(top, y: 1.85)
                row(home + [(.key(0x2A), 1)], y: 2.85)
                keys.append(VisualKey(content: .key(0x24), x: 13.5, y: 1.85,
                                      width: 1.5, height: 2, isTallReturn: true))
            } else {
                row(top + [(.key(0x2A), 1.5)], y: 1.85)
                row(home + [(.key(0x24), 2.25)], y: 2.85)
            }
            let shift: [(VisualKey.Content, Double)] = kind == .iso
                ? [(.modifier(.keyCode(0x38)), 1.25), (.key(0x32), 1)]
                : [(.modifier(.keyCode(0x38)), 2.25)]
            row(shift + letters([0x06, 0x07, 0x08, 0x09, 0x0B, 0x2D, 0x2E, 0x2B, 0x2F, 0x2C])
                + [(.modifier(.keyCode(0x3C)), 2.75)], y: 3.85)
            row([(.modifier(.fn), 1), (.modifier(.keyCode(0x3B)), 1),
                 (.modifier(.keyCode(0x3A)), 1), (.modifier(.keyCode(0x37)), 1.25),
                 (.key(0x31), 5.5), (.modifier(.keyCode(0x36)), 1.25),
                 (.modifier(.keyCode(0x3D)), 1)], y: 4.85)
        }
        // Compact Mac arrow cluster: half-height keys in an inverted T.
        for (code, x, y) in [(UInt16(0x7B), 12.0, 5.35), (0x7D, 13.0, 5.35),
                             (0x7E, 13.0, 4.85), (0x7C, 14.0, 5.35)] {
            keys.append(VisualKey(content: .key(code), x: x, y: y, width: 1, height: 0.5))
        }
        return keys
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
            // The tap this previews would mark the selection explicitly
            // edited: evaluate the same side-specific candidate it saves.
            trial.modifierSelectionEdited = true
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
            // The user explicitly changed the physical modifier selection:
            // saves now persist these exact side-specific codes.
            composition.modifierSelectionEdited = true
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
