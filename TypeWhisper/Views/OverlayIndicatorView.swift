import SwiftUI

struct OverlayTranscriptPreviewState: Equatable {
    let isRecording: Bool
    let previewEnabled: Bool
    let isRecorder: Bool
    let externalStreamingDisplayCount: Int
    let partialText: String
    let textExpanded: Bool

    var suppressStreamingText: Bool {
        !isRecorder && externalStreamingDisplayCount > 0
    }

    var showTranscriptPreview: Bool {
        previewEnabled && !suppressStreamingText
    }

    var hasTranscriptSection: Bool {
        isRecording && showTranscriptPreview
    }

    var transcriptBodyVisible: Bool {
        hasTranscriptSection && textExpanded
    }

    var shouldExpandForCurrentText: Bool {
        hasTranscriptSection && !partialText.isEmpty && !textExpanded
    }
}

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

    private var hasActionFeedback: Bool {
        presentation.state == .inserting && presentation.actionFeedbackMessage != nil
    }

    private var hasCancelWarning: Bool {
        presentation.cancelWarningMessage != nil
    }

    private var transcriptPreviewState: OverlayTranscriptPreviewState {
        OverlayTranscriptPreviewState(
            isRecording: presentation.state == .recording,
            previewEnabled: viewModel.indicatorTranscriptPreviewEnabled,
            isRecorder: presentation.isRecorder,
            externalStreamingDisplayCount: presentation.externalStreamingDisplayCount,
            partialText: presentation.partialText,
            textExpanded: textExpanded
        )
    }

    private var showTranscriptPreview: Bool {
        transcriptPreviewState.showTranscriptPreview
    }

    private var hasTranscriptSection: Bool {
        transcriptPreviewState.hasTranscriptSection
    }

    private var transcriptBodyVisible: Bool {
        transcriptPreviewState.transcriptBodyVisible
    }

    private var currentWidth: CGFloat {
        if hasCancelWarning { return max(closedWidth, 340) }
        if transcriptBodyVisible { return max(closedWidth, 400) }
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
        .onChange(of: presentation.partialText) {
            expandTranscriptPreviewIfNeeded()
        }
        .onChange(of: presentation.state) {
            if presentation.state == .recording {
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    dotPulse = true
                }
                expandTranscriptPreviewIfNeeded()
            } else {
                dotPulse = false
                textExpanded = false
            }
        }
        .onChange(of: transcriptPreviewState.suppressStreamingText) {
            if !showTranscriptPreview {
                withAnimation(.easeInOut(duration: 0.3)) {
                    textExpanded = false
                }
            } else {
                expandTranscriptPreviewIfNeeded()
            }
        }
        .onChange(of: viewModel.indicatorTranscriptPreviewEnabled) {
            if showTranscriptPreview {
                expandTranscriptPreviewIfNeeded()
            } else {
                withAnimation(.easeInOut(duration: 0.3)) {
                    textExpanded = false
                }
            }
        }
        .animation(.easeInOut(duration: 1.0), value: dotPulse)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private func expandTranscriptPreviewIfNeeded() {
        guard transcriptPreviewState.shouldExpandForCurrentText else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            textExpanded = true
        }
    }

    private var accessibilityLabel: String {
        if let warning = presentation.cancelWarningMessage {
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
        if hasCancelWarning {
            IndicatorActionFeedback(
                message: presentation.cancelWarningMessage ?? "",
                icon: "exclamationmark.triangle.fill",
                isError: false,
                iconColor: .yellow,
                contentPadding: contentPadding
            )
        } else if isTop {
            // Top position: text expands downward, action feedback below text
            if hasTranscriptSection {
                IndicatorExpandableText(
                    text: presentation.partialText,
                    fontSize: transcriptFontSize,
                    expandedHeight: transcriptExpandedHeight,
                    expanded: textExpanded,
                    contentPadding: contentPadding
                )
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

            if hasTranscriptSection {
                IndicatorExpandableText(
                    text: presentation.partialText,
                    fontSize: transcriptFontSize,
                    expandedHeight: transcriptExpandedHeight,
                    expanded: textExpanded,
                    contentPadding: contentPadding
                )
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
