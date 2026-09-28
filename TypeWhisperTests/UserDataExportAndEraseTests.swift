import XCTest
@testable import TypeWhisper

@MainActor
final class UserDataExportAndEraseTests: XCTestCase {
    private struct Fixture {
        let dir: URL
        let locations: UserDataLocations
        let userDefaults: UserDefaults
        let suiteName: String
    }

    private func makeFixture() throws -> Fixture {
        let dir = try TestSupport.makeTemporaryDirectory()
        let appSupport = dir.appendingPathComponent("AppSupport", isDirectory: true)
        let auxiliary = dir.appendingPathComponent("Caches/com.typewhisper.mac.tests", isDirectory: true)
        let suiteName = "UserDataExportAndEraseTests-\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))

        try write("history", to: appSupport.appendingPathComponent("history.store"))
        try write("wav", to: appSupport.appendingPathComponent("audio/one.wav"))
        try write("memory", to: appSupport.appendingPathComponent("PluginData/com.test.memory/memories.json"))
        try write("weights", to: appSupport.appendingPathComponent("PluginData/com.test.whisper/models/tiny/model.bin"))
        try write("weights", to: appSupport.appendingPathComponent("PluginData/com.test.cohere/Models/model.gguf"))
        try write("weights", to: appSupport.appendingPathComponent("PluginData/com.test.canary/custom-models/model.nemo"))
        try write("link", to: appSupport.appendingPathComponent("PluginData/com.test.weblink/Imports/page.html"))
        try write("bundle", to: appSupport.appendingPathComponent("Plugins/Test.bundle/Contents/Info.plist"))
        try write("cache", to: appSupport.appendingPathComponent("MarketplaceCache/registry.json"))
        try write("{\"token\":\"secret\"}", to: appSupport.appendingPathComponent("api-discovery.json"))
        try write("8978", to: appSupport.appendingPathComponent("api-port"))
        try write("cache", to: auxiliary.appendingPathComponent("Cache.db"))

        userDefaults.set("de", forKey: "selectedLanguage")
        userDefaults.set(Data([1, 2, 3]), forKey: "cloudFolderSync.folderBookmark")
        userDefaults.set(Date(timeIntervalSince1970: 0), forKey: "pluginRegistryLastUpdateCheck")

        return Fixture(
            dir: dir,
            locations: UserDataLocations(
                appSupportDirectory: appSupport,
                auxiliaryItems: [auxiliary, dir.appendingPathComponent("missing.json")],
                preferencesDomain: suiteName
            ),
            userDefaults: userDefaults,
            suiteName: suiteName
        )
    }

