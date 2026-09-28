import SwiftUI

struct HotkeyRecorderView: View {
    enum Presentation {
        case row
        case iconButton(systemName: String)
        case compactChip
    }

    let label: String
    var title: String = String(localized: "Dictation shortcut")
    var subtitle: String? = nil
    var presentation: Presentation = .row
    var trailingAccessory: AnyView = AnyView(EmptyView())
    let onRecord: (UnifiedHotkey) -> Void
    let onClear: () -> Void

    @State private var isRecording = false
    @State private var pendingModifiers: NSEvent.ModifierFlags = []
    @State private var peakModifiers: NSEvent.ModifierFlags = []
    @State private var pendingModifierKeyCodes: Set<UInt16> = []
    @State private var peakModifierKeyCodes: Set<UInt16> = []
    @State private var localMonitor: Any?
    @State private var globalMonitor: Any?
    @State private var modifierReleaseTimer: DispatchWorkItem?
    private static var activeRecorder: UUID?
    @State private var id = UUID()
    // Double-tap recording state
    @State private var firstTapHotkey: UnifiedHotkey?
    @State private var firstTapDisplayName: String?
    @State private var doubleTapTimer: DispatchWorkItem?

    var body: some View {
        switch presentation {
        case .row:
            rowBody
        case .iconButton(let systemName):
            iconButtonBody(systemName: systemName)
        case .compactChip:
            compactChipBody
        }
    }

    private var rowBody: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            recorderControl

