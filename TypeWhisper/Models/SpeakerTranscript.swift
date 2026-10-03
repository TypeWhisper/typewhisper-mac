import Foundation
import NaturalLanguage

enum TimedTextGranularity: String, Codable, Equatable, Sendable {
    case word
    case segment
    case none
}

/// A word or segment of a transcript with its time in the recording and its
/// place in the transcript text.
struct TimedTextEntry: Codable, Equatable, Sendable, Identifiable {
    var id: String { "\(utf16Location):\(utf16Length):\(start):\(end)" }

    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let utf16Location: Int
    let utf16Length: Int

    var range: NSRange {
        NSRange(location: utf16Location, length: utf16Length)
    }

    /// How far after the previous word the next one is looked for, in UTF-16 units.
    static let mappingWindow = 200

    /// Finds each timed word in the transcript, in order. A word is looked for
    /// shortly after the previous one; a match further on is only taken when
    /// the next words follow it too. Otherwise a word the transcript spells
    /// differently (after dictionary corrections, for example) would jump to a
    /// later occurrence and drop every word in between.
    static func map(
        textParts: [(text: String, start: TimeInterval, end: TimeInterval)],
        in transcript: String
    ) -> [TimedTextEntry] {
        let source = transcript as NSString
        let parts = textParts.filter { part in
            !part.text.isEmpty && part.start.isFinite && part.end.isFinite && part.end >= part.start
        }
        var searchLocation = 0
        var entries: [TimedTextEntry] = []

        for (index, part) in parts.enumerated() {
            var match = find(part.text, in: source, from: searchLocation, within: mappingWindow)
            if match.location == NSNotFound {
                let later = find(part.text, in: source, from: searchLocation, within: nil)
                let followers = parts[(index + 1)...].prefix(2).map(\.text)
                guard later.location != NSNotFound,
                      !followers.isEmpty,
                      follow(followers, in: source, from: NSMaxRange(later)) else { continue }
                match = later
            }

            entries.append(
                TimedTextEntry(
                    text: source.substring(with: match),
                    start: max(0, part.start),
                    end: max(part.start, part.end),
                    utf16Location: match.location,
                    utf16Length: match.length
                )
            )
            searchLocation = NSMaxRange(match)
        }

        return entries
    }

    private static func find(_ text: String, in source: NSString, from location: Int, within window: Int?) -> NSRange {
        let length = min(source.length - location, window.map { $0 + (text as NSString).length } ?? .max)
        let range = NSRange(location: location, length: length)
        let match = source.range(of: text, options: [], range: range)
        guard match.location == NSNotFound else { return match }
        return source.range(of: text, options: [.caseInsensitive, .diacriticInsensitive], range: range)
    }

    /// True when every word is found shortly after the previous one.
    private static func follow(_ words: [String], in source: NSString, from location: Int) -> Bool {
        var location = location
        for word in words {
            let match = find(word, in: source, from: location, within: mappingWindow)
            guard match.location != NSNotFound else { return false }
            location = NSMaxRange(match)
        }
        return true
    }
}

/// One stretch of a speaker transcript. The JSON keys match the `transcript`
/// history sync component.
struct SpeakerTranscriptSegment: Codable, Equatable, Sendable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    /// `S1`, `S2`, … within one speaker transcript revision; nil when unattributed.
    let speakerID: String?
    let speakerConfidence: Double?

    init(
        text: String,
        start: TimeInterval,
        end: TimeInterval,
        speakerID: String? = nil,
        speakerConfidence: Double? = nil
    ) {
        self.text = text
        self.start = start
        self.end = end
        self.speakerID = speakerID
        self.speakerConfidence = speakerConfidence
    }
}

/// A transcript split by speaker for one diarization run.
///
/// Mirrors the `transcript` history sync component.
struct SpeakerTranscript: Codable, Equatable, Sendable {
    struct Source: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable {
            case local
            case provider
        }

        let kind: Kind
        /// Stable identifier such as `fluidaudio-offline-diarizer`, not a display name.
        let engine: String
        let modelVersion: String?

        init(kind: Kind, engine: String, modelVersion: String? = nil) {
            self.kind = kind
            self.engine = engine
            self.modelVersion = modelVersion
        }

