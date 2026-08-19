import SwiftUI

enum PremiumCorrectionExamples {
    static var current: [(before: String, after: String)] {
        examples(for: preferredAppLanguageCode())
    }

    static func examples(for languageCode: String) -> [(before: String, after: String)] {
        let language = languageCode.lowercased()

        if language.hasPrefix("de") {
            return [
                ("Standart", "Standard"),
                ("wiederspiegeln", "widerspiegeln"),
            ]
        }
        if language.hasPrefix("ja") {
            return [
                ("こんにちわ", "こんにちは"),
                ("すいません", "すみません"),
            ]
        }
        if language.hasPrefix("zh") {
            return [
                ("因该", "应该"),
                ("在次", "再次"),
            ]
        }

        return [
            ("teh", "the"),
            ("recieve", "receive"),
        ]
    }

    static var primaryLine: String {
        guard let example = current.first else { return "" }
        return "\(example.before)  →  \(example.after)"
    }
}

enum PremiumFeatureID: String, CaseIterable, Identifiable, Sendable {
    case calendarMeeting
    case correctionLearning
    case cloudSync

    var id: String { rawValue }
}

enum PremiumFeatureRequirement: Equatable, Sendable {
    case available
    case commercialOrPremiumAccount
    case commercialLicense
    case premiumAccount
    case linkCommercialLicense
    case signIn
}

enum PremiumAccessSummary: Equatable, Sendable {
    case locked
    case supporterOnly
    case commercialLicense
    case premiumAccount
    case commercialAndPremiumAccount

    var localizedTitle: String {
        switch self {
        case .locked:
            String(localized: "premium.hub.access.locked")
        case .supporterOnly:
            String(localized: "premium.hub.access.supporter")
        case .commercialLicense:
            String(localized: "premium.hub.access.commercial")
        case .premiumAccount:
            String(localized: "premium.hub.access.account")
        case .commercialAndPremiumAccount:
            String(localized: "premium.hub.access.both")
        }
    }
}

enum PremiumFeatureCardAction: Equatable, Sendable {
    case none
    case openSettings(PremiumSettingsDestination)
    case manageAccess
}

struct PremiumFeatureAccessSnapshot: Equatable, Sendable {
    let hasCommercialLicense: Bool
    let hasPremiumEntitlement: Bool
    let isSignedIn: Bool
    let isSupporter: Bool

    var hasAnyPremiumAccess: Bool {
        CalendarMeetingPremiumAccess.isGranted(
            hasCommercialLicense: hasCommercialLicense,
            hasPremiumEntitlement: hasPremiumEntitlement
        )
    }

    var summary: PremiumAccessSummary {
        switch (hasCommercialLicense, hasPremiumEntitlement) {
        case (true, true):
            .commercialAndPremiumAccount
        case (true, false):
            .commercialLicense
        case (false, true):
            .premiumAccount
        case (false, false):
            isSupporter ? .supporterOnly : .locked
        }
    }

    func requirement(for feature: PremiumFeatureID) -> PremiumFeatureRequirement {
        switch feature {
        case .calendarMeeting:
            return hasAnyPremiumAccess ? .available : .commercialOrPremiumAccount
        case .correctionLearning:
            return hasCommercialLicense ? .available : .commercialLicense
        case .cloudSync:
            guard hasPremiumEntitlement else {
                return hasCommercialLicense && isSignedIn
                    ? .linkCommercialLicense
                    : .premiumAccount
            }
            return isSignedIn ? .available : .signIn
        }
    }

    func action(for feature: PremiumFeatureID) -> PremiumFeatureCardAction {
        guard hasAnyPremiumAccess else { return .none }
        guard requirement(for: feature) == .available else { return .manageAccess }

        switch feature {
        case .calendarMeeting:
            return .openSettings(.calendarMeeting)
        case .correctionLearning:
            return .openSettings(.correctionLearning)
        case .cloudSync:
            return .openSettings(.cloudSync)
        }
    }
}

@MainActor
struct PremiumAccessStatusBar: View {
    let summary: PremiumAccessSummary
    let onManageAccess: () -> Void

    private var isActive: Bool {
        switch summary {
        case .commercialLicense, .premiumAccount, .commercialAndPremiumAccount:
            true
        case .locked, .supporterOnly:
            false
        }
    }

