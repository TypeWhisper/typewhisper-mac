import AppKit
import XCTest
@testable import TypeWhisper

@MainActor
final class AppDelegateLifecycleTests: XCTestCase {
    /// #1721: on macOS 15, SwiftUI quit the menu bar app when the last window was closed.
    func testClosingTheLastWindowKeepsTheMenuBarAppRunning() {
        let delegate: NSApplicationDelegate = AppDelegate()

        XCTAssertEqual(
            delegate.applicationShouldTerminateAfterLastWindowClosed?(NSApplication.shared),
            false
        )
    }

    /// "Update All and Restart" and the language restart bring Settings back on the same page.
    func testRelaunchSettingsPageIsReadOnceByTheNextLaunch() throws {
        let suiteName = "RelaunchSettingsPageTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let restart = Date()

        for page in RelaunchSettingsPage.allCases {
            page.store(in: defaults, now: restart)
            XCTAssertEqual(RelaunchSettingsPage.consume(from: defaults, now: restart.addingTimeInterval(2)), page)
            XCTAssertNil(RelaunchSettingsPage.consume(from: defaults, now: restart.addingTimeInterval(3)))
        }

        RelaunchSettingsPage.integrations.store(in: defaults, now: restart)
        XCTAssertNil(RelaunchSettingsPage.consume(
            from: defaults,
            now: restart.addingTimeInterval(RelaunchSettingsPage.maximumAge + 1)
        ))
        XCTAssertNil(defaults.object(forKey: UserDefaultsKeys.relaunchSettingsPage))
    }
}
