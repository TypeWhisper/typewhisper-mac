import OSLog
import XCTest
@testable import TypeWhisper

final class SecretFileStoreTests: XCTestCase {
    private var directory: URL!
    private var store: SecretFileStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = try TestSupport.makeTemporaryDirectory(prefix: "SecretFileStoreTests")
            .appendingPathComponent("AppSupport", isDirectory: true)
        store = SecretFileStore(directory: directory)
    }

    override func tearDown() {
        TestSupport.remove(directory.deletingLastPathComponent())
        super.tearDown()
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertTrue(attributes.contains(url.lastPathComponent))
        return try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        )
    }

    func testSaveThenLoadReturnsTheValueAndOverwriteReplacesIt() throws {
        XCTAssertNil(store.load(name: "deepseek.apiKey"))

        try store.save("first-value", name: "deepseek.apiKey")
        XCTAssertEqual(store.load(name: "deepseek.apiKey"), "first-value")

        try store.save("second-value", name: "deepseek.apiKey")
        XCTAssertEqual(store.load(name: "deepseek.apiKey"), "second-value")
    }

    func testValuesSurviveANewStoreInstanceOnTheSameFolder() throws {
        try store.save("kept", name: "openai.apiKey")
        XCTAssertEqual(SecretFileStore(directory: directory).load(name: "openai.apiKey"), "kept")
    }

    func testDeleteRemovesOnlyThatEntryAndMissingEntriesAreNotErrors() throws {
        try store.save("a", name: "one")
        try store.save("b", name: "two")

        try store.delete(name: "one")
        try store.delete(name: "never-saved")

        XCTAssertNil(store.load(name: "one"))
        XCTAssertEqual(store.load(name: "two"), "b")
    }

    func testDeleteOnAMissingFolderDoesNotCreateIt() throws {
        try store.delete(name: "anything")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testDeleteAllRemovesMatchingPrefixOnly() throws {
        try store.save("1", name: "app.one")
        try store.save("2", name: "app.two")
        try store.save("3", name: "other.three")

        try store.deleteAll(withNamePrefix: "app.")

        XCTAssertNil(store.load(name: "app.one"))
        XCTAssertNil(store.load(name: "app.two"))
        XCTAssertEqual(store.load(name: "other.three"), "3")
    }

    func testDeleteAllWithEmptyPrefixRemovesEverything() throws {
        try store.save("1", name: "one")
        try store.save("2", name: "two")

        try store.deleteAll(withNamePrefix: "")

        XCTAssertNil(store.load(name: "one"))
        XCTAssertNil(store.load(name: "two"))
    }

    func testFolderIs0700AndFileIs0600() throws {
        try store.save("value", name: "service")

        XCTAssertEqual(try permissions(of: directory), 0o700)
        XCTAssertEqual(try permissions(of: store.fileURL), 0o600)
    }

    func testPermissionsAreTightenedOnAnExistingWideFolderAndStayAfterRewrites() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )

        try store.save("one", name: "a")
        try store.save("two", name: "b")
        try store.delete(name: "a")

        XCTAssertEqual(try permissions(of: directory), 0o700)
        XCTAssertEqual(try permissions(of: store.fileURL), 0o600)
    }

    func testSaveReplacesTheFileAtomicallyAndLeavesNoTemporaryFile() throws {
        try store.save("one", name: "a")
        let before = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.systemFileNumber] as? Int

        try store.save("two", name: "a")
        let after = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.systemFileNumber] as? Int

        XCTAssertNotEqual(before, after, "A rename installs a new file instead of rewriting the old one")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [SecretFileStore.fileName])
    }

    func testReadersNeverSeeAPartialFileWhileWritersReplaceIt() throws {
        try store.save("stable", name: "constant")
        let store = self.store!
        let writers = DispatchQueue(label: "writers", attributes: .concurrent)
        let group = DispatchGroup()

        for index in 0..<40 {
            group.enter()
            writers.async {
                try? store.save(String(repeating: "x", count: 4096) + "\(index)", name: "writer.\(index % 5)")
                group.leave()
            }
            group.enter()
            writers.async {
                XCTAssertEqual(store.load(name: "constant"), "stable")
                group.leave()
            }
        }
        group.wait()
    }

    func testConcurrentSavesOfDifferentNamesAreAllKept() throws {
        let store = self.store!
        DispatchQueue.concurrentPerform(iterations: 60) { index in
            try? store.save("value-\(index)", name: "service.\(index)")
        }

        for index in 0..<60 {
            XCTAssertEqual(store.load(name: "service.\(index)"), "value-\(index)")
        }
    }

    func testCorruptFileIsMovedAsideAndTreatedAsEmpty() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ this is not json".utf8).write(to: store.fileURL)

        XCTAssertNil(store.load(name: "service"))

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(names.contains(SecretFileStore.fileName))
        XCTAssertEqual(names.filter { $0.hasPrefix("\(SecretFileStore.fileName).corrupt-") }.count, 1)

        try store.save("fresh", name: "service")
        XCTAssertEqual(store.load(name: "service"), "fresh")
    }

    func testCorruptFileDoesNotBlockSaving() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("[1, 2, 3]".utf8).write(to: store.fileURL)

        try store.save("value", name: "service")

        XCTAssertEqual(store.load(name: "service"), "value")
    }

    func testCorruptFileContentsAreNeverWrittenToTheLog() throws {
        let secret = "sk-corrupt-file-secret-\(UUID().uuidString)"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{\"service\": \"\(secret)\"".utf8).write(to: store.fileURL)

        _ = store.load(name: "service")
        try store.save("value-\(secret)", name: "other")

        let logStore = try OSLogStore(scope: .currentProcessIdentifier)
        let position = logStore.position(timeIntervalSinceLatestBoot: 0)
        let predicate = NSPredicate(format: "subsystem == %@ AND category == %@", AppConstants.loggerSubsystem, "SecretFileStore")
        let messages = try logStore.getEntries(at: position, matching: predicate)
            .compactMap { ($0 as? OSLogEntryLog)?.composedMessage }

        XCTAssertFalse(messages.isEmpty, "The corrupt file is reported once in the log")
        XCTAssertFalse(messages.contains { $0.contains(secret) })
    }
}

