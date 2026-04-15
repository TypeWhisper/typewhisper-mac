import SwiftUI

struct HotkeyRecorderView: View {
    let label: String
    var title: String = String(localized: "Dictation shortcut")
    var subtitle: String? = nil
    let onRecord: (UnifiedHotkey) -> Void
    let onClear: () -> Void

    @State private var isRecording = false
    @State private var pendingModifiers: NSEvent.ModifierFlags = []
    @State private var pendingDeviceModifierFlags: UInt = 0
    @State private var peakModifiers: NSEvent.ModifierFlags = []
    @State private var peakDeviceModifierFlags: UInt = 0
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
            if isRecording {
                Button {
                    cancelRecording()
                } label: {
                    if let displayName = firstTapDisplayName {
                        Text("\(displayName) - \(String(localized: "tap again for double-tap…"))")
                            .foregroundStyle(.orange)
                    } else {
                        Text(pendingModifierString.isEmpty
                            ? String(localized: "Press a key or mouse button…")
                            : pendingModifierString)
                            .foregroundStyle(.orange)
                    }
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
            }
        }
    }

    private var pendingModifierString: String {
        guard !pendingModifiers.isEmpty else { return "" }
        return HotkeyService.displayName(
            for: UnifiedHotkey(
                keyCode: UnifiedHotkey.modifierComboKeyCode,
                modifierFlags: pendingModifiers.rawValue,
                deviceModifierFlags: pendingDeviceModifierFlags,
                isFn: false
            )
        )
    }

    private func startRecording() {
        if let activeId = Self.activeRecorder, activeId != id {
            return
        }
        Self.activeRecorder = id
        isRecording = true
        pendingModifiers = []
        pendingDeviceModifierFlags = 0
        peakModifiers = []
        peakDeviceModifierFlags = 0
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
            let currentDeviceModifierFlags = HotkeyService.deviceSpecificModifierFlags(from: event.modifierFlags)

            // Track peak modifier set (most modifiers held simultaneously)
            if current.isSuperset(of: peakModifiers) {
                peakModifiers = current
                peakDeviceModifierFlags = currentDeviceModifierFlags
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
                        deviceModifierFlags: peakDeviceModifierFlags,
                        isFn: false
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
                            deviceModifierFlags: candidate.deviceModifierFlags,
                            isFn: candidate.isFn,
                            isDoubleTap: true
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
                    pendingDeviceModifierFlags = 0
                    peakModifiers = []
                    peakDeviceModifierFlags = 0
                    return true
                }
            }

            pendingModifiers = current
            pendingDeviceModifierFlags = currentDeviceModifierFlags
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
            let deviceModifierFlags = HotkeyService.deviceSpecificModifierFlags(from: event.modifierFlags)

            finishRecording(
                UnifiedHotkey(
                    keyCode: event.keyCode,
                    modifierFlags: modifiers,
                    deviceModifierFlags: deviceModifierFlags,
                    isFn: false
                )
            )
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
        pendingDeviceModifierFlags = 0
        peakModifiers = []
        peakDeviceModifierFlags = 0
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
        pendingDeviceModifierFlags = 0
        peakModifiers = []
        peakDeviceModifierFlags = 0
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
}
