import AppKit
import SwiftUI

struct SelectionPaletteItem: Identifiable, Equatable {
    let id: UUID
    let title: String
    let subtitle: String?
    let iconSystemName: String?
    let searchTokens: [String]

    init(
        id: UUID,
        title: String,
        subtitle: String? = nil,
        iconSystemName: String? = nil,
        searchTokens: [String] = []
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.iconSystemName = iconSystemName
        self.searchTokens = searchTokens
    }
}

struct SelectionPaletteConfiguration: Equatable {
    let panelWidth: CGFloat
    let panelHeight: CGFloat
    let previewText: String?
    let previewLineLimit: Int
    let titleLineLimit: Int
    let searchPrompt: String?
    let emptyStateTitle: String

    init(
        panelWidth: CGFloat = 380,
        panelHeight: CGFloat = 400,
        previewText: String? = nil,
        previewLineLimit: Int = 3,
        titleLineLimit: Int = 1,
        searchPrompt: String? = nil,
        emptyStateTitle: String
    ) {
        self.panelWidth = panelWidth
        self.panelHeight = panelHeight
        self.previewText = previewText
        self.previewLineLimit = previewLineLimit
        self.titleLineLimit = titleLineLimit
        self.searchPrompt = searchPrompt
        self.emptyStateTitle = emptyStateTitle
    }

    var showsSearchField: Bool { searchPrompt != nil }
}

@MainActor
protocol SelectionPaletteControlling: AnyObject {
    var isVisible: Bool { get }
    func show(
        configuration: SelectionPaletteConfiguration,
        items: [SelectionPaletteItem],
        onSelect: @escaping (SelectionPaletteItem) -> Void
    )
    func hide()
}

@MainActor
final class SelectionPaletteInteractionModel: ObservableObject {
    let configuration: SelectionPaletteConfiguration

    @Published var searchText = "" {
        didSet {
            if searchText != oldValue {
                selectedIndex = 0
            }
        }
    }
    @Published private(set) var selectedIndex = 0

    private let items: [SelectionPaletteItem]
    private let onSelect: (SelectionPaletteItem) -> Void
    private let onDismiss: () -> Void

    init(
        configuration: SelectionPaletteConfiguration,
        items: [SelectionPaletteItem],
        onSelect: @escaping (SelectionPaletteItem) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.configuration = configuration
        self.items = items
        self.onSelect = onSelect
        self.onDismiss = onDismiss
    }

    var filteredItems: [SelectionPaletteItem] {
        guard configuration.showsSearchField, !searchText.isEmpty else {
            return items
        }

        return items.filter { item in
            item.title.localizedCaseInsensitiveContains(searchText)
                || (item.subtitle?.localizedCaseInsensitiveContains(searchText) ?? false)
                || item.searchTokens.contains(where: { $0.localizedCaseInsensitiveContains(searchText) })
        }
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 125: // Down arrow
            moveSelection(by: 1)
            return true
        case 126: // Up arrow
            moveSelection(by: -1)
            return true
        case 36, 76: // Return, keypad enter
            acceptSelection()
            return true
        case 53: // Escape
            onDismiss()
            return true
        case 51, 117: // Delete, forward delete
            guard configuration.showsSearchField else { return false }
            deleteBackward()
            return true
        default:
            guard configuration.showsSearchField, let typedText = event.selectionPaletteTypedText else {
                return false
            }
            searchText.append(typedText)
            return true
        }
    }

    func selectItem(_ item: SelectionPaletteItem) {
        onSelect(item)
    }

    private func moveSelection(by offset: Int) {
        guard !filteredItems.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + offset, 0), filteredItems.count - 1)
    }

    private func acceptSelection() {
        guard let item = filteredItems[safe: selectedIndex] else { return }
        onSelect(item)
    }

    private func deleteBackward() {
        guard !searchText.isEmpty else { return }
        searchText.removeLast()
    }
}

private struct SelectionPaletteContentView: View {
    @ObservedObject var model: SelectionPaletteInteractionModel

