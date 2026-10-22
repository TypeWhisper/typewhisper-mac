import AppKit
import Foundation

/// The dictation that Correct Last Dictation edits.
struct LastDictationCorrectionTarget: Equatable, Identifiable, Sendable {
    let id: UUID
    /// The text that was inserted, after post-processing. The editor starts with it.
    let finalText: String
    /// The engine's transcript before post-processing, when History kept one that differs.
    let rawText: String?
    let appName: String?
    let timestamp: Date
}

/// Whether a confirmed correction may teach the Dictionary. Mirrors the gate of learning
/// from edits after insertion: a Commercial license and the setting turned on.
enum CorrectionLearningAvailability: Equatable, Sendable {
    case available
    case turnedOff
    case requiresLicense
    /// The edition does not offer learning from corrections, such as the App Store edition.
    case notOffered
}

/// What a confirmed correction did to the Dictionary.
enum LastDictationCorrectionLearning: Equatable, Sendable {
    case learned([LearnedDictionaryCorrection])
    case unchanged
    /// The edit was more than one replaced word, so the learning rules skipped it.
    case notConfident
    case awaitingRepeat
    case alreadyInDictionary
    case failed
    case turnedOff
    case requiresLicense
    case notOffered
}

struct LastDictationCorrectionConfirmation: Equatable, Sendable {
    let correctedText: String
    /// False when the text was confirmed as it was, which only copies it.
    let textChanged: Bool
    let learning: LastDictationCorrectionLearning
    /// False when History is off or the entry was deleted while the editor was open.
    let updatedHistory: Bool
}

@MainActor
protocol LastDictationCorrectionPresenting: AnyObject {
    var isEditorVisible: Bool { get }
    /// Shows the editor for `target`. The presenter reports the user's choice through the
    /// callbacks and keeps the editor open until the handler hides it or shows a result.
    func showEditor(
        for target: LastDictationCorrectionTarget,
        learningAvailability: CorrectionLearningAvailability,
        onConfirm: @escaping @MainActor (String) -> Void,
        onCancel: @escaping @MainActor () -> Void
    )
    /// Closes the editor and reports the confirmed correction.
    func showConfirmation(_ confirmation: LastDictationCorrectionConfirmation)
    /// A short message in place of the editor, for example when there is nothing to correct.
    func showNotice(_ message: String)
    func hide()
}

/// Correct Last Dictation: edits the most recent dictation in a small editor, then learns from
/// the edit with the conservative correction rules, updates History and copies the corrected
/// text. It never changes text in another app.
@MainActor
final class LastDictationCorrectionHandler {
    typealias LearnCorrection = @MainActor (_ originalText: String, _ correctedText: String) -> ConfirmedCorrectionLearningResult

    private let historyService: HistoryService
    private let recentTranscriptionStore: RecentTranscriptionStore
    private let presenter: any LastDictationCorrectionPresenting
    private let learningAvailability: @MainActor () -> CorrectionLearningAvailability
    private let learnCorrection: LearnCorrection
    private let pasteboardProvider: @MainActor () -> NSPasteboard
    private let accessibilityAnnouncementService: AccessibilityAnnouncementService

    /// Called after a changed text was stored, so the owner can update what it keeps for the
    /// same dictation, such as a history record that is still waiting to be written.
    var onCorrectionApplied: ((_ id: UUID, _ correctedText: String) -> Void)?

    /// Identifies the open editor. A confirmation or cancellation from an editor that was
    /// replaced or closed in the meantime is ignored.
    private var activeEditorID: UUID?

    init(
        historyService: HistoryService,
        recentTranscriptionStore: RecentTranscriptionStore,
        presenter: any LastDictationCorrectionPresenting,
        learningAvailability: @escaping @MainActor () -> CorrectionLearningAvailability,
        learnCorrection: @escaping LearnCorrection,
        pasteboardProvider: @escaping @MainActor () -> NSPasteboard = { .general },
        accessibilityAnnouncementService: AccessibilityAnnouncementService
    ) {
        self.historyService = historyService
        self.recentTranscriptionStore = recentTranscriptionStore
        self.presenter = presenter
        self.learningAvailability = learningAvailability
        self.learnCorrection = learnCorrection
        self.pasteboardProvider = pasteboardProvider
        self.accessibilityAnnouncementService = accessibilityAnnouncementService
    }

    var isEditorVisible: Bool { presenter.isEditorVisible }

    /// The editor opens only between dictations. During a recording or transcription it would
    /// take the keyboard focus that the finished text is inserted into.
    static func canOpen(during state: DictationViewModel.State) -> Bool {
        switch state {
        case .idle, .inserting, .error:
            true
        case .recording, .processing, .promptSelection, .promptProcessing:
            false
        }
    }