    var body: some View {
        SettingsCard(accent: isActive ? .green : .yellow) {
            HStack(spacing: 12) {
                Image(systemName: isActive ? "checkmark.seal.fill" : "lock.fill")
                    .font(.headline)
                    .foregroundStyle(isActive ? .green : .yellow)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill((isActive ? Color.green : Color.yellow).opacity(0.12))
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "premium.hub.access.title"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(summary.localizedTitle)
                        .font(.callout.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("premium.access.status")
                }

                Spacer(minLength: 12)

                Button(String(localized: "premium.hub.access.manage"), action: onManageAccess)
                    .accessibilityIdentifier("premium.access.manage")
            }
        }
    }
}

@MainActor
struct PremiumLockedFeatureOverview: View {
    let isSupporter: Bool
    let onUnlock: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayoutMetrics.sectionSpacing) {
            SettingsCard(accent: .yellow) {
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.yellow)
                        .frame(width: 54, height: 54)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(.yellow.opacity(0.12))
                        )
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(localized: "premium.hub.locked.title"))
                            .font(.title2.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)

                        Text(String(localized: "premium.hub.locked.description"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Button(action: onUnlock) {
                            Label(
                                String(localized: "premium.hub.unlock"),
                                systemImage: "lock.open"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("premium.unlock")

                        if isSupporter {
                            Label(
                                String(localized: "premium.hub.supporter.note"),
                                systemImage: "info.circle"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 8)
                }
            }

            PremiumFeatureGrid(cards: lockedCards)
        }
    }

    private var lockedCards: [AnyView] {
        [
            AnyView(
                PremiumFeatureCard(
                    feature: .calendarMeeting,
                    icon: "calendar.badge.clock",
                    accent: .blue,
                    title: String(localized: "premium.hub.calendar.title"),
                    description: String(localized: "premium.hub.calendar.description"),
                    status: String(localized: "premium.hub.status.premium"),
                    statusTone: .secondary,
                    previewLines: [String(localized: "premium.hub.calendar.providersPreview")]
                )
            ),
            AnyView(
                PremiumFeatureCard(
                    feature: .correctionLearning,
                    icon: "wand.and.sparkles",
                    accent: .yellow,
                    title: String(localized: "premium.hub.learning.title"),
                    description: String(localized: "premium.hub.learning.description"),
                    status: String(localized: "premium.hub.status.premium"),
                    statusTone: .secondary,
                    previewLines: [PremiumCorrectionExamples.primaryLine]
                )
            ),
            AnyView(
                PremiumFeatureCard(
                    feature: .cloudSync,
                    icon: "cloud",
                    accent: .cyan,
                    title: String(localized: "premium.hub.sync.title"),
                    description: String(localized: "premium.hub.sync.description"),
                    status: String(localized: "premium.hub.status.premium"),
                    statusTone: .secondary,
                    previewLines: [String(localized: "premium.hub.sync.preview")]
                )
            )
        ]
    }
}

@MainActor
struct PremiumActiveFeatureOverview: View {
    @ObservedObject private var license: LicenseService
    @ObservedObject private var premiumAccount: PremiumAccountService
    @ObservedObject private var syncController: CloudFolderSyncController
    @ObservedObject private var correctionLearningService: TargetAppCorrectionLearningService
    @ObservedObject private var calendarController: CalendarMeetingAutomationController
    @AppStorage(UserDefaultsKeys.targetAppCorrectionLearningEnabled) private var learningEnabled = false

    private let windowPresenter: any PremiumSettingsWindowPresenting

    init(
        licenseService: LicenseService,
        premiumAccount: PremiumAccountService,
        syncController: CloudFolderSyncController,
        correctionLearningService: TargetAppCorrectionLearningService,
        calendarController: CalendarMeetingAutomationController,
        windowPresenter: any PremiumSettingsWindowPresenting
    ) {
        self.license = licenseService
        self.premiumAccount = premiumAccount
        self.syncController = syncController
        self.correctionLearningService = correctionLearningService
        self.calendarController = calendarController
        self.windowPresenter = windowPresenter
    }

    private var access: PremiumFeatureAccessSnapshot {
        PremiumFeatureAccessSnapshot(
            hasCommercialLicense: license.hasCommercialLicense,
            hasPremiumEntitlement: premiumAccount.hasPremiumEntitlement,
            isSignedIn: premiumAccount.isSignedIn,
            isSupporter: license.isSupporter
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "premium.hub.active.title"))
                    .font(.title2.weight(.semibold))
                Text(String(localized: "premium.hub.active.description"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            PremiumFeatureGrid(cards: activeCards)
        }
    }

    private var activeCards: [AnyView] {
        [
            AnyView(calendarCard),
            AnyView(learningCard),
            AnyView(syncCard)
        ]
    }

