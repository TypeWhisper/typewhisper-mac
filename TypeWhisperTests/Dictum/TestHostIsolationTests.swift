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

    func testAppDomainIsNeverRecordedForRemoval() throws {
        let appDomain = try XCTUnwrap(Bundle.main.bundleIdentifier)
        _ = UserDefaults(suiteName: appDomain)

        XCTAssertFalse(TestHostIsolation.createdSuiteNames.withLock { $0.contains(appDomain) })
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
