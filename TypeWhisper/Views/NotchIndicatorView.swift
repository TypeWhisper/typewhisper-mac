import SwiftUI

/// Notch-extending indicator that visually expands the MacBook notch area.
/// Three-zone layout: left ear | center (notch spacer) | right ear.
/// Both sides are configurable (indicator, timer, waveform, clock, battery).
/// Expands wider and downward to show streaming partial text.
/// Blue glow emanates from the notch shape, reacting to audio level.
struct NotchIndicatorView: View {
    @ObservedObject private var viewModel = DictationViewModel.shared
    @ObservedObject private var recorder = AudioRecorderViewModel.shared
    @ObservedObject var geometry: NotchGeometry
    @State private var textExpanded = false
    @State private var dotPulse = false

    private let contentPadding: CGFloat = 28
    private let sizing: IndicatorSizing = .notch
    private let processingBodyHeight: CGFloat = 28
    private let feedbackBodyHeight: CGFloat = 52

    private var presentation: IndicatorPresentationData {
        IndicatorPresentationData.make(dictation: viewModel, recorder: recorder)
    }

    private var closedWidth: CGFloat {
        if case .recording = presentation.state {
            return NotchIndicatorLayout.recordingClosedWidth(
                hasNotch: geometry.hasNotch,
                notchWidth: geometry.notchWidth,
                leftContent: viewModel.notchIndicatorLeftContent,
                rightContent: viewModel.notchIndicatorRightContent,
                recordingDuration: presentation.recordingDuration,
                activeRuleName: presentation.activeRuleName
            )
        }

        return NotchIndicatorLayout.closedWidth(hasNotch: geometry.hasNotch, notchWidth: geometry.notchWidth)
    }

    private var leftStatusSpacing: CGFloat {
        guard case .recording = presentation.state else {
            return 0
        }

        let leftContentWidth = NotchIndicatorLayout.recordingContentWidth(
            viewModel.notchIndicatorLeftContent,
            recordingDuration: presentation.recordingDuration,
            activeRuleName: presentation.activeRuleName
        )
        return leftContentWidth > 0 ? NotchIndicatorLayout.leftContentSpacing : 0
    }

    private var suppressStreamingText: Bool {
        !presentation.isRecorder && presentation.externalStreamingDisplayCount > 0
    }

    private var hasActionFeedback: Bool {
        presentation.state == .inserting && presentation.actionFeedbackMessage != nil
    }

    private var hasCancelWarning: Bool {
        presentation.cancelWarningMessage != nil
    }

    private var hasProcessingPhase: Bool {
        presentation.state == .processing && presentation.processingPhase != nil
    }

    private var showTranscriptPreview: Bool {
        viewModel.indicatorTranscriptPreviewEnabled && !suppressStreamingText
    }

    private var hasTranscriptSection: Bool {
        presentation.state == .recording && showTranscriptPreview
    }

    private var transcriptBodyVisible: Bool {
        presentation.state == .recording && showTranscriptPreview && textExpanded
    }

    private var expansionMode: NotchExpansionMode {
        if hasCancelWarning { return .feedback }
        if transcriptBodyVisible { return .transcript }
        if hasActionFeedback { return .feedback }
        if hasProcessingPhase { return .processing }
        return .closed
    }

    private var currentWidth: CGFloat {
        NotchIndicatorLayout.containerWidth(closedWidth: closedWidth, mode: expansionMode)
    }

    private var bottomCornerRadius: CGFloat {
        switch expansionMode {
        case .closed:
            return 14
        case .processing:
            return 18
        case .transcript, .feedback:
            return 24
        }
    }

    private var transcriptBodyHeight: CGFloat {
        hasTranscriptSection && textExpanded ? viewModel.indicatorTranscriptPreviewExpandedHeight(for: .notch) : 0
    }

    private var transcriptFontSize: CGFloat {
        viewModel.indicatorTranscriptPreviewFontSize(for: .notch)
    }

    private var expandedBodyHeight: CGFloat {
        if hasCancelWarning {
            return feedbackBodyHeight
        }
        if hasTranscriptSection {
            return transcriptBodyHeight
        }
        if hasProcessingPhase {
            return processingBodyHeight
        }
        if hasActionFeedback {
            return feedbackBodyHeight
        }
        return 0
    }

    private var presentationRevealScale: CGFloat {
        geometry.isPresented ? 1 : 0.001
    }

