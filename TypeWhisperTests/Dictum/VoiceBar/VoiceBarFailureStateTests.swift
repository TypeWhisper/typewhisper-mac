import XCTest
@testable import TypeWhisper

@MainActor
final class VoiceBarFailureStateTests: XCTestCase {
    private typealias Outcome = VoiceBarState.Input.Outcome

    func testOrdinaryErrorsAreTimedFailuresAndOnlyMicrophoneProblemsBlock() {
        let cases: [(icon: String?, isError: Bool, tab: SettingsTab?, expected: VoiceBarState?)] = [
            ("xmark.circle.fill", true, nil, .failure("m", destination: nil)),
            ("xmark.circle.fill", true, .dictation, .failure("m", destination: .page(.speech))),
            ("xmark.circle.fill", true, .installedPlugin(pluginId: "com.example.engine"), .failure("m", destination: .page(.speech))),
            ("xmark.circle.fill", true, .general, .failure("m", destination: .page(.general))),
            ("xmark.circle.fill", true, .dictationRecovery, .failure("m", destination: .advancedSettings)),
            ("exclamationmark.triangle", true, nil, .failure("m", destination: nil)),
            ("xmark.circle.fill", true, .home, .blockingError("m", page: .home)),
            ("mic.slash", true, nil, .blockingError("m", page: .general)),
            ("mic.slash", false, nil, .noSpeech),
            ("exclamationmark.triangle.fill", false, nil, .recoveredError),
            ("doc.on.clipboard", false, nil, .copied),
            ("checkmark.circle.fill", false, nil, nil),
        ]
        for (icon, isError, tab, expected) in cases {
            let outcome = Outcome.feedback(icon: icon, message: "m", isError: isError, settingsTab: tab, translation: false)
            var input = VoiceBarState.Input()
            input.outcome = outcome
            let state = outcome == nil ? nil : VoiceBarState.derive(input)
            XCTAssertEqual(state, expected, "\(icon ?? "nil") isError=\(isError) tab=\(String(describing: tab))")
        }
    }

    func testTranslationWarningKeepsItsOwnState() {
        let outcome = Outcome.feedback(icon: "exclamationmark.triangle.fill", message: "m", isError: false, settingsTab: nil, translation: true)
        var input = VoiceBarState.Input()
        input.outcome = outcome
        XCTAssertEqual(VoiceBarState.derive(input), .translationFailed)
    }

    func testUndoWithNothingToUndoShowsOneFailureForExactlyTheFeedbackDuration() async throws {
        let dictation = DictationViewModel.shared
        dictation.state = .idle
        let presentation = VoiceBarPresentation()
        let start = Date()
        dictation.undoLastDictation()
        presentation.refresh(dictation)

        guard case .failure(let message, let destination) = presentation.state else {
            return XCTFail("Expected a timed failure, got \(presentation.state)")
        }
        XCTAssertEqual(message, dictation.actionFeedbackMessage)
        XCTAssertFalse(message.isEmpty)
        XCTAssertNil(destination)
        XCTAssertTrue(presentation.isActive)
        XCTAssertTrue(VoiceBarPresentation.replacesLegacyIndicator(dictation))

        var remainedAt: TimeInterval = 0
        while presentation.isActive, Date().timeIntervalSince(start) < 8 {
            try await Task.sleep(for: .milliseconds(50))
            presentation.refresh(dictation)
            if presentation.isActive { remainedAt = Date().timeIntervalSince(start) }
        }
        let shownFor = Date().timeIntervalSince(start)
        XCTAssertFalse(presentation.isActive)
        // 反馈时长是听写模型的 actionDisplayDuration（默认 2.5 秒），不会一直停在屏幕上。
        XCTAssertGreaterThan(remainedAt, 2.0)
        XCTAssertLessThan(shownFor, 4.5)
    }

    func testEngineNotReadyShowsFailureThatOpensSpeech() async throws {
        let dictation = DictationViewModel.shared
        let manager = ServiceContainer.shared.modelManagerService
        let selected = manager.selectedProviderId
        defer {
            if let selected { manager.selectProvider(selected) } else { manager.clearProviderSelection() }
            dictation.dismissActionFeedback()
            dictation.state = .idle
        }
        dictation.state = .idle
        manager.clearProviderSelection()
        let presentation = VoiceBarPresentation()
        _ = dictation.apiStartRecording()
        presentation.refresh(dictation)

        guard case .failure(let message, let destination) = presentation.state else {
            return XCTFail("Expected a timed failure, got \(presentation.state)")
        }
        XCTAssertEqual(message, dictation.actionFeedbackMessage)
        XCTAssertEqual(destination, .page(.speech))
        XCTAssertTrue(presentation.isActive)
    }
}
