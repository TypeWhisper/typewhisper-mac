import AppKit
import Foundation
import os
import SwiftUI
import TypeWhisperModuleKit
import TypeWhisperModules

/// Loads the modules the app is built with and keeps their contributions.
///
/// Builds from this repository link the stub package, which has no modules.
@MainActor
final class ModuleRegistry {
    /// True when the linked `TypeWhisperModules` package is the stub.
    let isStub: Bool
    private(set) var modules: [any HostModule] = []
    private(set) var contributions = ModuleContributions()
    /// The host the modules were given. Kept as long as the registry, which
    /// lives as long as the app, so a module may hold the host weakly.
    let host: any ModuleHost

    private let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "Modules")

    init(
        entry: any ModuleEntryPoint.Type = ModuleEntry.self,
        host: any ModuleHost,
        kitVersion: ModuleKitVersion = .current
    ) {
        isStub = entry.isStub
        self.host = host
        let required = entry.requiredModuleKitVersion
        guard kitVersion.supports(required) else {
            logger.error(
                "Modules skipped: they require interface \(required.description, privacy: .public), the app has \(kitVersion.description, privacy: .public)"
            )
            return
        }
        modules = entry.makeModules()
        for module in modules {
            contributions.append(Self.withoutDuplicates(module.contributions(for: host), after: contributions))
        }
        (host as? AppModuleHost)?.panels = contributions.panels
    }

    /// Adds the modules' managed settings keys to the app's, so they are read,
    /// validated and reported with them.
    func registerManagedPolicyKeys() {
        let skipped = ManagedPolicyKeys.setModuleDefinitions(
            contributions.managedPolicyKeys.map(ManagedPolicyDefinition.init)
        )
        for name in skipped {
            logger.error("Module managed setting skipped: \(name, privacy: .public) is not a valid new key")
        }
    }

    func hotkeyAction(withID id: String) -> ModuleHotkeyAction? {
        contributions.hotkeyActions.first { $0.id == id }
    }

    func performHotkeyAction(withID id: String) {
        hotkeyAction(withID: id)?.perform()
    }

    /// The contributions of a module without the identifiers an earlier
    /// module already uses, which would share its settings. Hotkey actions
    /// also need an identifier that `ModuleIdentifier` accepts, because the
    /// app stores their shortcuts under it.
    private static func withoutDuplicates(
        _ new: ModuleContributions, after existing: ModuleContributions
    ) -> ModuleContributions {
        func unique<Item: Identifiable>(_ items: [Item], _ taken: [Item]) -> [Item] where Item.ID == String {
            var seen = Set(taken.map(\.id))
            return items.filter { seen.insert($0.id).inserted }
        }
        return ModuleContributions(
            hotkeyActions: unique(new.hotkeyActions.filter { ModuleIdentifier.isValid($0.id) }, existing.hotkeyActions),
            menuItems: unique(new.menuItems, existing.menuItems),
            panels: unique(new.panels, existing.panels),
            recordActions: unique(new.recordActions, existing.recordActions),
            premiumCards: unique(new.premiumCards, existing.premiumCards),
            managedPolicyKeys: new.managedPolicyKeys,
            historySidebarGroups: unique(new.historySidebarGroups, existing.historySidebarGroups)
        )
    }
}

/// The identifiers the app stores module settings and files under:
/// letters, digits, dots, hyphens and underscores, at most 128 characters.
enum ModuleIdentifier {
    static func isValid(_ id: some StringProtocol) -> Bool {
        guard !id.isEmpty, id.count <= 128, id != ".", id != "..", !id.hasPrefix(".") else { return false }
        return id.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "._-".unicodeScalars.contains(scalar))
        }
    }
}

/// The app's side of `ModuleHost`.
@MainActor
final class AppModuleHost: ModuleHost {
    let historyReading: (any HistoryReading)?
    let historySearching: (any HistorySearching)?
    let languageModelAnswering: (any LanguageModelAnswering)?
    let managedPolicyReading: (any TypeWhisperModuleKit.ManagedPolicyReading)?
    let premiumAccessReading: (any PremiumAccessReading)?
    let userDataLifecycle: (any UserDataLifecycle)?

    /// The panels of all modules. Set by `ModuleRegistry` once it has them.
    var panels: [ModulePanel] = []
    private var panelControllers: [String: ModulePanelController] = [:]

    init(
        historyReading: (any HistoryReading)? = nil,
        historySearching: (any HistorySearching)? = nil,
        languageModelAnswering: (any LanguageModelAnswering)? = nil,
        managedPolicyReading: (any TypeWhisperModuleKit.ManagedPolicyReading)? = nil,
        premiumAccessReading: (any PremiumAccessReading)? = nil,
        userDataLifecycle: (any UserDataLifecycle)? = nil
    ) {
        self.historyReading = historyReading
        self.historySearching = historySearching
        self.languageModelAnswering = languageModelAnswering
        self.managedPolicyReading = managedPolicyReading
        self.premiumAccessReading = premiumAccessReading
        self.userDataLifecycle = userDataLifecycle
    }

    func showPanel(withID id: String) {
        panelController(withID: id)?.show()
    }

    func hidePanel(withID id: String) {
        panelControllers[id]?.hide()
    }

    func togglePanel(withID id: String) {
        isPanelVisible(withID: id) ? hidePanel(withID: id) : showPanel(withID: id)
    }

    func isPanelVisible(withID id: String) -> Bool {
        panelControllers[id]?.isVisible == true
    }

    /// Made on first use, so the launch builds no panel.
    private func panelController(withID id: String) -> ModulePanelController? {
        if let controller = panelControllers[id] { return controller }
        guard let panel = panels.first(where: { $0.id == id }) else { return nil }
        let controller = ModulePanelController(panel: panel)
        panelControllers[id] = controller
        return controller
    }
}

/// Shows one module panel: borderless and floating, above the windows of
/// other apps, closed with Escape.
@MainActor
final class ModulePanelController {
    private let panel: ModulePanel
    private var window: ModulePanelWindow?

    init(panel: ModulePanel) {
        self.panel = panel
    }

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        if !window.isVisible {
            position(window)
        }
        window.makeKeyAndOrderFront(nil)
        panel.didShow?()
    }

    func hide() {
        guard let window, window.isVisible else { return }
        window.orderOut(nil)
        panel.didHide?()
    }

    private func makeWindow() -> ModulePanelWindow {
        let window = ModulePanelWindow()
        // Borderless panels have no visible title; VoiceOver still names the window by it.
        window.title = panel.title
        window.onCancel = { [weak self] in self?.hide() }
        let hosting = NSHostingController(rootView: panel.makeContent())
        // The panel takes the size of its content.
        hosting.sizingOptions = [.preferredContentSize]
        window.contentViewController = hosting
        return window
    }

    /// Centered in the upper third of the screen with the pointer.
    private func position(_ window: NSWindow) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = window.frame.size
        let top = visible.maxY - (visible.height * 0.12).rounded()
        window.setFrameOrigin(NSPoint(x: (visible.midX - size.width / 2).rounded(), y: top - size.height))
    }
}

private final class ModulePanelWindow: NSPanel {
    var onCancel: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        collectionBehavior = FloatingPanelSpacePolicy.selectionPaletteCollectionBehavior
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }
}