    private var presentationOpacity: Double {
        geometry.isPresented ? 1 : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            notchCap
            expandedBody
        }
        .frame(width: currentWidth)
        .background(.black)
        .clipShape(NotchShape(bottomCornerRadius: bottomCornerRadius))
        .mask(alignment: .top) {
            Rectangle()
                .scaleEffect(x: 1, y: presentationRevealScale, anchor: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(presentationOpacity)
        .preferredColorScheme(.dark)
        .animation(.easeOut(duration: 0.22), value: geometry.isPresented)
        .animation(.easeOut(duration: 0.24), value: currentWidth)
        .animation(.easeOut(duration: 0.24), value: expandedBodyHeight)
        .animation(.easeInOut(duration: 0.18), value: presentation.state)
        .animation(.easeOut(duration: 0.08), value: presentation.audioLevel)
        .onChange(of: presentation.partialText) {
            if showTranscriptPreview, !presentation.partialText.isEmpty, !textExpanded {
                withAnimation(.easeOut(duration: 0.24)) {
                    textExpanded = true
                }
            }
        }
        .onChange(of: presentation.state) {
            if presentation.state == .recording {
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    dotPulse = true
                }
            } else {
                dotPulse = false
                textExpanded = false
            }
        }
        .onChange(of: suppressStreamingText) {
            if !showTranscriptPreview {
                withAnimation(.easeOut(duration: 0.24)) {
                    textExpanded = false
                }
            }
        }
        .onChange(of: viewModel.indicatorTranscriptPreviewEnabled) {
            if showTranscriptPreview, presentation.state == .recording, !presentation.partialText.isEmpty {
                withAnimation(.easeOut(duration: 0.24)) {
                    textExpanded = true
                }
            } else if !showTranscriptPreview {
                withAnimation(.easeOut(duration: 0.24)) {
                    textExpanded = false
                }
            }
        }
        .animation(.easeInOut(duration: 1.0), value: dotPulse)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(notchAccessibilityLabel)
    }

    private var notchAccessibilityLabel: String {
        switch presentation.state {
        case .idle, .promptSelection, .promptProcessing:
            return String(localized: "Idle")
        case .recording:
            if let warning = presentation.cancelWarningMessage {
                return warning
            }
            if !presentation.isRecordingInputReady {
                return String(localized: "Preparing microphone")
            }
            return String(localized: "Recording")
        case .processing:
            if let warning = presentation.cancelWarningMessage {
                return warning
            }
            return String(localized: "Processing transcription")
        case .inserting:
            if let feedback = presentation.actionFeedbackMessage {
                return feedback
            }
            return String(localized: "Inserting text")
        case .error(let message):
            return String(localized: "Error - \(message)")
        }
    }

    // MARK: - Status bar (three-zone layout)

    private var notchCap: some View {
        statusBar
            .frame(width: currentWidth, height: geometry.notchHeight)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var expandedBody: some View {
        expandedBodyContent
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: expandedBodyHeight, alignment: .top)
            .clipped()
            .opacity(expandedBodyHeight > 0 ? 1 : 0)
    }

    @ViewBuilder
    private var expandedBodyContent: some View {
        if hasCancelWarning {
            IndicatorActionFeedback(
                message: presentation.cancelWarningMessage ?? "",
                icon: "exclamationmark.triangle.fill",
                isError: false,
                iconColor: .yellow,
                contentPadding: contentPadding
            )
        } else if hasTranscriptSection {
            IndicatorExpandableText(
                text: presentation.partialText,
                fontSize: transcriptFontSize,
                expandedHeight: viewModel.indicatorTranscriptPreviewExpandedHeight(for: .notch),
                expanded: true,
                contentPadding: 34
            )
            .opacity(textExpanded ? 1 : 0.72)
        } else if hasProcessingPhase {
            Text(presentation.processingPhase ?? "")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        } else if hasActionFeedback {
            IndicatorActionFeedback(
                message: presentation.actionFeedbackMessage ?? "",
                icon: presentation.actionFeedbackIcon,
                isError: presentation.actionFeedbackIsError,
                iconColor: nil,
                contentPadding: contentPadding
            )
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private var statusBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: leftStatusSpacing) {
                IndicatorLeftStatus(
                    presentation: presentation,
                    sizing: sizing,
                    dotPulse: dotPulse,
                    hasActionFeedback: hasActionFeedback
                )
                leftContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.leading, NotchIndicatorLayout.leadingInset)

            if geometry.hasNotch {
                Color.clear
                    .frame(width: geometry.notchWidth)
            }

            rightContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, NotchIndicatorLayout.trailingInset)
        }
    }

    // MARK: - Configurable content

    @ViewBuilder
    private var leftContent: some View {
        if case .recording = presentation.state {
            IndicatorRecordingContent(
                presentation: presentation,
                content: viewModel.notchIndicatorLeftContent,
                sizing: sizing,
                dotPulse: dotPulse
            )
        }
    }

    @ViewBuilder
    private var rightContent: some View {
        if case .recording = presentation.state {
            IndicatorRecordingContent(
                presentation: presentation,
                content: viewModel.notchIndicatorRightContent,
                sizing: sizing,
                dotPulse: dotPulse
            )
        } else if case .processing = presentation.state {
            ProgressView()
                .controlSize(.mini)
                .tint(.white)
        }
    }
}
