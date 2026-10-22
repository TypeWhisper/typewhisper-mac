import AppKit
import SwiftUI

// MARK: - Theme

extension IndicatorTheme {
    /// Color scheme the indicator content renders in. Glass follows the system appearance.
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .classic:
            .dark
        case .light:
            .light
        case .glass:
            nil
        }
    }

    /// Appearance for the hosting panel so semantic colors resolve to match the surface.
    var panelAppearance: NSAppearance? {
        switch self {
        case .classic:
            NSAppearance(named: .darkAqua)
        case .light:
            NSAppearance(named: .aqua)
        case .glass:
            nil
        }
    }

    /// Hairline around the surface. Glass draws its own rim highlight.
    var strokeColor: Color? {
        switch self {
        case .classic:
            .white.opacity(0.15)
        case .light:
            .black.opacity(0.1)
        case .glass:
            nil
        }
    }

    /// Multiplier for the drop shadow the indicator views draw. Glass ships its
    /// own shadow, and a SwiftUI shadow would show through the translucent surface.
    var shadowOpacityScale: Double {
        switch self {
        case .classic:
            1
        case .light:
            0.5
        case .glass:
            0
        }
    }
}

/// Draws the themed background, clip and hairline stroke of a floating indicator.
struct IndicatorSurfaceModifier<S: Shape>: ViewModifier {
    let theme: IndicatorTheme
    let shape: S
    let strokeColor: Color?

    func body(content: Content) -> some View {
        themedBackground(content)
            // The hosting panel itself is rectangular. Clip all rendered content,
            // especially the feedback progress bar, to the visible surface.
            .clipShape(shape)
            .overlay {
                if let stroke = strokeColor ?? theme.strokeColor {
                    shape.stroke(stroke, lineWidth: 1)
                }
            }
    }

    @ViewBuilder
    private func themedBackground(_ content: Content) -> some View {
        switch theme {
        case .classic:
            content.background(.black.opacity(0.85), in: shape)
        case .light:
            content.background(.regularMaterial, in: shape)
        case .glass:
            if #available(macOS 26.0, *) {
                content.glassEffect(.clear, in: shape)
            } else {
                content.background(.regularMaterial, in: shape)
            }
        }
    }
}

extension View {
    func indicatorSurface<S: Shape>(
        theme: IndicatorTheme,
        shape: S,
        strokeColor: Color? = nil
    ) -> some View {
        modifier(IndicatorSurfaceModifier(theme: theme, shape: shape, strokeColor: strokeColor))
    }
}

// MARK: - Motion

enum IndicatorMotion {
    /// Spring used when an indicator grows, shrinks or pops in.
    static let expand = Animation.spring(response: 0.38, dampingFraction: 0.78)

    /// Scale an indicator starts from when a recording begins, so it visibly
    /// unfolds instead of switching content in place.
    static let revealScale: CGFloat = 0.92

    /// Reduce Motion turns off the decorative pop-in and the recording pulse.
    /// The indicator still changes its content for every state.
    @MainActor static var reducesMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Starts the slow pulse of the recording dot, unless Reduce Motion is on.
    @MainActor static func startRecordingPulse(_ pulse: Binding<Bool>) {
        guard !reducesMotion else {
            pulse.wrappedValue = false
            return
        }
        withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
            pulse.wrappedValue = true
        }
    }

    /// Runs the pop-in: snap to the reveal scale without animation, then spring to 1.
    @MainActor static func popIn(_ scale: Binding<CGFloat>) {
        guard !reducesMotion else {
            scale.wrappedValue = 1
            return
        }
        var snap = Transaction()
        snap.disablesAnimations = true
        withTransaction(snap) { scale.wrappedValue = revealScale }
        DispatchQueue.main.async {
            withAnimation(expand) { scale.wrappedValue = 1 }
        }
    }
}

// MARK: - Sizing

struct IndicatorSizing {
    let iconSize: CGFloat
    let iconCornerRadius: CGFloat
    let dotSize: CGFloat
    let symbolSize: CGFloat
    let timerFontSize: CGFloat
    let timerOpacity: Double
    let profileFontSize: CGFloat
    let profilePaddingH: CGFloat
    let profilePaddingV: CGFloat
    let textFontSize: CGFloat
    let textExpandedHeight: CGFloat

