import AppKit
import CoreGraphics
import XCTest
@testable import TypeWhisper

@MainActor
final class TestHostIsolationTests: XCTestCase {
    func testTouchingServiceContainerKeepsTheTestsPluginManager() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }
        let original = PluginManager.shared
        defer { PluginManager.shared = original }

        let replacement = PluginManager(appSupportDirectory: appSupportDirectory)
        PluginManager.shared = replacement
        _ = ServiceContainer.shared

        XCTAssertTrue(PluginManager.shared === replacement)
    }

    func testGeneralPasteboardBelongsToThisRun() {
        XCTAssertNotEqual(NSPasteboard.general.name, NSPasteboard.Name.general)
    }

    func testSuitesCreatedByTestsAreRecordedForRemoval() throws {
        let suiteName = "TestHostIsolationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(TestHostIsolation.createdSuiteNames.withLock { $0.contains(suiteName) })
    }

    func testSuiteOpenedByCodeOutsideTheTestBundleIsNotRecorded() throws {
        let suiteName = "TestHostIsolationTests-\(UUID().uuidString)"
        defer { TestHostIsolation.removeDomain(suiteName) }
        let allocated = try XCTUnwrap(
            UserDefaults.self.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue()
        )

        // 初始化方法由运行循环调用，调用栈上紧接着的映像不是测试包。
        allocated.perform(NSSelectorFromString("initWithSuiteName:"), with: suiteName, afterDelay: 0)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        XCTAssertFalse(TestHostIsolation.createdSuiteNames.withLock { $0.contains(suiteName) })
    }

    func testOnlyNewSuitesOpenedByTestCodeAreRecorded() throws {
        let appDomain = "com.example.app"
        func shouldRecord(
            _ name: String,
            exists: Bool = false,
            inTestBundle: Bool = true
        ) -> Bool {
            TestHostIsolation.shouldRecordSuite(
                named: name,
                appDomain: appDomain,
                exists: exists,
                callerIsInTestBundle: { inTestBundle }
            )
        }

        XCTAssertTrue(shouldRecord("TestHostIsolationTests-suite"))
        XCTAssertFalse(shouldRecord(appDomain))
        XCTAssertFalse(shouldRecord("COM.EXAMPLE.APP"))
        XCTAssertFalse(shouldRecord(UserDefaults.globalDomain))
        XCTAssertFalse(shouldRecord("nsglobaldomain"))
        XCTAssertFalse(shouldRecord("/Users/test/Library/Preferences/example"))
        XCTAssertFalse(shouldRecord("../x"))
        XCTAssertFalse(shouldRecord("a/../../x"))
        XCTAssertFalse(shouldRecord("com.schneidervvv.dictum"))
        XCTAssertFalse(shouldRecord("COM.SCHNEIDERVVV.DICTUM.DEV"))
        XCTAssertFalse(shouldRecord("com.schneidervvv.Dictum"))
        XCTAssertFalse(shouldRecord("com.ſchneidervvv.dictum"))
        XCTAssertFalse(shouldRecord("com.schneidervvv.dictum.dev"))
        XCTAssertFalse(shouldRecord(".GlobalPreferences"))
        XCTAssertFalse(shouldRecord(".globalpreferences"))
        XCTAssertFalse(shouldRecord("TestHostIsolationTests-suite", exists: true))
        XCTAssertFalse(shouldRecord("TestHostIsolationTests-suite", inTestBundle: false))
    }

    func testPreferencesFileRejectsProtectedAndPathLikeNames() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        let appDomain = "com.example.app"
        let rejectedNames = [
            appDomain,
            appDomain.uppercased(),
            "com.schneidervvv.dictum",
            "COM.SCHNEIDERVVV.DICTUM",
            "com.schneidervvv.dictum.dev",
            "COM.SCHNEIDERVVV.DICTUM.DEV",
            "com.schneidervvv.Dictum",
            "com.ſchneidervvv.dictum",
            UserDefaults.globalDomain,
            "nsglobaldomain",
            ".GlobalPreferences",
            ".globalpreferences",
            "../x",
            "a/../../x",
        ]

        for name in rejectedNames {
            XCTAssertNil(
                TestHostIsolation.preferencesFile(forDomain: name, in: directory, appDomain: appDomain),
                "\(name) must not resolve to a preferences file"
            )
        }

        let acceptedName = "TestHostIsolationTests-\(UUID().uuidString)"
        XCTAssertEqual(
            TestHostIsolation.preferencesFile(forDomain: acceptedName, in: directory, appDomain: appDomain),
            directory.appendingPathComponent(acceptedName + ".plist")
        )
    }

    func testRemovingADomainDeletesItsPreferencesFile() throws {
        let (suiteName, file) = try makeSuiteWithPreferencesFile()

        TestHostIsolation.removeDomain(suiteName)

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(UserDefaults(suiteName: suiteName)?.object(forKey: "key"))
        TestHostIsolation.removeDomain(suiteName)
    }

    func testSuiteManifestListsASuiteWhenTheTestCreatesIt() throws {
        let (suiteName, _) = try makeSuiteWithPreferencesFile()
        defer { TestHostIsolation.removeDomain(suiteName) }

        let manifest = TestHostIsolation.suiteManifestDirectory
            .appendingPathComponent("\(ProcessInfo.processInfo.processIdentifier).json")
        let names = try JSONDecoder().decode([String].self, from: Data(contentsOf: manifest))
        XCTAssertTrue(names.contains(suiteName))
    }

    func testAppendingToTheSuiteManifestKeepsNamesOfAnEarlierRunWithTheSameProcessID() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        let manifest = directory.appendingPathComponent("\(ProcessInfo.processInfo.processIdentifier).json")
        try JSONEncoder().encode(["earlier-run-suite"]).write(to: manifest)

        TestHostIsolation.appendToSuiteManifest(["this-run-suite"], in: directory)

        let names = try JSONDecoder().decode([String].self, from: Data(contentsOf: manifest))
        XCTAssertEqual(names, ["earlier-run-suite", "this-run-suite"])
    }

    func testManifestSweepDeletesOnlyTheListedSuiteFiles() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(root) }
        let preferences = root.appendingPathComponent("Preferences", isDirectory: true)
        let manifests = root.appendingPathComponent("Manifests", isDirectory: true)
        try FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: manifests, withIntermediateDirectories: true)
        let owned = "TestHostIsolationTests-\(UUID().uuidString)"
        defer { TestHostIsolation.removeDomain(owned) }
        let survivors = [
            preferences.appendingPathComponent("TestHostIsolationTests-unlisted.plist"),
            preferences.appendingPathComponent("com.schneidervvv.dictum.plist"),
            preferences.appendingPathComponent("com.schneidervvv.dictum.dev.plist"),
        ]
        let ownedFile = preferences.appendingPathComponent(owned + ".plist")
        for file in survivors + [ownedFile] {
            try Data("plist".utf8).write(to: file)
        }
        let endedProcessID = try endedProcessIdentifier()
        try JSONEncoder().encode([owned]).write(to: manifests.appendingPathComponent("\(endedProcessID).json"))

        TestHostIsolation.removeDomainsOfEndedRuns(manifestDirectory: manifests, preferencesDirectory: preferences)

        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedFile.path))
        for file in survivors {
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "\(file.lastPathComponent) must stay")
        }
    }

    func testEndedRunsSuitesAreRemovedAfterTheirProcessEnded() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        let endedProcessID = try endedProcessIdentifier()
        let (endedSuite, endedFile) = try makeSuiteWithPreferencesFile()
        let (runningSuite, runningFile) = try makeSuiteWithPreferencesFile()
        defer { TestHostIsolation.removeDomain(runningSuite) }
        let endedManifest = directory.appendingPathComponent("\(endedProcessID).json")
        try JSONEncoder().encode([endedSuite]).write(to: endedManifest)
        TestHostIsolation.appendToSuiteManifest([runningSuite], in: directory)
        let runningManifest = directory.appendingPathComponent("\(ProcessInfo.processInfo.processIdentifier).json")

        TestHostIsolation.removeDomainsOfEndedRuns(manifestDirectory: directory)

        XCTAssertFalse(FileManager.default.fileExists(atPath: endedFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: endedManifest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: runningFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: runningManifest.path))
    }

    private func makeSuiteWithPreferencesFile() throws -> (name: String, file: URL) {
        let suiteName = "TestHostIsolationTests-\(UUID().uuidString)"
        let file = TestHostIsolation.preferencesDirectory.appendingPathComponent(suiteName + ".plist")
        do {
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defaults.set("value", forKey: "key")
            CFPreferencesAppSynchronize(suiteName as CFString)
        }
        let deadline = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: file.path), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        return (suiteName, file)
    }

    private func endedProcessIdentifier() throws -> pid_t {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        XCTAssertTrue(TestHostIsolation.processHasEnded(process.processIdentifier))
        return process.processIdentifier
    }

    func testHotkeyEventTapOnlyListens() throws {
        let service = HotkeyService()
        service.accessibilityTrustedProvider = { true }
        service.resumeMonitoring()
        defer { service.suspendMonitoring() }

        let taps = ownEventTaps()
        guard !taps.isEmpty else {
            throw XCTSkip("Creating an event tap needs local Accessibility or Input Monitoring permission")
        }
        XCTAssertTrue(taps.allSatisfy { $0.options == .listenOnly }, "The test host must not hold an active tap")
    }

    private func ownEventTaps() -> [CGEventTapInformation] {
        var count: UInt32 = 0
        CGGetEventTapList(0, nil, &count)
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        CGGetEventTapList(count, &taps, &count)
        let processID = ProcessInfo.processInfo.processIdentifier
        return taps.prefix(Int(count)).filter { $0.tappingProcess == processID }
    }
}
