import SwiftUI

/// Pill-shaped overlay indicator that appears centered on the screen.
/// Supports top and bottom positioning.
struct OverlayIndicatorView: View {
    @ObservedObject private var viewModel = DictationViewModel.shared
    @ObservedObject private var recorder = AudioRecorderViewModel.shared
    @State private var textExpanded = false
    @State private var dotPulse = false

    private let contentPadding: CGFloat = 20
    private let sizing: IndicatorSizing = .overlay
    private var closedWidth: CGFloat { 280 }

    private var presentation: IndicatorPresentationData {
        IndicatorPresentationData.make(dictation: viewModel, recorder: recorder)
    }

    private var suppressStreamingText: Bool {
        !presentation.isRecorder && presentation.externalStreamingDisplayCount > 0
    }

    private var hasActionFeedback: Bool {
        presentation.state == .inserting && presentation.actionFeedbackMessage != nil
    }

    private var hasRecordingCancelWarning: Bool {
        presentation.state == .recording && presentation.recordingCancelWarningMessage != nil
    }

    private var showTranscriptPreview: Bool {
        viewModel.indicatorTranscriptPreviewEnabled && !suppressStreamingText
    }

    private var isExpanded: Bool {
        textExpanded || hasActionFeedback || hasRecordingCancelWarning
    }

    private var currentWidth: CGFloat {
        if hasRecordingCancelWarning { return max(closedWidth, 340) }
        if textExpanded { return max(closedWidth, 400) }
        if hasActionFeedback { return max(closedWidth, 340) }
        return closedWidth
    }

    private var isTop: Bool {
        viewModel.overlayPosition == .top
    }

    private var transcriptFontSize: CGFloat {
        viewModel.indicatorTranscriptPreviewFontSize(for: .overlay)
    }

    private var transcriptExpandedHeight: CGFloat {
        viewModel.indicatorTranscriptPreviewExpandedHeight(for: .overlay)
    }

    var body: some View {
        VStack(alignment: .center, spacing: 0) {
            if isTop {
                statusBar
                    .frame(height: 48)
                    .frame(maxWidth: .infinity)
                expandableContent
            } else {
                expandableContent
                statusBar
                    .frame(height: 48)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(width: currentWidth)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isTop ? .top : .bottom)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.3), value: textExpanded)
        .animation(.easeInOut(duration: 0.2), value: presentation.state)
        .animation(.easeOut(duration: 0.08), value: presentation.audioLevel)
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
                withAnimation(.easeInOut(duration: 0.3)) {
                    textExpanded = false
                }
            }
        }
        .onChange(of: viewModel.indicatorTranscriptPreviewEnabled) {
            if showTranscriptPreview, presentation.state == .recording, !presentation.partialText.isEmpty {
                withAnimation(.easeOut(duration: 0.25)) {
                    textExpanded = true
                }
            } else if !showTranscriptPreview {
                withAnimation(.easeInOut(duration: 0.3)) {
                    textExpanded = false
                }
            }
        }
        .animation(.easeInOut(duration: 1.0), value: dotPulse)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        if let warning = presentation.recordingCancelWarningMessage, presentation.state == .recording {
            return warning
        }

        if let feedback = presentation.actionFeedbackMessage, presentation.state == .inserting {
            return feedback
        }

        switch presentation.state {
        case .idle, .promptSelection, .promptProcessing:
            return String(localized: "Idle")
        case .recording:
            if !presentation.isRecordingInputReady {
                return String(localized: "Preparing microphone")
            }
            return String(localized: "Recording")
        case .processing:
            return String(localized: "Processing transcription")
        case .inserting:
            return String(localized: "Inserting text")
        case .error(let message):
            return String(localized: "Error - \(message)")
        }
    }

    // MARK: - Expandable content (text + action feedback)

    @ViewBuilder
    private var expandableContent: some View {
        if hasRecordingCancelWarning {
            IndicatorActionFeedback(
                message: presentation.recordingCancelWarningMessage ?? "",
                icon: "exclamationmark.triangle.fill",
                isError: false,
                iconColor: .yellow,
                contentPadding: contentPadding
            )
        } else if isTop {
            // Top position: text expands downward, action feedback below text
            if presentation.state == .recording, showTranscriptPreview {
                IndicatorExpandableText(
                    text: presentation.partialText,
                    fontSize: transcriptFontSize,
                    expandedHeight: transcriptExpandedHeight,
                    expanded: textExpanded,
                    contentPadding: contentPadding
                )
                .onChange(of: presentation.partialText) {
                    if showTranscriptPreview, !presentation.partialText.isEmpty, !textExpanded {
                        withAnimation(.easeOut(duration: 0.25)) {
                            textExpanded = true
                        }
                    }
                }
            }

            if hasActionFeedback {
                Divider().background(Color.white.opacity(0.1))
                IndicatorActionFeedback(
                    message: presentation.actionFeedbackMessage ?? "",
                    icon: presentation.actionFeedbackIcon,
                    isError: presentation.actionFeedbackIsError,
                    iconColor: nil,
                    contentPadding: contentPadding
                )
            }
        } else {
            // Bottom position: action feedback on top, text above status bar
            if hasActionFeedback {
                IndicatorActionFeedback(
                    message: presentation.actionFeedbackMessage ?? "",
                    icon: presentation.actionFeedbackIcon,
                    isError: presentation.actionFeedbackIsError,
                    iconColor: nil,
                    contentPadding: contentPadding
                )
                Divider().background(Color.white.opacity(0.1))
            }

            if presentation.state == .recording, showTranscriptPreview {
                IndicatorExpandableText(
                    text: presentation.partialText,
                    fontSize: transcriptFontSize,
                    expandedHeight: transcriptExpandedHeight,
                    expanded: textExpanded,
                    contentPadding: contentPadding
                )
                .onChange(of: presentation.partialText) {
                    if showTranscriptPreview, !presentation.partialText.isEmpty, !textExpanded {
                        withAnimation(.easeOut(duration: 0.25)) {
                            textExpanded = true
                        }
                    }
                }
            }
        }
    }

    // MARK: - Status bar

    @ViewBuilder
    private var statusBar: some View {
        HStack(spacing: 12) {
            IndicatorLeftStatus(
                presentation: presentation,
                sizing: sizing,
                dotPulse: dotPulse,
                hasActionFeedback: hasActionFeedback
            )

            if case .recording = presentation.state {
                IndicatorRecordingContent(
                    presentation: presentation,
                    content: viewModel.notchIndicatorLeftContent,
                    sizing: sizing,
                    dotPulse: dotPulse
                )
            }

            Spacer()

            if case .recording = presentation.state {
                IndicatorRecordingContent(
                    presentation: presentation,
                    content: viewModel.notchIndicatorRightContent,
                    sizing: sizing,
                    dotPulse: dotPulse
                )
            } else if case .processing = presentation.state {
                if let phase = presentation.processingPhase {
                    Text(phase)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                }
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white)
            }
        }
        .padding(.horizontal, 20)
    }
}
