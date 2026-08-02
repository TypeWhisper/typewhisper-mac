import Foundation
import os
import XCTest
@testable import TypeWhisper

private final class BrowserResolutionProbe: @unchecked Sendable {
    private struct State {
        var calls: [(String, Bool)] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    let resolution: BrowserResolution

    init(resolution: BrowserResolution) {
        self.resolution = resolution
    }

    func resolve(bundleIdentifier: String, includeTitle: Bool) -> BrowserResolution {
        state.withLock { $0.calls.append((bundleIdentifier, includeTitle)) }
        return resolution
    }

    var calls: [(String, Bool)] { state.withLock { $0.calls } }
}

final class BrowserURLResolverTests: XCTestCase {
    func testSupportedAutomaticAndReminderOnlyBrowsersAreDistinct() {
        let automatic = [
            SupportedMeetingBrowser.safari,
            SupportedMeetingBrowser.chrome,
            SupportedMeetingBrowser.arc,
            SupportedMeetingBrowser.edge,
            SupportedMeetingBrowser.brave,
            SupportedMeetingBrowser.opera,
            SupportedMeetingBrowser.vivaldi,
            SupportedMeetingBrowser.chromium,
            "com.bookry.wavebox"
        ]
        XCTAssertTrue(automatic.allSatisfy(SupportedMeetingBrowser.supportsAutomaticURLResolution))

        let reminderOnly = [SupportedMeetingBrowser.firefox, SupportedMeetingBrowser.zen]
        XCTAssertTrue(reminderOnly.allSatisfy(SupportedMeetingBrowser.isKnownBrowser))
        XCTAssertTrue(reminderOnly.allSatisfy {
            !SupportedMeetingBrowser.supportsAutomaticURLResolution($0)
        })
    }

    func testResolverDelegatesURLAndTitleRequestsToInjectedProvider() async {
        let url = URL(string: "https://meet.google.com/abc-defg-hij")!
        let probe = BrowserResolutionProbe(
            resolution: BrowserResolution(url: url, title: "Daily")
        )
        let resolver = BrowserURLResolver { bundleIdentifier, includeTitle in
            probe.resolve(bundleIdentifier: bundleIdentifier, includeTitle: includeTitle)
        }

        let activeURL = await resolver.activeURL(for: SupportedMeetingBrowser.safari)
        let info = await resolver.activeBrowserInfo(for: SupportedMeetingBrowser.chrome)

        XCTAssertEqual(activeURL, url)
        XCTAssertEqual(info, BrowserResolution(url: url, title: "Daily"))
        XCTAssertEqual(probe.calls.count, 2)
        XCTAssertEqual(probe.calls[0].0, SupportedMeetingBrowser.safari)
        XCTAssertFalse(probe.calls[0].1)
        XCTAssertEqual(probe.calls[1].0, SupportedMeetingBrowser.chrome)
        XCTAssertTrue(probe.calls[1].1)
    }
}