        static let localDiarizer = Source(kind: .local, engine: "fluidaudio-offline-diarizer")
    }

    static let maximumSegmentCount = 50_000

    /// New for every diarization run; speaker names refer to it.
    let revision: UUID
    let source: Source
    let segments: [SpeakerTranscriptSegment]
    /// The speaker count the user asked for; nil when it was detected automatically.
    let requestedSpeakerCount: Int?

    init(
        revision: UUID = UUID(),
        source: Source,
        segments: [SpeakerTranscriptSegment],
        requestedSpeakerCount: Int? = nil
    ) {
        self.revision = revision
        self.source = source
        self.segments = segments
        self.requestedSpeakerCount = requestedSpeakerCount
    }

    /// Speaker counts offered besides automatic detection.
    static let selectableSpeakerCounts = Array(2...8)

    /// Speaker IDs in order of first appearance.
    var speakerIDs: [String] {
        var seen = Set<String>()
        return segments.compactMap(\.speakerID).filter { seen.insert($0).inserted }
    }

    func speakingTime(of speakerID: String) -> TimeInterval {
        segments
            .filter { $0.speakerID == speakerID }
            .reduce(0) { $0 + max(0, $1.end - $1.start) }
    }

    var isValid: Bool {
        segments.count <= Self.maximumSegmentCount
            && segments.allSatisfy { segment in
                segment.start.isFinite
                    && segment.end.isFinite
                    && 0 <= segment.start
                    && segment.start <= segment.end
                    && (segment.speakerConfidence.map { (0...1).contains($0) } ?? true)
                    && (segment.speakerID.map(Self.isValidSpeakerID) ?? true)
            }
    }

    /// The same revision with the given segments assigned to another
    /// speaker. Corrections keep the revision, so names keep applying.
    func assigning(segmentsIn range: Range<Int>, to speakerID: String) -> SpeakerTranscript {
        let range = range.clamped(to: segments.indices)
        var segments = segments
        for index in range {
            let segment = segments[index]
            segments[index] = SpeakerTranscriptSegment(
                text: segment.text,
                start: segment.start,
                end: segment.end,
                speakerID: speakerID,
                speakerConfidence: 1
            )
        }
        return correcting(segments)
    }

    /// The same revision with every segment of `source` assigned to `target`.
    func merging(_ source: String, into target: String) -> SpeakerTranscript {
        correcting(segments.map { segment in
            guard segment.speakerID == source else { return segment }
            return SpeakerTranscriptSegment(
                text: segment.text,
                start: segment.start,
                end: segment.end,
                speakerID: target,
                speakerConfidence: segment.speakerConfidence
            )
        })
    }

    /// Speaker IDs numbered again by first appearance, as diarization numbers
    /// them, so corrections leave no gaps; and the map from old to new IDs.
    func renumbered() -> (transcript: SpeakerTranscript, newSpeakerIDs: [String: String]) {
        let map = Dictionary(uniqueKeysWithValues: speakerIDs.enumerated().map { offset, speakerID in
            (speakerID, Self.speakerID(number: offset + 1))
        })
        guard map.contains(where: { $0.key != $0.value }) else { return (self, map) }
        let segments = segments.map { segment in
            guard let speakerID = segment.speakerID, let newID = map[speakerID], newID != speakerID else {
                return segment
            }
            return SpeakerTranscriptSegment(
                text: segment.text,
                start: segment.start,
                end: segment.end,
                speakerID: newID,
                speakerConfidence: segment.speakerConfidence
            )
        }
        return (correcting(segments), map)
    }

    /// Gives the rest of a turn, from `point` on, to another speaker, when
    /// the detection merged two people in one turn. The segment at the point
    /// is split at `time`; later segments of the turn move whole.
    func splitting(
        _ turn: SpeakerTranscriptTurn,
        at point: SpeakerSplitPoint,
        time: TimeInterval,
        to speakerID: String
    ) -> SpeakerTranscript {
        guard turn.segmentRange.contains(point.segmentIndex),
              segments.indices.contains(point.segmentIndex) else { return self }
        let segment = segments[point.segmentIndex]
        let text = segment.text as NSString
        let offset = min(max(point.utf16Offset, 0), text.length)
        let head = text.substring(to: offset).trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = text.substring(from: offset).trimmingCharacters(in: .whitespacesAndNewlines)
        let splitTime = min(max(time, segment.start), segment.end)

        var result = Array(segments[..<point.segmentIndex])
        if !head.isEmpty {
            result.append(SpeakerTranscriptSegment(
                text: head,
                start: segment.start,
                end: splitTime,
                speakerID: segment.speakerID,
                speakerConfidence: segment.speakerConfidence
            ))
        }
        if !tail.isEmpty {
            result.append(SpeakerTranscriptSegment(
                text: tail,
                start: head.isEmpty ? segment.start : splitTime,
                end: segment.end,
                speakerID: speakerID,
                speakerConfidence: 1
            ))
        }
        for index in (point.segmentIndex + 1)..<min(turn.segmentRange.upperBound, segments.count) {
            let moved = segments[index]
            result.append(SpeakerTranscriptSegment(
                text: moved.text,
                start: moved.start,
                end: moved.end,
                speakerID: speakerID,
                speakerConfidence: 1
            ))
        }
        result.append(contentsOf: segments[min(turn.segmentRange.upperBound, segments.count)...])
        return correcting(result)
    }

    /// A free ID for a turn whose speaker the detection merged with someone else.
    var unusedSpeakerID: String? {
        let highest = speakerIDs.compactMap(Self.speakerNumber(of:)).max() ?? 0
        return highest < 999 ? Self.speakerID(number: highest + 1) : nil
    }

    private func correcting(_ segments: [SpeakerTranscriptSegment]) -> SpeakerTranscript {
        SpeakerTranscript(
            revision: revision,
            source: source,
            segments: segments,
            requestedSpeakerCount: requestedSpeakerCount
        )
    }

    static func speakerID(number: Int) -> String {
        "S\(number)"
    }

    static func speakerNumber(of speakerID: String) -> Int? {
        guard isValidSpeakerID(speakerID) else { return nil }
        return Int(speakerID.dropFirst())
    }

    static func isValidSpeakerID(_ speakerID: String) -> Bool {
        guard speakerID.first == "S", (2...4).contains(speakerID.count) else { return false }
        let digits = speakerID.dropFirst()
        return digits.first != "0" && digits.allSatisfy(\.isASCIIDigit)
    }
}

