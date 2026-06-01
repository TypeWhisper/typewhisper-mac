import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

final class TranscriptionNormalizationServiceTests: XCTestCase {
    @MainActor
    func testDefaultOnNormalizesBeforePostProcessing() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        let result = TranscriptionNormalizationService.normalizeText(
            "I have two questions",
            language: "en",
            defaults: defaults
        )

        XCTAssertEqual(result, "I have 2 questions")
    }

    @MainActor
    func testGlobalOffSkipsNormalization() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set(false, forKey: UserDefaultsKeys.transcriptionNumberNormalizationEnabled)
        defer { defaults.removePersistentDomain(forName: #function) }

        let result = TranscriptionNormalizationService.normalizeText(
            "I have two questions",
            language: "en",
            defaults: defaults
        )

        XCTAssertEqual(result, "I have two questions")
    }

    @MainActor
    func testWorkflowOverrideOffWinsOverGlobalOn() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set(true, forKey: UserDefaultsKeys.transcriptionNumberNormalizationEnabled)
        defer { defaults.removePersistentDomain(forName: #function) }

        let result = TranscriptionNormalizationService.normalizeText(
            "I have two questions",
            language: "en",
            normalizeNumbers: false,
            defaults: defaults
        )

        XCTAssertEqual(result, "I have two questions")
    }

    @MainActor
    func testLaterLanguageCandidateNormalizesWhenConfiguredLanguageDoesNotMatch() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        let result = TranscriptionNormalizationService.normalizeText(
            "Set the value to twenty three",
            language: "de",
            languageCandidates: ["de", "en"],
            defaults: defaults
        )

        XCTAssertEqual(result, "Set the value to 23")
    }

    @MainActor
    func testNormalizeResultUsesLaterConfiguredLanguageCandidate() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        let result = TranscriptionNormalizationService.normalizeResult(
            text: "Set the value to twenty three",
            detectedLanguage: nil,
            configuredLanguage: "de",
            configuredLanguageCandidates: ["de", "en"],
            duration: 1,
            processingTime: 0.1,
            engineUsed: "test",
            segments: [
                TranscriptionSegment(text: "twenty three", start: 0, end: 1)
            ],
            task: .transcribe,
            defaults: defaults
        )

        XCTAssertEqual(result.text, "Set the value to 23")
        XCTAssertEqual(result.segments.first?.text, "23")
    }
}