    static let notch = IndicatorSizing(
        iconSize: 14,
        iconCornerRadius: 3,
        dotSize: 6,
        symbolSize: 11,
        timerFontSize: 10,
        timerOpacity: 0.6,
        profileFontSize: 9,
        profilePaddingH: 5,
        profilePaddingV: 2,
        textFontSize: IndicatorStyle.notch.transcriptPreviewBaseFontSize,
        textExpandedHeight: IndicatorStyle.notch.transcriptPreviewBaseExpandedHeight
    )

    static let overlay = IndicatorSizing(
        iconSize: 18,
        iconCornerRadius: 4,
        dotSize: 8,
        symbolSize: 14,
        timerFontSize: 12,
        timerOpacity: 0.8,
        profileFontSize: 11,
        profilePaddingH: 6,
        profilePaddingV: 3,
        textFontSize: IndicatorStyle.overlay.transcriptPreviewBaseFontSize,
        textExpandedHeight: IndicatorStyle.overlay.transcriptPreviewBaseExpandedHeight
    )

    static let minimal = IndicatorSizing(
        iconSize: 14,
        iconCornerRadius: 3,
        dotSize: 6,
        symbolSize: 12,
        timerFontSize: 11,
        timerOpacity: 0.75,
        profileFontSize: 10,
        profilePaddingH: 5,
        profilePaddingV: 2,
        textFontSize: 12,
        textExpandedHeight: 0
    )
}

// MARK: - App Icon

struct IndicatorAppIconView: View {
    let icon: NSImage
    var borderColor: Color?
    let sizing: IndicatorSizing

    var body: some View {
        Image(nsImage: icon)
            .resizable()
            .frame(width: sizing.iconSize, height: sizing.iconSize)
            .clipShape(RoundedRectangle(cornerRadius: sizing.iconCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: sizing.iconCornerRadius)
                    .stroke(borderColor ?? .clear, lineWidth: 1.5)
            )
            .accessibilityHidden(true)
    }
}

// MARK: - Left Status Indicator

struct IndicatorLeftStatus: View {
    let presentation: IndicatorPresentationData
    let sizing: IndicatorSizing
    let dotPulse: Bool
    let hasActionFeedback: Bool
    @Environment(\.isPointerOverIndicator) private var isPointerOverIndicator

    var body: some View {
        // The Recorder has no other control on screen, so the recording dot
        // turns into Stop while the pointer rests on the indicator. The button
        // sits over the dot so the content next to it does not shift.
        let showsRecorderStop = isPointerOverIndicator
            && presentation.isRecorder
            && presentation.state == .recording
        statusContent
            .opacity(showsRecorderStop ? 0 : 1)
            .accessibilityHidden(true)
            .background {
                // VoiceOver opens the model menu here when no side shows the Model content.
                if presentation.offersModelMenu {
                    IndicatorModelMenuAnchor(role: .status)
                }
            }
            .overlay {
                if showsRecorderStop {
                    IndicatorRecorderStopButton(sizing: sizing)
                }
            }
    }

    @ViewBuilder
    private var statusContent: some View {
        switch presentation.state {
        case .idle, .promptSelection, .promptProcessing:
            Color.clear.frame(width: 0, height: 0)
        case .recording:
            if presentation.isPreparingMicrophone {
                IndicatorPreparingView(sizing: sizing)
            } else if let icon = presentation.activeAppIcon {
                IndicatorAppIconView(icon: icon, sizing: sizing)
            } else {
                IndicatorDot(audioLevel: presentation.audioLevel, dotPulse: dotPulse, sizing: sizing)
            }
        case .processing:
            if let icon = presentation.activeAppIcon {
                IndicatorAppIconView(icon: icon, sizing: sizing)
            } else {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.primary)
            }
        case .inserting:
            if hasActionFeedback {
                Color.clear.frame(width: 0, height: 0)
            } else if let icon = presentation.activeAppIcon {
                IndicatorAppIconView(icon: icon, sizing: sizing)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: sizing.symbolSize))
            }
        case .error:
            if let icon = presentation.activeAppIcon {
                IndicatorAppIconView(icon: icon, borderColor: .red, sizing: sizing)
            } else {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.system(size: sizing.symbolSize))
            }
        }
    }
}

