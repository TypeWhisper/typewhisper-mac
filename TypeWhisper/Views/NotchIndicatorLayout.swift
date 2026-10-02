import AppKit

enum IndicatorFeedbackPanelLayout {
    static let feedbackWidth: CGFloat = 340
    static let minimalFeedbackWidth: CGFloat = 360
    static let feedbackBodyHeight: CGFloat = 52
    static let minimalFeedbackProgressHorizontalInset: CGFloat = feedbackBodyHeight / 2
    static let overlayStatusHeight: CGFloat = 48
    static let screenEdgeInset: CGFloat = 20
    static let wideFeedbackWidth: CGFloat = 520
    static let feedbackLineCountBeforeWidening = 3
    static let feedbackMaximumLineCount = 10

    /// Size of the feedback surface for one message.
    struct FeedbackBody: Equatable {
        let width: CGFloat
        let height: CGFloat
        let lineLimit: Int
    }

    /// Short messages keep the fixed two-line body. Longer ones, such as a
    /// provider's error text, widen the surface first and then grow line by line
    /// up to `feedbackMaximumLineCount`.
    static func feedbackBody(
        for style: IndicatorStyle,
        message: String?,
        actionTitle: String? = nil,
        notchClosedWidth: CGFloat = 0
    ) -> FeedbackBody {
        let baseWidth: CGFloat
        switch style {
        case .notch:
            baseWidth = max(notchClosedWidth, feedbackWidth)
        case .overlay:
            baseWidth = feedbackWidth
        case .minimal:
            baseWidth = minimalFeedbackWidth
        }
        let compact = FeedbackBody(width: baseWidth, height: feedbackBodyHeight, lineLimit: 2)
        guard let message, !message.isEmpty else { return compact }

        let font = feedbackMessageFont(for: style)
        let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: font))
        func lineCount(surfaceWidth: CGFloat) -> Int {
            let textWidth = surfaceWidth - feedbackChromeWidth(for: style, actionTitle: actionTitle)
            let bounds = (message as NSString).boundingRect(
                with: CGSize(width: max(textWidth, 1), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font]
            )
            return max(1, Int(ceil(bounds.height / lineHeight)))
        }

        var width = baseWidth
        var lines = lineCount(surfaceWidth: width)
        guard lines > compact.lineLimit else { return compact }
        if lines > feedbackLineCountBeforeWidening, width < wideFeedbackWidth {
            width = wideFeedbackWidth
            lines = lineCount(surfaceWidth: width)
        }
        lines = min(max(lines, compact.lineLimit), feedbackMaximumLineCount)

        return FeedbackBody(
            width: width,
            height: feedbackSurfaceHeight(lineCount: lines, lineHeight: lineHeight),
            lineLimit: lines
        )
    }

    private static func feedbackSurfaceHeight(lineCount: Int, lineHeight: CGFloat) -> CGFloat {
        let chromeHeight = feedbackBodyHeight - 2 * lineHeight
        return max(feedbackBodyHeight, CGFloat(lineCount) * lineHeight + chromeHeight)
    }

    /// Constant size of the SwiftUI root inside an indicator panel. The overlay
    /// and minimal roots cover the passive panel and the largest feedback, so
    /// the panel frame can change without ever resizing the hosting view.
    static func hostingSize(for style: IndicatorStyle) -> CGSize {
        let passive = panelSize(for: style, isFeedbackInteractive: false)
        guard style != .notch else { return passive }

        let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: feedbackMessageFont(for: style)))
        let bodyHeight = feedbackSurfaceHeight(lineCount: feedbackMaximumLineCount, lineHeight: lineHeight)
        let feedbackHeight = style == .overlay ? overlayStatusHeight + bodyHeight : bodyHeight
        return CGSize(
            width: max(passive.width, wideFeedbackWidth),
            height: max(passive.height, feedbackHeight)
        )
    }

    private static func feedbackMessageFont(for style: IndicatorStyle) -> NSFont {
        .systemFont(ofSize: style == .minimal ? 12 : 13, weight: .medium)
    }

    /// Horizontal space the feedback row spends on everything but the message.
    private static func feedbackChromeWidth(for style: IndicatorStyle, actionTitle: String?) -> CGFloat {
        let padding: CGFloat
        let iconWidth: CGFloat
        let actionFontSize: CGFloat
        let actionSpacing: CGFloat
        switch style {
        case .notch:
            (padding, iconWidth, actionFontSize, actionSpacing) = (28, 20, 12, 24)
        case .overlay:
            (padding, iconWidth, actionFontSize, actionSpacing) = (20, 20, 12, 24)
        case .minimal:
            (padding, iconWidth, actionFontSize, actionSpacing) = (14, 18, 11, 8)
        }

        // Safety margin so SwiftUI never needs one more line than measured here.
        var chrome = padding * 2 + iconWidth + 8 + 6
        if let actionTitle, !actionTitle.isEmpty {
            let titleFont = NSFont.systemFont(ofSize: actionFontSize, weight: .semibold)
            let titleWidth = ceil((actionTitle as NSString).size(withAttributes: [.font: titleFont]).width)
            chrome += titleWidth + 16 + actionSpacing
        }
        return chrome
    }

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
        notchClosedHeight: CGFloat = NotchIndicatorLayout.notchedClosedHeight,
        feedbackMessage: String? = nil,
        feedbackActionTitle: String? = nil
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

        let body = feedbackBody(
            for: style,
            message: feedbackMessage,
            actionTitle: feedbackActionTitle,
            notchClosedWidth: notchClosedWidth
        )
        switch style {
        case .notch:
            return CGSize(width: body.width, height: notchClosedHeight + body.height)
        case .overlay:
            if countdownKind?.isStart == true {
                return CGSize(width: feedbackWidth, height: feedbackBodyHeight)
            }
            return CGSize(width: body.width, height: overlayStatusHeight + body.height)
        case .minimal:
            return CGSize(width: body.width, height: body.height)
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

/// Positions a fixed-size hosting view without involving SwiftUI in window sizing.
final class IndicatorHostingContainerView: NSView {
    enum VerticalAnchor {
        case top
        case bottom
    }

    private let hostingView: NSView

    /// Edge of the container the hosting view stays attached to.
    var verticalAnchor: VerticalAnchor {
        didSet {
            if verticalAnchor != oldValue {
                positionHostingView()
            }
        }
    }

    init(
        hostingView: NSView,
        size: NSSize,
        hostingSize: NSSize? = nil,
        verticalAnchor: VerticalAnchor = .top
    ) {
        self.hostingView = hostingView
        self.verticalAnchor = verticalAnchor
        super.init(frame: NSRect(origin: .zero, size: size))
        hostingView.frame = NSRect(origin: .zero, size: hostingSize ?? size)
        hostingView.autoresizingMask = []
        addSubview(hostingView)
        positionHostingView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        // Flexible margins do not reliably center an oversized subview when
        // both horizontal margins initially have zero width. Move only the
        // origin: resizing the hosting view reintroduces the layout feedback loop.
        positionHostingView()
    }

    private func positionHostingView() {
        let origin = NSPoint(
            x: bounds.midX - hostingView.frame.width / 2,
            y: verticalAnchor == .top ? bounds.maxY - hostingView.frame.height : bounds.minY
        )
        if hostingView.frame.origin != origin {
            hostingView.setFrameOrigin(origin)
        }
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
