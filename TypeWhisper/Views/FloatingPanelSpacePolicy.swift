import AppKit
import CoreGraphics

enum FloatingPanelSpacePolicy {
    // Passive indicator panels should stay above normal desktop spaces,
    // but they must not bleed into another app's fullscreen space.
    static let indicatorWindowLevel = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))

    static let indicatorCollectionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces,
        .stationary,
        .ignoresCycle
    ]

    static let selectionPaletteCollectionBehavior: NSWindow.CollectionBehavior = [
        .canJoinAllSpaces,
        .fullScreenAuxiliary
    ]
}
