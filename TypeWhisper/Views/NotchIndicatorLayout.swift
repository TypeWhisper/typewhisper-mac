import CoreGraphics

enum NotchExpansionMode {
    case closed
    case transcript
    case feedback
    case processing
}

enum NotchIndicatorLayout {
    static let extensionWidth: CGFloat = 60
    static let notchedClosedHeight: CGFloat = 34
    static let fallbackClosedHeight: CGFloat = 32
    static let fallbackClosedWidth: CGFloat = 200

    /// Uses the real screen safe-area inset when available so the closed cap matches
    /// the physical notch across different MacBook models and display scaling modes.
    static func closedHeight(hasNotch: Bool, safeAreaTopInset: CGFloat? = nil) -> CGFloat {
        guard hasNotch else {
            return fallbackClosedHeight
        }

        if let safeAreaTopInset, safeAreaTopInset > 0 {
            return safeAreaTopInset
        }

        return notchedClosedHeight
    }

    static func closedWidth(hasNotch: Bool, notchWidth: CGFloat) -> CGFloat {
        hasNotch ? notchWidth + (2 * extensionWidth) : fallbackClosedWidth
    }

    static func containerWidth(closedWidth: CGFloat, mode: NotchExpansionMode) -> CGFloat {
        switch mode {
        case .closed:
            return closedWidth
        case .transcript:
            return max(closedWidth, 400)
        case .feedback:
            return max(closedWidth, 340)
        case .processing:
            return closedWidth + 80
        }
    }
}