    /// The most recent successful dictation made on this Mac whose text can be edited:
    /// dictations of this session, also with History turned off, and History entries
    /// dictated on this Mac. Files, Recorder recordings, other devices, entries with
    /// speakers and failed entries are skipped.
    func latestTarget() -> LastDictationCorrectionTarget? {
        struct Candidate {
            let id: UUID
            let timestamp: Date
            let sessionEntry: RecentTranscriptionStore.Entry?
        }

        let records = historyService.recentRecords
        var recordsByID: [UUID: TranscriptionRecord] = [:]
        for record in records where recordsByID[record.id] == nil {
            recordsByID[record.id] = record
        }

        let candidates = recentTranscriptionStore.sessionEntries.map {
            Candidate(id: $0.id, timestamp: $0.timestamp, sessionEntry: $0)
        } + records.filter { $0.source == .mac && historyService.isFromThisMac($0) }.map {
            Candidate(id: $0.id, timestamp: $0.timestamp, sessionEntry: nil)
        }
        // Newest first. On equal timestamps the session entry, listed first, wins.
        let ordered = candidates.enumerated().sorted { lhs, rhs in
            if lhs.element.timestamp != rhs.element.timestamp {
                return lhs.element.timestamp > rhs.element.timestamp
            }
            return lhs.offset < rhs.offset
        }

        var seen = Set<UUID>()
        for (_, candidate) in ordered where seen.insert(candidate.id).inserted {
            if let record = recordsByID[candidate.id] ?? historyService.record(withID: candidate.id) {
                // History holds the current text, including edits made there.
                if let target = Self.target(from: record) {
                    return target
                }
                continue
            }
            // History is off, the entry was deleted, or it is still being written.
            if let entry = candidate.sessionEntry, let target = Self.target(from: entry) {
                return target
            }
        }
        return nil
    }

    /// Opens the editor with the latest dictation, or closes it when it is already open.
    func toggle(currentState: DictationViewModel.State) {
        if presenter.isEditorVisible {
            cancel()
            return
        }
        guard Self.canOpen(during: currentState) else {
            showNotice(LastDictationCorrectionCopy.busyNotice)
            return
        }
        guard let target = latestTarget() else {
            showNotice(LastDictationCorrectionCopy.noDictationNotice)
            return
        }

        let editorID = UUID()
        activeEditorID = editorID
        presenter.showEditor(
            for: target,
            learningAvailability: learningAvailability(),
            onConfirm: { [weak self] text in
                self?.confirm(text, for: target, editorID: editorID)
            },
            onCancel: { [weak self] in
                self?.finishEditor(editorID)
            }
        )
    }

    /// Closes the editor without changing History, the Dictionary or the clipboard.
    func cancel() {
        guard let activeEditorID else { return }
        finishEditor(activeEditorID)
    }

    private func finishEditor(_ editorID: UUID) {
        guard activeEditorID == editorID else { return }
        activeEditorID = nil
        presenter.hide()
    }

    private func showNotice(_ message: String) {
        activeEditorID = nil
        presenter.showNotice(message)
        accessibilityAnnouncementService.announce(message)
    }

    private func confirm(_ editedText: String, for target: LastDictationCorrectionTarget, editorID: UUID) {
        guard activeEditorID == editorID else { return }
        let correctedText = editedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !correctedText.isEmpty else { return }
        activeEditorID = nil

        let textChanged = correctedText != target.finalText
        var updatedHistory = false
        if textChanged {
            // Looked up again: the entry may have been deleted while the editor was open.
            if let record = historyService.record(withID: target.id), Self.isCorrectable(record) {
                historyService.updateRecord(record, finalText: correctedText)
                updatedHistory = true
            }
            recentTranscriptionStore.updateFinalText(id: target.id, finalText: correctedText)
            onCorrectionApplied?(target.id, correctedText)
        }

        let pasteboard = pasteboardProvider()
        pasteboard.clearContents()
        pasteboard.setString(correctedText, forType: .string)

        let confirmation = LastDictationCorrectionConfirmation(
            correctedText: correctedText,
            textChanged: textChanged,
            learning: textChanged
                ? learn(originalText: target.finalText, correctedText: correctedText)
                : .unchanged,
            updatedHistory: updatedHistory
        )
        presenter.showConfirmation(confirmation)
        accessibilityAnnouncementService.announce(
            LastDictationCorrectionCopy.announcement(for: confirmation),
            isUrgent: confirmation.learning == .failed
        )
    }

