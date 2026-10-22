import AppKit
import Combine
import OSLog
import SwiftUI

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "IndicatorModelMenu")

/// Shows the transcription model menu of the dictation indicator and applies its choice
/// (#1351). The menu opens from the indicator's non-activating panel, so the app that
/// receives the dictation keeps focus. A model chosen while a recording or transcription
/// runs waits until nothing transcribes anymore, so the running session keeps its model.
@MainActor
final class IndicatorModelMenuController: NSObject, ObservableObject, NSMenuDelegate {
    static let shared = IndicatorModelMenuController()

    /// A model chosen for the next dictation.
    @Published private(set) var pendingSwitch: PendingDictationModelSwitch?
    @Published private(set) var isMenuOpen = false

    private var quickSelectionModel: DictationQuickSelectionModel?
    private var anchors: [WeakView] = []
    private var menuChoices: [DictationModelChoice] = []
    /// The menu on screen, from `popUpMenu()` until `menuDidClose(_:)`.
    private var openMenu: NSMenu?
    private var isOpenMenuTracking = false
    /// Menu windows hidden from screen sharing while the menu is open, with their sharing before.
    private var hiddenMenuWindows: [HiddenMenuWindow] = []
    private var menuWindowTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private final class WeakView {
        weak var view: NSView?
        init(_ view: NSView) { self.view = view }
    }

    private struct HiddenMenuWindow {
        weak var window: NSWindow?
        let sharingType: NSWindow.SharingType
    }

