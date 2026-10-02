import SwiftUI

/// Settings of the Premium speaker feature: the detection model and when
/// speakers are detected automatically.
struct SpeakerDetectionSettingsSection: View {
    @ObservedObject var coordinator: SpeakerTranscriptCoordinator
    @ObservedObject private var voiceStore = ServiceContainer.shared.speakerVoiceProfileService.store
    @State private var deletedProfile: VoiceProfile?
    @AppStorage(UserDefaultsKeys.calendarMeetingDetectSpeakers) private var detectsInCalendarMeetings = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PremiumSettingsDetailHeader(
                icon: "person.2.wave.2",
                accent: .purple,
                title: String(localized: "premium.window.speakers.title"),
                description: String(localized: "premium.window.speakers.description"),
                status: statusText,
                statusColor: coordinator.areModelsInstalled ? .green : .secondary
            )

            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text(String(localized: "premium.window.speakers.model.title"))
                        .font(.headline)

                    Text(String(localized: "premium.window.speakers.model.description"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if coordinator.provider == nil {
                        Label(String(localized: "speakers.status.providerUnavailable"), systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    } else if let progress = coordinator.modelDownloadProgress {
                        ProgressView(value: progress) {
                            Text(String(localized: "speakers.status.downloadingModel"))
                                .font(.caption)
                        }
                    } else if coordinator.areModelsInstalled {
                        HStack {
                            Label(String(localized: "premium.window.speakers.model.installed"), systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Spacer()
                            Button(String(localized: "premium.window.speakers.model.delete"), role: .destructive) {
                                coordinator.deleteModels()
                            }
                            .disabled(!coordinator.stages.isEmpty)
                        }
                    } else {
                        Button(String(localized: "premium.window.speakers.model.download")) {
                            coordinator.downloadModels()
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if let error = coordinator.modelError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text(String(localized: "premium.window.speakers.automatic.title"))
                        .font(.headline)

                    Toggle(
                        String(localized: "premium.window.speakers.automatic.calendarMeetings"),
                        isOn: $detectsInCalendarMeetings
                    )

                    Text(String(localized: "premium.window.speakers.automatic.description"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text(String(localized: "premium.window.speakers.profiles.title"))
                        .font(.headline)

                    if voiceStore.profiles.isEmpty {
                        Text(String(localized: "premium.window.speakers.profiles.empty"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(voiceStore.profiles) { profile in
                            VoiceProfileRow(profile: profile) { deletedProfile = profile }
                        }
                    }

                    Text(String(localized: "premium.window.speakers.profiles.footer"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .confirmationDialog(
                String.localizedStringWithFormat(
                    String(localized: "premium.window.speakers.profiles.deleteTitle"),
                    deletedProfile?.name ?? ""
                ),
                isPresented: Binding(get: { deletedProfile != nil }, set: { if !$0 { deletedProfile = nil } }),
                presenting: deletedProfile
            ) { profile in
                Button(String(localized: "premium.window.speakers.profiles.delete"), role: .destructive) {
                    ServiceContainer.shared.speakerVoiceProfileService.deleteProfile(profile.id)
                }
            } message: { _ in
                Text(String(localized: "premium.window.speakers.profiles.deleteMessage"))
            }

            Text(String(localized: "premium.window.speakers.privacy"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusText: String {
        coordinator.areModelsInstalled
            ? String(localized: "premium.hub.status.on")
            : String(localized: "premium.hub.speakers.modelMissing")
    }
}

/// One voice profile in the settings: rename in place, see what it was
/// learned from, delete.
private struct VoiceProfileRow: View {
    let profile: VoiceProfile
    let onDelete: () -> Void
    @State private var nameDraft = ""
    @FocusState private var isNameFocused: Bool

    var body: some View {
        let service = ServiceContainer.shared.speakerVoiceProfileService
        HStack(spacing: 10) {
            Image(systemName: "person.wave.2")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                TextField(profile.name, text: $nameDraft)
                    .textFieldStyle(.plain)
                    .focused($isNameFocused)
                    .onSubmit { commit(service) }
                    .onChange(of: isNameFocused) { _, focused in
                        if !focused { commit(service) }
                    }
                Text(String.localizedStringWithFormat(
                    String(localized: "premium.window.speakers.profiles.learnedFormat"),
                    SpeakerTranscriptPresentation.timestamp(profile.enrolledSeconds),
                    Int64(service.appearances(of: profile.id).count)
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "premium.window.speakers.profiles.delete"))
            .accessibilityLabel(String(localized: "premium.window.speakers.profiles.delete"))
        }
        .onAppear { nameDraft = profile.name }
        .onChange(of: profile.name) { _, name in
            if !isNameFocused { nameDraft = name }
        }
    }

    private func commit(_ service: SpeakerVoiceProfileService) {
        if nameDraft != profile.name { service.renameProfile(profile.id, to: nameDraft) }
        nameDraft = service.store.profile(withID: profile.id)?.name ?? profile.name
    }
}
