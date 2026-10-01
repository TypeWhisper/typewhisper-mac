import SwiftUI
import Carbon.HIToolbox

/// Interactive Mac keyboard map for composing a shortcut visually.
/// Complements the event-driven `HotkeyRecorderView`: saving goes through the
/// exact same `onRecord` callback, so validation is identical by construction.
struct VisualShortcutKeyboardView: View {
    @StateObject private var model: VisualShortcutKeyboardModel

    let onSave: (UnifiedHotkey) -> Void
    let onClear: () -> Void
    let onCancel: () -> Void

    private let rowPitch: CGFloat = 46
    private let keySpacing: CGFloat = 5

    init(
        editingHotkey: UnifiedHotkey? = nil,
        existingAssignmentDescription: ((UnifiedHotkey) -> String?)? = nil,
        onSave: @escaping (UnifiedHotkey) -> Void,
        onClear: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        _model = StateObject(wrappedValue: VisualShortcutKeyboardModel(
            editingHotkey: editingHotkey,
            existingAssignmentDescription: existingAssignmentDescription
        ))
        self.onSave = onSave
        self.onClear = onClear
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 18) {
            header
            keyGrid
            optionsRow
            if let notice = model.conflictNotice {
                conflictNotice(notice)
            }
            buttonRow
            Divider()
            legend
        }
        .padding(24)
        .frame(width: 780)
        .onReceive(DistributedNotificationCenter.default()
            .publisher(for: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String))
            .receive(on: RunLoop.main)) { _ in
                model.refreshInputSource()
            }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshInputSource()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text(String(localized: "Visual Keyboard"))
                    .font(.headline)
                Text(String(localized: "Click modifiers, then a key."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(model.composedDisplayName.isEmpty ? "—" : model.composedDisplayName)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel(String(localized:
                    "Current combination: \(model.composedDisplayName.isEmpty ? String(localized: "None") : model.composedDisplayName)"))
        }
    }

    // MARK: - Physical keyboard

    private var keyGrid: some View {
        GeometryReader { geometry in
            let pitch = (geometry.size.width + keySpacing) / VisualShortcutKeyboardModel.keyboardWidth
            ZStack(alignment: .topLeading) {
                ForEach(VisualShortcutKeyboardModel.keyLayout(for: model.layoutKind)) { key in
                    keyButton(key, pitch: pitch)
                        .offset(x: key.x * pitch, y: key.y * rowPitch)
                }
            }
        }
        .frame(height: VisualShortcutKeyboardModel.keyboardHeight * rowPitch - keySpacing)
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08)))
    }

    private func keyButton(_ key: VisualKey, pitch: CGFloat) -> some View {
        let state = state(for: key.content)
        let shape = MacKeycapShape(isTallReturn: key.isTallReturn, notch: pitch * 0.25,
                                  shoulder: rowPitch - keySpacing)
        let width = key.width * pitch - keySpacing
        let height = key.height * rowPitch - keySpacing
        return Button {
            switch key.content {
            case .key(let code): model.toggleKey(code)
            case .modifier(let entry): model.toggleModifier(entry)
            case .capsLock, .touchID: break
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                shape.fill(stateFill(state))
                    .shadow(color: .black.opacity(0.16), radius: 0.5, y: 1)
                shape.stroke(stateBorder(state), lineWidth: state == .active ? 1.5 : 0.75)
                keyLegend(key.content)
                    .foregroundStyle(stateForeground(state))
                    .padding(.bottom, key.isTallReturn ? 10 : 0)
                    .frame(width: width, height: height, alignment: key.isTallReturn ? .bottom : .center)
                if key.content != .capsLock && key.content != .touchID {
                    stateBadge(state).padding(3)
                }
            }
            .frame(width: width, height: height)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(key.content == .capsLock || key.content == .touchID)
        .help(accessibilityName(for: key.content))
        .accessibilityLabel(keyAccessibilityLabel(label: accessibilityName(for: key.content), state: state))
    }

    @ViewBuilder
    private func keyLegend(_ content: VisualKey.Content) -> some View {
        switch content {
        case .modifier(let entry):
            switch entry {
            case .fn:
                Text("fn").font(.system(size: 12, weight: .medium))
            case .keyCode(let code):
                if code == 0x38 || code == 0x3C {
                    Text("⇧").font(.system(size: 21, weight: .regular))
                } else {
                    VStack(spacing: 2) {
                        Text(modifierSymbol(code)).font(.system(size: 17))
                        Text(modifierCaption(code)).font(.system(size: 8))
                    }
                }
            }
        case .capsLock:
            Text("⇪").font(.system(size: 20))
        case .touchID:
            Image(systemName: "touchid")
                .font(.system(size: 18, weight: .light))
        case .key(let code):
            Text(code == 0x35 ? "esc" : code == 0x31 ? "" : model.keyLabel(code))
                .font(.system(size: code == 0x35 || functionKeyCodes.contains(code) ? 10 : 15,
                              weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private var functionKeyCodes: Set<UInt16> {
        [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F]
    }

    private func modifierSymbol(_ code: UInt16) -> String {
        switch code {
        case 0x37, 0x36: return "⌘"
        case 0x3A, 0x3D: return "⌥"
        default: return "⌃"
        }
    }

    private func modifierCaption(_ code: UInt16) -> String {
        switch code {
        case 0x37, 0x36: return "command"
        case 0x3A, 0x3D: return "option"
        default: return "control"
        }
    }

    private func state(for content: VisualKey.Content) -> VisualKeyState {
        switch content {
        case .key(let code): model.state(forKey: code)
        case .modifier(let entry): model.state(forModifier: entry)
        case .capsLock, .touchID: .reserved
        }
    }

    private func accessibilityName(for content: VisualKey.Content) -> String {
        switch content {
        case .key(0x31): return String(localized: "Space")
        case .key(0x35): return "Escape"
        case .key(let code): return model.keyLabel(code)
        case .modifier(let entry): return model.label(forModifier: entry)
        case .capsLock: return "Caps Lock"
        case .touchID: return "Touch ID"
        }
    }

    // MARK: - State visuals (shape + icon, never color alone)

    @ViewBuilder
    private func stateBadge(_ state: VisualKeyState) -> some View {
        switch state {
        case .available:
            EmptyView()
        case .active:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 9))
                .foregroundStyle(.white, Color.accentColor)
                .background(Circle().fill(.white))
        case .conflicting:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .foregroundStyle(.orange)
                .background(Circle().fill(.white))
        case .reserved:
            Image(systemName: "nosign")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    private func stateFill(_ state: VisualKeyState) -> some ShapeStyle {
        switch state {
        case .available: return AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
        case .active: return AnyShapeStyle(Color.accentColor)
        case .conflicting: return AnyShapeStyle(.orange.opacity(0.12))
        case .reserved: return AnyShapeStyle(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        }
    }

    private func stateBorder(_ state: VisualKeyState) -> some ShapeStyle {
        switch state {
        case .available: return AnyShapeStyle(Color.primary.opacity(0.18))
        case .active: return AnyShapeStyle(Color.accentColor)
        case .conflicting: return AnyShapeStyle(.orange)
        case .reserved: return AnyShapeStyle(Color.primary.opacity(0.08))
        }
    }

    private func stateForeground(_ state: VisualKeyState) -> some ShapeStyle {
        switch state {
        case .available: return AnyShapeStyle(.primary)
        case .active: return AnyShapeStyle(.white)
        case .conflicting: return AnyShapeStyle(.primary)
        case .reserved: return AnyShapeStyle(.secondary)
        }
    }

    private func keyAccessibilityLabel(label: String, state: VisualKeyState) -> String {
        "\(label), \(stateVoiceOverText(state))"
    }

    private func stateVoiceOverText(_ state: VisualKeyState) -> String {
        switch state {
        case .available:
            return String(localized: "Available")
        case .active:
            return String(localized: "Selected")
        case .conflicting(let assignment):
            if let assignment {
                return String(localized: "Conflicts with \(assignment)")
            }
            return String(localized: "Conflicting")
        case .reserved:
            return String(localized: "Reserved, cannot be recorded")
        }
    }

    // MARK: - Legend

    private var legend: some View {
        HStack(spacing: 16) {
            legendItem(label: String(localized: "Available"), state: .available)
            legendItem(label: String(localized: "Selected"), state: .active)
            legendItem(label: String(localized: "Conflicting"), state: .conflicting(assignment: nil))
            legendItem(label: String(localized: "Reserved"), state: .reserved)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func legendItem(label: String, state: VisualKeyState) -> some View {
        HStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(stateFill(state))
                    .frame(width: 18, height: 18)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(stateBorder(state), lineWidth: 1)
                    )
                stateBadge(state)
                    .offset(x: 2, y: -2)
            }
            Text(label)
        }
    }

    // MARK: - Options

    private var optionsRow: some View {
        HStack {
            Toggle(
                String(localized: "Double-tap"),
                isOn: Binding(
                    get: { model.composition.isDoubleTap },
                    set: { _ in model.toggleDoubleTap() }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.small)

            Menu {
                if model.layoutKind == .jis {
                    modifierMenuItem(0x3D)
                }
                modifierMenuItem(0x3E)
            } label: {
                Text(String(localized: "More Keys"))
            }
            .fixedSize()
            .controlSize(.small)

            Spacer()

            if !model.inputSource.name.isEmpty {
                Label(model.inputSource.name, systemImage: "keyboard")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(String(localized: "Follows your current macOS input source."))
            }
        }
    }

    private func modifierMenuItem(_ code: UInt16) -> some View {
        Button {
            model.toggleModifier(.keyCode(code))
        } label: {
            if model.composition.modifierKeyCodes.contains(code) {
                Label(model.label(forModifier: .keyCode(code)), systemImage: "checkmark")
            } else {
                Text(model.label(forModifier: .keyCode(code)))
            }
        }
    }

    // MARK: - Conflict notice & buttons

    private func conflictNotice(_ notice: String) -> some View {
        Label {
            Text(String(localized: "Conflicts with \(notice). Saving will reassign it."))
            .font(.caption)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var buttonRow: some View {
        HStack {
            Button(String(localized: "Clear")) {
                model.clear()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel(String(localized: "Clear composed shortcut"))

            Spacer()

            Button(String(localized: "Cancel")) {
                onCancel()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(String(localized: "Save Shortcut")) {
                if let hotkey = model.composedHotkey {
                    onSave(hotkey)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!model.canSave)
            .accessibilityLabel(String(localized: "Save composed shortcut"))
        }
    }
}

/// ISO and JIS return keys have a single L-shaped hit target spanning two rows.
private struct MacKeycapShape: Shape {
    var isTallReturn: Bool
    var notch: CGFloat
    var shoulder: CGFloat

    func path(in rect: CGRect) -> Path {
        guard isTallReturn else {
            return RoundedRectangle(cornerRadius: 5).path(in: rect)
        }
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: rect.width, y: 0),
                      CGPoint(x: rect.width, y: rect.height), CGPoint(x: notch, y: rect.height),
                      CGPoint(x: notch, y: shoulder), CGPoint(x: 0, y: shoulder)]
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: shoulder / 2))
        for index in points.indices {
            path.addArc(tangent1End: points[index], tangent2End: points[(index + 1) % points.count], radius: 5)
        }
        path.closeSubpath()
        return Path(path)
    }
}
