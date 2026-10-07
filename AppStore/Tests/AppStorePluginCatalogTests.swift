import XCTest
@testable import TypeWhisper

@MainActor
final class AppStorePluginCatalogTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AppStorePluginCatalogTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testSpeakerDetectionIsAlwaysInstalled() {
        let speakerID = SpeakerTranscriptCoordinator.bundledPluginID

        XCTAssertTrue(AppStorePluginCatalog.isInstalled(speakerID, userDefaults: defaults))

        AppStorePluginCatalog.setInstalled(false, pluginId: speakerID, userDefaults: defaults)

        XCTAssertTrue(AppStorePluginCatalog.isInstalled(speakerID, userDefaults: defaults))
    }

    func testMarketplacePluginsStillNeedInstalling() {
        XCTAssertFalse(AppStorePluginCatalog.isInstalled("com.typewhisper.parakeet", userDefaults: defaults))

        AppStorePluginCatalog.setInstalled(true, pluginId: "com.typewhisper.parakeet", userDefaults: defaults)

        XCTAssertTrue(AppStorePluginCatalog.isInstalled("com.typewhisper.parakeet", userDefaults: defaults))
    }

    func testSpeakerDetectionIsBundledButNotListedInTheMarketplace() {
        let speakerID = SpeakerTranscriptCoordinator.bundledPluginID

        let listed = AppStorePluginCatalog.registryPlugins().map(\.id)

        XCTAssertTrue(AppStorePluginCatalog.entries().contains { $0.id == speakerID })
        XCTAssertTrue(listed.contains("com.typewhisper.parakeet"))
        XCTAssertFalse(listed.contains(speakerID))
    }
}