            if !isRecording {
                trailingAccessory
            }
        }
    }

    @ViewBuilder
    private func iconButtonBody(systemName: String) -> some View {
        if isRecording {
            Button {
                cancelRecording()
            } label: {
                Text(recordingLabel)
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel(String(localized: "Recording shortcut - press a key or Escape to cancel"))
        } else {
            Button {
                startRecording()
            } label: {
                Image(systemName: systemName)
                    .imageScale(.medium)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(title)
            .accessibilityLabel(title)
        }
    }

    @ViewBuilder
    private var compactChipBody: some View {
        if isRecording {
            Button {
                cancelRecording()
            } label: {
                Text(recordingLabel)
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel(String(localized: "Recording shortcut - press a key or Escape to cancel"))
        } else if !label.isEmpty {
            recordedShortcutControl
        }
    }

    @ViewBuilder
    private var recorderControl: some View {
        if isRecording {
            Button {
                cancelRecording()
            } label: {
                Text(recordingLabel)
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel(String(localized: "Recording shortcut - press a key or Escape to cancel"))
        } else if label.isEmpty {
            Button {
                startRecording()
            } label: {
                Text(String(localized: "Record Shortcut"))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel(String(localized: "Record shortcut for \(title)"))
        } else {
            recordedShortcutControl
        }
    }

    private var recordedShortcutControl: some View {
        HStack(spacing: 4) {
            Button {
                startRecording()
            } label: {
                Text(label)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Current shortcut: \(label). Click to change."))
            Button {
                onClear()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Clear shortcut"))
        }
        .fixedSize()
    }

    private var recordingLabel: String {
        if let displayName = firstTapDisplayName {
            return "\(displayName) - \(String(localized: "tap again for double-tap…"))"
        }

        return pendingModifierString.isEmpty
            ? String(localized: "Press a key or mouse button…")
            : pendingModifierString
    }

    private var pendingModifierString: String {
        if !pendingModifierKeyCodes.isEmpty {
            return HotkeyService.displayName(
                forModifierKeyCodes: pendingModifierKeyCodes,
                modifierFlags: pendingModifiers
            )
        }

        var parts: [String] = []
        if pendingModifiers.contains(.function) { parts.append("Fn") }
        if pendingModifiers.contains(.control) { parts.append("⌃") }
        if pendingModifiers.contains(.option) { parts.append("⌥") }
        if pendingModifiers.contains(.shift) { parts.append("⇧") }
        if pendingModifiers.contains(.command) { parts.append("⌘") }
        return parts.joined()
    }

    private func startRecording() {
        if let activeId = Self.activeRecorder, activeId != id {
            return
        }
        Self.activeRecorder = id
        isRecording = true
        pendingModifiers = []
        peakModifiers = []
        pendingModifierKeyCodes = []
        peakModifierKeyCodes = []
        ServiceContainer.shared.hotkeyService.suspendMonitoring()

        // Local monitor - can swallow events (return nil)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .otherMouseDown]) { event in
            let handled = handleRecorderEvent(event)
            return handled ? nil : event
        }

        // Global monitor - captures events intercepted by macOS (e.g. Ctrl+Space for input switching)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged, .otherMouseDown]) { event in
            handleRecorderEvent(event)
        }
    }

    /// Shared event processing for both local and global monitors.
    /// Returns true if the event was handled (consumed).
    @discardableResult
    private func handleRecorderEvent(_ event: NSEvent) -> Bool {
        guard isRecording else { return false }

        if event.type == .flagsChanged {
            let relevantMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]
            let current = event.modifierFlags.intersection(relevantMask)
            let currentModifierKeyCodes = modifierKeyCodes(for: event, currentModifiers: current)

            // Track peak modifier set (most modifiers held simultaneously)
            if current.isSuperset(of: peakModifiers) {
                peakModifiers = current
                peakModifierKeyCodes.formUnion(currentModifierKeyCodes)
            }

            if current.isEmpty, !pendingModifiers.isEmpty {
                let modifierList: [NSEvent.ModifierFlags] = [.command, .option, .control, .shift, .function]
                let peakCount = modifierList.filter { peakModifiers.contains($0) }.count

                // Build the candidate single-tap hotkey for this release
                let candidateHotkey: UnifiedHotkey?
                if peakCount > 1 {
                    candidateHotkey = UnifiedHotkey(
                        keyCode: UnifiedHotkey.modifierComboKeyCode,
                        modifierFlags: peakModifiers.rawValue,
                        isFn: false,
                        modifierKeyCodes: modifierKeyCodesForRecordedCombo()
                    )
                } else if peakModifiers.contains(.function) {
                    candidateHotkey = UnifiedHotkey(keyCode: 0, modifierFlags: 0, isFn: true)
                } else if HotkeyService.modifierKeyCodes.contains(event.keyCode) {
                    candidateHotkey = UnifiedHotkey(keyCode: event.keyCode, modifierFlags: 0, isFn: false)
                } else {
                    candidateHotkey = nil
                }

                if let candidate = candidateHotkey {
                    // Check if this is a second tap of the same key (double-tap detection)
                    if let firstTap = firstTapHotkey, firstTap == candidate {
                        // Second tap - finish as double-tap
                        doubleTapTimer?.cancel()
                        doubleTapTimer = nil
                        let doubleTapHotkey = UnifiedHotkey(
                            keyCode: candidate.keyCode,
                            modifierFlags: candidate.modifierFlags,
                            isFn: candidate.isFn,
                            isDoubleTap: true,
                            modifierKeyCodes: candidate.modifierKeyCodes
                        )
                        let work = DispatchWorkItem { [self] in
                            finishRecording(doubleTapHotkey)
                        }
                        modifierReleaseTimer = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
                    } else {
                        // First tap - wait for possible second tap
                        doubleTapTimer?.cancel()
                        firstTapHotkey = candidate
                        firstTapDisplayName = HotkeyService.displayName(for: candidate)
                        let singleTapHotkey = candidate
                        let work = DispatchWorkItem { [self] in
                            // Timer expired - finish as single-tap
                            firstTapHotkey = nil
                            firstTapDisplayName = nil
                            finishRecording(singleTapHotkey)
                        }
                        doubleTapTimer = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
                    }
                    pendingModifiers = []
                    peakModifiers = []
                    pendingModifierKeyCodes = []
                    peakModifierKeyCodes = []
                    return true
                }
            }

            pendingModifiers = current
            pendingModifierKeyCodes = currentModifierKeyCodes
            return true
        }

        if event.type == .otherMouseDown {
            modifierReleaseTimer?.cancel()
            modifierReleaseTimer = nil

            let buttonNumber = UInt16(event.buttonNumber)
            let candidate = UnifiedHotkey(mouseButton: buttonNumber)

            // Double-tap detection for mouse buttons
            if let firstTap = firstTapHotkey, firstTap == candidate {
                doubleTapTimer?.cancel()
                doubleTapTimer = nil
                let doubleTapHotkey = UnifiedHotkey(mouseButton: buttonNumber, isDoubleTap: true)
                let work = DispatchWorkItem { [self] in
                    finishRecording(doubleTapHotkey)
                }
                modifierReleaseTimer = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
            } else {
                doubleTapTimer?.cancel()
                firstTapHotkey = candidate
                firstTapDisplayName = HotkeyService.displayName(for: candidate)
                let singleTapHotkey = candidate
                let work = DispatchWorkItem { [self] in
                    firstTapHotkey = nil
                    firstTapDisplayName = nil
                    finishRecording(singleTapHotkey)
                }
                doubleTapTimer = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
            }
            return true
        }

        if event.type == .keyDown {
            modifierReleaseTimer?.cancel()
            modifierReleaseTimer = nil

            if event.keyCode == 0x35, pendingModifiers.isEmpty {
                cancelRecording()
                return true
            }

            let relevantMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .function]
            let modifiers = event.modifierFlags.intersection(relevantMask).rawValue

            finishRecording(UnifiedHotkey(keyCode: event.keyCode, modifierFlags: modifiers, isFn: false))
            return true
        }

        return false
    }

    private func finishRecording(_ hotkey: UnifiedHotkey) {
        modifierReleaseTimer?.cancel()
        modifierReleaseTimer = nil
        doubleTapTimer?.cancel()
        doubleTapTimer = nil
        firstTapHotkey = nil
        firstTapDisplayName = nil
        if Self.activeRecorder == id {
            Self.activeRecorder = nil
        }
        isRecording = false
        pendingModifiers = []
        peakModifiers = []
        pendingModifierKeyCodes = []
        peakModifierKeyCodes = []
        removeMonitors()
        ServiceContainer.shared.hotkeyService.resumeMonitoring()
        onRecord(hotkey)
    }

    private func cancelRecording() {
        modifierReleaseTimer?.cancel()
        modifierReleaseTimer = nil
        doubleTapTimer?.cancel()
        doubleTapTimer = nil
        firstTapHotkey = nil
        firstTapDisplayName = nil
        if Self.activeRecorder == id {
            Self.activeRecorder = nil
        }
        isRecording = false
        pendingModifiers = []
        peakModifiers = []
        pendingModifierKeyCodes = []
        peakModifierKeyCodes = []
        removeMonitors()
        ServiceContainer.shared.hotkeyService.resumeMonitoring()
    }

    private func removeMonitors() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
    }

    private func modifierKeyCodes(
        for event: NSEvent,
        currentModifiers: NSEvent.ModifierFlags
    ) -> Set<UInt16> {
        let deviceKeyCodes = HotkeyService.modifierKeyCodes(from: event.modifierFlags)
        if !deviceKeyCodes.isEmpty || currentModifiers.isEmpty {
            return deviceKeyCodes
        }

        var updated = pendingModifierKeyCodes
        if HotkeyService.modifierKeyCodes.contains(event.keyCode),
           let flag = HotkeyService.modifierFlagForKeyCode(event.keyCode) {
            if currentModifiers.contains(flag) {
                updated.insert(event.keyCode)
            } else {
                updated.remove(event.keyCode)
            }
        }

        return updated.filter { keyCode in
            guard let flag = HotkeyService.modifierFlagForKeyCode(keyCode) else { return false }
            return currentModifiers.contains(flag)
        }
    }

    private func modifierKeyCodesForRecordedCombo() -> Set<UInt16> {
        let sideAwareFlags: [NSEvent.ModifierFlags] = [.command, .option, .control, .shift]
        let expectedKeyCodeCount = sideAwareFlags.filter { peakModifiers.contains($0) }.count
        guard expectedKeyCodeCount > 0,
              peakModifierKeyCodes.count == expectedKeyCodeCount else {
            return []
        }

        let recordedFlagRawValues = Set(peakModifierKeyCodes.compactMap {
            HotkeyService.modifierFlagForKeyCode($0)?.rawValue
        })
        guard recordedFlagRawValues.count == expectedKeyCodeCount,
              recordedFlagRawValues.allSatisfy({
                  peakModifiers.contains(NSEvent.ModifierFlags(rawValue: $0))
              }) else {
            return []
        }
        return peakModifierKeyCodes
    }
}