@MainActor
final class KeychainServiceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = try TestSupport.makeTemporaryDirectory(prefix: "KeychainServiceTests")
        AppConstants.testAppSupportDirectoryOverride = directory
    }

    override func tearDown() {
        AppConstants.testAppSupportDirectoryOverride = nil
        TestSupport.remove(directory)
        super.tearDown()
    }

    private var fileText: String {
        (try? String(contentsOf: directory.appendingPathComponent(SecretFileStore.fileName), encoding: .utf8)) ?? ""
    }

    func testSaveLoadDeleteStoreEntriesInTheAppSupportSecretsFile() throws {
        try KeychainService.save(key: "value", service: "plugin.apiKey")

        XCTAssertEqual(KeychainService.load(service: "plugin.apiKey"), "value")
        XCTAssertTrue(fileText.contains("\(AppConstants.secretKeyPrefix)plugin.apiKey"))

        try KeychainService.delete(service: "plugin.apiKey")
        XCTAssertNil(KeychainService.load(service: "plugin.apiKey"))
    }

    func testDeleteAllRemovesEntriesOfThePrefix() throws {
        try KeychainService.save(key: "1", service: "plugin.one")
        try KeychainService.save(key: "2", service: "other.two")

        try KeychainService.deleteAll(withServicePrefix: "plugin.")

        XCTAssertNil(KeychainService.load(service: "plugin.one"))
        XCTAssertEqual(KeychainService.load(service: "other.two"), "2")

        try UserDataEraser.deleteAppSecrets()
        XCTAssertNil(KeychainService.load(service: "other.two"))
    }

    func testPluginSecretsGoThroughTheSecretsFile() throws {
        let host = HostServicesImpl(
            pluginId: "com.test.provider",
            eventBus: EventBus(),
            ruleNamesProvider: { [] }
        )

        try host.storeSecret(key: "apiKey", value: "plugin-secret")

        XCTAssertEqual(KeychainService.load(service: "com.test.provider.apiKey"), "plugin-secret")
        XCTAssertEqual(host.loadSecret(key: "apiKey"), "plugin-secret")

        try host.storeSecret(key: "apiKey", value: "")
        XCTAssertNil(host.loadSecret(key: "apiKey"))
    }
}
