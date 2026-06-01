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
}
