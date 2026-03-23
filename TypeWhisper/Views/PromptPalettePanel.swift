import SwiftUI
import AppKit

// MARK: - SwiftUI View

struct PromptPaletteContentView: View {
    let actions: [PromptAction]
    let sourceText: String
    let onSelect: (PromptAction) -> Void
    let onDismiss: () -> Void

    @State private var searchText = ""
    @State private var selectedIndex = 0

    private var filteredActions: [PromptAction] {
        if searchText.isEmpty {
            return actions
        }
        return actions.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Source text preview
            Text(sourceText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 8)

            Divider()

            // Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)

                TextField(String(localized: "Search prompts..."), text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .accessibilityLabel(String(localized: "Search prompts"))
                    .onSubmit {
                        if let action = filteredActions[safe: selectedIndex] {
                            onSelect(action)
                        }
                    }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            // Actions list
            if filteredActions.isEmpty {
                VStack(spacing: 8) {
                    Text(String(localized: "No matching prompts"))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(filteredActions.enumerated()), id: \.element.id) { index, action in
                                PromptPaletteRow(
                                    action: action,
                                    isSelected: index == selectedIndex
                                )
                                .id(index)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    onSelect(action)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                    }
                    .onChange(of: selectedIndex) { _, newValue in
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 380, height: 400)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
        .onKeyPress(.upArrow) {
            if selectedIndex > 0 {
                selectedIndex -= 1
            }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if selectedIndex < filteredActions.count - 1 {
                selectedIndex += 1
            }
            return .handled
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
        .onChange(of: searchText) { _, _ in
            selectedIndex = 0
        }
    }
}

private struct PromptPaletteRow: View {
    let action: PromptAction
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: action.icon)
                .font(.system(size: 14))
                .foregroundColor(isSelected ? .white : .accentColor)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

            Text(action.name)
                .font(.system(size: 13))
                .foregroundColor(isSelected ? .white : .primary)

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .accessibilityLabel(action.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - NSPanel

class PromptPalettePanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.isMovableByWindowBackground = false
    }

    override var canBecomeKey: Bool { true }

    func positionOnActiveScreen() {
        let screen = activeScreen() ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen = screen else { return }

        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - frame.width / 2
        let y = screenFrame.midY + 60

        setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func activeScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            if screen.frame.contains(mouseLocation) {
                return screen
            }
        }
        return nil
    }
}

// MARK: - Controller

@MainActor
class PromptPaletteController {
    private var panel: PromptPalettePanel?
    private var hostingView: NSHostingView<PromptPaletteContentView>?
    private var onActionSelected: ((PromptAction) -> Void)?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?

    func show(actions: [PromptAction], sourceText: String, onSelect: @escaping (PromptAction) -> Void) {
        hide()

        let enabledActions = actions.filter { $0.isEnabled }
        guard !enabledActions.isEmpty else { return }

        self.onActionSelected = onSelect

        let contentView = PromptPaletteContentView(
            actions: enabledActions,
            sourceText: sourceText,
            onSelect: { [weak self] action in
                self?.hide()
                onSelect(action)
            },
            onDismiss: { [weak self] in
                self?.hide()
            }
        )

        let hosting = NSHostingView(rootView: contentView)
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hostingView = hosting

        let panelSize = NSSize(width: 380, height: 400)

        let palettePanel = PromptPalettePanel()
        palettePanel.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: panelSize)
        palettePanel.setContentSize(panelSize)
        palettePanel.positionOnActiveScreen()

        panel = palettePanel
        palettePanel.makeKeyAndOrderFront(nil)

        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            if let panel = self?.panel, !panel.frame.contains(NSEvent.mouseLocation) {
                self?.hide()
            }
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.hide()
        }
    }

    func hide() {
        if let monitor = localClickMonitor {
            NSEvent.removeMonitor(monitor)
            localClickMonitor = nil
        }
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
        onActionSelected = nil
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }
}

// MARK: - Array Extension

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