// MARK: - Recorder Stop on Hover

struct IndicatorRecorderStopButton: View {
    let sizing: IndicatorSizing
    var action: () -> Void = { AudioRecorderViewModel.shared.stopRecording() }

    var body: some View {
        Button(action: action) {
            Image(systemName: "stop.circle.fill")
                .resizable()
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .red)
                .frame(width: sizing.iconSize, height: sizing.iconSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "Stop Recorder"))
        .accessibilityLabel(String(localized: "Stop Recorder"))
        .accessibilityIdentifier("indicator.recorder.stop")
    }
}

extension EnvironmentValues {
    /// True while the pointer is over the visible indicator surface.
    @Entry var isPointerOverIndicator = false
    /// Region the visible indicator surface reports its frame to.
    @Entry var indicatorPointerRegion: IndicatorPointerRegion?
}

/// The visible surface of a click-through indicator panel and whether the
/// pointer is over it. The panels are much larger than what they draw, so they
/// only accept the mouse while the pointer is on this surface and never block
/// clicks meant for the apps underneath.
@MainActor
final class IndicatorPointerRegion: ObservableObject {
    nonisolated static let coordinateSpaceName = "IndicatorPointerRegion"

    /// Surface frame in the root view's coordinate space (top-left origin).
    var surfaceFrame: CGRect = .zero
    @Published fileprivate(set) var isPointerInside = false
}

/// Root of an indicator panel: sets up the coordinate space the surface frame
/// is measured in and hands the hover state down to the content.
struct IndicatorPointerHost<Content: View>: View {
    @ObservedObject var region: IndicatorPointerRegion
    let content: Content

    var body: some View {
        content
            .environment(\.isPointerOverIndicator, region.isPointerInside)
            .environment(\.indicatorPointerRegion, region)
            .coordinateSpace(.named(IndicatorPointerRegion.coordinateSpaceName))
    }
}

private struct IndicatorPointerSurfaceModifier: ViewModifier {
    @Environment(\.indicatorPointerRegion) private var region

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { geometry in
            geometry.frame(in: .named(IndicatorPointerRegion.coordinateSpaceName))
        } action: { frame in
            region?.surfaceFrame = frame
        }
    }
}

extension View {
    /// Marks the view as the visible indicator surface that accepts the pointer.
    func indicatorPointerSurface() -> some View {
        modifier(IndicatorPointerSurfaceModifier())
    }
}

/// Follows the pointer while a Recorder indicator is up and tells the panel
/// when it enters or leaves the visible surface.
@MainActor
final class IndicatorPointerTracker {
    weak var hostingView: NSView?
    var onChange: () -> Void = {}

    private let region: IndicatorPointerRegion
    private let pointerLocationProvider: () -> NSPoint
    private var globalMonitor: Any?
    private var exitTimer: Timer?
    private(set) var isActive = false

    init(
        region: IndicatorPointerRegion,
        pointerLocationProvider: @escaping () -> NSPoint = { NSEvent.mouseLocation }
    ) {
        self.region = region
        self.pointerLocationProvider = pointerLocationProvider
    }

    func setActive(_ active: Bool) {
        guard isActive != active else {
            if active { update() }
            return
        }
        isActive = active
        if active {
            // Pointer moves over other apps, including over the transparent
            // part of this panel, arrive here; a global monitor needs no
            // Accessibility permission for mouse events.
            globalMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.mouseMoved, .leftMouseDragged]
            ) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.update()
                }
            }
        } else if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        update()
    }

    func update() {
        let isInside = isActive
            && hostingView?.window?.isVisible == true
            && surfaceScreenFrame().contains(pointerLocationProvider())
        guard isInside != region.isPointerInside else { return }
        region.isPointerInside = isInside
        // Once the panel takes the mouse, moves over it no longer reach the
        // global monitor, so a short timer notices when the pointer leaves.
        exitTimer?.invalidate()
        exitTimer = nil
        if isInside {
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.update()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            exitTimer = timer
        }
        onChange()
    }

    func surfaceScreenFrame() -> CGRect {
        guard let hostingView, let window = hostingView.window, !region.surfaceFrame.isEmpty else {
            return .null
        }
        var frame = region.surfaceFrame
        if !hostingView.isFlipped {
            frame.origin.y = hostingView.bounds.height - frame.maxY
        }
        return window.convertToScreen(hostingView.convert(frame, to: nil))
    }
}