    var body: some View {
        VStack(spacing: 0) {
            if let previewText = model.configuration.previewText {
                Text(previewText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(model.configuration.previewLineLimit)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 8)

                Divider()
            }

            if let searchPrompt = model.configuration.searchPrompt {
                SelectionPaletteSearchField(
                    prompt: searchPrompt,
                    text: model.searchText
                )
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider()
            }

            if model.filteredItems.isEmpty {
                VStack(spacing: 8) {
                    Text(model.configuration.emptyStateTitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 20)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(model.filteredItems.enumerated()), id: \.element.id) { index, item in
                                SelectionPaletteRow(
                                    item: item,
                                    isSelected: index == model.selectedIndex,
                                    titleLineLimit: model.configuration.titleLineLimit
                                )
                                .id(index)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    model.selectItem(item)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                    }
                    .onChange(of: model.selectedIndex) { _, newValue in
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
        .frame(width: model.configuration.panelWidth, height: model.configuration.panelHeight)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
    }
}

private struct SelectionPaletteSearchField: View {
    let prompt: String
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .accessibilityHidden(true)

            HStack(spacing: 1) {
                if text.isEmpty {
                    Text(prompt)
                        .foregroundColor(.secondary)
                } else {
                    Text(text)
                        .foregroundColor(.primary)
                }

                Rectangle()
                    .fill(Color.accentColor.opacity(0.85))
                    .frame(width: 1, height: 14)
            }
            .font(.system(size: 15))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(prompt)
        .accessibilityValue(text)
    }
}

private struct SelectionPaletteRow: View {
    let item: SelectionPaletteItem
    let isSelected: Bool
    let titleLineLimit: Int

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let iconSystemName = item.iconSystemName {
                Image(systemName: iconSystemName)
                    .font(.system(size: 14))
                    .foregroundColor(isSelected ? .white : .accentColor)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: item.subtitle == nil ? 0 : 2) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isSelected ? .white : .primary)
                    .lineLimit(titleLineLimit)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(isSelected ? .white.opacity(0.9) : .secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.subtitle.map { "\(item.title), \($0)" } ?? item.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private final class SelectionPalettePanel: NSPanel {
    var keyDownHandler: ((NSEvent) -> Bool)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if keyDownHandler?(event) == true {
            return
        }
        super.keyDown(with: event)
    }

    func positionOnActiveScreen() {
        let screen = activeScreen() ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }

        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - frame.width / 2
        let y = screenFrame.midY + 60

        setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func activeScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
    }
}

@MainActor
final class SelectionPaletteController: SelectionPaletteControlling {
    private var panel: SelectionPalettePanel?
    private var hostingView: NSHostingView<SelectionPaletteContentView>?
    private var interactionModel: SelectionPaletteInteractionModel?
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?

    var isVisible: Bool { panel != nil }

    func show(
        configuration: SelectionPaletteConfiguration,
        items: [SelectionPaletteItem],
        onSelect: @escaping (SelectionPaletteItem) -> Void
    ) {
        hide()
        guard !items.isEmpty else { return }

        let interactionModel = SelectionPaletteInteractionModel(
            configuration: configuration,
            items: items,
            onSelect: { [weak self] item in
                self?.hide()
                onSelect(item)
            },
            onDismiss: { [weak self] in
                self?.hide()
            }
        )
        self.interactionModel = interactionModel

        let contentView = SelectionPaletteContentView(
            model: interactionModel
        )

        let hosting = NSHostingView(rootView: contentView)
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hostingView = hosting

        let panelSize = NSSize(width: configuration.panelWidth, height: configuration.panelHeight)
        let palettePanel = SelectionPalettePanel()
        palettePanel.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: panelSize)
        palettePanel.setContentSize(panelSize)
        palettePanel.positionOnActiveScreen()
        palettePanel.keyDownHandler = { [weak interactionModel] event in
            interactionModel?.handleKeyDown(event) ?? false
        }

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
        interactionModel = nil
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension NSEvent {
    var selectionPaletteTypedText: String? {
        let disallowedModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .function]
        let modifiers = modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.intersection(disallowedModifiers).isEmpty else {
            return nil
        }

        guard let characters, !characters.isEmpty else {
            return nil
        }

        let containsControlCharacter = characters.unicodeScalars.contains(where: { scalar in
            CharacterSet.controlCharacters.contains(scalar)
        })
        return containsControlCharacter ? nil : characters
    }
}
