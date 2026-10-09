import SwiftUI
import UniformTypeIdentifiers
import TypeWhisperPluginSDK

/// The home of speaker detection: add recordings and watch them turn into
/// speaker transcripts, manage the people recognized by voice, and choose
/// where speakers are detected without asking.
struct SpeakersView: View {
    enum Section: String, CaseIterable, Identifiable {
        case recordings, people, setup

        var id: String { rawValue }

        var title: String {
            switch self {
            case .recordings: String(localized: "speakers.page.tab.recordings")
            case .people: String(localized: "speakers.page.tab.people")
            case .setup: String(localized: "speakers.page.tab.setup")
            }
        }
    }

    @ObservedObject private var viewModel = ServiceContainer.shared.speakerTranscriptionViewModel
    @ObservedObject private var coordinator = ServiceContainer.shared.speakerTranscriptCoordinator
    @ObservedObject private var historyService = ServiceContainer.shared.historyService
    @ObservedObject private var license = ServiceContainer.shared.licenseService
    @ObservedObject private var premiumAccount = ServiceContainer.shared.premiumAccountService
    @ObservedObject private var recorder = AudioRecorderViewModel.shared
    @ObservedObject private var watchFolders = ServiceContainer.shared.watchFolderViewModel
    @ObservedObject private var voiceStore = ServiceContainer.shared.speakerVoiceProfileService.store
    @AppStorage(UserDefaultsKeys.calendarMeetingDetectSpeakers) private var detectsInCalendarMeetings = true

    @State private var section: Section = .recordings
    @State private var isDragTargeted = false
    @State private var showFilePicker = false
    @State private var deletedProfile: VoiceProfile?

