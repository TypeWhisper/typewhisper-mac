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
}
