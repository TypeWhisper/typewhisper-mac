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

    func testIndicatorStyleDefaultsToNotch() {
        defaults.removeObject(forKey: UserDefaultsKeys.indicatorStyle)

        XCTAssertEqual(DictationViewModel.loadIndicatorStyle(defaults: defaults), .notch)
    }

    func testIndicatorStylePersistsMinimal() {
        DictationViewModel.persistIndicatorStyle(.minimal, defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: UserDefaultsKeys.indicatorStyle), IndicatorStyle.minimal.rawValue)
        XCTAssertEqual(DictationViewModel.loadIndicatorStyle(defaults: defaults), .minimal)
    }

    func testUnknownIndicatorStyleFallsBackToNotch() {
        defaults.set("mystery", forKey: UserDefaultsKeys.indicatorStyle)

        XCTAssertEqual(DictationViewModel.loadIndicatorStyle(defaults: defaults), .notch)
    }
}
