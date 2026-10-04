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
            SpeakerStrip(
                model: model,
                coordinator: coordinator,
                record: record,
                hasAudio: audioURL != nil,
                onDetectAgain: { pendingSpeakerCount = $0.map(SpeakerCountChoice.fixed) ?? .automatic }
            )
            Divider()
            transcript
            if audioURL != nil {
                SpeakerPlayerBar(
                    model: model,
                    playback: model.playback,
                    title: record.appName ?? record.source.displayName
                )
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
                Group {
                    if isActive {
                        ActiveParagraphWords(
                            highlight: model.wordHighlight,
                            words: model.words(of: paragraph),
                            isPlayable: audioURL != nil
                        ) { play(paragraph, from: $0) }
                    } else {
                        SpeakerParagraphWords(
                            words: model.words(of: paragraph),
                            activeIndex: nil,
                            isPlayable: audioURL != nil
                        ) { play(paragraph, from: $0) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isActive ? Color.accentColor.opacity(0.08) : .clear)
            )
            .contentShape(Rectangle())
            // Clicks beside the words: the time and the empty rest of a line.
            .onTapGesture { play(paragraph, from: nil) }
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

    /// Plays from the clicked word, or from the paragraph's start for a click
    /// beside the words.
    private func play(_ paragraph: SpeakerParagraph, from word: SpeakerWorkspaceModel.WordToken?) {
        guard !selectWithModifiers(paragraph), audioURL != nil else { return }
        if let word {
            model.play(from: word)
        } else {
            model.followsPlayback = true
            model.playback.play(from: paragraph.start)
        }
    }

    /// Command- and Shift-clicks select the turn instead of playing.
    private func selectWithModifiers(_ paragraph: SpeakerParagraph) -> Bool {
        let flags = NSEvent.modifierFlags
        guard flags.contains(.command) || flags.contains(.shift) else { return false }
        model.select(
            turn: paragraph.turnIndex,
            extending: flags.contains(.shift),
            toggling: flags.contains(.command)
        )
        return true
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

/// The speakers of the recording as a row above the transcript. A speaker
/// opens its details: name, share, solo and mute, merging, voice.
private struct SpeakerStrip: View {
    @ObservedObject var model: SpeakerWorkspaceModel
    @ObservedObject var coordinator: SpeakerTranscriptCoordinator
    let record: TranscriptionRecord
    let hasAudio: Bool
    let onDetectAgain: (Int?) -> Void
    @AppStorage(UserDefaultsKeys.speakerStripCollapsed) private var isCollapsed = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.82)) { isCollapsed.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    if isCollapsed {
                        HStack(spacing: -5) {
                            ForEach(model.speakerIDs, id: \.self) { speakerID in
                                SpeakerBadge(speakerID: speakerID, name: model.names?.displayName(for: speakerID))
                            }
                        }
                        Text(verbatim: "\(String(localized: "speakers.view.speakers")) · \(model.speakerIDs.count)")
                            .font(.caption)
                    }
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(String(localized: isCollapsed ? "speakers.strip.show" : "speakers.strip.hide"))
            .accessibilityLabel(String(localized: isCollapsed ? "speakers.strip.show" : "speakers.strip.hide"))

            if isCollapsed {
                Spacer(minLength: 0)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(model.speakerIDs.enumerated()), id: \.element) { index, speakerID in
                            SpeakerChip(
                                model: model,
                                speakerID: speakerID,
                                share: model.shares.first { $0.speakerID == speakerID },
                                hasAudio: hasAudio,
                                canCorrect: coordinator.hasPremiumAccess
                            )
                            // The speakers come in from the left, one after the other.
                            .transition(
                                .asymmetric(
                                    insertion: .opacity
                                        .combined(with: .offset(x: -14))
                                        .animation(reduceMotion ? nil : .easeOut(duration: 0.25).delay(Double(index) * 0.05)),
                                    removal: .opacity
                                )
                            )
                        }
                    }
                    .padding(.vertical, 1)
                }
                .transition(.opacity)
            }

            if model.filteredSpeaker != nil {
                Button(String(localized: "speakers.filter.clear")) { model.filteredSpeaker = nil }
                    .buttonStyle(.link)
                    .font(.caption)
            }

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
                Image(systemName: "person.2.badge.gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(String(localized: "speakers.action.detectAgain"))
            .accessibilityLabel(String(localized: "speakers.action.detectAgain"))

            Menu {
                Button(String(localized: "speakers.action.copyWithNames")) { model.copyWithNames() }
                Divider()
                ForEach(SpeakerTranscriptExportFormat.allCases) { format in
                    Button(format.displayName) { model.export(format, title: record.appName) }
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(String(localized: "speakers.export.title"))
            .accessibilityLabel(String(localized: "speakers.export.title"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}

/// One speaker in the strip. A click opens the speaker's details.
private struct SpeakerChip: View {
    @ObservedObject var model: SpeakerWorkspaceModel
    let speakerID: String
    let share: SpeakerShare?
    let hasAudio: Bool
    let canCorrect: Bool
    @State private var showsDetails = false
    @State private var isHovered = false

    var body: some View {
        let isFiltered = model.filteredSpeaker == speakerID
        Button {
            showsDetails = true
        } label: {
            HStack(spacing: 6) {
                SpeakerBadge(speakerID: speakerID, name: model.names?.displayName(for: speakerID))
                Text(model.name(of: speakerID))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if let share {
                    Text(share.fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if model.soloedSpeakers.contains(speakerID) {
                    Image(systemName: "headphones").font(.caption2).foregroundStyle(Color.accentColor)
                }
                if model.mutedSpeakers.contains(speakerID) {
                    Image(systemName: "speaker.slash.fill").font(.caption2).foregroundStyle(.secondary)
                }
                if model.voiceState(of: speakerID) == .suggestion {
                    Image(systemName: "waveform.badge.magnifyingglass").font(.caption2).foregroundStyle(.orange)
                }
            }
            .padding(.leading, 4)
            .padding(.trailing, 9)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(
                    isFiltered ? Color.accentColor.opacity(0.2) : Color.primary.opacity(isHovered || showsDetails ? 0.12 : 0.06)
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(model.isAudible(speakerID) ? 1 : 0.55)
        .onHover { isHovered = $0 }
        .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
            SpeakerInspectorRow(
                model: model,
                speakerID: speakerID,
                share: share,
                hasAudio: hasAudio,
                canCorrect: canCorrect
            )
            .frame(width: 270)
            .padding(8)
        }
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
        let isSoloed = model.soloedSpeakers.contains(speakerID)
        let isMuted = model.mutedSpeakers.contains(speakerID)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                SpeakerBadge(speakerID: speakerID, name: model.names?.displayName(for: speakerID))
                TextField(SpeakerTranscriptPresentation.defaultName(for: speakerID), text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
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
                } else if voiceState == .outdated {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .help(String(localized: "speakers.voice.outdated"))
                        .accessibilityLabel(String(localized: "speakers.voice.outdated"))
                }
                if let share {
                    Text(share.fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
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

            HStack(spacing: 8) {
                if let share {
                    Text(SpeakerTranscriptPresentation.timestamp(share.seconds))
                }
                Spacer(minLength: 4)
                if hasAudio {
                    Group {
                        iconButton("play.circle", help: "speakers.excerpt.play") {
                            model.playExcerpt(of: speakerID)
                        }
                        toggleButton("headphones", isOn: isSoloed, help: "speakers.playback.solo") {
                            model.toggleSolo(speakerID)
                        }
                        toggleButton("speaker.slash.fill", isOn: isMuted, help: "speakers.playback.mute") {
                            model.toggleMute(speakerID)
                        }
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
                    } else if voiceState == .linked || voiceState == .outdated {
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
            .padding(.leading, 25)

            if let share {
                GeometryReader { geometry in
                    Capsule()
                        .fill(SpeakerBadge.color(for: speakerID))
                        .frame(width: max(3, geometry.size.width * share.fraction))
                }
                .frame(height: 3)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isFiltered ? Color.accentColor.opacity(0.14) : Color.clear)
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

    private func toggleButton(_ systemImage: String, isOn: Bool, help: String.LocalizationValue, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption2.weight(.bold))
                .frame(width: 20, height: 18)
                .foregroundStyle(isOn ? Color.white : .secondary)
                .background(RoundedRectangle(cornerRadius: 4).fill(isOn ? Color.accentColor : Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help(String(localized: help))
        .accessibilityLabel(String(localized: help))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

// MARK: - Words

/// The paragraph being spoken: the only one that redraws for each new word.
private struct ActiveParagraphWords: View {
    @ObservedObject var highlight: SpeakerWordHighlight
    let words: [SpeakerWorkspaceModel.WordToken]
    let isPlayable: Bool
    let onTap: (SpeakerWorkspaceModel.WordToken?) -> Void

    var body: some View {
        SpeakerParagraphWords(words: words, activeIndex: highlight.index, isPlayable: isPlayable, onTap: onTap)
    }
}

/// A paragraph as words that can be played from, with the spoken word marked.
/// One AppKit view draws the whole paragraph: a long recording has many
/// thousand words, and a SwiftUI view for each makes scrolling stutter.
private struct SpeakerParagraphWords: NSViewRepresentable {
    let words: [SpeakerWorkspaceModel.WordToken]
    /// The word being spoken; nil in every paragraph but the active one.
    let activeIndex: Int?
    let isPlayable: Bool
    /// Gets the clicked word, or nil for a click beside the words.
    let onTap: (SpeakerWorkspaceModel.WordToken?) -> Void

    func makeNSView(context: Context) -> SpeakerParagraphTextView {
        SpeakerParagraphTextView()
    }

    func updateNSView(_ view: SpeakerParagraphTextView, context: Context) {
        view.onTap = { index in onTap(index.map { words[$0] }) }
        view.update(words: words, activeIndex: activeIndex, isPlayable: isPlayable)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: SpeakerParagraphTextView, context: Context) -> CGSize? {
        view.size(forWidth: proposal.width ?? .greatestFiniteMagnitude)
    }
}

private final class SpeakerParagraphTextView: NSView {
    var onTap: ((Int?) -> Void)?

    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer(size: .zero)
    private var words: [SpeakerWorkspaceModel.WordToken] = []
    /// Each word's characters, with the space after it.
    private var wordRanges: [NSRange] = []
    private var activeIndex: Int?
    private var hoveredIndex: Int? {
        didSet { if hoveredIndex != oldValue { needsDisplay = true } }
    }
    private var isPlayable = false

    private static let font = NSFont.preferredFont(forTextStyle: .body)
    /// Room around a marked word, as the space between words.
    private static let markInset = CGSize(width: 1.6, height: 1)

    override init(frame: NSRect) {
        super.init(frame: frame)
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    func update(words: [SpeakerWorkspaceModel.WordToken], activeIndex: Int?, isPlayable: Bool) {
        self.isPlayable = isPlayable
        if !isPlayable { hoveredIndex = nil }
        if words != self.words {
            self.words = words
            setText()
        } else if activeIndex == self.activeIndex {
            return
        }
        self.activeIndex = activeIndex
        applyColors()
        needsDisplay = true
    }

    func size(forWidth width: CGFloat) -> CGSize {
        let width = width.isFinite ? width : 100_000
        if container.size.width != width {
            container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        return CGSize(width: width.isFinite && width < 100_000 ? width : ceil(used.width), height: ceil(used.height))
    }

    private func setText() {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        var text = ""
        var ranges: [NSRange] = []
        for word in words {
            let start = (text as NSString).length
            text += word.text
            if word.isFollowedBySpace { text += " " }
            ranges.append(NSRange(location: start, length: (text as NSString).length - start))
        }
        wordRanges = ranges
        storage.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: Self.font,
            .paragraphStyle: style,
        ]))
    }

    private func applyColors() {
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: whole)
        if let activeIndex, wordRanges.indices.contains(activeIndex) {
            let current = wordRanges[activeIndex]
            let upcoming = current.upperBound
            if upcoming < storage.length {
                storage.addAttribute(
                    .foregroundColor,
                    value: NSColor.secondaryLabelColor,
                    range: NSRange(location: upcoming, length: storage.length - upcoming)
                )
            }
            storage.addAttribute(.foregroundColor, value: NSColor.white, range: current)
        }
        storage.endEditing()
    }

    override func layout() {
        super.layout()
        _ = size(forWidth: bounds.width)
    }

    override func draw(_ dirtyRect: NSRect) {
        if let activeIndex {
            fillMark(of: activeIndex, with: .controlAccentColor)
        }
        if let hoveredIndex, hoveredIndex != activeIndex {
            fillMark(of: hoveredIndex, with: NSColor.labelColor.withAlphaComponent(0.12))
        }
        let glyphs = layoutManager.glyphRange(for: container)
        layoutManager.drawGlyphs(forGlyphRange: glyphs, at: .zero)
    }

    private func fillMark(of index: Int, with color: NSColor) {
        guard wordRanges.indices.contains(index) else { return }
        var range = wordRanges[index]
        if words[index].isFollowedBySpace { range.length -= 1 }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        color.setFill()
        // A word broken over two lines gets a mark on each.
        layoutManager.enumerateEnclosingRects(
            forGlyphRange: glyphs,
            withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
            in: container
        ) { rect, _ in
            var mark = rect.insetBy(dx: -Self.markInset.width, dy: -Self.markInset.height)
            mark.size.height = min(mark.height, Self.font.boundingRectForFont.height + 2 * Self.markInset.height)
            NSBezierPath(roundedRect: mark, xRadius: 4, yRadius: 4).fill()
        }
    }

    /// The word under `point`, or nil beside the words.
    private func wordIndex(at point: NSPoint) -> Int? {
        guard storage.length > 0 else { return nil }
        let glyph = layoutManager.glyphIndex(for: point, in: container)
        let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            .insetBy(dx: -Self.markInset.width, dy: -Self.markInset.height)
        guard glyphRect.contains(point) else { return nil }
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        return wordRanges.firstIndex { NSLocationInRange(character, $0) }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        hoveredIndex = isPlayable ? wordIndex(at: convert(event.locationInWindow, from: nil)) : nil
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onTap?(wordIndex(at: point))
    }

    /// The paragraph's context menu comes from SwiftUI; the hosting view
    /// builds it for the clicked location.
    override func menu(for event: NSEvent) -> NSMenu? {
        var ancestor = superview
        while let view = ancestor {
            if let menu = view.menu(for: event), !menu.items.isEmpty { return menu }
            ancestor = view.superview
        }
        return nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - Player

/// The player at the bottom of the workspace: who is speaking, the transport
/// with a scrubber in the speakers' colours, and speed and volume.
private struct SpeakerPlayerBar: View {
    @ObservedObject var model: SpeakerWorkspaceModel
    @ObservedObject var playback: SpeakerPlaybackController
    let title: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            layout(showsNowPlaying: true, showsVolume: true)
            layout(showsNowPlaying: true, showsVolume: false)
            layout(showsNowPlaying: false, showsVolume: false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private func layout(showsNowPlaying: Bool, showsVolume: Bool) -> some View {
        HStack(spacing: 16) {
            if showsNowPlaying {
                nowPlaying
                    .frame(width: 180, alignment: .leading)
            }
            transport
                .frame(minWidth: 300, idealWidth: 300, maxWidth: .infinity)
            options(showsVolume: showsVolume, compact: false)
                .fixedSize()
        }
    }

    // MARK: Now playing

    private var nowPlaying: some View {
        let speakerID = model.activeTurnIndex.flatMap { index in
            model.turns.first { $0.index == index }?.speakerID
        }
        return HStack(spacing: 10) {
            Group {
                if let speakerID {
                    SpeakerBadge(speakerID: speakerID, name: model.names?.displayName(for: speakerID))
                        .scaleEffect(30.0 / 18.0)
                } else {
                    Image(systemName: "waveform")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(speakerID.map(model.name(of:)) ?? title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                if speakerID != nil {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: speakerID)
        .accessibilityElement(children: .combine)
    }

    // MARK: Transport

    private var transport: some View {
        VStack(spacing: 5) {
            HStack(spacing: 20) {
                button("backward.end.fill", help: "speakers.playback.previousTurn") { model.playTurn(offset: -1) }
                button("gobackward.5", help: "speakers.playback.back") { playback.skip(by: -5) }
                Button {
                    playback.togglePlayPause()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.primary))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(playback.isPlaying ? String(localized: "Pause") : String(localized: "Play"))
                button("goforward.5", help: "speakers.playback.forward") { playback.skip(by: 5) }
                button("forward.end.fill", help: "speakers.playback.nextTurn") { model.playTurn(offset: 1) }
            }

            SpeakerTimeline(model: model, playback: playback, clock: playback.clock)
        }
    }

    // MARK: Options

    private func options(showsVolume: Bool, compact: Bool) -> some View {
        HStack(spacing: 10) {
            Button {
                model.skipsSilence.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "forward.frame.fill")
                    if !compact {
                        Text(String(localized: "speakers.playback.skipSilence"))
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(model.skipsSilence ? Color.white : Color.secondary)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(
                    Capsule().fill(model.skipsSilence ? Color.accentColor : Color.primary.opacity(0.08))
                )
            }
            .buttonStyle(.plain)
            .help(String(localized: "speakers.playback.skipSilence"))
            .accessibilityLabel(String(localized: "speakers.playback.skipSilence"))
            .accessibilityAddTraits(model.skipsSilence ? .isSelected : [])

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
                    .font(.caption.monospacedDigit().weight(.medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(String(localized: "speakers.playback.speed"))
            .accessibilityLabel(String(localized: "speakers.playback.speed"))

            if showsVolume {
                HStack(spacing: 4) {
                    Image(systemName: playback.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    Slider(value: $playback.volume, in: 0...1)
                        .controlSize(.mini)
                        .frame(width: 64)
                        .accessibilityLabel(String(localized: "speakers.playback.volume"))
                }
            }
        }
    }

    private static func rateTitle(_ rate: Float) -> String {
        rate.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    private func button(_ systemImage: String, help: String.LocalizationValue, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .help(String(localized: help))
        .accessibilityLabel(String(localized: help))
    }
}

/// Elapsed time, scrubber and remaining time: the part of the player that
/// follows the playback position.
private struct SpeakerTimeline: View {
    @ObservedObject var model: SpeakerWorkspaceModel
    @ObservedObject var playback: SpeakerPlaybackController
    @ObservedObject var clock: SpeakerPlaybackClock

    var body: some View {
        HStack(spacing: 8) {
            Text(SpeakerTranscriptPresentation.timestamp(clock.time))
                .frame(width: 46, alignment: .trailing)
            SpeakerScrubber(model: model, playback: playback, time: clock.time)
            Text("-" + SpeakerTranscriptPresentation.timestamp(max(0, playback.duration - clock.time)))
                .frame(width: 50, alignment: .leading)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
    }
}

/// The playback position over the whole recording. Each turn has its
/// speaker's colour; what has played is filled in.
private struct SpeakerScrubber: View {
    @ObservedObject var model: SpeakerWorkspaceModel
    @ObservedObject var playback: SpeakerPlaybackController
    let time: TimeInterval

    @State private var hoverX: CGFloat?
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let duration = max(playback.duration, model.turns.last?.end ?? 0, 0.001)
            let progress = min(max(time / duration, 0), 1)
            let isExpanded = hoverX != nil || isDragging

            ZStack(alignment: .leading) {
                Canvas { context, size in
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.primary.opacity(0.1)))
                    let played = size.width * progress
                    for turn in model.turns {
                        let x = size.width * turn.start / duration
                        let turnWidth = max(1, size.width * (turn.end - turn.start) / duration)
                        let color = SpeakerBadge.color(for: turn.speakerID)
                        let isAudible = model.isAudible(turn.speakerID)
                        context.fill(
                            Path(CGRect(x: x, y: 0, width: turnWidth, height: size.height)),
                            with: .color(color.opacity(isAudible ? 0.32 : 0.1))
                        )
                        if x < played {
                            context.fill(
                                Path(CGRect(x: x, y: 0, width: min(turnWidth, played - x), height: size.height)),
                                with: .color(color.opacity(isAudible ? 1 : 0.3))
                            )
                        }
                    }
                }
                .frame(height: isExpanded ? 9 : 5)
                .clipShape(Capsule())

                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                    .frame(width: 12, height: 12)
                    .offset(x: width * progress - 6)
                    .opacity(isExpanded ? 1 : 0)
            }
            .frame(width: width, alignment: .leading)
            .frame(maxHeight: .infinity)
            // Above the bar, centred on the pointer, without taking part in the layout.
            .overlay(alignment: .topLeading) {
                if let hoverX {
                    Text(hint(at: duration * min(max(hoverX / width, 0), 1)))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.thickMaterial))
                        .fixedSize()
                        .position(x: hoverX, y: -9)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hoverX = point.x
                case .ended: hoverX = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        hoverX = min(max(value.location.x, 0), width)
                        model.followsPlayback = true
                        playback.seek(to: duration * min(max(value.location.x / width, 0), 1))
                    }
                    .onEnded { _ in isDragging = false }
            )
            .animation(.easeOut(duration: 0.12), value: isExpanded)
        }
        .frame(height: 16)
        .accessibilityElement()
        .accessibilityLabel(String(localized: "speakers.timeline.title"))
        .accessibilityValue(SpeakerTranscriptPresentation.timestamp(time))
        .accessibilityAdjustableAction { direction in
            playback.skip(by: direction == .increment ? 5 : -5)
        }
    }

    /// The time under the pointer and who speaks there.
    private func hint(at time: TimeInterval) -> String {
        let stamp = SpeakerTranscriptPresentation.timestamp(time)
        guard let turn = SpeakerTranscriptPresentation.spokenTurn(in: model.turns, at: time) else { return stamp }
        return stamp + " · " + model.name(of: turn.speakerID)
    }
}
