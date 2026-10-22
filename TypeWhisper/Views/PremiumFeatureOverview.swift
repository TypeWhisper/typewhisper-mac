import SwiftUI

enum PremiumFeatureID: String, CaseIterable, Identifiable, Sendable {
    case calendarMeeting
    case correctionLearning
    case cloudSync
    case speakerWorkspace
    case pairedDevices

    var id: String { rawValue }
    static var editionFeatures: [PremiumFeatureID] { allCases }

    var title: String {
        switch self {
        case .calendarMeeting: String(localized: "calendarMeeting.settings.title")
        case .correctionLearning: String(localized: "premium.hub.learning.title")
        case .cloudSync: String(localized: "premium.hub.sync.title")
        case .speakerWorkspace: String(localized: "speakers.page.title")
        case .pairedDevices: PairedDevicesPremiumCopy.title
        }
    }

    var icon: String {
        switch self {
        case .calendarMeeting: "calendar"
        case .correctionLearning: "wand.and.sparkles"
        case .cloudSync: "cloud"
        case .speakerWorkspace: "person.wave.2"
        case .pairedDevices: "iphone.and.ipad"
        }
    }
}

struct FeatureSettingsLink: View {
    let feature: PremiumFeatureID

    var body: some View {
        Button {
            SettingsNavigationCoordinator.shared.navigate(to: feature)
        } label: {
            HStack {
                Label(feature.title, systemImage: feature.icon)
                Spacer()
                Image(systemName: "chevron.right")
                    .accessibilityHidden(true)
            }
            .padding(12)
        }
        .buttonStyle(.bordered)
    }
}

struct SettingsDetailPart<Content: View>: View {
    let backTitle: String
    let onBack: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Button(action: onBack) {
                    Label(backTitle, systemImage: "chevron.left")
                        .font(.callout.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .keyboardShortcut(.cancelAction)
                content
            }
            .padding(SettingsLayoutMetrics.pagePadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

enum PremiumCorrectionExamples {
    static var current: [(before: String, after: String)] {
        examples(for: preferredAppLanguageCode())
    }

    static func examples(for languageCode: String) -> [(before: String, after: String)] {
        let language = languageCode.lowercased()
        if language.hasPrefix("de") {
            return [("Standart", "Standard"), ("wiederspiegeln", "widerspiegeln")]
        }
        if language.hasPrefix("ja") {
            return [("こんにちわ", "こんにちは"), ("すいません", "すみません")]
        }
        if language.hasPrefix("zh") {
            return [("因该", "应该"), ("在次", "再次")]
        }
        return [("teh", "the"), ("recieve", "receive")]
    }

    static var primaryLine: String {
        guard let example = current.first else { return "" }
        return "\(example.before)  →  \(example.after)"
    }
}

enum PairedDevicesPremiumCopy {
    static var title: String {
        localizedAppText("iPhone and iPad", de: "iPhone und iPad", ja: "iPhone と iPad", zh: "iPhone 和 iPad")
    }

    static var description: String {
        localizedAppText(
            "Transcribe and write on your iPhone or iPad with this Mac's models and workflows.",
            de: "Transkribiere und schreibe auf deinem iPhone oder iPad mit den Modellen und Workflows dieses Macs.",
            ja: "この Mac のモデルとワークフローを使って、iPhone や iPad で文字起こしや文章作成ができます。",
            zh: "在 iPhone 或 iPad 上使用这台 Mac 的模型和工作流进行转写和写作。"
        )
    }

    static func pairedCount(_ count: Int) -> String {
        localizedAppText(
            "\(count) paired", de: "\(count) gekoppelt",
            ja: "\(count) 台ペアリング済み", zh: "已配对 \(count) 台"
        )
    }
}

struct PremiumSettingsDetailHeader: View {
    let icon: String
    let accent: Color
    let title: String
    let description: String
    var status: String? = nil
    var statusColor: Color = .secondary

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2.weight(.semibold))
                .foregroundStyle(accent)
                .frame(width: 46, height: 46)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(accent.opacity(0.13)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text(description).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if let status {
                Text(status)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(statusColor.opacity(0.12)))
            }
        }
    }
}

enum PremiumCorrectionLearningCopy {
    static func outcomeText(_ outcome: TargetAppCorrectionLearningOutcome) -> String {
        switch outcome {
        case .learned: String(localized: "premium.window.learning.outcome.learned")
        case .unsupportedTextObservation: String(localized: "premium.window.learning.outcome.unsupportedTextObservation")
        case .noEdit: String(localized: "premium.window.learning.outcome.noEdit")
        case .ambiguousEdit: String(localized: "premium.window.learning.outcome.ambiguousEdit")
        case .noCommitBeforeTimeout: String(localized: "premium.window.learning.outcome.noCommitBeforeTimeout")
        case .duplicateCorrection: String(localized: "premium.window.learning.outcome.duplicateCorrection")
        case .awaitingRepeat: String(localized: "premium.window.learning.outcome.awaitingRepeat")
        case .cancelled: String(localized: "premium.window.learning.outcome.cancelled")
        case .failed: String(localized: "premium.window.learning.outcome.failed")
        }
    }

    static func outcomeIcon(_ outcome: TargetAppCorrectionLearningOutcome) -> String {
        switch outcome {
        case .learned: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .unsupportedTextObservation, .ambiguousEdit, .noCommitBeforeTimeout: "info.circle.fill"
        case .noEdit, .duplicateCorrection, .awaitingRepeat, .cancelled: "minus.circle.fill"
        }
    }

    static func outcomeColor(_ outcome: TargetAppCorrectionLearningOutcome) -> Color {
        switch outcome {
        case .learned: .green
        case .failed: .red
        case .unsupportedTextObservation, .ambiguousEdit, .noCommitBeforeTimeout: .yellow
        case .noEdit, .duplicateCorrection, .awaitingRepeat, .cancelled: .secondary
        }
    }

    static func commitSignalText(_ signal: TargetAppCorrectionCommitSignal) -> String {
        switch signal {
        case .returnKey: String(localized: "premium.window.learning.signal.return")
        case .keypadEnterKey: String(localized: "premium.window.learning.signal.enter")
        case .tabKey: String(localized: "premium.window.learning.signal.tab")
        case .focusChanged: String(localized: "premium.window.learning.signal.focusChanged")
        case .activeApplicationChanged: String(localized: "premium.window.learning.signal.appChanged")
        }
    }
}

struct PremiumCorrectionExampleRow: View {
    let before: String
    let after: String

    var body: some View {
        HStack(spacing: 8) {
            Text(before)
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .strikethrough(true, color: .secondary)
                .foregroundStyle(.secondary)
            Image(systemName: "arrow.right").accessibilityHidden(true)
            Text(after).fontWeight(.semibold)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(localizedAppText(
            "\(before), corrected to \(after)",
            de: "\(before), korrigiert zu \(after)",
            ja: "\(before) を \(after) に修正",
            zh: "\(before) 更正为 \(after)"
        ))
    }
}
