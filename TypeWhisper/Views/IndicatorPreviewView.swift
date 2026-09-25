import SwiftUI

#if DEBUG
struct ScreenshotIndicatorShowcaseView: View {
    @ObservedObject private var dictation = DictationViewModel.shared
    @StateObject private var countdownModel = CalendarMeetingCountdownModel()
    @State private var prepared = false

    var body: some View {
        HomeSettingsView()
            .overlay(alignment: .bottom) {
                OverlayIndicatorView(countdownModel: countdownModel)
                    .frame(width: 500, height: 200)
                    .padding(.bottom, 28)
                    .allowsHitTesting(false)
            }
            .onAppear {
                guard !prepared else { return }
                prepared = true
                dictation.prepareScreenshotIndicatorFixture()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    dictation.partialText = String(
                        localized: "Hello, this is a live preview of the streaming text..."
                    )
                }
            }
    }
}
#endif

// MARK: - Option Tile

/// Selectable tile shared by the style and theme pickers.
struct IndicatorOptionTile<Icon: View>: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        Button(action: action) {
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
        .frame(maxWidth: .infinity)
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isSelected ? String(localized: "Selected") : "")
    }
}

// MARK: - Theme Tile Picker

struct IndicatorThemePicker: View {
    @ObservedObject private var dictation = DictationViewModel.shared
    @Environment(\.colorScheme) private var systemColorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Theme"))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach(IndicatorTheme.allCases, id: \.self) { theme in
                    IndicatorOptionTile(
                        label: theme.title,
                        isSelected: dictation.indicatorTheme == theme,
                        action: { dictation.indicatorTheme = theme }
                    ) {
                        themeSwatch(theme)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func themeSwatch(_ theme: IndicatorTheme) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.primary.opacity(0.45))
                .frame(width: 5, height: 5)
            Text("1:23")
                .font(.system(size: 7, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.primary.opacity(0.65))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 8)
        .frame(width: 56, height: 20)
        .indicatorSurface(theme: theme, shape: Capsule())
        .environment(\.colorScheme, theme.preferredColorScheme ?? systemColorScheme)
        .padding(6)
        .background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - Style Tile Picker

struct IndicatorStylePicker: View {
    @ObservedObject private var dictation = DictationViewModel.shared
    private let notchTileWidth: CGFloat = 84
    private let compactTileWidth: CGFloat = 70

    var body: some View {
        HStack(spacing: 8) {
            styleTile(.notch, label: String(localized: "Notch")) {
                HStack(spacing: 0) {
                    HStack(spacing: 3) {
                        tileStatusIndicator(size: 7, cornerRadius: 2)
                        tileContentLabel(dictation.notchIndicatorLeftContent, size: 7)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 6)

                    Color.clear.frame(width: 24)

                    tileContentLabel(dictation.notchIndicatorRightContent, size: 7)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 6)
                }
                .frame(width: notchTileWidth, height: 20)
                .background(.black)
                .clipShape(NotchShape(bottomCornerRadius: 6))
            }

            styleTile(.overlay, label: String(localized: "Overlay")) {
                HStack(spacing: 4) {
                    tileStatusIndicator(size: 5, cornerRadius: 1.5)
                    tileContentLabel(dictation.notchIndicatorLeftContent, size: 7)
                    Spacer(minLength: 4)
                    tileContentLabel(dictation.notchIndicatorRightContent, size: 7)
                }
                .padding(.horizontal, 6)
                .frame(width: compactTileWidth, height: 20)
                .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                )
            }

            styleTile(.minimal, label: String(localized: "Indicator")) {
                HStack(spacing: 4) {
                    tileStatusIndicator(size: 7, cornerRadius: 2)
                    if dictation.notchIndicatorRightContent != .none {
                        tileContentLabel(dictation.notchIndicatorRightContent, size: 7)
                    }
                }
                .padding(.horizontal, 7)
                .frame(width: 52, height: 20)
                .background(.black.opacity(0.85), in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func styleTile<Content: View>(
        _ style: IndicatorStyle,
        label: String,
        @ViewBuilder icon: @escaping () -> Content
    ) -> some View {
        IndicatorOptionTile(
            label: label,
            isSelected: dictation.indicatorStyle == style,
            action: { dictation.indicatorStyle = style },
            icon: icon
        )
    }

    private func tileStatusIndicator(size: CGFloat, cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(.white.opacity(0.45))
            .frame(width: size, height: size)
    }

    @ViewBuilder
    private func tileContentLabel(_ content: NotchIndicatorContent, size: CGFloat) -> some View {
        switch content {
        case .indicator:
            Circle()
                .fill(Color.red)
                .frame(width: size * 0.7, height: size * 0.7)
        case .timer:
            Text("1:23")
                .font(.system(size: size, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        case .waveform:
            HStack(spacing: 1) {
                ForEach(0..<5, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 0.7)
                        .fill(.white.opacity(0.9))
                        .frame(width: 1.8, height: [3, 6, 8, 5, 3][index])
                }
            }
            .frame(height: 10)
        case .profile:
            Text("P")
                .font(.system(size: size * 0.9, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(.white.opacity(0.2), in: Capsule())
        case .none:
            Color.clear.frame(width: 0, height: 0)
        }
    }
}