    private var calendarCard: some View {
        let action = access.action(for: .calendarMeeting)
        return PremiumFeatureCard(
            feature: .calendarMeeting,
            icon: "calendar.badge.clock",
            accent: .blue,
            title: String(localized: "premium.hub.calendar.title"),
            description: String(localized: "premium.hub.calendar.description"),
            status: calendarStatus,
            statusTone: calendarStatusTone,
            previewLines: calendarPreviewLines,
            actionTitle: actionTitle(for: action),
            action: { perform(action) }
        )
    }

    private var learningCard: some View {
        let action = access.action(for: .correctionLearning)
        return PremiumFeatureCard(
            feature: .correctionLearning,
            icon: "wand.and.sparkles",
            accent: .yellow,
            title: String(localized: "premium.hub.learning.title"),
            description: String(localized: "premium.hub.learning.description"),
            status: learningStatus,
            statusTone: learningStatusTone,
            previewLines: learningPreviewLines,
            actionTitle: actionTitle(for: action),
            action: { perform(action) }
        )
    }

    private var syncCard: some View {
        let action = access.action(for: .cloudSync)
        return PremiumFeatureCard(
            feature: .cloudSync,
            icon: "cloud",
            accent: .cyan,
            title: String(localized: "premium.hub.sync.title"),
            description: String(localized: "premium.hub.sync.description"),
            status: syncStatus,
            statusTone: syncStatusTone,
            previewLines: syncPreviewLines,
            actionTitle: actionTitle(for: action),
            action: { perform(action) }
        )
    }

    private var calendarStatus: String {
        guard access.requirement(for: .calendarMeeting) == .available else {
            return requirementStatus(access.requirement(for: .calendarMeeting))
        }
        if calendarController.startMode != .off,
           calendarController.calendarAuthorization != .fullAccess {
            return String(localized: "premium.hub.status.actionRequired")
        }
        switch calendarController.startMode {
        case .off:
            return String(localized: "premium.hub.status.off")
        case .reminder:
            return String(localized: "premium.hub.status.remindersOnly")
        case .automatic:
            return String(localized: "premium.hub.status.automaticRecording")
        }
    }

    private var calendarStatusTone: PremiumFeatureStatusTone {
        guard access.requirement(for: .calendarMeeting) == .available else { return .warning }
        if calendarController.startMode != .off,
           calendarController.calendarAuthorization != .fullAccess {
            return .warning
        }
        switch calendarController.startMode {
        case .off:
            return .secondary
        case .reminder:
            return .accent
        case .automatic:
            return .success
        }
    }

    private var calendarPreviewLines: [String] {
        let permission: String
        switch calendarController.calendarAuthorization {
        case .fullAccess:
            permission = String(localized: "premium.hub.calendar.accessGranted")
        case .notDetermined:
            permission = String(localized: "premium.hub.calendar.accessNotRequested")
        case .denied, .restricted, .writeOnly, .unknown:
            permission = String(localized: "premium.hub.calendar.accessNeeded")
        }
        let selection = String.localizedStringWithFormat(
            String(localized: "premium.hub.calendar.selectionFormat"),
            Int64(calendarController.selectedCalendarIDs.count),
            Int64(calendarController.enabledProviders.count)
        )
        return [permission, selection]
    }

    private var learningStatus: String {
        let requirement = access.requirement(for: .correctionLearning)
        guard requirement == .available else { return requirementStatus(requirement) }
        return learningEnabled
            ? String(localized: "premium.hub.status.on")
            : String(localized: "premium.hub.status.off")
    }

    private var learningStatusTone: PremiumFeatureStatusTone {
        access.requirement(for: .correctionLearning) == .available
            ? (learningEnabled ? .success : .secondary)
            : .warning
    }

    private var learningPreviewLines: [String] {
        let activity = correctionLearningService.latestAttempt.map {
            PremiumCorrectionLearningCopy.outcomeText($0.outcome)
        } ?? String(localized: "premium.hub.learning.preview")
        return [activity, PremiumCorrectionExamples.primaryLine]
    }

    private var syncStatus: String {
        let requirement = access.requirement(for: .cloudSync)
        guard requirement == .available else { return requirementStatus(requirement) }
        if syncController.isSyncing {
            return String(localized: "premium.window.sync.syncing")
        }
        switch syncController.mode {
        case .off:
            return String(localized: "premium.hub.status.off")
        case .automaticICloud:
            return String(localized: "premium.window.sync.mode.automaticICloud")
        case .cloudFolder:
            return syncController.provider.displayName
        }
    }

    private var syncStatusTone: PremiumFeatureStatusTone {
        guard access.requirement(for: .cloudSync) == .available else { return .warning }
        if syncController.isSyncing { return .accent }
        return syncController.mode == .off ? .secondary : .success
    }

