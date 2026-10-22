import AppKit
import XCTest
@testable import TypeWhisper

/// Stands in for the editor and result panels. The callbacks stay available after the editor
/// closed, so tests can deliver late confirmations and cancellations.
@MainActor
final class LastDictationCorrectionPresenterSpy: LastDictationCorrectionPresenting {
    private(set) var isEditorVisible = false
    private(set) var shownTargets: [LastDictationCorrectionTarget] = []
    private(set) var shownAvailabilities: [CorrectionLearningAvailability] = []
    private(set) var confirmations: [LastDictationCorrectionConfirmation] = []
    private(set) var notices: [String] = []
    private(set) var hideCount = 0
    private var onConfirm: (@MainActor (String) -> Void)?
    private var onCancel: (@MainActor () -> Void)?

    func showEditor(
        for target: LastDictationCorrectionTarget,
        learningAvailability: CorrectionLearningAvailability,
        onConfirm: @escaping @MainActor (String) -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        isEditorVisible = true
        shownTargets.append(target)
        shownAvailabilities.append(learningAvailability)
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    func showConfirmation(_ confirmation: LastDictationCorrectionConfirmation) {
        isEditorVisible = false
        confirmations.append(confirmation)
    }

    func showNotice(_ message: String) {
        isEditorVisible = false
        notices.append(message)
    }

    func hide() {
        isEditorVisible = false
        hideCount += 1
    }

    /// What the editor reports when the user confirms.
    func confirm(_ text: String) {
        onConfirm?(text)
    }

    /// What the editor reports when the user presses Escape or clicks elsewhere.
    func cancel() {
        onCancel?()
    }
}

@MainActor
final class LastDictationCorrectionHandlerTests: XCTestCase {
    private final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    @MainActor
    private struct Fixture {
        let historyService: HistoryService
        let store: RecentTranscriptionStore
        let dictionaryService: DictionaryService
        let defaults: UserDefaults
        let presenter: LastDictationCorrectionPresenterSpy
        let pasteboard: NSPasteboard
        let availability: Box<CorrectionLearningAvailability>
        let learnCalls: Box<[String]>
        let announcements: Box<[(message: String, isUrgent: Bool)]>
        let appliedCorrections: Box<[(id: UUID, text: String)]>
        let handler: LastDictationCorrectionHandler

        @discardableResult
        func addDictation(
            id: UUID = UUID(),
            rawText: String,
            finalText: String? = nil,
            timestamp: Date = Date(),
            appName: String? = "Notes",
            recordsSessionEntry: Bool = true
        ) -> UUID {
            let finalText = finalText ?? rawText
            XCTAssertTrue(historyService.addRecord(
                id: id,
                timestamp: timestamp,
                rawText: rawText,
                finalText: finalText,
                appName: appName,
                appBundleIdentifier: "com.apple.Notes",
                durationSeconds: 2,
                language: "en",
                engineUsed: "test"
            ))
            if recordsSessionEntry {
                store.recordTranscription(
                    id: id,
                    finalText: finalText,
                    timestamp: timestamp,
                    appName: appName,
                    appBundleIdentifier: "com.apple.Notes"
                )
            }
            return id
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = try TestSupport.makeTemporaryDirectory()
        addTeardownBlock { TestSupport.remove(directory) }
        return directory
    }

