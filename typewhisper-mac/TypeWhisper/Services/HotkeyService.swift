import Foundation
import KeyboardShortcuts
import Combine

extension KeyboardShortcuts.Name {
    static let toggleDictation = Self("toggleDictation")
}

/// Manages global hotkey for dictation with push-to-talk / toggle dual-mode.
@MainActor
final class HotkeyService: ObservableObject {

    enum HotkeyMode: String {
        case pushToTalk
        case toggle
    }

    @Published private(set) var currentMode: HotkeyMode?

    var onDictationStart: (() -> Void)?
    var onDictationStop: (() -> Void)?

    private var keyDownTime: Date?
    private var isActive = false

    private static let toggleThreshold: TimeInterval = 1.0

    func setup() {
        KeyboardShortcuts.onKeyDown(for: .toggleDictation) { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleKeyDown()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .toggleDictation) { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleKeyUp()
            }
        }
    }

    func cancelDictation() {
        isActive = false
        currentMode = nil
        keyDownTime = nil
    }

    private func handleKeyDown() {
        if isActive {
            // Currently recording in toggle mode → stop
            isActive = false
            currentMode = nil
            keyDownTime = nil
            onDictationStop?()
        } else {
            // Start recording
            keyDownTime = Date()
            isActive = true
            currentMode = .pushToTalk
            onDictationStart?()
        }
    }

    private func handleKeyUp() {
        guard isActive, let downTime = keyDownTime else { return }

        let holdDuration = Date().timeIntervalSince(downTime)

        if holdDuration < Self.toggleThreshold {
            // Short press → push-to-talk, stop on release
            isActive = false
            currentMode = nil
            keyDownTime = nil
            onDictationStop?()
        } else {
            // Long hold → switch to toggle mode, keyUp is ignored
            currentMode = .toggle
        }
    }
}
