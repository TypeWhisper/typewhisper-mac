import SwiftUI

/// Settings of the Premium speaker feature in its Premium window: the
/// detection model, automatic detection, and the voice profiles.
struct SpeakerDetectionSettingsSection: View {
    @ObservedObject var coordinator: SpeakerTranscriptCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PremiumSettingsDetailHeader(
                icon: "person.2.wave.2",
                accent: .purple,
                title: String(localized: "premium.window.speakers.title"),
                description: String(localized: "premium.window.speakers.description"),
                status: coordinator.areModelsInstalled
                    ? String(localized: "premium.hub.status.on")
                    : String(localized: "premium.hub.speakers.modelMissing"),
                statusColor: coordinator.areModelsInstalled ? .green : .secondary
            )
            SpeakerModelCard(coordinator: coordinator)
            SpeakerAutomaticDetectionCard()
            VoiceProfilesCard()
            SpeakerPrivacyNote()
        }
    }
}

/// Download, state, and removal of the detection model.
struct SpeakerModelCard: View {
    @ObservedObject var coordinator: SpeakerTranscriptCoordinator

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "premium.window.speakers.model.title"))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)

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
                        .accessibilityLabel(String(localized: "Error: \(error)"))
                }
            }
        }
    }
}

/// When speakers are detected without asking.
struct SpeakerAutomaticDetectionCard: View {
    @AppStorage(UserDefaultsKeys.calendarMeetingDetectSpeakers) private var detectsInCalendarMeetings = true

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "premium.window.speakers.automatic.title"))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)

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
    }
}

struct SpeakerPrivacyNote: View {
    var body: some View {
        Text(String(localized: "premium.window.speakers.privacy"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The people TypeWhisper recognizes by voice, with the recordings each
/// of them appears in.
struct VoiceProfilesCard: View {
    @ObservedObject private var voiceStore = ServiceContainer.shared.speakerVoiceProfileService.store
    @State private var deletedProfile: VoiceProfile?

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "premium.window.speakers.profiles.title"))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)

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
    }
}

/// One voice profile: rename in place, see what it was learned from and
/// where the person appears, delete.
private struct VoiceProfileRow: View {
    let profile: VoiceProfile
    let onDelete: () -> Void
    @State private var nameDraft = ""
    @State private var showsRecordings = false
    @FocusState private var isNameFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let service = ServiceContainer.shared.speakerVoiceProfileService
        let appearances = service.appearances(of: profile.id)
        VStack(alignment: .leading, spacing: 6) {
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
                        .accessibilityLabel(localizedAppText(
                            "Rename \(profile.name)",
                            de: "\(profile.name) umbenennen",
                            ja: "\(profile.name)の名前を変更",
                            zh: "重命名\(profile.name)",
                            es: "Renombrar \(profile.name)"
                        ))
                    Text(String.localizedStringWithFormat(
                        String(localized: "premium.window.speakers.profiles.learnedFormat"),
                        SpeakerTranscriptPresentation.timestamp(profile.enrolledSeconds),
                        Int64(appearances.count)
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if !appearances.isEmpty {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { showsRecordings.toggle() }
                    } label: {
                        Image(systemName: showsRecordings ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "speakers.page.profile.recordings"))
                    .accessibilityLabel(String(localized: "speakers.page.profile.recordings"))
                    .accessibilityValue(showsRecordings
                        ? localizedAppText("Expanded", de: "Ausgeklappt", ja: "展開", zh: "已展开")
                        : localizedAppText("Collapsed", de: "Eingeklappt", ja: "折りたたみ", zh: "已折叠"))
                }
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "premium.window.speakers.profiles.delete"))
                .accessibilityLabel(localizedAppText(
                    "Delete Voice Profile of \(profile.name)",
                    de: "Sprecherprofil von \(profile.name) löschen",
                    ja: "\(profile.name)の声のプロフィールを削除",
                    zh: "删除\(profile.name)的声音档案",
                    es: "Eliminar el perfil de voz de \(profile.name)"
                ))
            }

            if showsRecordings {
                ForEach(appearances) { appearance in
                    let speakingTime = SpeakerTranscriptPresentation.timestamp(
                        appearance.turns.reduce(0) { $0 + max(0, $1.end - $1.start) }
                    )
                    HStack(spacing: 8) {
                        // The magnifier badge marks a suggested, unconfirmed match.
                        Image(systemName: appearance.isSuggestion ? "waveform.badge.magnifyingglass" : "waveform")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(localizedAppText("Suggested", de: "Vorgeschlagen", ja: "提案", zh: "建议"))
                            .accessibilityHidden(!appearance.isSuggestion)
                        Text(appearance.title)
                            .lineLimit(1)
                        Text(appearance.date, format: .dateTime.day().month().year())
                            .foregroundStyle(.secondary)
                        Text(speakingTime)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .accessibilityLabel(String(localized: "speakers.speakingTime") + ": " + speakingTime)
                        Spacer()
                        Button(String(localized: "speakers.page.openInHistory")) {
                            SpeakerNavigation.openInHistory(appearance.recordID)
                        }
                        .buttonStyle(.link)
                        .accessibilityLabel(localizedAppText(
                            "Open \(appearance.title)",
                            de: "\(appearance.title) öffnen",
                            ja: "\(appearance.title)を開く",
                            zh: "打开\(appearance.title)",
                            es: "Abrir \(appearance.title)"
                        ))
                    }
                    .font(.caption)
                    .padding(.leading, 28)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(profile.name)
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

@MainActor
enum SpeakerNavigation {
    /// Opens the History window with the record selected, also when it is
    /// outside the loaded page or hidden by the mailbox or filters.
    static func openInHistory(
        _ recordID: UUID,
        in history: HistoryViewModel = .shared,
        openWindow: @MainActor () -> Void = { ManagedAppWindowOpener.shared.open(id: "history") }
    ) {
        history.requestOpenRecord(withID: recordID)
        openWindow()
    }
}
