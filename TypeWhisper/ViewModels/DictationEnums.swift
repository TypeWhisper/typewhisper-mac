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
    case none
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