    private func teardown(_ fixture: Fixture) {
        TestSupport.remove(fixture.dir)
        fixture.userDefaults.removePersistentDomain(forName: fixture.suiteName)
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    // MARK: - Export

    func testShouldExportSkipsModelsPluginsAndSecrets() {
        XCTAssertTrue(UserDataExportService.shouldExport(relativePath: "history.store"))
        XCTAssertTrue(UserDataExportService.shouldExport(relativePath: "PluginData/com.test/memories.json"))
        XCTAssertTrue(UserDataExportService.shouldExport(relativePath: "PluginData/com.test/Imports"))
        XCTAssertTrue(UserDataExportService.shouldExport(relativePath: "audio/models/clip.wav"))

        XCTAssertFalse(UserDataExportService.shouldExport(relativePath: "Plugins"))
        XCTAssertFalse(UserDataExportService.shouldExport(relativePath: "MarketplaceCache/registry.json"))
        XCTAssertFalse(UserDataExportService.shouldExport(relativePath: "models"))
        XCTAssertFalse(UserDataExportService.shouldExport(relativePath: "api-discovery.json"))
        XCTAssertFalse(UserDataExportService.shouldExport(relativePath: "api-port"))
        XCTAssertFalse(UserDataExportService.shouldExport(relativePath: "PluginData/com.test/models"))
        XCTAssertFalse(UserDataExportService.shouldExport(relativePath: "PluginData/com.test/Models/a.gguf"))
        XCTAssertFalse(UserDataExportService.shouldExport(relativePath: "PluginData/com.test/custom-models"))
    }

    func testExportWritesArchiveWithUserDataOnly() async throws {
        let fixture = try makeFixture()
        defer { teardown(fixture) }

        let destination = fixture.dir.appendingPathComponent("TypeWhisper Data 2026-09-28.zip")
        try await UserDataExportService.export(
            to: destination,
            settingsBackup: Data("{\"schemaVersion\":1}".utf8),
            locations: fixture.locations,
            userDefaults: fixture.userDefaults
        )

        let extracted = fixture.dir.appendingPathComponent("Extracted", isDirectory: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", destination.path, extracted.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let root = extracted.appendingPathComponent("TypeWhisper Data 2026-09-28", isDirectory: true)
        let files = try XCTUnwrap(FileManager.default.subpaths(atPath: root.path))
            .filter { !$0.hasSuffix("/") }
        let expectedPresent = [
            "README.txt",
            "preferences.json",
            "settings-backup.json",
            "Application Support/history.store",
            "Application Support/audio/one.wav",
            "Application Support/PluginData/com.test.memory/memories.json",
            "Application Support/PluginData/com.test.weblink/Imports/page.html",
        ]
        for path in expectedPresent {
            XCTAssertTrue(files.contains(path), "missing \(path)")
        }
        for file in files {
            XCTAssertFalse(file.contains("models") || file.contains("Models"), "unexpected \(file)")
            XCTAssertFalse(file.hasPrefix("Application Support/Plugins"), "unexpected \(file)")
            XCTAssertFalse(file.hasPrefix("Application Support/MarketplaceCache"), "unexpected \(file)")
            XCTAssertFalse(file.hasPrefix("Application Support/api-"), "unexpected \(file)")
        }

        let preferencesData = try Data(contentsOf: root.appendingPathComponent("preferences.json"))
        let preferences = try XCTUnwrap(JSONSerialization.jsonObject(with: preferencesData) as? [String: Any])
        XCTAssertEqual(preferences["selectedLanguage"] as? String, "de")
        XCTAssertEqual(preferences["cloudFolderSync.folderBookmark"] as? String, Data([1, 2, 3]).base64EncodedString())
        XCTAssertEqual(preferences["pluginRegistryLastUpdateCheck"] as? String, "1970-01-01T00:00:00Z")
    }

    func testExportReplacesExistingArchive() async throws {
        let fixture = try makeFixture()
        defer { teardown(fixture) }

        let destination = fixture.dir.appendingPathComponent("export.zip")
        try write("old", to: destination)
        try await UserDataExportService.export(
            to: destination,
            settingsBackup: nil,
            locations: fixture.locations,
            userDefaults: fixture.userDefaults
        )

        let data = try Data(contentsOf: destination)
        XCTAssertEqual(data.prefix(2), Data("PK".utf8))
    }

    // MARK: - Erase

    func testEraseAllRemovesFilesPreferencesAndKeychainItems() throws {
        let fixture = try makeFixture()
        defer { teardown(fixture) }

        var keychainDeleted = false
        var systemReset = false
        let failures = UserDataEraser.eraseAll(
            locations: fixture.locations,
            userDefaults: fixture.userDefaults,
            deleteKeychainItems: { keychainDeleted = true },
            resetSystemRegistrations: { systemReset = true }
        )

        XCTAssertEqual(failures, [])
        XCTAssertTrue(keychainDeleted)
        XCTAssertTrue(systemReset)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.locations.appSupportDirectory.path))
        for item in fixture.locations.auxiliaryItems {
            XCTAssertFalse(FileManager.default.fileExists(atPath: item.path))
        }
        XCTAssertNil(fixture.userDefaults.string(forKey: "selectedLanguage"))
        XCTAssertNil(fixture.userDefaults.persistentDomain(forName: fixture.suiteName)?["selectedLanguage"])
    }

    func testEraseAllContinuesAfterKeychainFailure() throws {
        let fixture = try makeFixture()
        defer { teardown(fixture) }

        let failures = UserDataEraser.eraseAll(
            locations: fixture.locations,
            userDefaults: fixture.userDefaults,
            deleteKeychainItems: { throw KeychainError.deleteFailed(errSecInteractionNotAllowed) },
            resetSystemRegistrations: {}
        )

        XCTAssertEqual(failures.map(\.item), ["Keychain"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.locations.appSupportDirectory.path))
        XCTAssertNil(fixture.userDefaults.string(forKey: "selectedLanguage"))
    }
}