    private var syncPreviewLines: [String] {
        let provider = syncController.mode == .off
            ? String(localized: "premium.hub.sync.notConfigured")
            : syncController.provider.displayName
        let lastSync = syncController.lastSyncDate.map {
            String.localizedStringWithFormat(
                String(localized: "premium.hub.sync.lastSyncFormat"),
                $0.formatted(date: .abbreviated, time: .shortened)
            )
        } ?? String(localized: "premium.hub.sync.neverSynced")
        return [provider, lastSync]
    }

    private func requirementStatus(_ requirement: PremiumFeatureRequirement) -> String {
        switch requirement {
        case .available:
            String(localized: "premium.hub.status.on")
        case .commercialOrPremiumAccount:
            String(localized: "premium.hub.status.premiumRequired")
        case .commercialLicense:
            String(localized: "premium.hub.status.commercialRequired")
        case .premiumAccount:
            String(localized: "premium.hub.status.accountRequired")
        case .linkCommercialLicense:
            String(localized: "premium.hub.status.linkPurchase")
        case .signIn:
            String(localized: "premium.hub.status.signInRequired")
        }
    }

    private func actionTitle(for action: PremiumFeatureCardAction) -> String? {
        switch action {
        case .none:
            nil
        case .openSettings:
            String(localized: "premium.hub.settings")
        case .manageAccess:
            String(localized: "premium.hub.access.manage")
        }
    }

    private func perform(_ action: PremiumFeatureCardAction) {
        switch action {
        case .none:
            break
        case .openSettings(let destination):
            windowPresenter.present(destination)
        case .manageAccess:
            windowPresenter.present(.access)
        }
    }
}

private struct PremiumFeatureGrid: View {
    let cards: [AnyView]

    var body: some View {
        PremiumFeatureResponsiveLayout(spacing: 12, minimumColumnWidth: 210) {
            ForEach(cards.indices, id: \.self) { index in
                cards[index]
            }
        }
    }
}

private struct PremiumFeatureResponsiveLayout: Layout {
    let spacing: CGFloat
    let minimumColumnWidth: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard !subviews.isEmpty else { return .zero }

        let availableWidth = proposal.width
            ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max()
            ?? minimumColumnWidth

        if usesColumns(width: availableWidth, count: subviews.count) {
            let columnWidth = columnWidth(for: availableWidth, count: subviews.count)
            let height = subviews
                .map { $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height }
                .max()
                ?? 0
            return CGSize(width: availableWidth, height: height)
        }

        let sizes = subviews.map {
            $0.sizeThatFits(ProposedViewSize(width: availableWidth, height: nil))
        }
        return CGSize(
            width: availableWidth,
            height: sizes.reduce(0) { $0 + $1.height }
                + spacing * CGFloat(max(0, subviews.count - 1))
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard !subviews.isEmpty else { return }

        if usesColumns(width: bounds.width, count: subviews.count) {
            let width = columnWidth(for: bounds.width, count: subviews.count)
            var x = bounds.minX

            for subview in subviews {
                subview.place(
                    at: CGPoint(x: x, y: bounds.minY),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: width, height: bounds.height)
                )
                x += width + spacing
            }
            return
        }

        var y = bounds.minY
        for subview in subviews {
            let size = subview.sizeThatFits(
                ProposedViewSize(width: bounds.width, height: nil)
            )
            subview.place(
                at: CGPoint(x: bounds.minX, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: size.height)
            )
            y += size.height + spacing
        }
    }

    private func usesColumns(width: CGFloat, count: Int) -> Bool {
        width >= minimumColumnWidth * CGFloat(count)
            + spacing * CGFloat(max(0, count - 1))
    }

    private func columnWidth(for availableWidth: CGFloat, count: Int) -> CGFloat {
        (availableWidth - spacing * CGFloat(max(0, count - 1))) / CGFloat(count)
    }
}

private enum PremiumFeatureStatusTone {
    case secondary
    case accent
    case success
    case warning

    var color: Color {
        switch self {
        case .secondary:
            .secondary
        case .accent:
            .blue
        case .success:
            .green
        case .warning:
            .orange
        }
    }
}

private struct PremiumFeatureCard: View {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    let feature: PremiumFeatureID
    let icon: String
    let accent: Color
    let title: String
    let description: String
    let status: String
    let statusTone: PremiumFeatureStatusTone
    let previewLines: [String]
    var actionTitle: String?
    var action: (() -> Void)?

