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

private final class SerializedBrowserResolutionProbe: @unchecked Sendable {
    private struct State {
        var activeCalls = 0
        var maximumActiveCalls = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func resolve(bundleIdentifier: String, includeTitle: Bool) -> BrowserResolution {
        state.withLock {
            $0.activeCalls += 1
            $0.maximumActiveCalls = max($0.maximumActiveCalls, $0.activeCalls)
        }
        Thread.sleep(forTimeInterval: 0.05)
        state.withLock { $0.activeCalls -= 1 }
        return BrowserResolution(url: URL(string: "https://example.com"), title: nil)
    }

    var maximumActiveCalls: Int { state.withLock { $0.maximumActiveCalls } }
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
            SupportedMeetingBrowser.wavebox
        ]
        XCTAssertTrue(automatic.allSatisfy(SupportedMeetingBrowser.supportsAutomaticURLResolution))

        let reminderOnly = [SupportedMeetingBrowser.firefox, SupportedMeetingBrowser.zen]
        XCTAssertTrue(reminderOnly.allSatisfy(SupportedMeetingBrowser.isKnownBrowser))
        XCTAssertTrue(reminderOnly.allSatisfy {
            !SupportedMeetingBrowser.supportsAutomaticURLResolution($0)
        })
        XCTAssertFalse(SupportedMeetingBrowser.supportsAutomaticURLResolution(
            "com.example.wavebox-lookalike"
        ))
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

    func testResolverSerializesConcurrentResolutionRequests() async {
        let probe = SerializedBrowserResolutionProbe()
        let resolver = BrowserURLResolver { bundleIdentifier, includeTitle in
            probe.resolve(bundleIdentifier: bundleIdentifier, includeTitle: includeTitle)
        }

        async let first = resolver.activeURL(for: SupportedMeetingBrowser.safari)
        async let second = resolver.activeURL(for: SupportedMeetingBrowser.chrome)
        _ = await (first, second)

        XCTAssertEqual(probe.maximumActiveCalls, 1)
    }
}