/// User-given speaker names for one speaker transcript revision.
///
/// Mirrors the `speakers` history sync component.
struct SpeakerNameTable: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let speakerID: String
        let displayName: String
        /// Links the name to an on-device voice profile; carries no voice data.
        let profileID: UUID?
        /// True while a name recognized from a voice profile is not confirmed.
        let isSuggestion: Bool?
        /// When the name was given. Devices merge names one by one, so two
        /// devices naming different speakers both keep their names.
        var updatedAt: Date?

        init(
            speakerID: String,
            displayName: String,
            profileID: UUID? = nil,
            isSuggestion: Bool = false,
            updatedAt: Date? = nil
        ) {
            self.speakerID = speakerID
            self.displayName = displayName
            self.profileID = profileID
            self.isSuggestion = isSuggestion ? true : nil
            self.updatedAt = updatedAt
        }

        /// The same name, regardless of when it was given.
        func isSameName(as other: Entry) -> Bool {
            speakerID == other.speakerID
                && displayName == other.displayName
                && profileID == other.profileID
                && isSuggestion == other.isSuggestion
        }
    }

    /// A name removed on purpose, kept so an older name from another device
    /// does not bring it back.
    struct ClearedName: Codable, Equatable, Sendable {
        let speakerID: String
        let updatedAt: Date
    }

    static let maximumNameLength = 100

    let transcriptRevision: UUID
    private(set) var entries: [Entry]
    private(set) var cleared: [ClearedName]

    init(transcriptRevision: UUID, entries: [Entry] = [], cleared: [ClearedName] = []) {
        self.transcriptRevision = transcriptRevision
        self.entries = entries
        self.cleared = cleared
    }

    private enum CodingKeys: String, CodingKey {
        case transcriptRevision, entries, cleared
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transcriptRevision = try container.decode(UUID.self, forKey: .transcriptRevision)
        entries = try container.decode([Entry].self, forKey: .entries)
        cleared = try container.decodeIfPresent([ClearedName].self, forKey: .cleared) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(transcriptRevision, forKey: .transcriptRevision)
        try container.encode(entries, forKey: .entries)
        if !cleared.isEmpty { try container.encode(cleared, forKey: .cleared) }
    }

    /// Confirmed names, the ones that sync; suggestions stay on this device.
    var confirmedEntries: [Entry] { entries.filter { $0.isSuggestion != true } }

    /// Nothing to keep: no names and no removals other devices must learn of.
    var isEmpty: Bool { entries.isEmpty && cleared.isEmpty }

    /// The same names and removals, regardless of when they were made.
    func hasSameNames(as other: SpeakerNameTable?) -> Bool {
        guard let other else { return isEmpty }
        return transcriptRevision == other.transcriptRevision
            && entries.count == other.entries.count
            && zip(entries, other.entries).allSatisfy { $0.isSameName(as: $1) }
            && Set(cleared.map(\.speakerID)) == Set(other.cleared.map(\.speakerID))
    }

    func displayName(for speakerID: String) -> String? {
        entries.first { $0.speakerID == speakerID }?.displayName
    }

    func profileID(for speakerID: String) -> UUID? {
        entries.first { $0.speakerID == speakerID }?.profileID
    }

    func isSuggestion(for speakerID: String) -> Bool {
        entries.first { $0.speakerID == speakerID }?.isSuggestion == true
    }

    /// Sets or clears a name. Blank names remove the entry; names are trimmed
    /// and limited to `maximumNameLength` characters.
    mutating func setName(
        _ name: String,
        for speakerID: String,
        profileID: UUID? = nil,
        isSuggestion: Bool = false
    ) {
        entries.removeAll { $0.speakerID == speakerID }
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maximumNameLength))
        guard !trimmed.isEmpty else { return }
        // A suggestion is this device's guess and does not undo a removal.
        if !isSuggestion { cleared.removeAll { $0.speakerID == speakerID } }
        entries.append(Entry(
            speakerID: speakerID,
            displayName: trimmed,
            profileID: profileID,
            isSuggestion: isSuggestion
        ))
        entries.sort { ($0.speakerNumber ?? .max) < ($1.speakerNumber ?? .max) }
    }

    /// Moves names to renumbered speaker IDs and drops names of speakers
    /// that a correction removed.
    func renamingSpeakers(_ newSpeakerIDs: [String: String]) -> SpeakerNameTable {
        var table = SpeakerNameTable(transcriptRevision: transcriptRevision)
        for entry in entries {
            guard let newID = newSpeakerIDs[entry.speakerID] else { continue }
            table.setName(
                entry.displayName,
                for: newID,
                profileID: entry.profileID,
                isSuggestion: entry.isSuggestion == true
            )
        }
        return table
    }

    /// Names only count for the transcript revision they were given for.
    func applies(to transcript: SpeakerTranscript) -> Bool {
        transcriptRevision == transcript.revision
    }

    /// This table as stored after an edit on this device: confirmed names
    /// that changed since `previous` are dated `date`, unchanged ones keep
    /// their date, and confirmed names that disappeared are recorded as
    /// removed. Suggestions are never dated or recorded as removed.
    func stamped(against previous: SpeakerNameTable?, at date: Date) -> SpeakerNameTable {
        let previous = previous?.transcriptRevision == transcriptRevision ? previous : nil
        let previousConfirmed = previous?.confirmedEntries ?? []
        var table = self
        table.entries = entries.map { entry in
            guard entry.isSuggestion != true else { return entry }
            var stamped = entry
            if let unchanged = previousConfirmed.first(where: { $0.isSameName(as: entry) }) {
                stamped.updatedAt = unchanged.updatedAt ?? entry.updatedAt ?? date
            } else {
                stamped.updatedAt = date
            }
            return stamped
        }
        let named = Set(table.confirmedEntries.map(\.speakerID))
        var removals = (previous?.cleared ?? []).filter { !named.contains($0.speakerID) }
        for entry in previousConfirmed where !named.contains(entry.speakerID) {
            removals.removeAll { $0.speakerID == entry.speakerID }
            removals.append(ClearedName(speakerID: entry.speakerID, updatedAt: date))
        }
        for removal in cleared where !named.contains(removal.speakerID)
            && !removals.contains(where: { $0.speakerID == removal.speakerID }) {
            removals.append(removal)
        }
        table.cleared = removals.sorted { $0.speakerID < $1.speakerID }
        return table
    }

    /// Merges names from another device for the same transcript revision, one
    /// speaker at a time: the newer name or removal wins. `localDate` stands
    /// in for local names stored without a date. Returns true when this table
    /// now holds something the other device lacks, so it has to publish it.
    mutating func merge(
        names remoteNames: [Entry],
        cleared remoteCleared: [ClearedName],
        remoteDate: Date,
        localDate: Date
    ) -> Bool {
        func localStamp(of speakerID: String) -> Date? {
            let named = confirmedEntries.first { $0.speakerID == speakerID }.map { $0.updatedAt ?? localDate }
            let removed = cleared.first { $0.speakerID == speakerID }?.updatedAt
            return [named, removed].compactMap { $0 }.max()
        }
        for name in remoteNames {
            let date = name.updatedAt ?? remoteDate
            if let local = localStamp(of: name.speakerID), local > date { continue }
            setName(name.displayName, for: name.speakerID, profileID: name.profileID)
            if let index = entries.firstIndex(where: { $0.speakerID == name.speakerID }) {
                entries[index].updatedAt = date
            }
        }
        for removal in remoteCleared {
            if let local = localStamp(of: removal.speakerID), local > removal.updatedAt { continue }
            entries.removeAll { $0.speakerID == removal.speakerID && $0.isSuggestion != true }
            cleared.removeAll { $0.speakerID == removal.speakerID }
            cleared.append(removal)
        }
        cleared.sort { $0.speakerID < $1.speakerID }

        let remoteNamed = Dictionary(remoteNames.map { ($0.speakerID, $0) }, uniquingKeysWith: { first, _ in first })
        let remoteRemoved = Set(remoteCleared.map(\.speakerID))
        let hasNamesTheRemoteLacks = confirmedEntries.contains { entry in
            guard let remote = remoteNamed[entry.speakerID] else { return true }
            return remote.displayName != entry.displayName || remote.profileID != entry.profileID
        }
        let hasRemovalsTheRemoteLacks = cleared.contains { !remoteRemoved.contains($0.speakerID) }
        return hasNamesTheRemoteLacks || hasRemovalsTheRemoteLacks
    }
}

