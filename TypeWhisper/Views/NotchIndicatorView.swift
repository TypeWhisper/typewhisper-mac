import SwiftUI

/// Notch-extending indicator that visually expands the MacBook notch area.
/// Three-zone layout: left ear | center (notch spacer) | right ear.
/// Both sides are configurable (indicator, timer, waveform, clock, battery).
/// Expands wider and downward to show streaming partial text.
/// Blue glow emanates from the notch shape, reacting to audio level.
struct NotchIndicatorView: View {
    @ObservedObject private var viewModel = DictationViewModel.shared
    @ObservedObject var geometry: NotchGeometry
    @State private var textExpanded = false
    @State private var dotPulse = false

    private let extensionWidth: CGFloat = 60
    private let contentPadding: CGFloat = 28
    private let sizing: IndicatorSizing = .notch

    private var closedWidth: CGFloat {
        geometry.hasNotch ? geometry.notchWidth + 2 * extensionWidth : 200
    }

    private var suppressStreamingText: Bool {
        viewModel.externalStreamingDisplayCount > 0
    }

    private var hasActionFeedback: Bool {
        viewModel.state == .inserting && viewModel.actionFeedbackMessage != nil
    }

    private var hasProcessingPhase: Bool {
        viewModel.state == .processing && viewModel.processingPhase != nil
    }

    private var isExpanded: Bool {
        textExpanded || hasActionFeedback
    }

    private var currentWidth: CGFloat {
        if textExpanded { return max(closedWidth, 400) }
        if hasActionFeedback { return max(closedWidth, 340) }
        if hasProcessingPhase { return closedWidth + 80 }
        return closedWidth
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusBar
                .frame(width: currentWidth, height: geometry.notchHeight)
                .frame(maxWidth: .infinity)

            if viewModel.state == .recording, !suppressStreamingText {
                IndicatorExpandableText(
                    text: viewModel.partialText,
                    sizing: sizing,
                    expanded: textExpanded,
                    contentPadding: 34
                )
                .onChange(of: viewModel.partialText) {
                    if !viewModel.partialText.isEmpty, !textExpanded {
                        withAnimation(.easeOut(duration: 0.25)) {
                            textExpanded = true
                        }
                    }
                }
            }

            if hasProcessingPhase {
                Text(viewModel.processingPhase ?? "")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }

            if hasActionFeedback {
                IndicatorActionFeedback(
                    message: viewModel.actionFeedbackMessage ?? "",
                    icon: viewModel.actionFeedbackIcon,
                    isError: viewModel.actionFeedbackIsError,
                    contentPadding: contentPadding
                )
            }
        }
        .frame(width: currentWidth)
        .background(.black)
        .clipShape(NotchShape(
            topCornerRadius: isExpanded ? 19 : (hasProcessingPhase ? 8 : 6),
            bottomCornerRadius: isExpanded ? 24 : (hasProcessingPhase ? 18 : 14)
        ))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.3), value: textExpanded)
        .animation(.easeInOut(duration: 0.2), value: viewModel.state)
        .animation(.easeOut(duration: 0.08), value: viewModel.audioLevel)
        .onChange(of: viewModel.state) {
            if viewModel.state == .recording {
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    dotPulse = true
                }
            } else {
                dotPulse = false
                textExpanded = false
            }
        }
        .onChange(of: suppressStreamingText) {
            if suppressStreamingText {
                withAnimation(.easeInOut(duration: 0.3)) {
                    textExpanded = false
                }
            }
        }
        .animation(.easeInOut(duration: 1.0), value: dotPulse)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(notchAccessibilityLabel)
    }

    private var notchAccessibilityLabel: String {
        switch viewModel.state {
        case .idle, .promptSelection, .promptProcessing:
            return String(localized: "Idle")
        case .recording:
            return String(localized: "Recording")
        case .processing:
            return String(localized: "Processing transcription")
        case .inserting:
            if let feedback = viewModel.actionFeedbackMessage {
                return feedback
            }
            return String(localized: "Inserting text")
        case .error(let message):
            return String(localized: "Error - \(message)")
        }
    }

    // MARK: - Status bar (three-zone layout)

    @ViewBuilder
    private var statusBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                IndicatorLeftStatus(
                    viewModel: viewModel,
                    sizing: sizing,
                    dotPulse: dotPulse,
                    hasActionFeedback: hasActionFeedback
                )
                leftContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.leading, 14)

            if geometry.hasNotch {
                Color.clear
                    .frame(width: geometry.notchWidth)
            }

            rightContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, 34)
        }
    }

    // MARK: - Configurable content

    @ViewBuilder
    private var leftContent: some View {
        if case .recording = viewModel.state {
            IndicatorRecordingContent(
                viewModel: viewModel,
                content: viewModel.notchIndicatorLeftContent,
                sizing: sizing,
                dotPulse: dotPulse
            )
        }
    }

    @ViewBuilder
    private var rightContent: some View {
        if case .recording = viewModel.state {
            IndicatorRecordingContent(
                viewModel: viewModel,
                content: viewModel.notchIndicatorRightContent,
                sizing: sizing,
                dotPulse: dotPulse
            )
        } else if case .processing = viewModel.state {
            ProgressView()
                .controlSize(.mini)
                .tint(.white)
        }
    }
}
