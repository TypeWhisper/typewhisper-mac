import SwiftUI

/// Interactive Mac keyboard map for composing a shortcut visually.
/// Complements the event-driven `HotkeyRecorderView`: saving goes through the
/// exact same `onRecord` callback, so validation is identical by construction.
struct VisualShortcutKeyboardView: View {
    @StateObject private var model: VisualShortcutKeyboardModel

    let onSave: (UnifiedHotkey) -> Void
    let onClear: () -> Void
    let onCancel: () -> Void

    private let keyHeight: CGFloat = 40
    private let keySpacing: CGFloat = 4

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
        VStack(spacing: 12) {
            header
            modifierStripSection
            Divider()
            keyGrid
            legend
            optionsRow
            if let notice = model.conflictNotice {
                conflictNotice(notice)
            }
            buttonRow
        }
        .padding(20)
        .frame(width: 660)
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 4) {
            Text(localizedAppText("Visual Keyboard", de: "Visuelle Tastatur"))
                .font(.headline)
            Text(model.composedDisplayName.isEmpty
                ? localizedAppText("Tap modifiers, then a key.", de: "Tippe auf Modifikatoren, dann auf eine Taste.")
                : model.composedDisplayName)
                .font(.title2.monospaced())
                .foregroundStyle(model.composedDisplayName.isEmpty ? .secondary : .primary)
                .accessibilityLabel(localizedAppText(
                    "Current combination: \(model.composedDisplayName.isEmpty ? "none" : model.composedDisplayName)",
                    de: "Aktuelle Kombination: \(model.composedDisplayName.isEmpty ? "keine" : model.composedDisplayName)"
                ))
        }
    }

    // MARK: - Modifier strip

    private var modifierStripSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localizedAppText("Modifiers", de: "Modifikatoren"))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: keySpacing) {
                ForEach(VisualShortcutKeyboardModel.modifierStrip, id: \.self) { entry in
                    modifierButton(entry)
                }
            }
        }
    }

    private func modifierButton(_ entry: VisualModifierEntry) -> some View {
        let state = model.state(forModifier: entry)
        return Button {
            model.toggleModifier(entry)
        } label: {
            ZStack(alignment: .topTrailing) {
                Text(model.label(forModifier: entry))
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, minHeight: keyHeight)
                    .background(stateFill(state), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(stateBorder(state), lineWidth: state == .active ? 2 : 1)
                    )
                    .foregroundStyle(stateForeground(state))
                stateBadge(state)
                    .offset(x: 2, y: -2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(modifierAccessibilityLabel(entry: entry, state: state))
    }

    // MARK: - Key grid

    private var keyGrid: some View {
        let rows = VisualShortcutKeyboardModel.mainRows(for: model.layoutKind)
        return VStack(spacing: keySpacing) {
            ForEach(rows.indices, id: \.self) { index in
                keyRow(rows[index])
            }
            HStack {
                Spacer()
                ForEach(VisualShortcutKeyboardModel.arrowKeys) { key in
                    arrowButton(key)
                }
            }
        }
    }

    private func keyRow(_ keys: [VisualKey]) -> some View {
        GeometryReader { geometry in
            HStack(spacing: keySpacing) {
                ForEach(keys) { key in
                    let width = keyWidth(key, in: keys, totalWidth: geometry.size.width)
                    mainKeyButton(key, width: width)
                }
            }
        }
        .frame(height: keyHeight)
    }

    private func keyWidth(_ key: VisualKey, in row: [VisualKey], totalWidth: CGFloat) -> CGFloat {
        let totalWeight = row.reduce(0) { $0 + $1.weight }
        let totalSpacing = keySpacing * CGFloat(row.count - 1)
        guard totalWeight > 0, totalWidth > totalSpacing else { return 0 }
        return (totalWidth - totalSpacing) * (key.weight / totalWeight)
    }

    private func mainKeyButton(_ key: VisualKey, width: CGFloat) -> some View {
        let state = model.state(forKey: key.keyCode)
        let label = model.keyLabel(key.keyCode)
        return Button {
            model.toggleKey(key.keyCode)
        } label: {
            ZStack(alignment: .topTrailing) {
                Text(label)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(width: width, height: keyHeight)
                    .background(stateFill(state), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(stateBorder(state), lineWidth: state == .active ? 2 : 1)
                    )
                    .foregroundStyle(stateForeground(state))
                stateBadge(state)
                    .offset(x: 2, y: -2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(keyAccessibilityLabel(label: label, state: state))
    }

    private func arrowButton(_ key: VisualKey) -> some View {
        mainKeyButton(key, width: 44)
    }

    // MARK: - State visuals (shape + icon, never color alone)

    @ViewBuilder
    private func stateBadge(_ state: VisualKeyState) -> some View {
        switch state {
        case .available:
            EmptyView()
        case .active:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.white, Color.accentColor)
                .background(Circle().fill(.white))
        case .conflicting:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .background(Circle().fill(.white))
        case .reserved:
            Image(systemName: "nosign")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func stateFill(_ state: VisualKeyState) -> some ShapeStyle {
        switch state {
        case .available: return AnyShapeStyle(.quaternary)
        case .active: return AnyShapeStyle(Color.accentColor)
        case .conflicting: return AnyShapeStyle(.orange.opacity(0.25))
        case .reserved: return AnyShapeStyle(.tertiary.opacity(0.5))
        }
    }

    private func stateBorder(_ state: VisualKeyState) -> some ShapeStyle {
        switch state {
        case .available: return AnyShapeStyle(.tertiary)
        case .active: return AnyShapeStyle(Color.accentColor)
        case .conflicting: return AnyShapeStyle(.orange)
        case .reserved: return AnyShapeStyle(.secondary.opacity(0.4))
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

    private func modifierAccessibilityLabel(entry: VisualModifierEntry, state: VisualKeyState) -> String {
        "\(model.label(forModifier: entry)), \(stateVoiceOverText(state))"
    }

    private func stateVoiceOverText(_ state: VisualKeyState) -> String {
        switch state {
        case .available:
            return localizedAppText("available", de: "verfügbar")
        case .active:
            return localizedAppText("selected", de: "ausgewählt")
        case .conflicting(let assignment):
            if let assignment {
                return localizedAppText("conflicts with \(assignment)", de: "Konflikt mit \(assignment)")
            }
            return localizedAppText("conflicting", de: "in Konflikt")
        case .reserved:
            return localizedAppText("reserved, cannot be recorded", de: "reserviert, kann nicht aufgenommen werden")
        }
    }

    // MARK: - Legend

    private var legend: some View {
        HStack(spacing: 16) {
            legendItem(label: localizedAppText("Available", de: "Verfügbar"), state: .available)
            legendItem(label: localizedAppText("Selected", de: "Ausgewählt"), state: .active)
            legendItem(label: localizedAppText("Conflicting", de: "In Konflikt"), state: .conflicting(assignment: nil))
            legendItem(label: localizedAppText("Reserved", de: "Reserviert"), state: .reserved)
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
                localizedAppText("Double-tap", de: "Doppeltippen"),
                isOn: Binding(
                    get: { model.composition.isDoubleTap },
                    set: { _ in model.toggleDoubleTap() }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.small)

            Spacer()

            Picker(
                localizedAppText("Layout", de: "Layout"),
                selection: $model.layoutKind
            ) {
                Text("ANSI").tag(VisualKeyboardLayoutKind.ansi)
                Text("ISO").tag(VisualKeyboardLayoutKind.iso)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: 140)
        }
    }

    // MARK: - Conflict notice & buttons

    private func conflictNotice(_ notice: String) -> some View {
        Label {
            Text(localizedAppText(
                "Conflicts with \(notice). Saving will reassign it.",
                de: "Konflikt mit \(notice). Beim Speichern wird er neu zugewiesen."
            ))
            .font(.caption)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var buttonRow: some View {
        HStack {
            Button(localizedAppText("Clear", de: "Löschen")) {
                model.clear()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel(localizedAppText("Clear composed shortcut", de: "Zusammengestellten Shortcut löschen"))

            Spacer()

            Button(localizedAppText("Cancel", de: "Abbrechen")) {
                onCancel()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(localizedAppText("Save Shortcut", de: "Shortcut speichern")) {
                if let hotkey = model.composedHotkey {
                    onSave(hotkey)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!model.canSave)
            .accessibilityLabel(localizedAppText("Save composed shortcut", de: "Zusammengestellten Shortcut speichern"))
        }
    }
}
