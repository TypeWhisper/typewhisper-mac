import AppKit

enum NotchExpansionMode {
    case closed
    case transcript
    case feedback
    case processing
}

enum NotchIndicatorLayout {
    static let extensionWidth: CGFloat = 60
    static let leadingInset: CGFloat = 20
    static let trailingInset: CGFloat = 34
    static let leftContentSpacing: CGFloat = 6
    static let widthSafetyBuffer: CGFloat = 8
    static let profileChipMaxWidth: CGFloat = 150
    static let notchedClosedHeight: CGFloat = 34
    static let fallbackClosedHeight: CGFloat = 32
    static let fallbackClosedWidth: CGFloat = 200
    static let compactWaveformWidth: CGFloat = 23

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

    static func recordingClosedWidth(
        hasNotch: Bool,
        notchWidth: CGFloat,
        leftContent: NotchIndicatorContent,
        rightContent: NotchIndicatorContent,
        recordingDuration: TimeInterval,
        activeRuleName: String?
    ) -> CGFloat {
        let baseWidth = closedWidth(hasNotch: hasNotch, notchWidth: notchWidth)
        let leftContentWidth = recordingContentWidth(
            leftContent,
            recordingDuration: recordingDuration,
            activeRuleName: activeRuleName
        )
        let rightContentWidth = recordingContentWidth(
            rightContent,
            recordingDuration: recordingDuration,
            activeRuleName: activeRuleName
        )
        let leftRequiredWidth = leadingInset + IndicatorSizing.notch.iconSize
            + (leftContentWidth > 0 ? leftContentSpacing + leftContentWidth : 0)
        let rightRequiredWidth = trailingInset + rightContentWidth
        let candidateWidth = hasNotch
            ? notchWidth + leftRequiredWidth + rightRequiredWidth + widthSafetyBuffer
            : leftRequiredWidth + rightRequiredWidth + widthSafetyBuffer

        return max(baseWidth, candidateWidth)
    }

    static func reservedTimerText(for seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds))
        let minuteDigits = max(2, String(totalSeconds / 60).count)
        return String(repeating: "0", count: minuteDigits) + ":00"
    }

    static func recordingContentWidth(
        _ content: NotchIndicatorContent,
        recordingDuration: TimeInterval,
        activeRuleName: String?
    ) -> CGFloat {
        switch content {
        case .indicator:
            return IndicatorSizing.notch.dotSize
        case .timer:
            return timerWidth(for: recordingDuration)
        case .waveform:
            return compactWaveformWidth
        case .profile:
            return profileChipWidth(for: activeRuleName)
        case .none:
            return 0
        }
    }

    static func timerWidth(for recordingDuration: TimeInterval) -> CGFloat {
        measureTextWidth(
            reservedTimerText(for: recordingDuration),
            font: NSFont.monospacedDigitSystemFont(
                ofSize: IndicatorSizing.notch.timerFontSize,
                weight: .medium
            )
        )
    }

    static func profileChipWidth(for activeRuleName: String?) -> CGFloat {
        guard let activeRuleName, !activeRuleName.isEmpty else {
            return 0
        }

        let textWidth = measureTextWidth(
            activeRuleName,
            font: NSFont.systemFont(
                ofSize: IndicatorSizing.notch.profileFontSize,
                weight: .medium
            )
        )
        let paddedWidth = textWidth + (2 * IndicatorSizing.notch.profilePaddingH)
        return min(profileChipMaxWidth, paddedWidth)
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

    private static func measureTextWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}
