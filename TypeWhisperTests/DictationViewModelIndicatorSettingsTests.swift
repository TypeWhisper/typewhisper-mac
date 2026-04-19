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

    func testAggressiveShortSpeechTranscriptionDefaultsToDisabled() {
        XCTAssertFalse(DictationViewModel.loadTranscribeShortQuietClipsAggressively(defaults: defaults))
    }

    func testAggressiveShortSpeechTranscriptionPersistsWhenEnabled() {
        DictationViewModel.persistTranscribeShortQuietClipsAggressively(true, defaults: defaults)

        XCTAssertEqual(
            defaults.object(forKey: UserDefaultsKeys.transcribeShortQuietClipsAggressively) as? Bool,
            true
        )
        XCTAssertTrue(DictationViewModel.loadTranscribeShortQuietClipsAggressively(defaults: defaults))
    }
}

final class DockIconVisibilityTests: XCTestCase {
    func testDockIconStaysHiddenWhenMenuBarIconIsVisibleAndNoWindowIsOpen() {
        XCTAssertFalse(
            DockIconVisibility.shouldShowDockIcon(
                showMenuBarIcon: true,
                dockIconBehavior: .keepVisible,
                hasVisibleManagedWindow: false
            )
        )
    }

    func testDockIconStaysVisibleWhenMenuBarIconIsHiddenAndBehaviorKeepsItVisible() {
        XCTAssertTrue(
            DockIconVisibility.shouldShowDockIcon(
                showMenuBarIcon: false,
                dockIconBehavior: .keepVisible,
                hasVisibleManagedWindow: false
            )
        )
    }

    func testDockIconStaysHiddenWhenMenuBarIconIsHiddenAndBehaviorRequiresWindow() {
        XCTAssertFalse(
            DockIconVisibility.shouldShowDockIcon(
                showMenuBarIcon: false,
                dockIconBehavior: .onlyWhileWindowOpen,
                hasVisibleManagedWindow: false
            )
        )
    }

    func testDockIconAppearsWhileManagedWindowIsVisibleEvenWhenBehaviorRequiresWindow() {
        XCTAssertTrue(
            DockIconVisibility.shouldShowDockIcon(
                showMenuBarIcon: false,
                dockIconBehavior: .onlyWhileWindowOpen,
                hasVisibleManagedWindow: true
            )
        )
    }

    func testDockIconAppearsForInteractiveForegroundContent() {
        XCTAssertTrue(
            DockIconVisibility.shouldShowDockIcon(
                showMenuBarIcon: true,
                dockIconBehavior: .onlyWhileWindowOpen,
                hasVisibleManagedWindow: false,
                hasInteractiveForegroundContent: true
            )
        )
    }
}

final class LanguageLocalizationTests: XCTestCase {
    private var originalPreferredAppLanguage: String?

    override func setUp() {
        super.setUp()
        originalPreferredAppLanguage = UserDefaults.standard.string(forKey: UserDefaultsKeys.preferredAppLanguage)
    }

    override func tearDown() {
        if let originalPreferredAppLanguage {
            UserDefaults.standard.set(originalPreferredAppLanguage, forKey: UserDefaultsKeys.preferredAppLanguage)
        } else {
            UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.preferredAppLanguage)
        }
        super.tearDown()
    }

    func testLocalizedAppLanguageOptionsFollowPreferredAppLanguage() {
        UserDefaults.standard.set("en", forKey: UserDefaultsKeys.preferredAppLanguage)

        let options = localizedAppLanguageOptions(for: ["de", "en"])

        XCTAssertEqual(options.map(\.code), ["de", "en"])
        XCTAssertEqual(options.map(\.name), ["German", "English"])
    }

    func testLanguageSearchTermsIncludeEnglishAliasForEnglish() {
        UserDefaults.standard.set("de", forKey: UserDefaultsKeys.preferredAppLanguage)

        let searchTerms = localizedAppLanguageSearchTerms(for: "en")

        XCTAssertTrue(searchTerms.contains(where: { $0.localizedCaseInsensitiveContains("english") }))
        XCTAssertTrue(searchTerms.contains(where: { $0.localizedCaseInsensitiveContains("englisch") }))
    }
}