    /// The same selection state the menu bar uses, created when the menu is first needed.
    private var quickSelection: DictationQuickSelectionModel {
        if let quickSelectionModel { return quickSelectionModel }
        let model = DictationQuickSelectionModel()
        quickSelectionModel = model
        // The snapshot follows the end of a recording or transcription with a short
        // delay. A waiting switch is checked whenever it reports a change of the lock.
        model.$snapshot
            .map(\.isLocked)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyPendingSwitchIfPossible()
            }
            .store(in: &cancellables)
        return model
    }

    private var enforcesTranscription: Bool {
        PluginManager.shared?.selectionPolicy.enforcesTranscription ?? false
    }

    private var currentSelection: DictationModelSelectionState {
        let modelManager = ServiceContainer.shared.modelManagerService
        let providerId = modelManager.selectedProviderId
        return DictationModelSelectionState(
            providerId: providerId,
            modelId: modelManager.selectedModelId(for: providerId)
        )
    }

    // MARK: Menu

    /// Registers the view the menu opens from. Each indicator style has its own.
    func registerAnchor(_ view: NSView) {
        anchors.removeAll { $0.view == nil || $0.view === view }
        anchors.append(WeakView(view))
    }

    /// The anchor of the indicator on screen; only one indicator style shows at a time.
    private var visibleAnchor: NSView? {
        anchors.removeAll { $0.view == nil }
        return anchors.reversed().compactMap(\.view).first { $0.window?.isVisible == true }
    }

    func showMenu() {
        guard !isMenuOpen, visibleAnchor != nil else { return }
        isMenuOpen = true
        // A menu can track in a nested run loop. Started from a run loop block instead of
        // a main queue job, the main queue keeps serving the recording meanwhile. The
        // indicator also shows its menu button before the menu appears.
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                self?.popUpMenu()
            }
        }
    }

    private func popUpMenu() {
        guard let anchor = visibleAnchor, let window = anchor.window else {
            finishMenuSession()
            return
        }
        let quickSelection = quickSelection
        quickSelection.rebuild()
        var snapshot = quickSelection.snapshot
        #if DEBUG
        if let screenshotSnapshot {
            snapshot = screenshotSnapshot
        }
        #endif
        let menu = makeMenu(entries: IndicatorModelMenu.entries(
            snapshot: snapshot,
            pending: pendingSwitch,
            enforcesTranscription: enforcesTranscription
        ))
        let origin = Self.menuOrigin(menuSize: menu.size, anchor: anchor, window: window)
        openMenu = menu
        menu.popUp(positioning: nil, at: origin, in: anchor)
        // popUp returns once the menu has closed, or right away when AppKit tracks the
        // menu without blocking (seen in the app). Then the menu stays open until
        // menuDidClose.
        if openMenu === menu, !isOpenMenuTracking {
            finishMenuSession()
        }
    }

    private func finishMenuSession() {
        openMenu = nil
        isOpenMenuTracking = false
        ServiceContainer.shared.hotkeyService.isIndicatorMenuOpen = false
        menuWindowTimer?.invalidate()
        menuWindowTimer = nil
        restoreMenuWindowSharing()
        isMenuOpen = false
    }

    /// Opens the menu below the anchor, or above it when the screen has no room below,
    /// as for an indicator at the bottom of the screen.
    private static func menuOrigin(menuSize: NSSize, anchor: NSView, window: NSWindow) -> NSPoint {
        let gap: CGFloat = 6
        let anchorOnScreen = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let screenFrame = window.screen?.visibleFrame ?? anchorOnScreen
        let opensUpward = anchorOnScreen.minY - gap - menuSize.height < screenFrame.minY
        let bounds = anchor.bounds
        // The menu's top left corner goes to this point.
        let y: CGFloat = switch (anchor.isFlipped, opensUpward) {
        case (false, false): bounds.minY - gap
        case (false, true): bounds.maxY + gap + menuSize.height
        case (true, false): bounds.maxY + gap
        case (true, true): bounds.minY - gap - menuSize.height
        }
        return NSPoint(x: bounds.minX, y: y)
    }

    private func makeMenu(entries: [IndicatorModelMenu.Entry]) -> NSMenu {
        menuChoices = []
        let menu = NSMenu(title: IndicatorModelMenu.title)
        menu.autoenablesItems = false
        menu.delegate = self
        for entry in entries {
            switch entry {
            case .note(let text):
                let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            case .header(let title):
                menu.addItem(NSMenuItem.sectionHeader(title: title))
            case .option(let option):
                menu.addItem(menuItem(for: option))
            case .moreModels(let title, let options):
                let submenu = NSMenu(title: title)
                submenu.autoenablesItems = false
                submenu.delegate = self
                options.forEach { submenu.addItem(menuItem(for: $0)) }
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.submenu = submenu
                menu.addItem(item)
            case .separator:
                menu.addItem(.separator())
            case .dictationSettings(let title):
                let item = NSMenuItem(title: title, action: #selector(openDictationSettings), keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
        }
        return menu
    }

    private func menuItem(for option: IndicatorModelMenu.Option) -> NSMenuItem {
        let item = NSMenuItem(title: option.title, action: #selector(chooseModel(_:)), keyEquivalent: "")
        item.target = self
        item.tag = menuChoices.count
        menuChoices.append(option.choice)
        item.state = option.isSelected ? .on : .off
        item.isEnabled = option.isEnabled
        return item
    }

    @objc private func chooseModel(_ sender: NSMenuItem) {
        guard menuChoices.indices.contains(sender.tag) else { return }
        select(menuChoices[sender.tag])
    }

    @objc private func openDictationSettings() {
        quickSelection.openDictationSettings()
    }

    // MARK: Selection

    func select(_ choice: DictationModelChoice) {
        let quickSelection = quickSelection
        quickSelection.rebuild()
        let request = IndicatorModelMenu.request(
            choosing: choice,
            snapshot: quickSelection.snapshot,
            pending: pendingSwitch,
            currentSelection: currentSelection,
            enforcesTranscription: enforcesTranscription
        )
        switch request {
        case .ignore:
            return
        case .cancelPending:
            pendingSwitch = nil
        case .queue(let pending):
            pendingSwitch = pending
            announce(IndicatorModelMenu.nextDictationNote(modelTitle: pending.title))
        case .apply(let title):
            pendingSwitch = nil
            quickSelection.selectModel(choice)
            announce(localizedAppText("Model: \(title)", de: "Modell: \(title)"))
        }
    }

    private func applyPendingSwitchIfPossible() {
        guard let pendingSwitch else { return }
        let quickSelection = quickSelection
        quickSelection.rebuild()
        switch IndicatorModelMenu.resolve(
            pendingSwitch,
            isLocked: quickSelection.snapshot.isLocked,
            currentSelection: currentSelection
        ) {
        case .wait:
            return
        case .discard:
            self.pendingSwitch = nil
            logger.info("Dropped the model chosen for the next dictation because the selection changed elsewhere")
        case .apply(let choice):
            self.pendingSwitch = nil
            // Checks again that the model can be used without setup.
            quickSelection.selectModel(choice)
        }
    }

    private func announce(_ message: String) {
        ServiceContainer.shared.accessibilityAnnouncementService.announce(message)
    }

    #if DEBUG
    /// Screenshot runs list fixed engines instead of the plugins installed in the run.
    private var screenshotSnapshot: DictationQuickSelectionSnapshot?

    func prepareScreenshotFixture(
        snapshot: DictationQuickSelectionSnapshot,
        pending: PendingDictationModelSwitch?
    ) {
        guard AppConstants.isScreenshotAutomation else { return }
        screenshotSnapshot = snapshot
        pendingSwitch = pending
    }
    #endif

    // MARK: Menu windows

    func menuWillOpen(_ menu: NSMenu) {
        if menu === openMenu {
            isOpenMenuTracking = true
            // Escape, Return and the arrow keys belong to the menu, so they neither
            // cancel nor submit the dictation while it is open.
            ServiceContainer.shared.hotkeyService.isIndicatorMenuOpen = true
            // An indicator hidden from screen sharing keeps its menu hidden too. Menu
            // windows appear after this and AppKit sets their sharing when it shows them,
            // so they are checked again while the menu is open.
            if !DictationViewModel.shared.indicatorVisibleInScreenCaptures {
                let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.hideMenuWindowsFromCaptures()
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                menuWindowTimer?.invalidate()
                menuWindowTimer = timer
            }
        }
        hideMenuWindowsFromCaptures()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === openMenu else { return }
        finishMenuSession()
    }

    private func hideMenuWindowsFromCaptures() {
        guard isMenuOpen, !DictationViewModel.shared.indicatorVisibleInScreenCaptures else { return }
        for window in NSApp.windows where Self.isMenuWindow(window) && window.sharingType != .none {
            if !hiddenMenuWindows.contains(where: { $0.window === window }) {
                hiddenMenuWindows.append(HiddenMenuWindow(window: window, sharingType: window.sharingType))
            }
            window.sharingType = .none
        }
    }

    /// AppKit draws menus in its own windows (`NSPopupMenuWindow`), above the window they
    /// open from, which for the notch indicator is above the usual menu level.
    private static func isMenuWindow(_ window: NSWindow) -> Bool {
        window.level.rawValue >= NSWindow.Level.popUpMenu.rawValue
            && NSStringFromClass(type(of: window)).contains("Menu")
    }

    /// AppKit reuses menu windows, so other menus keep their usual sharing.
    private func restoreMenuWindowSharing() {
        for hidden in hiddenMenuWindows {
            hidden.window?.sharingType = hidden.sharingType
        }
        hiddenMenuWindows.removeAll()
    }
}

// MARK: - Indicator views

/// Where the model menu opens: the status area of a dictation indicator.
struct IndicatorModelMenuAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        IndicatorModelMenuController.shared.registerAnchor(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }
    }
}

/// Opens the transcription model menu. A dictation indicator shows it in place of its
/// status while the pointer rests on the indicator, as the Recorder shows Stop.
struct IndicatorModelMenuButton: View {
    let sizing: IndicatorSizing
    var action: () -> Void = { IndicatorModelMenuController.shared.showMenu() }

    var body: some View {
        Button(action: action) {
            Image(systemName: "cpu")
                .font(.system(size: sizing.iconSize * 0.6, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: sizing.iconSize, height: sizing.iconSize)
                .background(Circle().fill(Color.accentColor))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(IndicatorModelMenu.title)
        .accessibilityLabel(IndicatorModelMenu.title)
        .accessibilityIdentifier("indicator.dictation.model")
    }
}

extension View {
    /// Lets VoiceOver open the model menu of a dictation indicator, which pointer users
    /// reach through the button that appears on hover.
    func indicatorModelMenuAccessibilityAction(isAvailable: Bool) -> some View {
        accessibilityActions {
            if isAvailable {
                Button(IndicatorModelMenu.chooseModelActionName) {
                    IndicatorModelMenuController.shared.showMenu()
                }
            }
        }
    }
}