// MARK: - Preparing Indicator

struct IndicatorPreparingView: View {
    let sizing: IndicatorSizing

    var body: some View {
        ProgressView()
            .controlSize(.mini)
            .tint(.primary)
            .frame(width: max(sizing.iconSize, sizing.dotSize), height: max(sizing.iconSize, sizing.dotSize))
            .accessibilityHidden(true)
    }
}

struct IndicatorPreparingLabel: View {
    let presentation: IndicatorPresentationData
    let sizing: IndicatorSizing

    var body: some View {
        Text(presentation.recordingStatusLabel)
            .font(.system(size: sizing.profileFontSize, weight: .medium))
            .foregroundStyle(Color.primary.opacity(sizing.timerOpacity))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel(presentation.recordingStatusLabel)
    }
}

// MARK: - Recording Dot

struct IndicatorDot: View {
    let audioLevel: Float
    let dotPulse: Bool
    let sizing: IndicatorSizing

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: sizing.dotSize, height: sizing.dotSize)
            .scaleEffect(1.0 + CGFloat(audioLevel) * 0.8)
            .shadow(color: .yellow.opacity(dotPulse ? 0.8 : 0.2), radius: dotPulse ? 6 : 2)
            .accessibilityHidden(true)
    }
}

// MARK: - Recording Content

struct IndicatorRecordingContent: View {
    let presentation: IndicatorPresentationData
    let content: NotchIndicatorContent
    let sizing: IndicatorSizing
    let dotPulse: Bool

