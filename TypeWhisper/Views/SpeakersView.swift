import SwiftUI
import UniformTypeIdentifiers
import TypeWhisperPluginSDK

/// The home of speaker detection: transcribe files by speaker, open the
/// recordings that have speakers, and manage the people recognized by voice.
struct SpeakersView: View {
    @ObservedObject private var viewModel = ServiceContainer.shared.speakerTranscriptionViewModel
    @ObservedObject private var coordinator = ServiceContainer.shared.speakerTranscriptCoordinator
    @ObservedObject private var historyService = ServiceContainer.shared.historyService
    @ObservedObject private var license = ServiceContainer.shared.licenseService
    @ObservedObject private var premiumAccount = ServiceContainer.shared.premiumAccountService
    @ObservedObject private var recorder = AudioRecorderViewModel.shared

    @State private var isDragTargeted = false
    @State private var showFilePicker = false

    private var hasAccess: Bool {
        SpeakerWorkspacePremiumAccess.isGranted(
            hasCommercialLicense: license.hasCommercialLicense,
            hasPremiumEntitlement: premiumAccount.hasPremiumEntitlement
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsPageHeader(
                String(localized: "speakers.page.title"),
                summary: String(localized: "speakers.page.summary")
            )
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: SettingsLayoutMetrics.sectionSpacing) {
                    if hasAccess {
                        transcribeSection
                        recordingsSection
                        VoiceProfilesCard()
                        sourcesCard
                        SpeakerModelCard(coordinator: coordinator)
                        SpeakerPrivacyNote()
                    } else {
                        lockedCard
                        recordingsSection
                    }
                }
                .padding(SettingsLayoutMetrics.pagePadding)
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .onDrop(of: [.fileURL], isTargeted: $isDragTargeted) { providers in
            guard hasAccess else { return false }
            return handleDrop(providers)
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: FileTranscriptionViewModel.allowedContentTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                viewModel.addFiles(urls)
            }
        }
    }

    // MARK: - Locked

    private var lockedCard: some View {
        SettingsCard(accent: .purple) {
            VStack(alignment: .leading, spacing: 10) {
                Label(String(localized: "speakers.premium.required"), systemImage: "lock")
                    .font(.headline)
                Text(String(localized: "premium.hub.speakers.description"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(String(localized: "speakers.premium.open")) {
                    SettingsNavigationCoordinator.shared.navigate(to: .premium)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Transcribe files

    @ViewBuilder
    private var transcribeSection: some View {
        if viewModel.files.isEmpty {
            dropZone
        } else {
            VStack(alignment: .leading, spacing: SettingsLayoutMetrics.cardSpacing) {
                ForEach(viewModel.files) { item in
                    fileRow(item)
                }
                controls
            }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.2.wave.2")
                .font(.largeTitle)
                .foregroundStyle(isDragTargeted ? .blue : .secondary)
                .accessibilityHidden(true)
            Text(String(localized: "speakers.page.drop.title"))
                .font(.headline)
            Text(String(localized: "speakers.page.drop.description"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(String(localized: "Choose Files...")) {
                showFilePicker = true
            }
            .buttonStyle(.bordered)
            Text(String(localized: "WAV, MP3, M4A, FLAC, MP4, MOV"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: SettingsLayoutMetrics.cardCornerRadius)
                .fill(isDragTargeted ? Color.blue.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: SettingsLayoutMetrics.cardCornerRadius)
                        .strokeBorder(
                            isDragTargeted ? Color.blue : Color.secondary.opacity(0.3),
                            style: StrokeStyle(lineWidth: 2, dash: [8])
                        )
                )
        )
    }

    private func fileRow(_ item: FileTranscriptionViewModel.FileItem) -> some View {
        let recordID = item.historyRecordID
        let stage = recordID.flatMap { coordinator.stages[$0] }
        let record = recordID.flatMap { historyService.record(withID: $0) }
        return HStack(spacing: 8) {
            switch item.state {
            case .loading, .transcribing:
                ProgressView().controlSize(.small)
            case .done where stage != nil:
                ProgressView().controlSize(.small)
            case .done:
                Image(systemName: record?.speakerTranscriptState == .ready ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(record?.speakerTranscriptState == .ready ? .green : .orange)
            case .error:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            case .pending, .cancelled:
                Image(systemName: "circle").foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(item.fileName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(status(of: item, stage: stage, record: record))
                    .font(.caption)
                    .foregroundStyle(item.state == .error ? .red : .secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let recordID, record != nil {
                Button(String(localized: "speakers.page.openInHistory")) {
                    SpeakerNavigation.openInHistory(recordID)
                }
                .controlSize(.small)
            }
            if viewModel.batchState != .processing {
                Button {
                    viewModel.removeFile(item)
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Remove \(item.fileName)"))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: SettingsLayoutMetrics.cardCornerRadius)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func status(
        of item: FileTranscriptionViewModel.FileItem,
        stage: SpeakerTranscriptCoordinator.Stage?,
        record: TranscriptionRecord?
    ) -> String {
        if let error = item.errorMessage { return error }
        switch stage {
        case .waiting: return String(localized: "speakers.status.waiting")
        case .transcribing: return String(localized: "speakers.status.transcribing")
        case .downloadingModels: return String(localized: "speakers.status.downloadingModel")
        case .detecting: return String(localized: "speakers.status.detecting")
        case nil: break
        }
        guard item.state == .done else {
            return item.phaseDescription ?? String(localized: "Pending")
        }
        guard let record else { return String(localized: "speakers.page.file.notSaved") }
        return Self.speakerSummary(of: record)
    }

    /// "3 speakers" for a finished record, or why there are none.
    static func speakerSummary(of record: TranscriptionRecord) -> String {
        switch record.speakerTranscriptState {
        case .ready:
            String.localizedStringWithFormat(
                String(localized: "speakers.page.speakerCount"),
                Int64(record.speakerTranscript?.speakerIDs.count ?? 0)
            )
        case .pending:
            String(localized: "speakers.status.waiting")
        case .failed, nil:
            String(localized: "speakers.status.failed")
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(String(localized: "Engine"), selection: $viewModel.selectedEngine) {
                Text(String(localized: "Default Engine")).tag(nil as String?)
                Divider()
                ForEach(viewModel.availableEngines, id: \.providerId) { engine in
                    Text(engine.providerDisplayName)
                        .tag(engine.providerId as String?)
                        .disabled(!viewModel.canUseForTranscription(engine))
                }
            }
            .controlSize(.small)
            .frame(maxWidth: 320)
            .disabled(viewModel.batchState == .processing)

            HStack {
                Button(String(localized: "Add Files...")) {
                    showFilePicker = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.batchState == .processing)

                Spacer()

                if viewModel.batchState == .processing {
                    Button(String(localized: "Cancel")) {
                        viewModel.cancelTranscription()
                    }
                    .controlSize(.small)
                } else {
                    Button(String(localized: "speakers.page.transcribe")) {
                        viewModel.transcribeAll()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!viewModel.canTranscribe)
                }
            }
        }
    }

    // MARK: - Recordings

    private var recordingsSection: some View {
        // Reading `recentRecords` keeps the list current when History changes.
        _ = historyService.recentRecords.count
        let records = historyService.speakerRecords(limit: 8)
        return SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "speakers.page.recordings.title"))
                    .font(.headline)

                if records.isEmpty {
                    Text(String(localized: "speakers.page.recordings.empty"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(records, id: \.id) { record in
                        HStack(spacing: 8) {
                            Image(systemName: record.source == .recorder ? "record.circle" : "doc")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(record.appName ?? record.source.displayName)
                                    .lineLimit(1)
                                Text(recordingDetail(of: record))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button(String(localized: "speakers.page.openInHistory")) {
                                SpeakerNavigation.openInHistory(record.id)
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    private func recordingDetail(of record: TranscriptionRecord) -> String {
        var parts = [
            record.timestamp.formatted(date: .abbreviated, time: .shortened),
            SpeakerTranscriptPresentation.timestamp(record.durationSeconds),
        ]
        if let stage = coordinator.stages[record.id] {
            parts.append(stage == .waiting
                ? String(localized: "speakers.status.waiting")
                : String(localized: "speakers.status.detecting"))
        } else {
            parts.append(Self.speakerSummary(of: record))
            if let names = record.speakerNames?.entries.map(\.displayName), !names.isEmpty {
                parts.append(names.joined(separator: ", "))
            }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Other sources

    private var sourcesCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "speakers.page.sources.title"))
                    .font(.headline)

                Toggle(String(localized: "speakers.page.sources.recorder"), isOn: $recorder.detectSpeakers)
                Toggle(
                    String(localized: "premium.window.speakers.automatic.calendarMeetings"),
                    isOn: Binding(
                        get: {
                            UserDefaults.standard.object(forKey: UserDefaultsKeys.calendarMeetingDetectSpeakers) as? Bool ?? true
                        },
                        set: { UserDefaults.standard.set($0, forKey: UserDefaultsKeys.calendarMeetingDetectSpeakers) }
                    )
                )

                Text(String(localized: "speakers.page.sources.description"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Drop handling

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil),
                      AudioFileService.supportedExtensions.contains(url.pathExtension.lowercased()) else { return }
                Task { @MainActor in
                    viewModel.addFiles([url])
                }
            }
            handled = true
        }
        return handled
    }
}
