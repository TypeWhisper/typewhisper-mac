import AppKit
import CoreGraphics

enum FloatingPanelSpacePolicy {
    // Passive indicator panels should stay above the menu bar on normal spaces
    // without remaining at the shielding level used by system lock overlays.
    static let indicatorWindowLevel = NSWindow.Level.screenSaver

    private static let activeSpaceIndicatorCollectionBehavior: NSWindow.CollectionBehavior = [
        .moveToActiveSpace,
        .fullScreenAuxiliary,
        .stationary,
        .ignoresCycle
    ]

    private static let fixedDisplayIndicatorCollectionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces,
        .fullScreenAuxiliary,
        .stationary,
        .ignoresCycle
    ]

    static let selectionPaletteCollectionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces,
        .fullScreenAuxiliary
    ]

    static func indicatorCollectionBehavior(for displayMode: NotchIndicatorDisplay) -> NSWindow.CollectionBehavior {
        switch displayMode {
        case .activeScreen:
            activeSpaceIndicatorCollectionBehavior
        case .primaryScreen, .builtInScreen:
            fixedDisplayIndicatorCollectionBehavior
        }
    }

    @MainActor
    static func applyIndicatorPolicy(to panel: NSPanel, displayMode: NotchIndicatorDisplay) {
        panel.level = indicatorWindowLevel
        panel.collectionBehavior = indicatorCollectionBehavior(for: displayMode)
        // Best-effort: keep passive indicators visible locally while excluding the
        // window from capture APIs that honor AppKit sharing policy.
        panel.sharingType = .none
    }

    @MainActor
    static func orderIndicatorFront(_ panel: NSPanel, displayMode: NotchIndicatorDisplay) {
        applyIndicatorPolicy(to: panel, displayMode: displayMode)
        panel.orderFrontRegardless()
    }
}