    private static let shownRecordings = 30

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
            ) {
                if hasAccess {
                    Picker(String(localized: "speakers.page.title"), selection: $section) {
                        ForEach(Section.allCases) { section in
                            Text(section.title).tag(section)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: SettingsLayoutMetrics.sectionSpacing) {
                    if !hasAccess {
                        lockedCard
                        howItWorks
                        recordingsList
                    } else {
                        switch section {
                        case .recordings: recordingsTab
                        case .people: peopleTab
                        case .setup: setupTab
                        }
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
                add(urls)
            }
        }
        .onChange(of: viewModel.batchState) { _, state in
            switch state {
            case .cancelled:
                // Cancelling stops one file; the rest of the queue carries on.
                for item in viewModel.files where item.state == .cancelled {
                    viewModel.removeFile(item)
                }
                startPending()
            case .done:
                startPending()
            default:
                break
            }
        }
        .onChange(of: viewModel.engineChoice) { _, _ in
            startPending()
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

    // MARK: - Recordings

    private struct RowModel: Identifiable {
        let id: UUID
        let file: FileTranscriptionViewModel.FileItem?
        let record: TranscriptionRecord?
    }

    /// Files added on this page first, in queue order, then the other
    /// recordings with speakers from History.
    private var rowModels: [RowModel] {
        // Reading `recentRecords` keeps the list current when History changes.
        _ = historyService.recentRecords.count
        var claimed = Set<UUID>()
        var models = viewModel.files.map { item in
            let record = item.historyRecordID.flatMap { historyService.record(withID: $0) }
            if let record { claimed.insert(record.id) }
            return RowModel(id: item.id, file: item, record: record)
        }
        models += historyService.speakerRecords(limit: Self.shownRecordings)
            .filter { !claimed.contains($0.id) }
            .map { RowModel(id: $0.id, file: nil, record: $0) }
        return models
    }

    @ViewBuilder
    private var recordingsTab: some View {
        addCard
        if rowModels.isEmpty {
            howItWorks
        } else {
            recordingsList
        }
    }

    private var engineIsReady: Bool {
        viewModel.resolvedEngine.map { viewModel.canUseForTranscription($0) } ?? false
    }

    private var addCard: some View {
        HStack(spacing: 14) {
            Image(systemName: isDragTargeted ? "arrow.down" : "person.2.wave.2.fill")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(Circle().fill(Color.purple.gradient))
                .scaleEffect(isDragTargeted ? 1.12 : 1)
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(String(localized: isDragTargeted ? "speakers.page.add.drop" : "speakers.page.add.title"))
                    .font(.headline)
                Text(String(localized: "speakers.page.add.description"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !engineIsReady {
                    Label(String(localized: "speakers.page.engine.notReady"), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 6) {
                Button(String(localized: "Choose Files...")) {
                    showFilePicker = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                engineMenu
            }
        }
        .padding(SettingsLayoutMetrics.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: SettingsLayoutMetrics.cardCornerRadius, style: .continuous)
                .fill(Color.purple.opacity(isDragTargeted ? 0.16 : 0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsLayoutMetrics.cardCornerRadius, style: .continuous)
                .strokeBorder(
                    Color.purple.opacity(isDragTargeted ? 1 : 0.35),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                )
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isDragTargeted)
    }

    private var engineMenu: some View {
        Menu {
            Picker(String(localized: "Engine"), selection: $viewModel.engineChoice) {
                Text(String(localized: "Default Engine")).tag(nil as String?)
                Divider()
                ForEach(viewModel.availableEngines, id: \.providerId) { engine in
                    Text(engine.providerDisplayName)
                        .tag(engine.providerId as String?)
                        .disabled(!viewModel.canUseForTranscription(engine))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(verbatim: "\(String(localized: "Engine")): \(viewModel.resolvedEngine?.providerDisplayName ?? String(localized: "Default Engine"))")
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize()
        .disabled(viewModel.batchState == .processing)
    }

    private var howItWorks: some View {
        HStack(alignment: .top, spacing: SettingsLayoutMetrics.cardSpacing) {
            howStep(
                "square.and.arrow.down",
                String(localized: "speakers.page.add.title"),
                String(localized: "speakers.page.how.add")
            )
            howStep(
                "person.crop.circle.badge.checkmark",
                String(localized: "speakers.page.how.name.title"),
                String(localized: "speakers.page.how.name")
            )
            howStep(
                "person.wave.2",
                String(localized: "speakers.page.how.recognize.title"),
                String(localized: "speakers.page.how.recognize")
            )
        }
    }

    private func howStep(_ systemImage: String, _ title: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.purple)
                .frame(height: 26)
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(SettingsLayoutMetrics.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: SettingsLayoutMetrics.cardCornerRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    @ViewBuilder
    private var recordingsList: some View {
        let models = rowModels
        if !models.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "speakers.page.recordings.title"))
                    .font(.headline)

                VStack(spacing: 0) {
                    ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                        if index > 0 {
                            Divider().padding(.leading, 62)
                        }
                        row(model)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: SettingsLayoutMetrics.cardCornerRadius, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .clipShape(RoundedRectangle(cornerRadius: SettingsLayoutMetrics.cardCornerRadius, style: .continuous))
                .animation(.spring(response: 0.4, dampingFraction: 0.85), value: models.map(\.id))
            }
        }
    }

    @ViewBuilder
    private func row(_ model: RowModel) -> some View {
        if let record = model.record {
            recordRow(record, isFresh: model.file != nil)
        } else if let item = model.file {
            fileRow(item)
        }
    }

    private func recordRow(_ record: TranscriptionRecord, isFresh: Bool) -> some View {
        let phase = phase(of: record)
        let isWorking = coordinator.stages[record.id] != nil
        var canRetry = false
        if case .failed = phase { canRetry = coordinator.startError(for: record) == nil }
        return SpeakerRecordingRow(
            title: record.appName ?? record.source.displayName,
            detail: [
                record.timestamp.formatted(date: .abbreviated, time: .shortened),
                SpeakerTranscriptPresentation.timestamp(record.durationSeconds),
            ].joined(separator: " · "),
            systemImage: record.source == .recorder ? "mic.fill" : "doc.fill",
            phase: phase,
            isFresh: isFresh,
            onOpen: { SpeakerNavigation.openInHistory(record.id) },
            onCancel: isWorking ? { coordinator.cancel(recordID: record.id) } : nil,
            onRetry: canRetry ? { _ = coordinator.start(recordID: record.id) } : nil
        )
    }

    private func phase(of record: TranscriptionRecord) -> SpeakerRecordingRow.Phase {
        switch coordinator.stages[record.id] {
        case .waiting:
            return .working(step: 2, detail: String(localized: "speakers.status.waiting"), fraction: nil)
        case .transcribing:
            return .working(step: 1, detail: String(localized: "speakers.status.transcribing"), fraction: nil)
        case .downloadingModels:
            return .working(step: 2, detail: String(localized: "speakers.status.downloadingModel"), fraction: nil)
        case .detecting(let fraction):
            return .working(step: 2, detail: "", fraction: fraction)
        case nil:
            break
        }
        switch record.speakerTranscriptState {
        case .ready: return .ready(NamedSpeakerShare.shares(of: record))
        case .pending: return .queued
        case .failed, nil: return .failed(String(localized: "speakers.status.failed"))
        }
    }

    private func fileRow(_ item: FileTranscriptionViewModel.FileItem) -> some View {
        let isProcessing = viewModel.batchState == .processing
        let remove: (() -> Void)? = isProcessing ? nil : { viewModel.removeFile(item) }
        let phase: SpeakerRecordingRow.Phase
        var onCancel: (() -> Void)?
        var onRetry: (() -> Void)?
        var onRemove: (() -> Void)?
        switch item.state {
        case .pending, .cancelled:
            phase = .queued
            onRemove = remove
        case .loading:
            phase = .working(step: 1, detail: item.phaseDescription ?? "", fraction: nil)
            onCancel = { viewModel.cancelTranscription() }
        case .transcribing:
            phase = .working(step: 1, detail: item.progressText ?? "", fraction: item.progressFraction)
            onCancel = { viewModel.cancelTranscription() }
        case .error:
            phase = .failed(item.errorMessage ?? String(localized: "Error"))
            onRetry = isProcessing ? nil : { viewModel.transcribeAll() }
            onRemove = remove
        case .done:
            phase = .failed(String(localized: "speakers.page.file.notSaved"))
            onRemove = remove
        }
        return SpeakerRecordingRow(
            title: item.fileName,
            detail: "",
            systemImage: "doc.fill",
            phase: phase,
            onCancel: onCancel,
            onRetry: onRetry,
            onRemove: onRemove
        )
    }

    // MARK: - People

    @ViewBuilder
    private var peopleTab: some View {
        if voiceStore.profiles.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "person.wave.2")
                    .font(.system(size: 34))
                    .foregroundStyle(.purple)
                    .accessibilityHidden(true)
                Text(String(localized: "speakers.page.people.emptyTitle"))
                    .font(.headline)
                Text(String(localized: "speakers.page.people.empty"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .fixedSize(horizontal: false, vertical: true)
                Button(String(localized: "speakers.page.people.showRecordings")) {
                    section = .recordings
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 44)
        } else {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 250), spacing: SettingsLayoutMetrics.cardSpacing, alignment: .top)],
                alignment: .leading,
                spacing: SettingsLayoutMetrics.cardSpacing
            ) {
                ForEach(voiceStore.profiles) { profile in
                    SpeakerPersonCard(profile: profile) { deletedProfile = profile }
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

        Text(String(localized: "premium.window.speakers.profiles.footer"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: voiceStore.profiles.isEmpty ? .center : .leading)
    }

    // MARK: - Setup

    @ViewBuilder
    private var setupTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "speakers.page.sources.title"))
                .font(.headline)

            VStack(spacing: 0) {
                sourceRow(
                    "mic.fill",
                    String(localized: "speakers.page.sources.recorder.title"),
                    String(localized: "speakers.page.sources.recorder.caption"),
                    isOn: $recorder.detectSpeakers
                )
                Divider().padding(.leading, 50)
                sourceRow(
                    "calendar",
                    String(localized: "speakers.page.sources.calendar.title"),
                    String(localized: "speakers.page.sources.calendar.caption"),
                    isOn: $detectsInCalendarMeetings
                )
                Divider().padding(.leading, 50)
                sourceRow(
                    "folder.fill",
                    String(localized: "speakers.page.sources.watch.title"),
                    String(localized: "speakers.page.sources.watch.caption"),
                    isOn: $watchFolders.detectSpeakers
                )
            }
            .background(
                RoundedRectangle(cornerRadius: SettingsLayoutMetrics.cardCornerRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            Text(String(localized: "speakers.page.sources.description"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        SpeakerModelCard(coordinator: coordinator)
        SpeakerPrivacyNote()
    }

    private func sourceRow(_ systemImage: String, _ title: String, _ caption: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.purple)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Adding files

    /// Adds the files and starts on them right away.
    private func add(_ urls: [URL]) {
        viewModel.addFiles(urls)
        section = .recordings
        startPending()
    }

    /// Files added while a batch runs are picked up when it ends.
    private func startPending() {
        guard viewModel.files.contains(where: { $0.state == .pending }) else { return }
        viewModel.transcribePending()
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil),
                      AudioFileService.supportedExtensions.contains(url.pathExtension.lowercased()) else { return }
                Task { @MainActor in
                    add([url])
                }
            }
            handled = true
        }
        return handled
    }
}
