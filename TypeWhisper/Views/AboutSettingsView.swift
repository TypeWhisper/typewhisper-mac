import SwiftUI

struct AboutSettingsView: View {
    @ObservedObject private var license = LicenseService.shared
    @AppStorage(UserDefaultsKeys.updateChannel) private var selectedUpdateChannelRawValue = AppConstants.defaultReleaseChannel.rawValue
    @ObservedObject private var updateCoordinator = ServiceContainer.shared.managedUpdateCoordinator
    @State private var isLogoHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The channel updates use: the organization's channel, then the user's choice, then the recommendation.
    private var selectedUpdateChannel: AppConstants.ReleaseChannel {
        _ = selectedUpdateChannelRawValue
        return updateCoordinator.effectiveChannel.value
    }

    private var updateChannelBinding: Binding<AppConstants.ReleaseChannel> {
        Binding(
            get: { selectedUpdateChannel },
            set: { newChannel in
                guard selectedUpdateChannel != newChannel, !updateCoordinator.policy.isChannelLocked else { return }
                selectedUpdateChannelRawValue = newChannel.rawValue
                UpdateChecker.shared?.resetUpdateCycleAfterSettingsChange()
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsPageHeader(String(localized: "About"))
            Divider()

            Form {
                Section {
                VStack(spacing: 12) {
                    WaveformLogoView(isActive: isLogoHovering && !reduceMotion)
                        .frame(width: 96, height: 96)
                        .scaleEffect(isLogoHovering && !reduceMotion ? 1.05 : 1.0)
                        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: isLogoHovering)
                        .onHover { isLogoHovering = $0 }
                        // Decorative: the app name follows right below.
                        .accessibilityHidden(true)

                    Text("dictum")
                        .font(.title)
                        .fontWeight(.semibold)
                        .accessibilityAddTraits(.isHeader)

                    if license.isSupporter, let tier = license.supporterTier {
                        SupporterBadgeView(tier: tier)
                    }

                    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
                    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
                    let channelSuffix = AppConstants.releaseChannel.versionDisplayName.map { " - \($0)" } ?? ""
                    Text("Version \(version) (\(build))\(channelSuffix)")
                        .foregroundStyle(.secondary)

                    if let previewRelease = AppConstants.previewRelease {
                        Link(destination: previewRelease.url) {
                            Text("Release \(previewRelease.tag)")
                        }
                        .font(.caption)
                    }

                    if let coordinator = WhatsNewCoordinator.shared {
                        WhatsNewButton(coordinator: coordinator)
                    }

                    Text(String(localized: "Fast, private speech-to-text for your Mac. Transcribe with local or cloud engines, process text with AI prompts, and insert directly into any app."))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 400)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

                #if !APPSTORE
                Section {
                let updatePolicy = updateCoordinator.policy
                let checkRefusal = updateCoordinator.checkRefusal
                Picker(String(localized: "Update Channel"), selection: updateChannelBinding) {
                    ForEach(updatePolicy.selectableChannels(current: selectedUpdateChannel), id: \.self) { channel in
                        Text(channel.selectionDisplayName)
                            .tag(channel)
                    }
                }
                .pickerStyle(.menu)
                .disabled(updatePolicy.isChannelLocked)
                .managedLockAccessibilityHint(isLocked: updatePolicy.isChannelLocked, reason: nil)

                Text(selectedUpdateChannel.updateDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if updatePolicy.isChannelLocked {
                    ManagedByOrganizationLabel()
                } else if updatePolicy.allowedChannels != nil {
                    ManagedByOrganizationLabel(text: String(localized: "Your organization limits the available update channels."))
                }

                if let checkRefusal {
                    ManagedByOrganizationLabel(text: checkRefusal)
                } else if let version = updateCoordinator.announcedVersion {
                    ManagedByOrganizationLabel(text: String(localized: "TypeWhisper \(version) is available."))
                }

                HStack {
                    Spacer()
                    Button(String(localized: "Check for Updates...")) {
                        UpdateChecker.shared?.checkForUpdates()
                    }
                    .disabled(checkRefusal != nil || UpdateChecker.shared?.canCheckForUpdates() != true)
                    .managedLockAccessibilityHint(isLocked: checkRefusal != nil, reason: checkRefusal)
                    Spacer()
                }
            }
                #endif

                Section {
                HStack {
                    Spacer()
                    Button {
                        openSetupWizard()
                    } label: {
                        Label(
                            localizedAppText("Open Setup Wizard", de: "Einrichtungsassistent öffnen"),
                            systemImage: "sparkles"
                        )
                    }
                    Spacer()
                }

                Text(localizedAppText(
                    "Run the first-time setup flow again without changing your saved settings.",
                    de: "Starte den Einrichtungsassistenten erneut, ohne deine gespeicherten Einstellungen zu ändern."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

                Section {
                VStack(spacing: 4) {
                    Text(String(localized: "\u{00A9} 2024-2026 TypeWhisper Contributors"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Link("based on TypeWhisper", destination: URL(string: "https://github.com/TypeWhisper/typewhisper-mac")!)
                        .font(.caption)

                    Text(String(localized: "Licensed under the GNU General Public License v3.0"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, SettingsLayoutMetrics.pagePadding)
            .padding(.bottom, SettingsLayoutMetrics.pagePadding)
        }
        .frame(minWidth: 500, minHeight: 300)
    }

    private func openSetupWizard() {
        UserDefaults.standard.set(0, forKey: UserDefaultsKeys.setupWizardCurrentStep)
        NotificationCenter.default.post(name: .resetSetupWizardWindow, object: nil)
        ManagedAppWindowOpener.shared.open(id: "setup")
    }
}

private struct WhatsNewButton: View {
    @ObservedObject var coordinator: WhatsNewCoordinator

    var body: some View {
        Button("New in dictum") {
            NotificationCenter.default.post(name: .whatsNewRequested, object: nil)
        }
        .disabled(coordinator.operationInProgress)
    }
}

/// The TypeWhisper waveform logo, drawn as five live capsule bars.
///
/// At rest the bars reproduce the app icon's static silhouette
/// (short / mid / tall / mid / short). When `isActive` is true the bars
/// animate like a voice spectrum, each oscillating on its own phase.
struct WaveformLogoView: View {
    /// Drives the live spectrum motion; bars settle into the static logo shape when false.
    var isActive: Bool

    // Geometry sampled from the app icon (512px canvas): bar width 12.1%,
    // gap 6.6%, and these resting height fractions.
    private let barColor = Color(red: 0, green: 120.0 / 255.0, blue: 215.0 / 255.0) // #0078D7
    private let restHeights: [CGFloat] = [0.371, 0.621, 0.871, 0.621, 0.371]
    private let phases: [Double] = [0.0, 2.1, 4.0, 0.9, 3.1]

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let barWidth = width * 0.121
            let spacing = width * 0.066

            TimelineView(.animation(paused: !isActive)) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                HStack(spacing: spacing) {
                    ForEach(restHeights.indices, id: \.self) { index in
                        Capsule(style: .continuous)
                            .fill(barColor)
                            .frame(width: barWidth, height: barHeight(index, time: time, full: height))
                    }
                }
                .frame(width: width, height: height)
            }
        }
    }

    private func barHeight(_ index: Int, time: Double, full: CGFloat) -> CGFloat {
        let rest = restHeights[index] * full
        guard isActive else { return rest }
        // Each bar breathes ±20% around its own base length, so the logo keeps
        // its shape while the bars pulse like a spectrum.
        let speed = 3.2
        let factor = 1.0 + 0.20 * sin(time * speed + phases[index % phases.count])
        return min(full, rest * CGFloat(factor))
    }
}
