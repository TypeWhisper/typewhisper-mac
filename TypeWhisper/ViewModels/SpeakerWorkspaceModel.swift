import AppKit
import Combine
import Foundation

/// State of the speaker workspace of one History record: the transcript by
/// speaker, what is selected, which speakers play, and the corrections with
/// undo.
@MainActor
final class SpeakerWorkspaceModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        let paragraph: SpeakerParagraph
        /// True for the first paragraph of a turn, which shows the speaker.
        let startsTurn: Bool

        var id: Int { paragraph.id }
    }

    typealias WordToken = SpeakerTimedWord

    let playback = SpeakerPlaybackController()

    @Published private(set) var transcript: SpeakerTranscript?
    @Published private(set) var names: SpeakerNameTable?
    @Published private(set) var turns: [SpeakerTranscriptTurn] = []
    @Published private(set) var rows: [Row] = []
    @Published private(set) var shares: [SpeakerShare] = []
    /// Speakers in order of first appearance.
    @Published private(set) var speakerIDs: [String] = []
    @Published private(set) var activeTurnIndex: Int?
    /// The speaker heard on the microphone channel, if the recording has one.
    private(set) var microphoneSpeakerID: String?
    @Published private(set) var activeParagraphID: Int?
    /// The word being spoken, as an index into the active paragraph's words.
    /// Kept apart so a new word redraws only the active paragraph.
    let wordHighlight = SpeakerWordHighlight()
    var activeWordIndex: Int? { wordHighlight.index }

    @Published var selectedTurns: Set<Int> = []
    @Published var soloedSpeakers: Set<String> = [] { didSet { updatePlaybackPlan() } }
    @Published var mutedSpeakers: Set<String> = [] { didSet { updatePlaybackPlan() } }
    @Published var skipsSilence = false { didSet { updatePlaybackPlan() } }
    /// Shows only this speaker's turns in the transcript.
    @Published var filteredSpeaker: String?
    @Published var followsPlayback = true

    private let recordID: UUID
    private let historyService: HistoryService
    private let voices: SpeakerVoiceProfileService?
    private var cancellables = Set<AnyCancellable>()
    private var lastSelectedTurn: Int?
    /// Word timing of the recording, by start time; empty without it.
    private var words: [TranscriptionWord] = []
    private var wordTokens: [Int: [WordToken]] = [:]

    init(recordID: UUID, historyService: HistoryService, voices: SpeakerVoiceProfileService? = nil) {
        self.recordID = recordID
        self.historyService = historyService
        self.voices = voices
        playback.clock.$time
            .sink { [weak self] time in self?.updateActivePosition(at: time) }
            .store(in: &cancellables)
        playback.$duration
            .removeDuplicates()
            .sink { [weak self] _ in self?.updatePlaybackPlan() }
            .store(in: &cancellables)
        reload()
    }

    var visibleRows: [Row] {
        guard let filteredSpeaker else { return rows }
        return rows.filter { $0.paragraph.speakerID == filteredSpeaker }
    }

    func name(of speakerID: String) -> String {
        SpeakerTranscriptPresentation.name(for: speakerID, names: names)
    }

    /// True for the user's own speaker, whose turns show on the right: the
    /// speaker heard on the microphone channel of a Recorder recording, or
    /// one named as the user ("Me" in the app's language).
    func isOwnSpeaker(_ speakerID: String) -> Bool {
        if speakerID == microphoneSpeakerID { return true }
        guard let name = names?.displayName(for: speakerID)?.trimmingCharacters(in: .whitespaces) else { return false }
        return name.compare(String(localized: "speakers.me"), options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    /// The speaker whose turns are mostly where the microphone carried the
    /// user's speech; nil without a microphone channel.
    static func microphoneSpeaker(
        of turns: [SpeakerTranscriptTurn],
        ownSpeech: [ClosedRange<TimeInterval>]
    ) -> String? {
        guard !ownSpeech.isEmpty else { return nil }
        var spoken: [String: TimeInterval] = [:]
        var onMicrophone: [String: TimeInterval] = [:]
        for turn in turns {
            spoken[turn.speakerID, default: 0] += max(0, turn.end - turn.start)
            for range in ownSpeech {
                let overlap = min(turn.end, range.upperBound) - max(turn.start, range.lowerBound)
                if overlap > 0 { onMicrophone[turn.speakerID, default: 0] += overlap }
            }
        }
        guard let best = onMicrophone.max(by: { $0.value < $1.value }),
              let total = spoken[best.key], total > 0,
              best.value >= total / 2 else { return nil }
        return best.key
    }

    /// Reads the record again after it changed.
    func reload() {
        guard let record = historyService.record(withID: recordID) else { return }
        let transcript = record.speakerTranscript
        let names = record.speakerNames
        guard transcript != self.transcript || names != self.names else { return }
        self.transcript = transcript
        self.names = names
        words = record.speakerWords.sorted { $0.start < $1.start }
        wordTokens = [:]
        let turns = transcript.map(SpeakerTranscriptPresentation.turns(of:)) ?? []
        microphoneSpeakerID = Self.microphoneSpeaker(of: turns, ownSpeech: record.speakerOwnSpeech)
        self.turns = turns
        rows = turns.flatMap { turn in
            SpeakerTranscriptPresentation.paragraphs(of: turn, in: transcript!).enumerated().map {
                Row(paragraph: $1, startsTurn: $0 == 0)
            }
        }
        shares = SpeakerTranscriptPresentation.shares(of: turns)
        speakerIDs = transcript?.speakerIDs ?? []
        let known = Set(speakerIDs)
        selectedTurns = selectedTurns.filter { turns.indices.contains($0) }
        soloedSpeakers.formIntersection(known)
        mutedSpeakers.formIntersection(known)
        if let filteredSpeaker, !known.contains(filteredSpeaker) { self.filteredSpeaker = nil }
        updatePlaybackPlan()
        updateActivePosition(at: playback.currentTime)
    }

    // MARK: - Playback

    func toggleSolo(_ speakerID: String) {
        if soloedSpeakers.contains(speakerID) {
            soloedSpeakers.remove(speakerID)
        } else {
            soloedSpeakers.insert(speakerID)
            mutedSpeakers.remove(speakerID)
        }
    }

    func toggleMute(_ speakerID: String) {
        if mutedSpeakers.contains(speakerID) {
            mutedSpeakers.remove(speakerID)
        } else {
            mutedSpeakers.insert(speakerID)
            soloedSpeakers.remove(speakerID)
        }
    }

    func isAudible(_ speakerID: String) -> Bool {
        audibleSpeakers?.contains(speakerID) ?? true
    }

    /// The speakers that play, or nil when all do.
    private var audibleSpeakers: Set<String>? {
        if !soloedSpeakers.isEmpty { return soloedSpeakers }
        let audible = Set(speakerIDs).subtracting(mutedSpeakers)
        // With everyone muted nothing would play; that state plays all instead.
        return mutedSpeakers.isEmpty || audible.isEmpty ? nil : audible
    }

    private func updatePlaybackPlan() {
        playback.ranges = SpeakerPlaybackPlan.ranges(
            turns: turns,
            audibleSpeakers: audibleSpeakers,
            skipsSilence: skipsSilence,
            duration: playback.duration
        )
    }

    private func updateActivePosition(at time: TimeInterval) {
        let turn = playback.duration > 0 && (playback.isPlaying || time > 0)
            ? SpeakerTranscriptPresentation.spokenTurn(in: turns, at: time)
            : nil
        if turn?.index != activeTurnIndex { activeTurnIndex = turn?.index }
        let paragraph = turn.flatMap { turn in
            rows.last { $0.paragraph.turnIndex == turn.index && $0.paragraph.start <= time + 0.05 }?.id
        }
        if paragraph != activeParagraphID { activeParagraphID = paragraph }
        let word = paragraph.flatMap { id in
            rows.first { $0.id == id }.flatMap { row in
                words(of: row.paragraph).lastIndex { $0.start <= time + 0.05 }
            }
        }
        if word != wordHighlight.index { wordHighlight.index = word }
    }

    private func words(from start: TimeInterval, until end: TimeInterval) -> [TranscriptionWord] {
        words.filter { $0.start >= start - 0.05 && $0.start < end + 0.05 }
    }

    /// The paragraph's words with their times, for marking the spoken word and
    /// for playing from a word.
    func words(of paragraph: SpeakerParagraph) -> [WordToken] {
        if let tokens = wordTokens[paragraph.id] { return tokens }
        let tokens = SpeakerTranscriptPresentation.timedWords(
            of: paragraph,
            segments: transcript?.segments ?? [],
            words: words
        )
        wordTokens[paragraph.id] = tokens
        return tokens
    }

    func play(from word: WordToken) {
        followsPlayback = true
        playback.play(from: word.start)
    }

    // MARK: - Split at the playback position

    /// The turn the playback position is in, when another speaker could
    /// take over from there: not at the turn's very start or end.
    var turnAtPlayhead: SpeakerTranscriptTurn? { splittableTurn(at: playback.currentTime) }

    func splittableTurn(at time: TimeInterval) -> SpeakerTranscriptTurn? {
        turns.first { $0.start + 0.3 < time && time < $0.end - 0.3 }
    }

    /// Gives the turn from the playback position on to another speaker, or
    /// to a new one when `speakerID` is nil. With word timing the turn is cut
    /// before the word spoken there; otherwise at the nearest word by text
    /// position.
    func splitAtPlayhead(to speakerID: String?, undoManager: UndoManager?) {
        split(at: playback.currentTime, to: speakerID, undoManager: undoManager)
    }

    func split(at time: TimeInterval, to speakerID: String?, undoManager: UndoManager?) {
        guard let transcript, let turn = splittableTurn(at: time),
              let target = speakerID ?? transcript.unusedSpeakerID,
              let segmentIndex = turn.segmentRange.last(where: { transcript.segments[$0].start <= time }) else { return }
        let segment = transcript.segments[segmentIndex]
        let text = segment.text as NSString

        var offset: Int
        let mapped = TimedTextEntry.map(
            textParts: words(from: segment.start, until: segment.end).map { ($0.text, $0.start, $0.end) },
            in: segment.text
        )
        if let word = mapped.first(where: { $0.end > time }) {
            offset = word.utf16Location
        } else if !mapped.isEmpty || segment.end <= segment.start {
            offset = text.length
        } else {
            let estimate = Int(Double(text.length) * (time - segment.start) / (segment.end - segment.start))
            let rest = NSRange(location: min(max(estimate, 0), text.length), length: text.length - min(max(estimate, 0), text.length))
            let space = text.rangeOfCharacter(from: .whitespaces, options: [], range: rest)
            offset = space.location == NSNotFound ? text.length : space.location + 1
        }

        let edited: SpeakerTranscript
        if offset >= text.length {
            // The position is after this segment's last word: the next segments move.
            let range = (segmentIndex + 1)..<turn.segmentRange.upperBound
            guard !range.isEmpty else { return }
            edited = transcript.assigning(segmentsIn: range, to: target)
        } else if offset <= 0 {
            guard segmentIndex > turn.segmentRange.lowerBound else { return }
            edited = transcript.assigning(segmentsIn: segmentIndex..<turn.segmentRange.upperBound, to: target)
        } else {
            edited = transcript.splitting(
                turn,
                at: SpeakerSplitPoint(segmentIndex: segmentIndex, utf16Offset: offset, text: ""),
                time: time,
                to: target
            )
        }
        apply(edited, names: names, actionName: String(localized: "speakers.action.split"), undoManager: undoManager)
    }

    func playTurn(offset: Int) {
        let time = playback.currentTime
        let target: SpeakerTranscriptTurn?
        if offset > 0 {
            target = turns.first { $0.start > time + 0.05 && isAudible($0.speakerID) }
        } else {
            // Within the first second of a turn "previous" goes one turn back.
            target = turns.last { $0.start < time - 1 && isAudible($0.speakerID) }
        }
        guard let target else { return }
        followsPlayback = true
        playback.isPlaying ? playback.play(from: target.start) : playback.seek(to: target.start)
    }

    func playExcerpt(of speakerID: String) {
        guard let turn = SpeakerTranscriptPresentation.sampleTurn(of: speakerID, in: turns) else { return }
        playback.playExcerpt(
            from: turn.start,
            until: min(turn.end, turn.start + SpeakerTranscriptPresentation.sampleDuration)
        )
    }

    // MARK: - Selection

    func select(turn index: Int, extending: Bool, toggling: Bool) {
        if extending, let anchor = lastSelectedTurn {
            selectedTurns.formUnion(min(anchor, index)...max(anchor, index))
        } else if toggling {
            if selectedTurns.contains(index) { selectedTurns.remove(index) } else { selectedTurns.insert(index) }
            lastSelectedTurn = index
        } else {
            selectedTurns = [index]
            lastSelectedTurn = index
        }
    }

    /// The turns an action on `index` applies to: the selection when the
    /// turn is part of it, the turn alone otherwise.
    func actionTurns(for index: Int) -> [Int] {
        selectedTurns.contains(index) ? selectedTurns.sorted() : [index]
    }

    // MARK: - Corrections

    func rename(_ speakerID: String, to name: String, undoManager: UndoManager?) {
        guard let transcript else { return }
        var table = names ?? SpeakerNameTable(transcriptRevision: transcript.revision)
        // Keeping a recognized name confirms it; another name no longer belongs to that voice.
        let previousName = table.displayName(for: speakerID) ?? ""
        let keepsVoice = !previousName.isEmpty
            && SpeakerTranscriptPresentation.nameKey(name) == SpeakerTranscriptPresentation.nameKey(previousName)
        if keepsVoice, table.isSuggestion(for: speakerID) {
            confirmVoice(of: speakerID)
            return
        }
        table.setName(name, for: speakerID, profileID: keepsVoice ? table.profileID(for: speakerID) : nil)
        guard table != names else { return }
        apply(transcript, names: table, actionName: String(localized: "speakers.rename.help"), undoManager: undoManager)
    }

    // MARK: - Voice profiles

    func voiceState(of speakerID: String) -> SpeakerVoiceState {
        voices?.state(of: speakerID, inRecordID: recordID) ?? .none
    }

    func enrollVoice(of speakerID: String) {
        voices?.enroll(speakerID, inRecordID: recordID)
        reload()
    }

    func confirmVoice(of speakerID: String) {
        voices?.confirm(speakerID, inRecordID: recordID)
        reload()
    }

    func rejectVoice(of speakerID: String) {
        voices?.reject(speakerID, inRecordID: recordID)
        reload()
    }

    func relearnVoice(of speakerID: String) {
        voices?.relearn(speakerID, inRecordID: recordID)
        reload()
    }

    /// Gives the turns to another speaker, or to a new one when `speakerID` is nil.
    func assign(turns indexes: [Int], to speakerID: String?, undoManager: UndoManager?) {
        guard var edited = transcript,
              let target = speakerID ?? edited.unusedSpeakerID else { return }
        // Segment ranges stay valid: assigning changes no segment boundaries.
        for index in indexes where turns.indices.contains(index) {
            edited = edited.assigning(segmentsIn: turns[index].segmentRange, to: target)
        }
        selectedTurns = []
        apply(edited, names: names, actionName: String(localized: "speakers.action.assign"), undoManager: undoManager)
    }

    /// Gives the turn from this paragraph on to another speaker, or to a new
    /// one when `speakerID` is nil.
    func split(at paragraph: SpeakerParagraph, to speakerID: String?, undoManager: UndoManager?) {
        guard let transcript, turns.indices.contains(paragraph.turnIndex),
              let target = speakerID ?? transcript.unusedSpeakerID else { return }
        let turn = turns[paragraph.turnIndex]
        let range = paragraph.segmentRange.lowerBound..<turn.segmentRange.upperBound
        apply(
            transcript.assigning(segmentsIn: range, to: target),
            names: names,
            actionName: String(localized: "speakers.action.split"),
            undoManager: undoManager
        )
    }

    func merge(_ source: String, into target: String, undoManager: UndoManager?) {
        guard let transcript, source != target else { return }
        var table = names
        // The merged speaker's name survives when the target has none.
        if var moved = table, moved.displayName(for: target) == nil, let name = moved.displayName(for: source) {
            moved.setName(name, for: target, profileID: moved.profileID(for: source))
            table = moved
        }
        table?.setName("", for: source)
        apply(
            transcript.merging(source, into: target),
            names: table,
            actionName: String(localized: "speakers.action.merge"),
            undoManager: undoManager
        )
    }

    func edit(_ paragraph: SpeakerParagraph, text: String, undoManager: UndoManager?) {
        guard let transcript, text.trimmingCharacters(in: .whitespacesAndNewlines) != paragraph.text else { return }
        apply(
            transcript.replacingText(ofSegmentsIn: paragraph.segmentRange, with: text),
            names: names,
            updatesText: true,
            actionName: String(localized: "speakers.action.editText"),
            undoManager: undoManager
        )
    }

    private func apply(
        _ transcript: SpeakerTranscript,
        names: SpeakerNameTable?,
        updatesText: Bool = false,
        actionName: String,
        undoManager: UndoManager?
    ) {
        let previous = (transcript: self.transcript, names: historyService.record(withID: recordID)?.speakerNames)
        guard historyService.updateSpeakerTranscript(
            transcript,
            names: names,
            forRecordID: recordID,
            updatesText: updatesText
        ) else {
            reload()
            return
        }
        reload()
        if let old = previous.transcript, let new = self.transcript, old != new {
            voices?.transcriptCorrected(recordID: recordID, from: old, to: new)
        }
        guard let undoManager, let previousTranscript = previous.transcript else { return }
        undoManager.registerUndo(withTarget: self) { model in
            model.apply(
                previousTranscript,
                names: previous.names,
                updatesText: updatesText,
                actionName: actionName,
                undoManager: undoManager
            )
        }
        undoManager.setActionName(actionName)
    }

    // MARK: - Copy and export

    func copyWithNames() {
        guard let transcript else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            SpeakerTranscriptPresentation.plainText(of: transcript, names: names),
            forType: .string
        )
    }

    func export(_ format: SpeakerTranscriptExportFormat, title: String?) {
        guard let transcript else { return }
        let content = SpeakerTranscriptExporter.content(of: transcript, names: names, title: title, format: format)
        let panel = NSSavePanel()
        let baseName = (title.map { ($0 as NSString).deletingPathExtension } ?? "Transcript")
        panel.nameFieldStringValue = "\(baseName).\(format.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        SubtitleExporter.writeContent(content, to: url, suggestedName: baseName)
    }
}

@MainActor
final class SpeakerWordHighlight: ObservableObject {
    @Published fileprivate(set) var index: Int?
}