private extension SpeakerNameTable.Entry {
    var speakerNumber: Int? { SpeakerTranscript.speakerNumber(of: speakerID) }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

/// One speaker's consecutive contribution, as shown in the transcript.
struct SpeakerTranscriptTurn: Equatable, Identifiable, Sendable {
    let index: Int
    let speakerID: String
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    /// The transcript segments this turn joins, for moving it to another speaker.
    let segmentRange: Range<Int>

    var id: Int { index }
}

/// One speaker's part of a meeting's speaking time.
struct SpeakerShare: Equatable, Identifiable, Sendable {
    let speakerID: String
    let seconds: TimeInterval
    /// Between 0 and 1; all shares of a transcript add up to 1.
    let fraction: Double

    var id: String { speakerID }
}

/// A place inside a turn where another speaker can take over: the start of
/// a sentence, or of a word when the turn has only one sentence.
struct SpeakerSplitPoint: Equatable, Identifiable, Sendable {
    let segmentIndex: Int
    /// UTF-16 offset in the segment's text.
    let utf16Offset: Int
    /// The sentence or word that starts here, for choosing the point.
    let text: String

    var id: String { "\(segmentIndex):\(utf16Offset)" }
}

/// The excerpt of one speaker that the speaker editor shows and plays.
struct SpeakerSample: Equatable, Sendable {
    let start: TimeInterval
    /// Where playback stops: after the last shown word, or after the whole turn.
    let end: TimeInterval
    let text: String
    /// Word timing with ranges in `text`; empty when the engine gave no word timing.
    let words: [TimedTextEntry]
}

/// Display rules for speaker transcripts: default names, turns, and text
/// with names for copying and sharing.
enum SpeakerTranscriptPresentation {
    static func defaultName(for speakerID: String) -> String {
        let number = SpeakerTranscript.speakerNumber(of: speakerID) ?? 0
        return String(localized: "Speaker \(number)", comment: "Default name of an unnamed speaker in a meeting transcript")
    }