    /// Learning stays behind the same gate as learning from edits after insertion.
    private func learn(originalText: String, correctedText: String) -> LastDictationCorrectionLearning {
        switch learningAvailability() {
        case .requiresLicense:
            return .requiresLicense
        case .turnedOff:
            return .turnedOff
        case .notOffered:
            return .notOffered
        case .available:
            break
        }

        let result = learnCorrection(originalText, correctedText)
        switch result.outcome {
        case .learned:
            return result.learnedCorrections.isEmpty ? .failed : .learned(result.learnedCorrections)
        case .noEdit:
            return .unchanged
        case .ambiguousEdit:
            return .notConfident
        case .awaitingRepeat:
            return .awaitingRepeat
        case .duplicateCorrection:
            return .alreadyInDictionary
        case .failed, .unsupportedTextObservation, .noCommitBeforeTimeout, .cancelled:
            return .failed
        }
    }

    private static func isCorrectable(_ record: TranscriptionRecord) -> Bool {
        // Text with speakers is edited by paragraph in History, so the transcript and the
        // text stay in step.
        record.processingState == .ready
            && record.speakerTranscriptState == nil
            && !record.finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func target(from record: TranscriptionRecord) -> LastDictationCorrectionTarget? {
        guard isCorrectable(record) else { return nil }
        let finalText = record.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawText = record.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        return LastDictationCorrectionTarget(
            id: record.id,
            finalText: finalText,
            rawText: rawText.isEmpty || rawText == finalText ? nil : rawText,
            appName: record.appName,
            timestamp: record.timestamp
        )
    }

    private static func target(from entry: RecentTranscriptionStore.Entry) -> LastDictationCorrectionTarget? {
        let finalText = entry.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalText.isEmpty else { return nil }
        return LastDictationCorrectionTarget(
            id: entry.id,
            finalText: finalText,
            rawText: nil,
            appName: entry.appName,
            timestamp: entry.timestamp
        )
    }
}

/// Texts of Correct Last Dictation that the handler and the panel share.
enum LastDictationCorrectionCopy {
    static var noDictationNotice: String {
        String(localized: "correctLastDictation.notice.noDictation")
    }

    static var busyNotice: String {
        String(localized: "correctLastDictation.notice.busy")
    }

    static func title(for confirmation: LastDictationCorrectionConfirmation) -> String {
        confirmation.textChanged
            ? String(localized: "correctLastDictation.confirmation.copied")
            : String(localized: "Copied to clipboard")
    }

    /// What happened to the Dictionary, as shown under the title. Nil where the edition does
    /// not learn from corrections.
    static func learningDetail(for learning: LastDictationCorrectionLearning) -> String? {
        switch learning {
        case .learned(let corrections):
            if corrections.count == 1, let correction = corrections.first {
                return String.localizedStringWithFormat(
                    String(localized: "Saved to Dictionary: “%@” -> “%@”"),
                    correction.original,
                    correction.replacement
                )
            }
            return String.localizedStringWithFormat(
                String(localized: "Saved %d corrections to Dictionary"),
                corrections.count
            )
        case .unchanged:
            return String(localized: "correctLastDictation.learning.unchanged")
        case .notConfident:
            return String(localized: "correctLastDictation.learning.notConfident")
        case .awaitingRepeat:
            return String(localized: "premium.window.learning.outcome.awaitingRepeat")
        case .alreadyInDictionary:
            return String(localized: "premium.window.learning.outcome.duplicateCorrection")
        case .failed:
            return String(localized: "correctLastDictation.learning.failed")
        case .turnedOff:
            return String(localized: "correctLastDictation.learning.turnedOff")
        case .requiresLicense:
            return requiresLicenseMessage
        case .notOffered:
            return nil
        }
    }

    /// The spoken form. The quotes and the arrow of a learned correction are visual only.
    static func announcement(for confirmation: LastDictationCorrectionConfirmation) -> String {
        let detail: String?
        if case .learned(let corrections) = confirmation.learning,
           corrections.count == 1,
           let correction = corrections.first {
            detail = String.localizedStringWithFormat(
                String(localized: "correctLastDictation.learning.learnedSpoken"),
                correction.original,
                correction.replacement
            )
        } else {
            detail = learningDetail(for: confirmation.learning)
        }
        guard let detail else { return title(for: confirmation) }
        return "\(title(for: confirmation)). \(detail)"
    }

    /// Shown in the editor before confirming, so the user knows whether an edit can be learned.
    static func learningHint(for availability: CorrectionLearningAvailability) -> String? {
        switch availability {
        case .available:
            String(localized: "correctLastDictation.learning.hint")
        case .turnedOff:
            String(localized: "correctLastDictation.learning.turnedOff")
        case .requiresLicense:
            requiresLicenseMessage
        case .notOffered:
            nil
        }
    }

    private static var requiresLicenseMessage: String {
        String(localized: "premium.window.learning.locked")
    }
}
