import SwiftUI

/// The speaker workspace of a History record: transcript by speaker in the
/// middle, speakers on the right, timeline and transport at the bottom.
struct SpeakerWorkspaceView: View {
    let record: TranscriptionRecord
    let audioURL: URL?
    @ObservedObject var coordinator: SpeakerTranscriptCoordinator
    @StateObject private var model: SpeakerWorkspaceModel
    @Environment(\.undoManager) private var undoManager

    @State private var editedParagraph: SpeakerParagraph?
    @State private var textDraft = ""
    @State private var pendingSpeakerCount: SpeakerCountChoice?
    @FocusState private var isFocused: Bool

    private enum SpeakerCountChoice: Identifiable, Equatable {
        case automatic
        case fixed(Int)

        var id: Int { count ?? 0 }
        var count: Int? {
            if case .fixed(let count) = self { return count }
            return nil
        }
    }

    init(
        record: TranscriptionRecord,
        audioURL: URL?,
        coordinator: SpeakerTranscriptCoordinator,
        historyService: HistoryService
    ) {
        self.record = record
        self.audioURL = audioURL
        self.coordinator = coordinator
        _model = StateObject(wrappedValue: SpeakerWorkspaceModel(
            recordID: record.id,
            historyService: historyService,
            voices: coordinator.voices
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                transcript
                Divider()
                SpeakerInspector(
                    model: model,
                    coordinator: coordinator,
                    record: record,
                    hasAudio: audioURL != nil,
                    onDetectAgain: { pendingSpeakerCount = $0.map(SpeakerCountChoice.fixed) ?? .automatic }
                )
                .frame(width: 250)
            }
            if audioURL != nil {
                Divider()
                SpeakerTimelineView(model: model, playback: model.playback)
                SpeakerTransportBar(model: model, playback: model.playback)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(phases: .down, action: handleKey)
        .onAppear {
            isFocused = true
            if let audioURL { model.playback.load(url: audioURL) }
        }
        .onDisappear { model.playback.unload() }
        .onChange(of: audioURL) { _, url in
            if let url { model.playback.load(url: url) } else { model.playback.unload() }
        }
        .onChange(of: record.speakerTranscriptData) { model.reload() }
        .onChange(of: record.speakerNamesData) { model.reload() }
        .confirmationDialog(
            String(localized: "speakers.redetect.title"),
            isPresented: Binding(
                get: { pendingSpeakerCount != nil },
                set: { if !$0 { pendingSpeakerCount = nil } }
            ),
            presenting: pendingSpeakerCount
        ) { choice in
            Button(String(localized: "speakers.action.detectAgain"), role: .destructive) {
                model.playback.pause()
                coordinator.start(recordID: record.id, speakerCount: choice.count)
            }
        } message: { _ in
            Text(String(localized: "speakers.redetect.message"))
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.visibleRows) { row in
                        paragraphRow(row)
                            .id(row.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .modifier(FollowPlaybackOnScroll(followsPlayback: $model.followsPlayback))
            .overlay(alignment: .bottom) {
                if !model.followsPlayback, model.playback.isPlaying {
                    Button {
                        model.followsPlayback = true
                        if let id = model.activeParagraphID {
                            withAnimation { proxy.scrollTo(id, anchor: .center) }
                        }
                    } label: {
                        Label(String(localized: "speakers.playback.return"), systemImage: "arrow.down.to.line")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.bottom, 10)
                }
            }
            .onChange(of: model.activeParagraphID) { _, id in
                guard model.followsPlayback, model.playback.isPlaying, let id else { return }
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func paragraphRow(_ row: SpeakerWorkspaceModel.Row) -> some View {
        let paragraph = row.paragraph
        let isSelected = model.selectedTurns.contains(paragraph.turnIndex)
        let isActive = model.activeParagraphID == paragraph.id
        return VStack(alignment: .leading, spacing: 3) {
            if row.startsTurn {
                HStack(spacing: 6) {
                    SpeakerBadge(speakerID: paragraph.speakerID, name: model.names?.displayName(for: paragraph.speakerID))
                    Text(model.name(of: paragraph.speakerID))
                        .font(.subheadline.weight(.semibold))
                    if model.names?.isSuggestion(for: paragraph.speakerID) == true {
                        Image(systemName: "waveform.badge.magnifyingglass")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 10)
                .contentShape(Rectangle())
                .onTapGesture {
                    model.select(
                        turn: paragraph.turnIndex,
                        extending: NSEvent.modifierFlags.contains(.shift),
                        toggling: NSEvent.modifierFlags.contains(.command)
                    )
                }
                .help(String(localized: "speakers.select.help"))
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(SpeakerTranscriptPresentation.timestamp(paragraph.start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    .frame(width: 46, alignment: .trailing)
                Text(paragraphText(paragraph, isActive: isActive))
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isActive ? Color.accentColor.opacity(0.16) : .clear)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                if NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) {
                    model.select(
                        turn: paragraph.turnIndex,
                        extending: NSEvent.modifierFlags.contains(.shift),
                        toggling: NSEvent.modifierFlags.contains(.command)
                    )
                } else if audioURL != nil {
                    model.followsPlayback = true
                    model.playback.play(from: paragraph.start)
                }
            }
            .popover(isPresented: Binding(
                get: { editedParagraph?.id == paragraph.id },
                set: { if !$0 { editedParagraph = nil } }
            )) {
                textEditor(for: paragraph)
            }
        }
        .padding(.leading, 6)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(isSelected ? Color.accentColor : SpeakerBadge.color(for: paragraph.speakerID).opacity(0.35))
                .frame(width: isSelected ? 3 : 2)
        }
        .background(isSelected ? Color.accentColor.opacity(0.07) : .clear)
        .contextMenu { paragraphMenu(paragraph, startsTurn: row.startsTurn) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.name(of: paragraph.speakerID)), \(SpeakerTranscriptPresentation.timestamp(paragraph.start)), \(paragraph.text)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The paragraph's text, with the word being spoken marked while it plays.
    private func paragraphText(_ paragraph: SpeakerParagraph, isActive: Bool) -> AttributedString {
        var text = AttributedString(paragraph.text)
        guard isActive, let wordRange = model.activeWordRange,
              let range = Range(wordRange, in: paragraph.text),
              let lower = AttributedString.Index(range.lowerBound, within: text),
              let upper = AttributedString.Index(range.upperBound, within: text) else { return text }
        text[lower..<upper].backgroundColor = Color.accentColor.opacity(0.45)
        return text
    }

    @ViewBuilder
    private func paragraphMenu(_ paragraph: SpeakerParagraph, startsTurn: Bool) -> some View {
        let canCorrect = coordinator.hasPremiumAccess
        let turnIndexes = model.actionTurns(for: paragraph.turnIndex)
        if audioURL != nil {
            Button(String(localized: "speakers.action.playFromHere")) {
                model.playback.play(from: paragraph.start)
            }
            Divider()
        }
        Menu(turnIndexes.count > 1
            ? String(localized: "speakers.action.assignSelection")
            : String(localized: "speakers.action.assign")) {
            ForEach(model.speakerIDs, id: \.self) { speakerID in
                Button(model.name(of: speakerID)) {
                    model.assign(turns: turnIndexes, to: speakerID, undoManager: undoManager)
                }
                .disabled(turnIndexes.count == 1 && speakerID == paragraph.speakerID)
            }
            Divider()
            Button(String(localized: "speakers.action.newSpeaker")) {
                model.assign(turns: turnIndexes, to: nil, undoManager: undoManager)
            }
        }
        .disabled(!canCorrect)
        if !startsTurn {
            Menu(String(localized: "speakers.action.split")) {
                ForEach(model.speakerIDs.filter { $0 != paragraph.speakerID }, id: \.self) { speakerID in
                    Button(model.name(of: speakerID)) {
                        model.split(at: paragraph, to: speakerID, undoManager: undoManager)
                    }
                }
                Divider()
                Button(String(localized: "speakers.action.newSpeaker")) {
                    model.split(at: paragraph, to: nil, undoManager: undoManager)
                }
            }
            .disabled(!canCorrect)
        }
        if let turn = model.turnAtPlayhead, turn.index == paragraph.turnIndex {
            Menu(String(localized: "speakers.action.splitAtPlayhead")) {
                ForEach(model.speakerIDs.filter { $0 != paragraph.speakerID }, id: \.self) { speakerID in
                    Button(model.name(of: speakerID)) {
                        model.splitAtPlayhead(to: speakerID, undoManager: undoManager)
                    }
                }
                Divider()
                Button(String(localized: "speakers.action.newSpeaker")) {
                    model.splitAtPlayhead(to: nil, undoManager: undoManager)
                }
            }
            .disabled(!canCorrect)
        }
        Button(String(localized: "speakers.action.editText")) {
            textDraft = paragraph.text
            editedParagraph = paragraph
        }
        .disabled(!canCorrect)
        Divider()
        Button(String(localized: "speakers.filter.show")) {
            model.filteredSpeaker = paragraph.speakerID
        }
        if !canCorrect {
            Divider()
            Button(String(localized: "speakers.premium.required")) {
                SettingsNavigationCoordinator.shared.navigate(to: .premium)
            }
        }
    }

    private func textEditor(for paragraph: SpeakerParagraph) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextEditor(text: $textDraft)
                .font(.body)
                .frame(width: 420, height: 140)
            HStack {
                Button(String(localized: "Cancel")) { editedParagraph = nil }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Save")) {
                    model.edit(paragraph, text: textDraft, undoManager: undoManager)
                    editedParagraph = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }

    // MARK: - Keyboard

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard editedParagraph == nil else { return .ignored }
        let playback = model.playback
        switch press.key {
        case .space:
            playback.togglePlayPause()
        case .leftArrow:
            press.modifiers.contains(.option) ? model.playTurn(offset: -1) : playback.skip(by: -5)
        case .rightArrow:
            press.modifiers.contains(.option) ? model.playTurn(offset: 1) : playback.skip(by: 5)
        case .upArrow where press.modifiers.contains(.command):
            playback.stepRate(by: 1)
        case .downArrow where press.modifiers.contains(.command):
            playback.stepRate(by: -1)
        case .escape:
            guard !model.selectedTurns.isEmpty || model.filteredSpeaker != nil else { return .ignored }
            model.selectedTurns = []
            model.filteredSpeaker = nil
        default:
            // 1–9 give the selected turns to that speaker.
            guard press.modifiers.isEmpty,
                  let number = Int(press.characters), (1...9).contains(number),
                  !model.selectedTurns.isEmpty,
                  coordinator.hasPremiumAccess,
                  model.speakerIDs.indices.contains(number - 1) else { return .ignored }
            model.assign(
                turns: model.selectedTurns.sorted(),
                to: model.speakerIDs[number - 1],
                undoManager: undoManager
            )
        }
        return .handled
    }
}

/// Stops following playback when the user scrolls the transcript.
private struct FollowPlaybackOnScroll: ViewModifier {
    @Binding var followsPlayback: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollPhaseChange { _, phase in
                if phase == .interacting || phase == .tracking { followsPlayback = false }
            }
        } else {
            content
        }
    }
}

// MARK: - Inspector

private struct SpeakerInspector: View {
    @ObservedObject var model: SpeakerWorkspaceModel
    @ObservedObject var coordinator: SpeakerTranscriptCoordinator
    let record: TranscriptionRecord
    let hasAudio: Bool
    let onDetectAgain: (Int?) -> Void
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(String(localized: "speakers.view.speakers"))
                    .font(.headline)
                Spacer()
                if model.filteredSpeaker != nil {
                    Button(String(localized: "speakers.filter.clear")) { model.filteredSpeaker = nil }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(model.speakerIDs, id: \.self) { speakerID in
                        SpeakerInspectorRow(
                            model: model,
                            speakerID: speakerID,
                            share: model.shares.first { $0.speakerID == speakerID },
                            hasAudio: hasAudio,
                            canCorrect: coordinator.hasPremiumAccess
                        )
                    }
                }
                .padding(.horizontal, 8)
            }

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Menu {
                    let startError = coordinator.startError(for: record)
                    Section(String(localized: "speakers.count.title")) {
                        Button(String(localized: "speakers.count.automatic")) { onDetectAgain(nil) }
                        ForEach(coordinator.selectableSpeakerCounts, id: \.self) { count in
                            Button(count.formatted()) { onDetectAgain(count) }
                        }
                    }
                    .disabled(startError != nil)
                    if startError == .premiumRequired {
                        Button(String(localized: "speakers.premium.required")) {
                            SettingsNavigationCoordinator.shared.navigate(to: .premium)
                        }
                    }
                } label: {
                    Label(String(localized: "speakers.action.detectAgain"), systemImage: "person.2.badge.gearshape")
                }
                .menuStyle(.borderlessButton)

                Menu {
                    Button(String(localized: "speakers.action.copyWithNames")) { model.copyWithNames() }
                    Divider()
                    ForEach(SpeakerTranscriptExportFormat.allCases) { format in
                        Button(format.displayName) { model.export(format, title: record.appName) }
                    }
                } label: {
                    Label(String(localized: "speakers.export.title"), systemImage: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
            }
            .padding(12)
        }
        .background(.bar)
    }
}

private struct SpeakerInspectorRow: View {
    @ObservedObject var model: SpeakerWorkspaceModel
    let speakerID: String
    let share: SpeakerShare?
    let hasAudio: Bool
    let canCorrect: Bool
    @Environment(\.undoManager) private var undoManager
    @State private var nameDraft = ""
    @State private var confirmsEnrollment = false
    @FocusState private var isNameFocused: Bool

    var body: some View {
        let isFiltered = model.filteredSpeaker == speakerID
        let voiceState = model.voiceState(of: speakerID)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                SpeakerBadge(speakerID: speakerID, name: model.names?.displayName(for: speakerID))
                TextField(SpeakerTranscriptPresentation.defaultName(for: speakerID), text: $nameDraft)
                    .textFieldStyle(.plain)
                    .font(.subheadline.weight(.medium))
                    .focused($isNameFocused)
                    .onSubmit { commitName() }
                    .onChange(of: isNameFocused) { _, focused in
                        if !focused { commitName() }
                    }
                    .disabled(!canCorrect)
                    .accessibilityLabel(String(localized: "speakers.rename.help"))
                if voiceState == .linked {
                    Image(systemName: "person.wave.2")
                        .foregroundStyle(.secondary)
                        .help(String(localized: "speakers.voice.linked"))
                        .accessibilityLabel(String(localized: "speakers.voice.linked"))
                }
            }

            if voiceState == .suggestion {
                VStack(alignment: .leading, spacing: 4) {
                    Label(String(localized: "speakers.voice.recognized"), systemImage: "waveform.badge.magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Button(String(localized: "speakers.voice.confirm")) { model.confirmVoice(of: speakerID) }
                        Button(String(localized: "speakers.voice.reject")) { model.rejectVoice(of: speakerID) }
                    }
                    .controlSize(.small)
                }
            }

            HStack(spacing: 4) {
                if let share {
                    Text(share.fraction, format: .percent.precision(.fractionLength(0)))
                    Text("·")
                    Text(SpeakerTranscriptPresentation.timestamp(share.seconds))
                }
                Spacer(minLength: 4)
                if hasAudio {
                    iconButton("play.circle", help: "speakers.excerpt.play") {
                        model.playExcerpt(of: speakerID)
                    }
                    toggleButton("S", isOn: model.soloedSpeakers.contains(speakerID), help: "speakers.playback.solo") {
                        model.toggleSolo(speakerID)
                    }
                    toggleButton("M", isOn: model.mutedSpeakers.contains(speakerID), help: "speakers.playback.mute") {
                        model.toggleMute(speakerID)
                    }
                }
                Menu {
                    Button(String(localized: isFiltered ? "speakers.filter.clear" : "speakers.filter.show")) {
                        model.filteredSpeaker = isFiltered ? nil : speakerID
                    }
                    Menu(String(localized: "speakers.action.merge")) {
                        ForEach(model.speakerIDs.filter { $0 != speakerID }, id: \.self) { other in
                            Button(model.name(of: other)) {
                                model.merge(speakerID, into: other, undoManager: undoManager)
                            }
                        }
                    }
                    .disabled(!canCorrect || model.speakerIDs.count < 2)
                    if voiceState == .canEnroll {
                        Divider()
                        Button(String(localized: "speakers.voice.enroll")) { confirmsEnrollment = true }
                    } else if voiceState == .linked {
                        Divider()
                        Button(String(localized: "speakers.voice.relearn")) { model.relearnVoice(of: speakerID) }
                            .disabled(!canCorrect)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            if let share {
                ProgressView(value: share.fraction)
                    .tint(SpeakerBadge.color(for: speakerID))
                    .accessibilityHidden(true)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isFiltered ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04))
        )
        .opacity(model.isAudible(speakerID) ? 1 : 0.55)
        .confirmationDialog(
            String.localizedStringWithFormat(String(localized: "speakers.voice.enroll.title"), model.name(of: speakerID)),
            isPresented: $confirmsEnrollment
        ) {
            Button(String(localized: "speakers.voice.enroll.action")) { model.enrollVoice(of: speakerID) }
        } message: {
            Text(String(localized: "speakers.voice.enroll.message"))
        }
        .onAppear { nameDraft = model.names?.displayName(for: speakerID) ?? "" }
        .onChange(of: model.names) { _, names in
            if !isNameFocused { nameDraft = names?.displayName(for: speakerID) ?? "" }
        }
    }

    private func commitName() {
        model.rename(speakerID, to: nameDraft, undoManager: undoManager)
        nameDraft = model.names?.displayName(for: speakerID) ?? ""
    }

    private func iconButton(_ systemImage: String, help: String.LocalizationValue, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: systemImage) }
            .buttonStyle(.borderless)
            .help(String(localized: help))
            .accessibilityLabel(String(localized: help))
    }