    static func name(for speakerID: String, names: SpeakerNameTable?) -> String {
        names?.displayName(for: speakerID) ?? defaultName(for: speakerID)
    }

    /// Joins consecutive segments of the same speaker; segments without a
    /// speaker join the surrounding turn.
    static func turns(of transcript: SpeakerTranscript) -> [SpeakerTranscriptTurn] {
        var turns: [SpeakerTranscriptTurn] = []
        for (offset, segment) in transcript.segments.enumerated() {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let last = turns.last, segment.speakerID == nil || segment.speakerID == last.speakerID {
                turns[turns.count - 1] = SpeakerTranscriptTurn(
                    index: last.index,
                    speakerID: last.speakerID,
                    start: last.start,
                    end: max(last.end, segment.end),
                    text: last.text + " " + text,
                    segmentRange: last.segmentRange.lowerBound..<(offset + 1)
                )
            } else {
                turns.append(SpeakerTranscriptTurn(
                    index: turns.count,
                    speakerID: segment.speakerID ?? SpeakerTranscript.speakerID(number: 1),
                    start: segment.start,
                    end: segment.end,
                    text: text,
                    segmentRange: offset..<(offset + 1)
                ))
            }
        }
        return turns
    }

    /// Speaking time per speaker, most first.
    static func shares(of turns: [SpeakerTranscriptTurn]) -> [SpeakerShare] {
        var seconds: [String: TimeInterval] = [:]
        for turn in turns {
            seconds[turn.speakerID, default: 0] += max(0, turn.end - turn.start)
        }
        let total = seconds.values.reduce(0, +)
        guard total > 0 else { return [] }
        return seconds
            .map { SpeakerShare(speakerID: $0.key, seconds: $0.value, fraction: $0.value / total) }
            .sorted { ($0.seconds, $1.speakerID) > ($1.seconds, $0.speakerID) }
    }

