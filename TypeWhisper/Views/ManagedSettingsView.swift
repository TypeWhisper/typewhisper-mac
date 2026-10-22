import SwiftUI

/// Marks a control whose value an administrator sets.
struct ManagedByOrganizationLabel: View {
    static var defaultText: String { String(localized: "Managed by your organization.") }

    var text = ManagedByOrganizationLabel.defaultText

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "building.2")
                .accessibilityHidden(true)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        // Read as one sentence; the building icon only decorates it.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityAddTraits(.isStaticText)
    }
}

extension View {
    /// A control that managed settings lock tells VoiceOver why, with the reason the
    /// visible `ManagedByOrganizationLabel` next to it shows.
    func managedLockAccessibilityHint(isLocked: Bool, reason: String?) -> some View {
        modifier(ManagedLockAccessibilityHint(isLocked: isLocked, reason: reason))
    }
}

private struct ManagedLockAccessibilityHint: ViewModifier {
    let isLocked: Bool
    let reason: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if isLocked {
            content.accessibilityHint(reason ?? ManagedByOrganizationLabel.defaultText)
        } else {
            content
        }
    }
}

/// Settings > Advanced > Managed Settings: the read-only view of the managed preferences.
struct ManagedSettingsSection: View {
    @ObservedObject var policyService: ManagedPolicyService
    @ObservedObject var updateCoordinator: ManagedUpdateCoordinator

    /// Shown while anything is managed or reported, so unmanaged Macs keep a short Advanced page.
    static func isVisible(_ snapshot: ManagedPolicySnapshot) -> Bool {
        snapshot.isManaged || !snapshot.issues.isEmpty || snapshot.status == .unreadable
    }

    var body: some View {
        let snapshot = policyService.current
        let rows = Self.rows(snapshot)
        let problems = Self.problems(snapshot, updatePolicy: updateCoordinator.policy) + Self.pairProblems()

        Section(String(localized: "Managed Settings")) {
            Text(Self.summary(snapshot))
                .foregroundStyle(.secondary)

            if !rows.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    // Each row below names its setting, scope and value, so the column
                    // titles are only shown.
                    GridRow {
                        Text(String(localized: "Setting"))
                        Text(String(localized: "Scope"))
                        Text(String(localized: "Value"))
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                    ForEach(rows) { row in
                        // VoiceOver reads a row as one element on its first cell,
                        // e.g. "AllowCloudTranscription, Enforced, Off".
                        GridRow {
                            Text(row.name)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(Self.accessibilityLabel(for: row))
                                .accessibilityAddTraits(.isStaticText)
                            Text(row.scope)
                                .accessibilityHidden(true)
                            Text(row.value)
                                .foregroundStyle(row.isInvalid ? Color.red : Color.primary)
                                .textSelection(.enabled)
                                .accessibilityHidden(true)
                        }
                        .font(.callout)
                    }
                }
            }

            if !problems.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Policy Problems"))
                        .font(.caption.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    ForEach(problems, id: \.self) { problem in
                        Label {
                            Text(problem)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                                .accessibilityHidden(true)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(problem)
                        .accessibilityAddTraits(.isStaticText)
                    }
                }
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    if snapshot.revision > 0 {
                        Text(String(localized: "Last checked \(snapshot.readAt.formatted(date: .omitted, time: .standard))"))
                            .font(.caption)
                    }
                    Text(String(localized: "dictum checks again every 30 seconds and when it becomes active."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(String(localized: "Refresh")) {
                    policyService.refresh()
                }
            }
        }
    }

    struct Row: Identifiable, Equatable {
        let name: String
        let scope: String
        let value: String
        var isInvalid = false

        var id: String { "\(name)|\(scope)" }
    }

    /// One spoken line per table row: setting, scope and value.
    static func accessibilityLabel(for row: Row) -> String {
        [row.name, row.scope, row.value].joined(separator: ", ")
    }

    static func summary(_ snapshot: ManagedPolicySnapshot) -> String {
        if snapshot.status == .unreadable {
            return String(localized: "The managed settings could not be read. Managed features wait until they can be read again.")
        }
        return snapshot.isManaged
            ? String(localized: "Your organization manages these settings on this Mac.")
            : String(localized: "No settings are managed on this Mac.")
    }

    /// One row per enforced, invalid enforced and recommended value, in catalog order.
    static func rows(_ snapshot: ManagedPolicySnapshot) -> [Row] {
        let enforced = String(localized: "Enforced")
        let recommended = String(localized: "Recommended")
        var rows: [Row] = []
        for definition in ManagedPolicyKeys.all {
            if let value = snapshot.enforced(definition.name) {
                rows.append(Row(name: definition.name, scope: enforced, value: display(value, for: definition)))
            } else if snapshot.invalidEnforcedKeys.contains(definition.name) {
                rows.append(Row(
                    name: definition.name,
                    scope: enforced,
                    value: String(localized: "Invalid value; the setting stays blocked"),
                    isInvalid: true
                ))
            }
            if let value = snapshot.recommended(definition.name) {
                rows.append(Row(name: definition.name, scope: recommended, value: display(value, for: definition)))
            }
        }
        return rows
    }

    /// Validation findings, conflicts between enforced values and keys this edition ignores.
    static func problems(_ snapshot: ManagedPolicySnapshot, updatePolicy: ManagedUpdatePolicy) -> [String] {
        var problems = snapshot.issues.map(\.message)
        if let conflict = updatePolicy.conflict {
            problems.append(conflict)
        }
        #if APPSTORE
        let notApplicable = [
            ManagedPolicyKeys.updateMode, ManagedPolicyKeys.updateChannel, ManagedPolicyKeys.allowedUpdateChannels,
            ManagedPolicyKeys.allowPluginDownloads,
        ]
        for key in notApplicable where snapshot.enforced(key) != nil || snapshot.recommended(key) != nil {
            problems.append("\(key) does not apply to the App Store edition and is ignored.")
        }
        #endif
        return problems
    }

    /// Enforced pairs that name a provider or model that cannot be used, with the reason.
    @MainActor
    static func pairProblems(pluginManager: PluginManager? = PluginManager.shared) -> [String] {
        guard let pluginManager else { return [] }
        return [
            pluginManager.enforcedTranscriptionResolution?.unavailableReason.map { "\(ManagedPolicyKeys.transcriptionProviderId): \($0)" },
            pluginManager.enforcedLlmResolution?.unavailableReason.map { "\(ManagedPolicyKeys.llmProviderId): \($0)" },
        ].compactMap { $0 }
    }

    static func display(_ value: ManagedPolicyValue, for definition: ManagedPolicyDefinition) -> String {
        if definition.sensitive {
            return "••••••"
        }
        switch value {
        case .boolean(let flag):
            return flag ? String(localized: "On") : String(localized: "Off")
        case .enumeration(let number):
            switch definition.name {
            case ManagedPolicyKeys.updateMode:
                switch ManagedUpdateMode(rawValue: number) {
                case .external: return String(localized: "External")
                case .checkOnly: return String(localized: "Check only")
                case .userInitiated: return String(localized: "User-initiated")
                case nil: return String(number)
                }
            case ManagedPolicyKeys.updateChannel:
                return ManagedUpdatePolicy.channel(policyValue: number)?.selectionDisplayName ?? String(number)
            default:
                return String(number)
            }
        case .text(let text):
            return text
        case .list(let items):
            return items.isEmpty ? String(localized: "None") : items.joined(separator: ", ")
        }
    }
}