    init(
        feature: PremiumFeatureID,
        icon: String,
        accent: Color,
        title: String,
        description: String,
        status: String,
        statusTone: PremiumFeatureStatusTone,
        previewLines: [String],
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.feature = feature
        self.icon = icon
        self.accent = accent
        self.title = title
        self.description = description
        self.status = status
        self.statusTone = statusTone
        self.previewLines = Array(previewLines.prefix(2))
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(accent)
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(accent.opacity(0.13))
                    )
                    .accessibilityHidden(true)

                Spacer(minLength: 4)

                Text(status)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusTone.color)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(statusTone.color.opacity(0.12)))
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(previewLines.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: index == 0 ? "checkmark.circle" : "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }

            Spacer(minLength: 0)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .accessibilityIdentifier("premium.feature.\(feature.rawValue).action")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 270, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: SettingsLayoutMetrics.cardCornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            accent.opacity(0.08),
                            Color(nsColor: .controlBackgroundColor)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsLayoutMetrics.cardCornerRadius, style: .continuous)
                .stroke(
                    accent.opacity(colorSchemeContrast == .increased ? 0.75 : 0.20),
                    lineWidth: colorSchemeContrast == .increased ? 2 : 1
                )
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("premium.feature.\(feature.rawValue)")
    }
}

struct PremiumSettingsDetailHeader: View {
    let icon: String
    let accent: Color
    let title: String
    let description: String
    let status: String?
    let statusColor: Color

    init(
        icon: String,
        accent: Color,
        title: String,
        description: String,
        status: String? = nil,
        statusColor: Color = .secondary
    ) {
        self.icon = icon
        self.accent = accent
        self.title = title
        self.description = description
        self.status = status
        self.statusColor = statusColor
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2.weight(.semibold))
                .foregroundStyle(accent)
                .frame(width: 46, height: 46)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(accent.opacity(0.13))
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
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

struct PremiumLockedDetailView: View {
    let message: String
    let onManageAccess: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PremiumSettingsDetailHeader(
                icon: "lock.fill",
                accent: .yellow,
                title: String(localized: "premium.window.locked.title"),
                description: message
            )

            SettingsCard(accent: .yellow) {
                Button(String(localized: "premium.hub.access.manage"), action: onManageAccess)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("premium.window.locked.manageAccess")
            }
        }
    }
}

enum PremiumCorrectionLearningCopy {
    static func outcomeText(_ outcome: TargetAppCorrectionLearningOutcome) -> String {
        switch outcome {
        case .learned:
            String(localized: "premium.window.learning.outcome.learned")
        case .unsupportedTextObservation:
            String(localized: "premium.window.learning.outcome.unsupportedTextObservation")
        case .noEdit:
            String(localized: "premium.window.learning.outcome.noEdit")
        case .ambiguousEdit:
            String(localized: "premium.window.learning.outcome.ambiguousEdit")
        case .noCommitBeforeTimeout:
            String(localized: "premium.window.learning.outcome.noCommitBeforeTimeout")
        case .duplicateCorrection:
            String(localized: "premium.window.learning.outcome.duplicateCorrection")
        case .cancelled:
            String(localized: "premium.window.learning.outcome.cancelled")
        case .failed:
            String(localized: "premium.window.learning.outcome.failed")
        }
    }

    static func outcomeIcon(_ outcome: TargetAppCorrectionLearningOutcome) -> String {
        switch outcome {
        case .learned:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        case .unsupportedTextObservation, .ambiguousEdit, .noCommitBeforeTimeout:
            "info.circle.fill"
        case .noEdit, .duplicateCorrection, .cancelled:
            "minus.circle.fill"
        }
    }

    static func outcomeColor(_ outcome: TargetAppCorrectionLearningOutcome) -> Color {
        switch outcome {
        case .learned:
            .green
        case .failed:
            .red
        case .unsupportedTextObservation, .ambiguousEdit, .noCommitBeforeTimeout:
            .yellow
        case .noEdit, .duplicateCorrection, .cancelled:
            .secondary
        }
    }

    static func commitSignalText(_ signal: TargetAppCorrectionCommitSignal) -> String {
        switch signal {
        case .returnKey:
            String(localized: "premium.window.learning.signal.return")
        case .keypadEnterKey:
            String(localized: "premium.window.learning.signal.enter")
        case .tabKey:
            String(localized: "premium.window.learning.signal.tab")
        case .focusChanged:
            String(localized: "premium.window.learning.signal.focusChanged")
        case .activeApplicationChanged:
            String(localized: "premium.window.learning.signal.appChanged")
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

            Image(systemName: "arrow.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(after)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}