    private func makeFixture(
        availability: CorrectionLearningAvailability = .available
    ) throws -> Fixture {
        let directory = try makeTemporaryDirectory()
        let suiteName = "LastDictationCorrectionHandlerTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suiteName) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))

        let historyService = HistoryService(appSupportDirectory: directory)
        let store = RecentTranscriptionStore()
        let dictionaryService = DictionaryService(appSupportDirectory: directory)
        let learningService = TargetAppCorrectionLearningService(
            textInsertionService: TextInsertionService(),
            textDiffService: TextDiffService(),
            dictionaryService: dictionaryService,
            defaults: defaults,
            persistLatestAttempt: false
        )
        let presenter = LastDictationCorrectionPresenterSpy()
        let pasteboard = NSPasteboard.withUniqueName()
        let availabilityBox = Box(availability)
        let learnCalls = Box<[String]>([])
        let announcements = Box<[(message: String, isUrgent: Bool)]>([])
        let appliedCorrections = Box<[(id: UUID, text: String)]>([])

        let announcer = AccessibilityAnnouncementService()
        var clock = ContinuousClock.now
        announcer.isVoiceOverEnabled = { true }
        // Announcements happen well apart, so the duplicate filter never applies here.
        announcer.now = {
            clock = clock.advanced(by: .seconds(5))
            return clock
        }
        announcer.post = { message, isUrgent in
            announcements.value.append((message, isUrgent))
        }

        let handler = LastDictationCorrectionHandler(
            historyService: historyService,
            recentTranscriptionStore: store,
            presenter: presenter,
            learningAvailability: { availabilityBox.value },
            learnCorrection: { originalText, correctedText in
                learnCalls.value.append(correctedText)
                return learningService.learnFromConfirmedCorrection(
                    originalText: originalText,
                    correctedText: correctedText
                )
            },
            pasteboardProvider: { pasteboard },
            accessibilityAnnouncementService: announcer
        )
        handler.onCorrectionApplied = { id, text in
            appliedCorrections.value.append((id, text))
        }

        return Fixture(
            historyService: historyService,
            store: store,
            dictionaryService: dictionaryService,
            defaults: defaults,
            presenter: presenter,
            pasteboard: pasteboard,
            availability: availabilityBox,
            learnCalls: learnCalls,
            announcements: announcements,
            appliedCorrections: appliedCorrections,
            handler: handler
        )
    }

    private func setClipboard(_ text: String, on pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Confirming

    func testConfirmedCorrectionUpdatesHistoryLearnsAndCopies() throws {
        let fixture = try makeFixture()
        let id = fixture.addDictation(rawText: "Please deploy it to Kubernetis tomorrow.")
        setClipboard("Before", on: fixture.pasteboard)

        fixture.handler.toggle(currentState: .idle)

        let target = try XCTUnwrap(fixture.presenter.shownTargets.first)
        XCTAssertTrue(fixture.presenter.isEditorVisible)
        XCTAssertEqual(target.id, id)
        XCTAssertEqual(target.finalText, "Please deploy it to Kubernetis tomorrow.")
        XCTAssertNil(target.rawText, "Raw text equal to the final text is not shown twice")
        XCTAssertEqual(target.appName, "Notes")
        XCTAssertEqual(fixture.presenter.shownAvailabilities, [.available])

        fixture.presenter.confirm("  Please deploy it to Kubernetes tomorrow.\n")

        let corrected = "Please deploy it to Kubernetes tomorrow."
        let record = try XCTUnwrap(fixture.historyService.record(withID: id))
        XCTAssertEqual(record.finalText, corrected)
        XCTAssertEqual(record.rawText, "Please deploy it to Kubernetis tomorrow.")
        XCTAssertEqual(fixture.store.sessionEntries.first?.finalText, corrected)
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), corrected)
        XCTAssertEqual(fixture.appliedCorrections.value.map(\.id), [id])
        XCTAssertEqual(fixture.appliedCorrections.value.map(\.text), [corrected])

        XCTAssertEqual(fixture.dictionaryService.corrections.map(\.original), ["Kubernetis"])
        XCTAssertEqual(fixture.dictionaryService.corrections.map(\.replacement), ["Kubernetes"])

        let confirmation = try XCTUnwrap(fixture.presenter.confirmations.first)
        XCTAssertEqual(fixture.presenter.confirmations.count, 1)
        XCTAssertEqual(confirmation.correctedText, corrected)
        XCTAssertTrue(confirmation.textChanged)
        XCTAssertTrue(confirmation.updatedHistory)
        guard case .learned(let learned) = confirmation.learning else {
            return XCTFail("Expected a learned correction, got \(confirmation.learning)")
        }
        XCTAssertEqual(learned.map(\.original), ["Kubernetis"])
        XCTAssertEqual(learned.map(\.replacement), ["Kubernetes"])
        XCTAssertFalse(fixture.presenter.isEditorVisible)