    /// Where another speaker can take over a turn. The turn's very start is
    /// left out: moving the whole turn is the assign action.
    static func splitPoints(of turn: SpeakerTranscriptTurn, in transcript: SpeakerTranscript) -> [SpeakerSplitPoint] {
        let sentences = points(of: turn, in: transcript, unit: .sentence)
        return sentences.count > 1 ? Array(sentences.dropFirst()) : Array(points(of: turn, in: transcript, unit: .word).dropFirst())
    }

    private static func points(
        of turn: SpeakerTranscriptTurn,
        in transcript: SpeakerTranscript,
        unit: NLTokenUnit
    ) -> [SpeakerSplitPoint] {
        var result: [SpeakerSplitPoint] = []
        for index in turn.segmentRange where transcript.segments.indices.contains(index) {
            let text = transcript.segments[index].text
            let tokenizer = NLTokenizer(unit: unit)
            tokenizer.string = text
            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                let token = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
                if !token.isEmpty {
                    result.append(SpeakerSplitPoint(
                        segmentIndex: index,
                        utf16Offset: NSRange(range, in: text).location,
                        text: token
                    ))
                }
                return true
            }
        }
        return result
    }

    /// The time where the split point is spoken: the start of its word from
    /// the word timing, or an estimate by text position without it.
    static func time(of point: SpeakerSplitPoint, in transcript: SpeakerTranscript, timedText: [TimedTextEntry]) -> TimeInterval {
        guard transcript.segments.indices.contains(point.segmentIndex) else { return 0 }
        let segment = transcript.segments[point.segmentIndex]
        guard point.utf16Offset > 0 else { return segment.start }
        let words = timedText
            .filter { segment.start - 0.05 <= $0.start && $0.start <= segment.end + 0.05 }
            .sorted { $0.utf16Location < $1.utf16Location }
        let mapped = TimedTextEntry.map(
            textParts: words.map { ($0.text, $0.start, $0.end) },
            in: segment.text
        )
        if let word = mapped.first(where: { $0.utf16Location >= point.utf16Offset }) {
            return min(max(word.start, segment.start), segment.end)
        }
        let length = max((segment.text as NSString).length, 1)
        return segment.start + (segment.end - segment.start) * Double(point.utf16Offset) / Double(length)
    }

