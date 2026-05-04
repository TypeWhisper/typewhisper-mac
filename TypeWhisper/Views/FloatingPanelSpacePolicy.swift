import AppKit
import CoreGraphics

enum FloatingPanelSpacePolicy {
    // Passive indicator panels should stay above the menu bar on normal spaces
    // without remaining at the shielding level used by system lock overlays.
    static let indicatorWindowLevel = NSWindow.Level.screenSaver

    static let indicatorCollectionBehavior: NSWindow.CollectionBehavior = [
        .moveToActiveSpace,
        .fullScreenNone,
        .stationary,
        .ignoresCycle
    ]

    static let selectionPaletteCollectionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces,
        .fullScreenAuxiliary
    ]

    @MainActor
    static func applyIndicatorPolicy(to panel: NSPanel) {
        panel.level = indicatorWindowLevel
        panel.collectionBehavior = indicatorCollectionBehavior
    }

    @MainActor
    static func orderIndicatorFront(_ panel: NSPanel) {
        applyIndicatorPolicy(to: panel)
        panel.orderFrontRegardless()
    }
}