    private func toggleButton(_ title: String, isOn: Bool, help: String.LocalizationValue, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption2.weight(.bold))
                .frame(width: 18, height: 18)
                .foregroundStyle(isOn ? Color.white : .secondary)
                .background(RoundedRectangle(cornerRadius: 4).fill(isOn ? Color.accentColor : Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help(String(localized: help))
        .accessibilityLabel(String(localized: help))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: - Timeline

private struct SpeakerTimelineView: View {
    @ObservedObject var model: SpeakerWorkspaceModel
    @ObservedObject var playback: SpeakerPlaybackController

    private let laneHeight: CGFloat = 12
    private let laneSpacing: CGFloat = 3
    private let labelWidth: CGFloat = 26

    var body: some View {
        let speakers = model.speakerIDs
        let height = CGFloat(speakers.count) * (laneHeight + laneSpacing) + laneSpacing
        HStack(alignment: .top, spacing: 6) {
            VStack(spacing: laneSpacing) {
                ForEach(speakers, id: \.self) { speakerID in
                    SpeakerBadge(speakerID: speakerID, name: model.names?.displayName(for: speakerID))
                        .scaleEffect(laneHeight / 18)
                        .frame(width: laneHeight, height: laneHeight)
                        .opacity(model.isAudible(speakerID) ? 1 : 0.4)
                }
            }
            .padding(.top, laneSpacing)
            .frame(width: labelWidth)

            GeometryReader { geometry in
                let width = geometry.size.width
                let duration = max(playback.duration, model.turns.last?.end ?? 0, 0.001)
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        for (lane, speakerID) in speakers.enumerated() {
                            let y = laneSpacing + CGFloat(lane) * (laneHeight + laneSpacing)
                            let track = CGRect(x: 0, y: y, width: size.width, height: laneHeight)
                            context.fill(Path(roundedRect: track, cornerRadius: 3), with: .color(.primary.opacity(0.05)))
                            let color = SpeakerBadge.color(for: speakerID).opacity(model.isAudible(speakerID) ? 0.9 : 0.3)
                            for turn in model.turns where turn.speakerID == speakerID {
                                let x = size.width * turn.start / duration
                                let turnWidth = max(1.5, size.width * (turn.end - turn.start) / duration)
                                let rect = CGRect(x: x, y: y, width: turnWidth, height: laneHeight)
                                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color))
                            }
                        }
                    }
                    Rectangle()
                        .fill(Color.primary)
                        .frame(width: 1.5, height: height)
                        .offset(x: width * min(max(playback.currentTime / duration, 0), 1))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            model.followsPlayback = true
                            playback.seek(to: duration * min(max(value.location.x / width, 0), 1))
                        }
                )
            }
            .frame(height: height)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .accessibilityElement()
        .accessibilityLabel(String(localized: "speakers.timeline.title"))
        .accessibilityValue(SpeakerTranscriptPresentation.timestamp(playback.currentTime))
        .accessibilityAdjustableAction { direction in
            playback.skip(by: direction == .increment ? 5 : -5)
        }
    }
}

