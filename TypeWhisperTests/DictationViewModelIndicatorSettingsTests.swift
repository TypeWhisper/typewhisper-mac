import XCTest
@testable import TypeWhisper

final class DictationViewModelIndicatorSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "DictationViewModelIndicatorSettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testIndicatorTranscriptPreviewDefaultsToEnabled() {
        XCTAssertTrue(DictationViewModel.loadIndicatorTranscriptPreviewEnabled(defaults: defaults))
    }

    func testIndicatorTranscriptPreviewPersistsWhenDisabled() {
        DictationViewModel.persistIndicatorTranscriptPreviewEnabled(false, defaults: defaults)

        XCTAssertEqual(
            defaults.object(forKey: UserDefaultsKeys.indicatorTranscriptPreviewEnabled) as? Bool,
            false
        )
        XCTAssertFalse(DictationViewModel.loadIndicatorTranscriptPreviewEnabled(defaults: defaults))
    }

    func testMissingIndicatorTranscriptPreviewKeyFallsBackToTrue() {
        defaults.removeObject(forKey: UserDefaultsKeys.indicatorTranscriptPreviewEnabled)

        XCTAssertTrue(DictationViewModel.loadIndicatorTranscriptPreviewEnabled(defaults: defaults))
    }
}