    /// Longest excerpt played to tell who a speaker is.
    static let sampleDuration: TimeInterval = 12

    /// The first seconds of the speaker's longest turn. With word timing the
    /// text ends with the last word spoken in them, so every shown word can
    /// be highlighted while it plays.
    static func sample(
        of speakerID: String,
        in turns: [SpeakerTranscriptTurn],
        timedText: [TimedTextEntry],
        granularity: TimedTextGranularity
    ) -> SpeakerSample? {
        guard let turn = sampleTurn(of: speakerID, in: turns) else { return nil }
        let limit = min(turn.end, turn.start + sampleDuration)
        let spoken = granularity == .word ? wordsSpoken(from: turn.start, before: limit, in: timedText) : []
        let words = TimedTextEntry.map(
            textParts: spoken.map { ($0.text, $0.start, $0.end) },
            in: turn.text
        )
        guard let last = words.last else {
            return SpeakerSample(start: turn.start, end: limit, text: turn.text, words: [])
        }
        let shownLength = NSMaxRange(last.range)
        let text = turn.text as NSString
        let shown = text.substring(to: shownLength)
        let isShortened = !text.substring(from: shownLength).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return SpeakerSample(
            start: turn.start,
            end: min(turn.end, max(limit, last.end)),
            text: isShortened ? shown + "…" : shown,
            words: words
        )
    }

    /// Words in text order from the one that starts the turn. Long file
    /// transcriptions are timed in chunks, so selecting words by time alone
    /// could pick words from elsewhere; the run stops when time passes the
    /// limit or jumps back.
    private static func wordsSpoken(
        from start: TimeInterval,
        before limit: TimeInterval,
        in timedText: [TimedTextEntry]
    ) -> [TimedTextEntry] {
        let ordered = timedText.sorted { $0.utf16Location < $1.utf16Location }
        // The turn starts exactly at its first word; it is the same stored value.
        guard let first = ordered.firstIndex(where: { abs($0.start - start) < 0.001 }) else { return [] }
        var words: [TimedTextEntry] = []
        for word in ordered[first...] {
            guard start <= word.start, word.start < limit else { break }
            // Recordings mapped before the bounded search can jump far ahead in the text.
            if let previous = words.last,
               word.utf16Location - NSMaxRange(previous.range) > TimedTextEntry.mappingWindow {
                break
            }
            words.append(word)
        }
        return words
    }

    /// The speaker's longest turn: its text and audio show best who is speaking.
    static func sampleTurn(of speakerID: String, in turns: [SpeakerTranscriptTurn]) -> SpeakerTranscriptTurn? {
        turns
            .filter { $0.speakerID == speakerID }
            .max { ($0.end - $0.start) < ($1.end - $1.start) }
    }

    /// Names from earlier recordings that contain the typed text regardless
    /// of case and accents, in the given order. The exact typed name and
    /// names already taken are left out; a spelling that only differs in case
    /// or accents stays so it can correct the typed name.
    static func nameSuggestions(
        from earlierNames: [String],
        matching typed: String,
        excluding taken: [String],
        limit: Int = 3
    ) -> [String] {
        let typedName = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = nameKey(typedName)
        let excluded = Set(taken.map(nameKey))
        return Array(
            earlierNames
                .filter { $0 != typedName }
                .map { ($0, nameKey($0)) }
                .filter { !excluded.contains($0.1) && (query.isEmpty || $0.1.contains(query)) }
                .map(\.0)
                .prefix(limit)
        )
    }

    /// Compares names regardless of case, accents, and surrounding spaces.
    static func nameKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The turn playing at `time`, or the last turn that started before it.
    static func activeTurn(in turns: [SpeakerTranscriptTurn], at time: TimeInterval) -> SpeakerTranscriptTurn? {
        turns.last { $0.start <= time }
    }

    /// `Name: text` paragraphs for copying and sharing.
    static func plainText(of transcript: SpeakerTranscript, names: SpeakerNameTable?) -> String {
        turns(of: transcript)
            .map { "\(name(for: $0.speakerID, names: names)): \($0.text)" }
            .joined(separator: "\n\n")
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}