        // The result is announced, with the learned words but without the visual quotes.
        let announcement = try XCTUnwrap(fixture.announcements.value.last)
        XCTAssertEqual(fixture.announcements.value.count, 1)
        XCTAssertEqual(announcement.message, LastDictationCorrectionCopy.announcement(for: confirmation))
        XCTAssertFalse(announcement.isUrgent)
        XCTAssertTrue(announcement.message.contains("Kubernetis"))
        XCTAssertTrue(announcement.message.contains("Kubernetes"))
        XCTAssertFalse(announcement.message.contains("“"))
        XCTAssertNotEqual(
            LastDictationCorrectionCopy.title(for: confirmation),
            String(localized: "Copied to clipboard"),
            "A changed text is confirmed as corrected, not only as copied"
        )

        // A late confirmation from the closed editor changes nothing.
        fixture.presenter.confirm("Something else entirely")
        XCTAssertEqual(fixture.historyService.record(withID: id)?.finalText, corrected)
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), corrected)
        XCTAssertEqual(fixture.presenter.confirmations.count, 1)
        XCTAssertEqual(fixture.learnCalls.value.count, 1)
    }

    func testUnchangedConfirmationOnlyCopiesTheText() throws {
        let fixture = try makeFixture()
        let id = fixture.addDictation(rawText: "Lunch at noon works for me.")
        let updatedAt = try XCTUnwrap(fixture.historyService.record(withID: id)?.contentUpdatedAt)
        setClipboard("Before", on: fixture.pasteboard)

        fixture.handler.toggle(currentState: .idle)
        fixture.presenter.confirm("Lunch at noon works for me.  ")

        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "Lunch at noon works for me.")
        XCTAssertEqual(fixture.historyService.record(withID: id)?.contentUpdatedAt, updatedAt)
        XCTAssertTrue(fixture.appliedCorrections.value.isEmpty)
        XCTAssertTrue(fixture.learnCalls.value.isEmpty)
        XCTAssertEqual(fixture.dictionaryService.correctionsCount, 0)
        XCTAssertEqual(
            fixture.presenter.confirmations,
            [LastDictationCorrectionConfirmation(
                correctedText: "Lunch at noon works for me.",
                textChanged: false,
                learning: .unchanged,
                updatedHistory: false
            )]
        )
        XCTAssertEqual(
            LastDictationCorrectionCopy.title(for: try XCTUnwrap(fixture.presenter.confirmations.first)),
            String(localized: "Copied to clipboard")
        )
    }

    func testEmptyCorrectionKeepsTheEditorOpen() throws {
        let fixture = try makeFixture()
        let id = fixture.addDictation(rawText: "Call Jon later.")
        setClipboard("Before", on: fixture.pasteboard)

        fixture.handler.toggle(currentState: .idle)
        fixture.presenter.confirm("  \n ")

        XCTAssertTrue(fixture.presenter.confirmations.isEmpty)
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "Before")
        XCTAssertEqual(fixture.historyService.record(withID: id)?.finalText, "Call Jon later.")

        fixture.presenter.confirm("Call John later.")
        XCTAssertEqual(fixture.historyService.record(withID: id)?.finalText, "Call John later.")
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "Call John later.")
    }

    // MARK: - Learning rules

    func testRejectedLearningCandidatesLeaveTheDictionaryUnchanged() throws {
        let cases: [(original: String, edited: String)] = [
            // More than one replaced word.
            ("Meet Jon at the cafe.", "Meet John at the café."),
            // Only the case changed.
            ("See you in berlin.", "See you in Berlin."),
            // A number changed into another number.
            ("It costs 90 euros.", "It costs 95 euros."),
            // Only punctuation changed.
            ("Thanks for the update.", "Thanks for the update!"),
            // A word was added rather than replaced.
            ("Send the draft.", "Send the final draft."),
        ]

        for testCase in cases {
            let fixture = try makeFixture()
            let id = fixture.addDictation(rawText: testCase.original)

            fixture.handler.toggle(currentState: .idle)
            fixture.presenter.confirm(testCase.edited)

            XCTAssertEqual(
                fixture.presenter.confirmations.first?.learning,
                .notConfident,
                "\(testCase.original) -> \(testCase.edited)"
            )
            XCTAssertEqual(fixture.dictionaryService.correctionsCount, 0, testCase.edited)
            // The text is still corrected and copied.
            XCTAssertEqual(fixture.historyService.record(withID: id)?.finalText, testCase.edited)
            XCTAssertEqual(fixture.pasteboard.string(forType: .string), testCase.edited)
        }
    }

    func testCorrectionAlreadyInTheDictionaryIsNotOverwritten() throws {
        let fixture = try makeFixture()
        XCTAssertTrue(fixture.dictionaryService.addEntry(type: .correction, original: "Kubernetis", replacement: "K8s"))
        fixture.addDictation(rawText: "Ask about Kubernetis.")

        fixture.handler.toggle(currentState: .idle)
        fixture.presenter.confirm("Ask about Kubernetes.")

        XCTAssertEqual(fixture.presenter.confirmations.first?.learning, .alreadyInDictionary)
        XCTAssertEqual(fixture.dictionaryService.corrections.map(\.original), ["Kubernetis"])
        XCTAssertEqual(fixture.dictionaryService.corrections.map(\.replacement), ["K8s"])
    }

    func testRepeatCountHoldsTheCorrectionBackUntilItIsRepeated() throws {
        let fixture = try makeFixture()
        fixture.defaults.set(2, forKey: UserDefaultsKeys.targetAppCorrectionLearningRequiredObservations)

        fixture.addDictation(rawText: "Ask about Kubernetis.", timestamp: Date(timeIntervalSinceNow: -60))
        fixture.handler.toggle(currentState: .idle)
        fixture.presenter.confirm("Ask about Kubernetes.")
        XCTAssertEqual(fixture.presenter.confirmations.last?.learning, .awaitingRepeat)
        XCTAssertEqual(fixture.dictionaryService.correctionsCount, 0)

        fixture.addDictation(rawText: "Kubernetis is ready.")
        fixture.handler.toggle(currentState: .idle)
        XCTAssertEqual(fixture.presenter.shownTargets.last?.finalText, "Kubernetis is ready.")
        fixture.presenter.confirm("Kubernetes is ready.")

        guard case .learned(let learned) = fixture.presenter.confirmations.last?.learning else {
            return XCTFail("The repeated correction should be learned")
        }
        XCTAssertEqual(learned.map(\.original), ["Kubernetis"])
        XCTAssertEqual(fixture.dictionaryService.correctionsCount, 1)
    }

    func testLearningKeepsTheLicenseAndSettingGate() throws {
        let cases: [(CorrectionLearningAvailability, LastDictationCorrectionLearning)] = [
            (.requiresLicense, .requiresLicense),
            (.turnedOff, .turnedOff),
            // The App Store edition does not offer learning from corrections.
            (.notOffered, .notOffered),
        ]
        for (availability, expected) in cases {
            let fixture = try makeFixture(availability: availability)
            let id = fixture.addDictation(rawText: "Ask about Kubernetis.")

            fixture.handler.toggle(currentState: .idle)
            XCTAssertEqual(fixture.presenter.shownAvailabilities, [availability])
            fixture.presenter.confirm("Ask about Kubernetes.")

            XCTAssertEqual(fixture.presenter.confirmations.first?.learning, expected)
            XCTAssertTrue(fixture.learnCalls.value.isEmpty, "\(availability) must not reach the learning rules")
            XCTAssertEqual(fixture.dictionaryService.correctionsCount, 0)
            // Correcting and copying do not need the license.
            XCTAssertEqual(fixture.historyService.record(withID: id)?.finalText, "Ask about Kubernetes.")
            XCTAssertEqual(fixture.pasteboard.string(forType: .string), "Ask about Kubernetes.")
        }
    }

    func testConfirmedLearningLeavesTheInsertionLearningAttemptUntouched() throws {
        let directory = try makeTemporaryDirectory()
        let dictionaryService = DictionaryService(appSupportDirectory: directory)
        let service = TargetAppCorrectionLearningService(
            textInsertionService: TextInsertionService(),
            textDiffService: TextDiffService(),
            dictionaryService: dictionaryService,
            persistLatestAttempt: false
        )
        let attemptBefore = service.latestAttempt

        let result = service.learnFromConfirmedCorrection(
            originalText: "Ask about Kubernetis.",
            correctedText: "Ask about Kubernetes."
        )
        XCTAssertEqual(result.outcome, .learned)
        XCTAssertEqual(result.learnedCorrections.map(\.replacement), ["Kubernetes"])
        XCTAssertEqual(service.latestAttempt, attemptBefore)

        XCTAssertEqual(
            service.learnFromConfirmedCorrection(originalText: "Same text", correctedText: " Same text ").outcome,
            .noEdit
        )
        XCTAssertEqual(
            service.learnFromConfirmedCorrection(originalText: "Two words here", correctedText: "Three words there").outcome,
            .ambiguousEdit
        )
    }

    // MARK: - Cancelling

    func testCancellingLeavesHistoryDictionaryAndClipboardUnchanged() throws {
        let fixture = try makeFixture()
        let id = fixture.addDictation(rawText: "Ask about Kubernetis.")
        let updatedAt = try XCTUnwrap(fixture.historyService.record(withID: id)?.contentUpdatedAt)
        setClipboard("Previous clipboard", on: fixture.pasteboard)
        let changeCount = fixture.pasteboard.changeCount

        fixture.handler.toggle(currentState: .idle)
        fixture.presenter.cancel()

        XCTAssertFalse(fixture.presenter.isEditorVisible)
        XCTAssertEqual(fixture.presenter.hideCount, 1)
        XCTAssertFalse(fixture.handler.isEditorVisible)

        // A confirmation that arrives after the cancellation is ignored.
        fixture.presenter.confirm("Ask about Kubernetes.")

        XCTAssertTrue(fixture.presenter.confirmations.isEmpty)
        XCTAssertEqual(fixture.historyService.record(withID: id)?.finalText, "Ask about Kubernetis.")
        XCTAssertEqual(fixture.historyService.record(withID: id)?.contentUpdatedAt, updatedAt)
        XCTAssertEqual(fixture.store.sessionEntries.first?.finalText, "Ask about Kubernetis.")
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "Previous clipboard")
        XCTAssertEqual(fixture.pasteboard.changeCount, changeCount)
        XCTAssertEqual(fixture.dictionaryService.correctionsCount, 0)
        XCTAssertTrue(fixture.learnCalls.value.isEmpty)
        XCTAssertTrue(fixture.appliedCorrections.value.isEmpty)
        XCTAssertTrue(fixture.announcements.value.isEmpty)
    }

    func testShortcutAgainOrAnotherActionClosesTheEditorWithoutChanges() throws {
        let fixture = try makeFixture()
        let id = fixture.addDictation(rawText: "Ask about Kubernetis.")
        setClipboard("Previous clipboard", on: fixture.pasteboard)

        // The shortcut toggles the editor.
        fixture.handler.toggle(currentState: .idle)
        XCTAssertTrue(fixture.handler.isEditorVisible)
        fixture.handler.toggle(currentState: .idle)
        XCTAssertFalse(fixture.handler.isEditorVisible)
        XCTAssertEqual(fixture.presenter.shownTargets.count, 1)

        // Another action, such as a recording or a palette, closes it too.
        fixture.handler.toggle(currentState: .idle)
        fixture.handler.cancel()
        XCTAssertFalse(fixture.handler.isEditorVisible)
        fixture.presenter.confirm("Ask about Kubernetes.")

        XCTAssertTrue(fixture.presenter.confirmations.isEmpty)
        XCTAssertEqual(fixture.historyService.record(withID: id)?.finalText, "Ask about Kubernetis.")
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "Previous clipboard")
        XCTAssertEqual(fixture.dictionaryService.correctionsCount, 0)
    }

    // MARK: - Raw and final text

    func testEditsTheFinalTextAndKeepsTheRawTranscript() throws {
        let fixture = try makeFixture()
        let id = fixture.addDictation(
            rawText: "send the report to mister smith",
            finalText: "Send the report to Mr. Smith."
        )

        fixture.handler.toggle(currentState: .idle)

        let target = try XCTUnwrap(fixture.presenter.shownTargets.first)
        XCTAssertEqual(target.finalText, "Send the report to Mr. Smith.")
        XCTAssertEqual(target.rawText, "send the report to mister smith")

        fixture.presenter.confirm("Send the report to Mr. Smyth.")

        let record = try XCTUnwrap(fixture.historyService.record(withID: id))
        XCTAssertEqual(record.finalText, "Send the report to Mr. Smyth.")
        XCTAssertEqual(record.rawText, "send the report to mister smith", "The raw transcript stays as recognized")
        // The final text is compared with the correction, as when learning from edits after insertion.
        guard case .learned(let learned) = fixture.presenter.confirmations.first?.learning else {
            return XCTFail("Expected a learned correction")
        }
        XCTAssertEqual(learned.map(\.original), ["Smith"])
        XCTAssertEqual(learned.map(\.replacement), ["Smyth"])
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "Send the report to Mr. Smyth.")
    }

    func testHistoryTextWinsOverTheSessionCopyOfTheSameDictation() throws {
        let fixture = try makeFixture()
        let id = fixture.addDictation(rawText: "Original wording here.")
        let record = try XCTUnwrap(fixture.historyService.record(withID: id))
        // Edited in History after the dictation; the session entry still has the inserted text.
        fixture.historyService.updateRecord(record, finalText: "Wording edited in History.")

        XCTAssertEqual(fixture.handler.latestTarget()?.finalText, "Wording edited in History.")
    }

    func testDictationWithHistoryOffIsCorrectedInTheSession() throws {
        let fixture = try makeFixture()
        let id = UUID()
        fixture.store.recordTranscription(
            id: id,
            finalText: "Ask about Kubernetis.",
            timestamp: Date(),
            appName: "Mail",
            appBundleIdentifier: "com.apple.mail"
        )

        fixture.handler.toggle(currentState: .idle)
        let target = try XCTUnwrap(fixture.presenter.shownTargets.first)
        XCTAssertEqual(target.id, id)
        XCTAssertNil(target.rawText)
        fixture.presenter.confirm("Ask about Kubernetes.")

        XCTAssertEqual(fixture.presenter.confirmations.first?.updatedHistory, false)
        XCTAssertEqual(fixture.store.sessionEntries.first?.finalText, "Ask about Kubernetes.")
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "Ask about Kubernetes.")
        XCTAssertEqual(fixture.dictionaryService.correctionsCount, 1)
        XCTAssertNil(fixture.historyService.record(withID: id))
    }

    func testNewestDictationIsChosen() throws {
        let fixture = try makeFixture()
        fixture.addDictation(rawText: "Older dictation.", timestamp: Date(timeIntervalSinceNow: -120))
        let newest = fixture.addDictation(rawText: "Newest dictation.", timestamp: Date(timeIntervalSinceNow: -5))
        fixture.addDictation(
            rawText: "Restored from History only.",
            timestamp: Date(timeIntervalSinceNow: -60),
            recordsSessionEntry: false
        )

        XCTAssertEqual(fixture.handler.latestTarget()?.id, newest)
    }

    // MARK: - Unavailable

    func testWithoutSuccessfulDictationTheActionExplainsWhy() throws {
        let fixture = try makeFixture()
        XCTAssertNil(fixture.handler.latestTarget())

        fixture.handler.toggle(currentState: .idle)

        XCTAssertTrue(fixture.presenter.shownTargets.isEmpty)
        XCTAssertFalse(fixture.presenter.isEditorVisible)
        XCTAssertEqual(fixture.presenter.notices, [LastDictationCorrectionCopy.noDictationNotice])
        XCTAssertEqual(fixture.announcements.value.map(\.message), [LastDictationCorrectionCopy.noDictationNotice])
        XCTAssertFalse(LastDictationCorrectionCopy.noDictationNotice.isEmpty)
    }

    func testEntriesThatAreNoSuccessfulDictationOnThisMacAreSkipped() throws {
        let fixture = try makeFixture()
        let skippedSources: [RecordingSource] = [.importedFile, .recorder, .iPhone, .windows]
        for (offset, source) in skippedSources.enumerated() {
            let id = fixture.addDictation(
                rawText: "Text from \(source.rawValue)",
                timestamp: Date(timeIntervalSinceNow: Double(-offset)),
                recordsSessionEntry: false
            )
            try XCTUnwrap(fixture.historyService.record(withID: id)).source = source
        }
        let failedID = fixture.addDictation(rawText: "Failed dictation", recordsSessionEntry: false)
        try XCTUnwrap(fixture.historyService.record(withID: failedID)).processingState = .failed
        // History sync imports another Mac's dictations with the Mac source and that Mac's device.
        let otherMacID = fixture.addDictation(rawText: "Dictated on another Mac", recordsSessionEntry: false)
        try XCTUnwrap(fixture.historyService.record(withID: otherMacID)).originDeviceID = "other-mac"
        XCTAssertTrue(fixture.historyService.addSpeakerRecord(
            id: UUID(),
            text: "Speaker one talks.",
            title: nil,
            source: .mac,
            durationSeconds: 3,
            language: "en",
            engineUsed: "test",
            timedText: [],
            granularity: .segment
        ))

        XCTAssertNil(fixture.handler.latestTarget())
        fixture.handler.toggle(currentState: .idle)
        XCTAssertEqual(fixture.presenter.notices, [LastDictationCorrectionCopy.noDictationNotice])

        let older = fixture.addDictation(rawText: "A real dictation.", timestamp: Date(timeIntervalSinceNow: -600))
        XCTAssertEqual(fixture.handler.latestTarget()?.id, older)
    }

    func testEditorOpensOnlyBetweenDictations() throws {
        let fixture = try makeFixture()
        fixture.addDictation(rawText: "Ask about Kubernetis.")

        let busyStates: [DictationViewModel.State] = [
            .recording, .processing, .promptSelection("Text"), .promptProcessing("Prompt"),
        ]
        for state in busyStates {
            fixture.handler.toggle(currentState: state)
        }
        XCTAssertTrue(fixture.presenter.shownTargets.isEmpty)
        XCTAssertEqual(
            fixture.presenter.notices,
            Array(repeating: LastDictationCorrectionCopy.busyNotice, count: busyStates.count)
        )

        // Right after the insertion the indicator still shows its result; the editor opens then.
        for state: DictationViewModel.State in [.inserting, .error("Failed"), .idle] {
            fixture.handler.toggle(currentState: state)
            XCTAssertTrue(fixture.presenter.isEditorVisible, "\(state)")
            fixture.presenter.cancel()
        }
        XCTAssertEqual(fixture.presenter.shownTargets.count, 3)
    }

    func testEveryLearningOutcomeHasADetail() throws {
        let outcomes: [LastDictationCorrectionLearning] = [
            .learned([LearnedDictionaryCorrection(id: UUID(), original: "Jon", replacement: "John")]),
            .learned([
                LearnedDictionaryCorrection(id: UUID(), original: "Jon", replacement: "John"),
                LearnedDictionaryCorrection(id: UUID(), original: "Smith", replacement: "Smyth"),
            ]),
            .unchanged, .notConfident, .awaitingRepeat, .alreadyInDictionary, .failed, .turnedOff, .requiresLicense,
        ]
        let details = try outcomes.map { try XCTUnwrap(LastDictationCorrectionCopy.learningDetail(for: $0)) }
        XCTAssertFalse(details.contains(where: \.isEmpty))
        XCTAssertEqual(Set(details).count, details.count, "Each outcome reads differently")
        for availability in [CorrectionLearningAvailability.available, .turnedOff, .requiresLicense] {
            XCTAssertFalse(try XCTUnwrap(LastDictationCorrectionCopy.learningHint(for: availability)).isEmpty)
        }

        // Where the edition does not learn, the editor and the result do not mention learning.
        XCTAssertNil(LastDictationCorrectionCopy.learningHint(for: .notOffered))
        XCTAssertNil(LastDictationCorrectionCopy.learningDetail(for: .notOffered))
        let confirmation = LastDictationCorrectionConfirmation(
            correctedText: "Text",
            textChanged: true,
            learning: .notOffered,
            updatedHistory: true
        )
        XCTAssertEqual(
            LastDictationCorrectionCopy.announcement(for: confirmation),
            LastDictationCorrectionCopy.title(for: confirmation)
        )
    }
}