    var body: some View {
        switch content {
        case .indicator:
            if presentation.isPreparingMicrophone {
                IndicatorPreparingView(sizing: sizing)
            } else {
                IndicatorDot(audioLevel: presentation.audioLevel, dotPulse: dotPulse, sizing: sizing)
            }
        case .timer:
            if presentation.isPreparingMicrophone {
                IndicatorPreparingLabel(presentation: presentation, sizing: sizing)
            } else {
                Text(formatDuration(presentation.recordingDuration))
                    .font(.system(size: sizing.timerFontSize, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.primary.opacity(sizing.timerOpacity))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel(String(localized: "Recording timer"))
                    .accessibilityValue(formatDuration(presentation.recordingDuration))
            }
        case .waveform:
            AudioWaveformView(
                audioLevel: presentation.audioLevel,
                isSetup: presentation.isPreparingMicrophone || (presentation.recordingDuration < 0.5 && presentation.audioLevel < 0.05),
                compact: true
            )
        case .profile:
            if let name = presentation.activeRuleName {
                Text(name)
                    .font(.system(size: sizing.profileFontSize, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, sizing.profilePaddingH)
                    .padding(.vertical, sizing.profilePaddingV)
                    .frame(maxWidth: NotchIndicatorLayout.profileChipMaxWidth, alignment: .leading)
                    .accessibilityLabel(localizedAppText("Active workflow", de: "Aktiver Workflow"))
                    .accessibilityValue(name)
            } else {
                Color.clear.frame(width: 0, height: 0)
            }
        case .model:
            // The Recorder picks its engine on its own page, so it shows no dictation model.
            if presentation.isRecorder {
                Color.clear.frame(width: 0, height: 0)
            } else {
                IndicatorModelContent(offersMenu: presentation.offersModelMenu, sizing: sizing)
            }
        case .none:
            Color.clear.frame(width: 0, height: 0)
        }
    }
}

// MARK: - Expandable Text

struct IndicatorExpandableText: View {
    let text: String
    let fontSize: CGFloat
    /// Upper bound; the area only grows this tall once the text needs it.
    let expandedHeight: CGFloat
    let expanded: Bool
    let contentPadding: CGFloat
    /// Lets a container that draws its own body (the notch) follow the text height.
    var onContentHeightChange: ((CGFloat) -> Void)? = nil

    @State private var contentHeight: CGFloat = 0

    nonisolated static let verticalPadding: CGFloat = 14

    /// Height for the transcript area: at least one line, at most `maximum`, otherwise
    /// what the text needs. A fixed maximum left a single sentence in a mostly empty box.
    nonisolated static func visibleHeight(
        contentHeight: CGFloat,
        expanded: Bool,
        maximum: CGFloat,
        fontSize: CGFloat
    ) -> CGFloat {
        guard expanded, maximum > 0 else { return 0 }
        let singleLine = (fontSize * 1.25).rounded(.up) + 2 * verticalPadding
        return min(max(contentHeight, singleLine), maximum)
    }

    private var visibleHeight: CGFloat {
        Self.visibleHeight(
            contentHeight: contentHeight,
            expanded: expanded,
            maximum: expandedHeight,
            fontSize: fontSize
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                Text(text)
                    .font(.system(size: fontSize))
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, contentPadding)
                    .padding(.vertical, Self.verticalPadding)
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        geometry.size.height
                    } action: { height in
                        contentHeight = height
                        onContentHeightChange?(height)
                    }
                    .id("bottom")
            }
            .frame(height: visibleHeight)
            .clipped()
            .onChange(of: text) {
                withAnimation(nil) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
        .accessibilityLabel(String(localized: "Streaming text"))
        .accessibilityValue(text)
    }
}

// MARK: - Action Feedback Banner

struct IndicatorFeedbackProgressBar: View {
    let remainingFraction: Double

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.65))
            .frame(maxWidth: .infinity)
            .frame(height: 2)
            .scaleEffect(
                x: CGFloat(min(max(remainingFraction, 0), 1)),
                y: 1,
                anchor: .leading
            )
            .transaction { transaction in
                transaction.animation = nil
            }
            .accessibilityHidden(true)
    }
}

struct IndicatorActionFeedback: View {
    let message: String
    let icon: String?
    let isError: Bool
    let iconColor: Color?
    let contentPadding: CGFloat
    var actionTitle: String? = nil
    var onAction: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil
    var remainingFraction: Double? = nil
    var bodyHeight: CGFloat = IndicatorFeedbackPanelLayout.feedbackBodyHeight
    var lineLimit = 2

    var body: some View {
        VStack(spacing: 0) {
            if let remainingFraction {
                IndicatorFeedbackProgressBar(remainingFraction: remainingFraction)
            } else {
                Color.clear
                    .frame(height: 2)
                    .accessibilityHidden(true)
            }

            HStack(spacing: 8) {
                Image(systemName: icon ?? (isError ? "xmark.circle.fill" : "checkmark.circle.fill"))
                    .foregroundStyle(iconColor ?? (isError ? .red : .green))
                    .font(.system(size: 16))
                    .accessibilityHidden(true)
                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.9))
                    .lineLimit(lineLimit)

                if let actionTitle, let onAction {
                    Spacer(minLength: 8)
                    Button(actionTitle, action: onAction)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.12), in: Capsule())
                }
                if let onDismiss {
                    IndicatorFeedbackDismissButton(action: onDismiss)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, contentPadding)
        }
        .frame(maxWidth: .infinity)
        .frame(height: bodyHeight)
        .accessibilityElement(children: actionTitle == nil && onDismiss == nil ? .combine : .contain)
        .accessibilityLabel(message)
    }
}

struct IndicatorFeedbackDismissButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(String(localized: "Dismiss notification"))
        .accessibilityLabel(String(localized: "Dismiss notification"))
        .accessibilityIdentifier("indicator.feedback.dismiss")
    }
}

// MARK: - Helpers

func formatDuration(_ seconds: TimeInterval) -> String {
    let totalSeconds = Int(seconds)
    let minutes = totalSeconds / 60
    let secs = totalSeconds % 60
    return String(format: "%d:%02d", minutes, secs)
}
