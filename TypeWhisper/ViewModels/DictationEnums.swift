import CoreGraphics
import Foundation

enum IndicatorStyle: String, CaseIterable {
    case notch
    case overlay
    case minimal
}

enum NotchIndicatorVisibility: String, CaseIterable {
    case always
    case duringActivity
    case never
}

enum NotchIndicatorContent: String, CaseIterable {
    case indicator
    case timer
    case waveform
    case profile
    /// The transcription model; during a dictation it opens the model menu (#1351).
    case model
    case none
}

extension NotchIndicatorContent {
    /// Whether an indicator style shows the model content on one of its sides. The
    /// Minimal style only has the right side.
    static func showsModel(style: IndicatorStyle, left: NotchIndicatorContent, right: NotchIndicatorContent) -> Bool {
        right == .model || (style != .minimal && left == .model)
    }

    /// The content a side actually shows. The Recorder has no model menu, so Model shows nothing there.
    func shown(isRecorder: Bool) -> NotchIndicatorContent {
        isRecorder && self == .model ? .none : self
    }
}

enum NotchIndicatorDisplay: String, CaseIterable {
    case activeScreen
    case primaryScreen
    case builtInScreen
}

enum OverlayPosition: String, CaseIterable {
    case top
    case bottom
}

/// Visual treatment of the floating indicator surfaces.
enum IndicatorTheme: String, CaseIterable {
    case classic
    case glass
    case light
}

extension IndicatorTheme {
    var title: String {
        switch self {
        case .classic: String(localized: "indicatorTheme.classic", defaultValue: "Classic")
        case .glass: String(localized: "indicatorTheme.glass", defaultValue: "Glass")
        case .light: String(localized: "indicatorTheme.light", defaultValue: "Light")
        }
    }
}

extension IndicatorStyle {
    var supportsTranscriptPreview: Bool {
        self != .minimal
    }

    var transcriptPreviewBaseFontSize: CGFloat {
        switch self {
        case .notch:
            12
        case .overlay:
            13
        case .minimal:
            12
        }
    }

    var transcriptPreviewBaseExpandedHeight: CGFloat {
        switch self {
        case .notch:
            80
        case .overlay:
            100
        case .minimal:
            0
        }
    }

    func scaledTranscriptPreviewMetric(_ baseMetric: CGFloat, fontSize: CGFloat) -> CGFloat {
        guard supportsTranscriptPreview, transcriptPreviewBaseFontSize > 0 else {
            return 0
        }

        return (baseMetric * fontSize / transcriptPreviewBaseFontSize).rounded(.up)
    }
}

/// Escape confirmation and post-cancellation feedback for dictation.
enum CancellationBehavior: String, CaseIterable, Sendable {
    case doubleEscape
    case singleEscape
    case instant
    case disabled

    var title: String {
        switch self {
        case .doubleEscape: String(localized: "cancellationBehavior.double", defaultValue: "Double")
        case .singleEscape: String(localized: "cancellationBehavior.single", defaultValue: "Single")
        case .instant: String(localized: "cancellationBehavior.instant", defaultValue: "Instant")
        case .disabled: String(localized: "cancellationBehavior.disabled", defaultValue: "Disabled")
        }
    }
}
