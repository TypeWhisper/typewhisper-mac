import ApplicationServices
import Combine
import Foundation

/// Session-only safe undo and raw-transcript restore for the most recent direct
/// text insertion (issue #999).
///
/// After each successful, verifiable direct text insertion the dictation
/// pipeline records a snapshot. "Undo Last Dictation" deletes the inserted text
/// and "Restore Raw Transcript" replaces it with the raw transcript — but only
/// when the same application and focused text element are still active, the
/// snapshot is fresh, and the caret sits at the exact post-insertion position
/// with the unchanged inserted text immediately before it. Every other
/// situation is a safe no-op with user-visible feedback; the service never
/// searches the document and never synthesizes repeated deletions.
///
/// The snapshot is independent of transcription history and is invalidated
/// after a verified or uncertain write, or once it goes stale.
@MainActor
final class DictationUndoService: ObservableObject {
    /// Captured right after a successful direct text insertion.
    struct InsertionSnapshot {
        let rawTranscript: String
        let insertedText: String
        let transcriptionID: UUID
        let timestamp: Date
        let applicationBundleIdentifier: String?
        let element: AXUIElement
        /// Exact post-insertion caret location (UTF-16 offset). The caret must
        /// still be here for undo/restore — this is what makes a moved caret,
        /// even after identical text elsewhere, a safe no-op.
        let caretLocation: Int
        /// Full post-insertion field value, used to reject edits anywhere in the field.
        let value: String
    }

    enum Kind: Equatable {
        case undo
        case restore
    }

    enum Failure: String, Equatable {
        case noSnapshot
        case nothingToRestore
        case staleSnapshot
        case dictationBusy
        case persistencePending
        case accessibilityUnavailable
        case targetChanged
        case caretMoved
        case textChanged
        case mutationFailed
        case mutationUnverified

        var feedbackMessage: String {
            switch self {
            case .noSnapshot:
                localizedAppText(
                    "There is no recent dictation to change.",
                    de: "Es gibt kein aktuelles Diktat zum Ändern."
                )
            case .nothingToRestore:
                localizedAppText(
                    "The inserted text already matches the raw transcript.",
                    de: "Der eingefügte Text entspricht bereits dem Roh-Transkript."
                )
            case .staleSnapshot:
                localizedAppText(
                    "The last dictation is too old to change safely.",
                    de: "Das letzte Diktat ist zu alt, um noch sicher geändert zu werden."
                )
            case .dictationBusy:
                localizedAppText(
                    "Dictation is active. Try again when it finishes.",
                    de: "Das Diktat ist aktiv. Versuche es erneut, wenn es beendet ist."
                )
            case .persistencePending:
                localizedAppText(
                    "The last dictation is still being saved. Try again shortly.",
                    de: "Das letzte Diktat wird noch gespeichert. Versuche es gleich erneut."
                )
            case .mutationUnverified:
                localizedAppText(
                    "The text may have changed, but the result couldn't be verified. Check the text field.",
                    de: "Der Text wurde möglicherweise geändert, aber das Ergebnis konnte nicht geprüft werden. Prüfe das Textfeld."
                )
            case .accessibilityUnavailable:
                localizedAppText(
                    "The text field can't be verified right now, so nothing was changed.",
                    de: "Das Textfeld kann gerade nicht geprüft werden, daher wurde nichts geändert."
                )
            case .targetChanged:
                localizedAppText(
                    "The app or text field changed since insertion, so nothing was changed.",
                    de: "App oder Textfeld haben sich seit dem Einfügen geändert, daher wurde nichts geändert."
                )
            case .caretMoved:
                localizedAppText(
                    "The caret moved since insertion, so nothing was changed.",
                    de: "Der Cursor hat sich seit dem Einfügen bewegt, daher wurde nichts geändert."
                )
            case .textChanged:
                localizedAppText(
                    "The inserted text was edited, so nothing was changed.",
                    de: "Der eingefügte Text wurde bearbeitet, daher wurde nichts geändert."
                )
            case .mutationFailed:
                localizedAppText(
                    "The text couldn't be changed.",
                    de: "Der Text konnte nicht geändert werden."
                )
            }
        }
    }

    enum Result: Equatable {
        case success
        case failed(Failure)
    }

    /// Snapshots older than this are invalidated instead of applied.
    static let defaultMaximumSnapshotAge: TimeInterval = 10 * 60

    @Published private(set) var snapshot: InsertionSnapshot?

    var canUndo: Bool { snapshot != nil }

    /// Restore is only meaningful when the raw transcript actually differs from
    /// what was inserted.
    var canRestoreRaw: Bool {
        guard let snapshot else { return false }
        return Self.normalizedForComparison(snapshot.rawTranscript)
            != Self.normalizedForComparison(snapshot.insertedText)
    }

    private let captureActiveApp: @MainActor () -> (name: String?, bundleId: String?, url: String?)
    private let focusedObservation: @MainActor () -> TextInsertionService.FocusedTextObservation?
    private let replaceRange: @MainActor (NSRange, AXUIElement, String) -> TextInsertionService.RangeReplacementResult
    private let isPersistencePending: @MainActor (UUID) -> Bool
    private let isDictationBusy: @MainActor () -> Bool
    private let didRestoreRawTranscript: @MainActor (UUID, String) -> Void
    private let now: @MainActor () -> Date
    private let maximumSnapshotAge: TimeInterval

