import AppKit

enum IndicatorFeedbackPanelLayout {
    static let feedbackWidth: CGFloat = 340
    static let minimalFeedbackWidth: CGFloat = 360
    static let feedbackBodyHeight: CGFloat = 52
    static let minimalFeedbackProgressHorizontalInset: CGFloat = feedbackBodyHeight / 2
    static let overlayStatusHeight: CGFloat = 48
    static let screenEdgeInset: CGFloat = 20

    static func isInteractive(
        state: DictationViewModel.State,
        message: String?
    ) -> Bool {
        state == .inserting && message != nil
    }

    static func panelSize(
        for style: IndicatorStyle,
        isFeedbackInteractive: Bool,
        countdownKind: CalendarMeetingCountdownKind? = nil,
        notchClosedWidth: CGFloat = 0,
        notchClosedHeight: CGFloat = NotchIndicatorLayout.notchedClosedHeight
    ) -> CGSize {
        guard isFeedbackInteractive else {
            switch style {
            case .notch:
                return CGSize(width: 500, height: 500)
            case .overlay:
                return CGSize(width: 500, height: 300)
            case .minimal:
                return CGSize(width: 420, height: 160)
            }
        }

        switch style {
        case .notch:
            return CGSize(
                width: max(notchClosedWidth, feedbackWidth),
                height: notchClosedHeight + feedbackBodyHeight
            )
        case .overlay:
            if countdownKind?.isStart == true {
                return CGSize(width: feedbackWidth, height: feedbackBodyHeight)
            }
            return CGSize(
                width: feedbackWidth,
                height: overlayStatusHeight + feedbackBodyHeight
            )
        case .minimal:
            return CGSize(width: minimalFeedbackWidth, height: feedbackBodyHeight)
        }
    }

    static func panelFrame(
        for style: IndicatorStyle,
        size: CGSize,
        in screenFrame: CGRect,
        overlayPosition: OverlayPosition = .top
    ) -> CGRect {
        let x = screenFrame.midX - (size.width / 2)
        let y: CGFloat

        switch style {
        case .notch:
            y = screenFrame.maxY - size.height
        case .overlay, .minimal:
            switch overlayPosition {
            case .bottom:
                y = screenFrame.minY + screenEdgeInset
            case .top:
                y = screenFrame.maxY - size.height - screenEdgeInset
            }
        }

        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}

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

    static func preparingClosedWidth(
        hasNotch: Bool,
        notchWidth: CGFloat,
        label: String
    ) -> CGFloat {
        let baseWidth = closedWidth(hasNotch: hasNotch, notchWidth: notchWidth)
        let labelWidth = measureTextWidth(
            label,
            font: NSFont.systemFont(
                ofSize: IndicatorSizing.notch.profileFontSize,
                weight: .medium
            )
        )
        let requiredContentWidth = leadingInset
            + IndicatorSizing.notch.iconSize
            + leftContentSpacing
            + labelWidth
            + trailingInset
            + widthSafetyBuffer
        let candidateWidth = hasNotch
            ? notchWidth + requiredContentWidth
            : requiredContentWidth
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
            return max(closedWidth, IndicatorFeedbackPanelLayout.feedbackWidth)
        case .processing:
            return closedWidth + 80
        }
    }

    private static func measureTextWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}
