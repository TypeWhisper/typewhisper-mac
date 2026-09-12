import XCTest
import TypeWhisperPluginSDK
@testable import TypeWhisper

final class TranscriptionNormalizationServiceTests: XCTestCase {
    @MainActor
    func testDefaultOnPreservesSmallNumbersBeforePostProcessing() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        let result = TranscriptionNormalizationService.normalizeText(
            "I have two questions",
            language: "en",
            defaults: defaults
        )

        XCTAssertEqual(result, "I have two questions")
    }

    @MainActor
    func testDutchLocalePreservesSmallNumbersBeforePostProcessing() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        let result = TranscriptionNormalizationService.normalizeText(
            "ik heb twee vragen",
            language: "nl-NL",
            defaults: defaults
        )

        XCTAssertEqual(result, "ik heb twee vragen")
    }

    @MainActor
    func testGlobalOffSkipsNormalization() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set(false, forKey: UserDefaultsKeys.transcriptionNumberNormalizationEnabled)
        defer { defaults.removePersistentDomain(forName: #function) }

        let result = TranscriptionNormalizationService.normalizeText(
            "I have twenty three questions",
            language: "en",
            defaults: defaults
        )

        XCTAssertEqual(result, "I have twenty three questions")
    }

    @MainActor
    func testWorkflowOverrideOffWinsOverGlobalOn() async throws {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set(true, forKey: UserDefaultsKeys.transcriptionNumberNormalizationEnabled)
        defer { defaults.removePersistentDomain(forName: #function) }

        let result = TranscriptionNormalizationService.normalizeText(
            "I have twenty three questions",
            language: "en",
            normalizeNumbers: false,
            defaults: defaults
        )

        XCTAssertEqual(result, "I have twenty three questions")
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

    func testMinimumValueDefaultsAndInvalidSettings() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        XCTAssertEqual(TranscriptionNormalizationService.numberNormalizationMinimumValue(defaults: defaults), 10)
        for value in [0, 10, 100] {
            defaults.set(value, forKey: UserDefaultsKeys.transcriptionNumberNormalizationMinimumValue)
            XCTAssertEqual(TranscriptionNormalizationService.numberNormalizationMinimumValue(defaults: defaults), value)
        }
        for value in [-1, 3, 999] {
            defaults.set(value, forKey: UserDefaultsKeys.transcriptionNumberNormalizationMinimumValue)
            XCTAssertEqual(TranscriptionNormalizationService.numberNormalizationMinimumValue(defaults: defaults), 10)
        }
    }

    func testAlwaysRestoresSmallNumberNormalization() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set(0, forKey: UserDefaultsKeys.transcriptionNumberNormalizationMinimumValue)
        defer { defaults.removePersistentDomain(forName: #function) }

        XCTAssertEqual(TranscriptionNormalizationService.normalizeText("one of my clients", language: "en", defaults: defaults), "1 of my clients")
    }

    func testWorkflowOverrideOnUsesGlobalThresholdEvenWhenGlobalNormalizationIsOff() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set(false, forKey: UserDefaultsKeys.transcriptionNumberNormalizationEnabled)
        defaults.set(100, forKey: UserDefaultsKeys.transcriptionNumberNormalizationMinimumValue)
        defer { defaults.removePersistentDomain(forName: #function) }

        let text = "three, ten, one hundred"
        XCTAssertEqual(TranscriptionNormalizationService.normalizeText(text, language: "en", defaults: defaults), text)
        XCTAssertEqual(TranscriptionNormalizationService.normalizeText(text, language: "en", normalizeNumbers: true, defaults: defaults), "three, ten, 100")
    }

    func testThresholdAppliesConsistentlyToTextAndSegments() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set(100, forKey: UserDefaultsKeys.transcriptionNumberNormalizationMinimumValue)
        defer { defaults.removePersistentDomain(forName: #function) }

        let result = TranscriptionNormalizationService.normalizeResult(
            text: "Three, twenty-three, one hundred",
            detectedLanguage: "en",
            configuredLanguage: "en",
            duration: 3,
            processingTime: 0.1,
            engineUsed: "test",
            segments: [
                TranscriptionSegment(text: "Three, twenty-three", start: 0, end: 1),
                TranscriptionSegment(text: "one hundred", start: 1, end: 3)
            ],
            task: .transcribe,
            defaults: defaults
        )

        XCTAssertEqual(result.text, "Three, twenty-three, 100")
        XCTAssertEqual(result.segments.map(\.text), ["Three, twenty-three", "100"])
        XCTAssertEqual(result.segments.map(\.start), [0, 1])
        XCTAssertEqual(result.segments.map(\.end), [1, 3])
    }
}