// MARK: - Transport

private struct SpeakerTransportBar: View {
    @ObservedObject var model: SpeakerWorkspaceModel
    @ObservedObject var playback: SpeakerPlaybackController

    var body: some View {
        HStack(spacing: 14) {
            button("backward.end.fill", help: "speakers.playback.previousTurn") { model.playTurn(offset: -1) }
            button("gobackward.5", help: "speakers.playback.back") { playback.skip(by: -5) }
            Button {
                playback.togglePlayPause()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 24)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(playback.isPlaying ? String(localized: "Pause") : String(localized: "Play"))
            button("goforward.5", help: "speakers.playback.forward") { playback.skip(by: 5) }
            button("forward.end.fill", help: "speakers.playback.nextTurn") { model.playTurn(offset: 1) }

            Text(SpeakerTranscriptPresentation.timestamp(playback.currentTime)
                + " / " + SpeakerTranscriptPresentation.timestamp(playback.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Toggle(String(localized: "speakers.playback.skipSilence"), isOn: $model.skipsSilence)
                .toggleStyle(.checkbox)
                .font(.caption)

            Menu {
                ForEach(SpeakerPlaybackController.rates, id: \.self) { rate in
                    Button {
                        playback.setRate(rate)
                    } label: {
                        if rate == playback.rate {
                            Label(Self.rateTitle(rate), systemImage: "checkmark")
                        } else {
                            Text(Self.rateTitle(rate))
                        }
                    }
                }
            } label: {
                Text(Self.rateTitle(playback.rate))
                    .font(.caption.monospacedDigit())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(String(localized: "speakers.playback.speed"))
            .accessibilityLabel(String(localized: "speakers.playback.speed"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private static func rateTitle(_ rate: Float) -> String {
        rate.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    private func button(_ systemImage: String, help: String.LocalizationValue, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: systemImage) }
            .buttonStyle(.borderless)
            .help(String(localized: help))
            .accessibilityLabel(String(localized: help))
    }
}