    init(
        captureActiveApp: @escaping @MainActor () -> (name: String?, bundleId: String?, url: String?),
        focusedObservation: @escaping @MainActor () -> TextInsertionService.FocusedTextObservation?,
        replaceRange: @escaping @MainActor (NSRange, AXUIElement, String) -> TextInsertionService.RangeReplacementResult,
        isDictationBusy: @escaping @MainActor () -> Bool,
        didRestoreRawTranscript: @escaping @MainActor (UUID, String) -> Void,
        isPersistencePending: @escaping @MainActor (UUID) -> Bool = { _ in false },
        now: @escaping @MainActor () -> Date = { Date() },
        maximumSnapshotAge: TimeInterval = DictationUndoService.defaultMaximumSnapshotAge
    ) {
        self.captureActiveApp = captureActiveApp
        self.focusedObservation = focusedObservation
        self.replaceRange = replaceRange
        self.isDictationBusy = isDictationBusy
        self.isPersistencePending = isPersistencePending
        self.didRestoreRawTranscript = didRestoreRawTranscript
        self.now = now
        self.maximumSnapshotAge = maximumSnapshotAge
    }

    convenience init(
        textInsertionService: TextInsertionService,
        isPersistencePending: @escaping @MainActor (UUID) -> Bool,
        isDictationBusy: @escaping @MainActor () -> Bool,
        didRestoreRawTranscript: @escaping @MainActor (UUID, String) -> Void
    ) {
        self.init(
            captureActiveApp: { textInsertionService.captureActiveApp() },
            focusedObservation: { textInsertionService.captureFocusedTextObservation() },
            replaceRange: { range, element, text in
                textInsertionService.replaceRange(range, in: element, with: text)
            },
            isDictationBusy: isDictationBusy,
            didRestoreRawTranscript: didRestoreRawTranscript,
            isPersistencePending: isPersistencePending
        )
    }

    /// Records the snapshot for a successful, verifiable direct text insertion.
    /// Replaces any previous snapshot. Records nothing unless the exact
    /// inserted text is observable immediately before the caret right now —
    /// unverified pastes and transformed output must not create snapshots, so
    /// callers gate on the insertion result before calling this.
    func recordSnapshot(rawTranscript: String, insertedText: String, transcriptionID: UUID) {
        guard !insertedText.isEmpty,
              let observation = focusedObservation(),
              let selectedRange = observation.selectedRange,
              selectedRange.length == 0 else {
            return
        }
        let valueNSString = observation.value as NSString
        let insertedLength = (insertedText as NSString).length
        guard selectedRange.location >= insertedLength else { return }
        let targetRange = NSRange(
            location: selectedRange.location - insertedLength,
            length: insertedLength
        )
        guard NSMaxRange(targetRange) <= valueNSString.length,
              valueNSString.substring(with: targetRange) == insertedText else {
            return
        }
        snapshot = InsertionSnapshot(
            rawTranscript: rawTranscript,
            insertedText: insertedText,
            transcriptionID: transcriptionID,
            timestamp: now(),
            applicationBundleIdentifier: captureActiveApp().bundleId,
            element: observation.element,
            caretLocation: selectedRange.location,
            value: observation.value
        )
    }

    /// Performs the undo or restore action, returning `.success` only when the
    /// document change was verified. An uncertain write also consumes the snapshot
    /// so the action can never affect unrelated text on a second invocation.
    @discardableResult
    func perform(_ kind: Kind) -> Result {
        guard let snapshot else { return .failed(.noSnapshot) }
        if kind == .restore, !canRestoreRaw { return .failed(.nothingToRestore) }
        if now().timeIntervalSince(snapshot.timestamp) > maximumSnapshotAge {
            self.snapshot = nil
            return .failed(.staleSnapshot)
        }
        guard !isDictationBusy() else { return .failed(.dictationBusy) }
        if kind == .restore, isPersistencePending(snapshot.transcriptionID) {
            return .failed(.persistencePending)
        }
        guard let observation = focusedObservation() else {
            return .failed(.accessibilityUnavailable)
        }
        guard observation.element == snapshot.element else { return .failed(.targetChanged) }
        let activeApp = captureActiveApp()
        guard activeApp.bundleId == snapshot.applicationBundleIdentifier else {
            return .failed(.targetChanged)
        }
        guard let selectedRange = observation.selectedRange else {
            return .failed(.accessibilityUnavailable)
        }
        let valueNSString = observation.value as NSString
        guard selectedRange.length == 0,
              selectedRange.location == snapshot.caretLocation else {
            // Compare the complete field, even when the inserted substring is unchanged.
            return .failed(
                valueNSString.isEqual(to: snapshot.value) ? .caretMoved : .textChanged
            )
        }
        guard valueNSString.isEqual(to: snapshot.value) else { return .failed(.textChanged) }
        let insertedLength = (snapshot.insertedText as NSString).length
        let targetRange = NSRange(
            location: snapshot.caretLocation - insertedLength,
            length: insertedLength
        )
        guard NSMaxRange(targetRange) <= valueNSString.length,
              valueNSString.substring(with: targetRange) == snapshot.insertedText else {
            return .failed(.textChanged)
        }

        let replacement = kind == .undo ? "" : snapshot.rawTranscript
        switch replaceRange(targetRange, observation.element, replacement) {
        case .notApplied:
            return .failed(.mutationFailed)
        case .unverified:
            self.snapshot = nil
            return .failed(.mutationUnverified)
        case .verified:
            break
        }

        self.snapshot = nil
        if kind == .restore {
            didRestoreRawTranscript(snapshot.transcriptionID, snapshot.rawTranscript)
        }
        return .success
    }

    private static func normalizedForComparison(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
