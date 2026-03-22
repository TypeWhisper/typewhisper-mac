import SwiftUI

struct IndicatorPreviewView: View {
    @ObservedObject private var dictation = DictationViewModel.shared

    private let streamingText = String(localized: "Hello, this is a live preview of the streaming text...")

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(white: 0.15))

            Group {
                if dictation.indicatorStyle == .notch {
                    notchPreview
                } else {
                    overlayPreview
                }
            }
            .environment(\.colorScheme, .dark)
        }
        .frame(height: 110)
        .animation(.easeInOut(duration: 0.2), value: dictation.indicatorStyle)
        .animation(.easeInOut(duration: 0.2), value: dictation.notchIndicatorLeftContent)
        .animation(.easeInOut(duration: 0.2), value: dictation.notchIndicatorRightContent)
        .accessibilityHidden(true)
    }

    // MARK: - Notch Preview

    private let notchWidth: CGFloat = 185
    private let notchHeight: CGFloat = 34
    private let extensionWidth: CGFloat = 60

    @ViewBuilder
    private var notchPreview: some View {
        let closedWidth = notchWidth + 2 * extensionWidth
        let expandedWidth: CGFloat = max(closedWidth, 360)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 5) {
                    appIconPlaceholder(size: 14, cornerRadius: 3)
                    contentLabel(dictation.notchIndicatorLeftContent, size: 9)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.leading, 14)

                Color.clear
                    .frame(width: notchWidth)

                contentLabel(dictation.notchIndicatorRightContent, size: 9)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(.trailing, 30)
            }
            .frame(width: closedWidth, height: notchHeight)
            .frame(maxWidth: .infinity)

            Text(streamingText)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 8)
        }
        .frame(width: expandedWidth)
        .background(.black)
        .clipShape(NotchShape(topCornerRadius: 19, bottomCornerRadius: 24))
    }

    // MARK: - Overlay Preview

    @ViewBuilder
    private var overlayPreview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                appIconPlaceholder(size: 18, cornerRadius: 4)
                contentLabel(dictation.notchIndicatorLeftContent, size: 11)
                Spacer()
                contentLabel(dictation.notchIndicatorRightContent, size: 11)
            }
            .padding(.horizontal, 20)
            .frame(height: 42)

            Text(streamingText)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
        }
        .frame(width: 320)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - App Icon Placeholder

    private func appIconPlaceholder(size: CGFloat, cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(.white.opacity(0.15))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "app.fill")
                    .font(.system(size: size * 0.6))
                    .foregroundStyle(.white.opacity(0.4))
            )
    }

    // MARK: - Content Label (for preview)

    @ViewBuilder
    private func contentLabel(_ content: NotchIndicatorContent, size: CGFloat) -> some View {
        switch content {
        case .indicator:
            Circle()
                .fill(Color.red)
                .frame(width: size * 0.7, height: size * 0.7)
        case .timer:
            Text("1:23")
                .font(.system(size: size, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
        case .waveform:
            HStack(spacing: 1.5) {
                ForEach(0..<5, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.white)
                        .frame(width: 2.5, height: [4, 8, 12, 7, 5][i])
                }
            }
            .frame(height: 14)
        case .profile:
            Text("Profile")
                .font(.system(size: size * 0.85, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.white.opacity(0.2), in: Capsule())
        case .none:
            Color.clear.frame(width: 0)
        }
    }
}

// MARK: - Style Tile Picker

struct IndicatorStylePicker: View {
    @ObservedObject private var dictation = DictationViewModel.shared

    var body: some View {
        HStack(spacing: 8) {
            styleTile(.notch, label: String(localized: "Notch")) {
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.white.opacity(0.5))
                        .frame(width: 16, height: 8)
                    Color.clear.frame(width: 30)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.white.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
                .frame(width: 70, height: 20)
                .background(.black)
                .clipShape(NotchShape(topCornerRadius: 3, bottomCornerRadius: 6))
            }

            styleTile(.overlay, label: String(localized: "Overlay")) {
                HStack(spacing: 3) {
                    Circle().fill(.white.opacity(0.5)).frame(width: 4, height: 4)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.white.opacity(0.3))
                        .frame(width: 16, height: 4)
                    Spacer()
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.white.opacity(0.3))
                        .frame(width: 8, height: 4)
                }
                .padding(.horizontal, 6)
                .frame(width: 70, height: 20)
                .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                )
            }
        }
    }

    @ViewBuilder
    private func styleTile<Content: View>(_ style: IndicatorStyle, label: String, @ViewBuilder icon: () -> Content) -> some View {
        let isSelected = dictation.indicatorStyle == style
        Button {
            dictation.indicatorStyle = style
        } label: {
            VStack(spacing: 6) {
                icon()
                    .frame(height: 36)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isSelected ? String(localized: "Selected") : "")
    }
}
