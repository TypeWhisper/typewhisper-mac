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
    func testMeetingTabsDoNotChangeTheActiveURLUsedForDictation() async {
        let foreground = URL(string: "https://example.com/document")!
        let meeting = URL(string: "https://meet.google.com/abc-defg-hij")!
        let resolver = BrowserURLResolver(
            resolutionProvider: { _, _ in BrowserResolution(url: foreground, title: "Document") },
            meetingTabProvider: { _ in [foreground, meeting] }
        )
        let activeURL = await resolver.activeURL(for: SupportedMeetingBrowser.chrome)
        let meetingURLs = await resolver.meetingTabURLs(for: SupportedMeetingBrowser.chrome)
        XCTAssertEqual(activeURL, foreground)
        XCTAssertEqual(meetingURLs, [foreground, meeting])
    }

    func testMeetingTabsDistinguishAnEmptyBrowserFromDeniedAccess() async {
        let unavailable = BrowserURLResolver(meetingTabProvider: { _ in nil })
        let empty = BrowserURLResolver(meetingTabProvider: { _ in [] })
        let unavailableURLs = await unavailable.meetingTabURLs(for: SupportedMeetingBrowser.chrome)
        let emptyURLs = await empty.meetingTabURLs(for: SupportedMeetingBrowser.chrome)
        XCTAssertNil(unavailableURLs)
        XCTAssertEqual(emptyURLs, [])
    }

    func testMeetingTabsResolveWhileActiveTabProviderIsBlocked() async {
        let activeStarted = expectation(description: "Active-tab provider started")
        let activeFinished = expectation(description: "Active-tab provider finished")
        let releaseActive = DispatchSemaphore(value: 0)
        defer { releaseActive.signal() }
        let meeting = URL(string: "https://meet.google.com/abc-defg-hij")!
        let resolver = BrowserURLResolver(
            resolutionProvider: { _, _ in
                activeStarted.fulfill()
                _ = releaseActive.wait(timeout: .now() + 5)
                activeFinished.fulfill()
                return BrowserResolution(url: nil, title: nil)
            },
            meetingTabProvider: { _ in [meeting] }
        )

        let activeTask = Task { await resolver.activeURL(for: SupportedMeetingBrowser.chrome) }
        await fulfillment(of: [activeStarted], timeout: 2)
        let meetingURLs = await resolver.meetingTabURLs(for: SupportedMeetingBrowser.chrome)
        releaseActive.signal()
        _ = await activeTask.value
        await fulfillment(of: [activeFinished], timeout: 2)

        XCTAssertEqual(meetingURLs, [meeting])
    }

    func testActiveTabResolvesWhileMeetingTabProviderIsBlocked() async {
        let meetingStarted = expectation(description: "Meeting-tab provider started")
        let meetingFinished = expectation(description: "Meeting-tab provider finished")
        let releaseMeeting = DispatchSemaphore(value: 0)
        defer { releaseMeeting.signal() }
        let foreground = URL(string: "https://example.com/document")!
        let resolver = BrowserURLResolver(
            resolutionProvider: { _, _ in BrowserResolution(url: foreground, title: nil) },
            meetingTabProvider: { _ in
                meetingStarted.fulfill()
                _ = releaseMeeting.wait(timeout: .now() + 5)
                meetingFinished.fulfill()
                return []
            }
        )

        let meetingTask = Task { await resolver.meetingTabURLs(for: SupportedMeetingBrowser.chrome) }
        await fulfillment(of: [meetingStarted], timeout: 2)
        let activeURL = await resolver.activeURL(for: SupportedMeetingBrowser.chrome)
        releaseMeeting.signal()
        _ = await meetingTask.value
        await fulfillment(of: [meetingFinished], timeout: 2)

        XCTAssertEqual(activeURL, foreground)
    }

    func testMeetingTabsForAnotherBrowserResolveWhileOneBrowserIsBlocked() async {
        let firstStarted = expectation(description: "First browser query started")
        let firstFinished = expectation(description: "First browser query finished")
        let releaseFirst = DispatchSemaphore(value: 0)
        defer { releaseFirst.signal() }
        let meeting = URL(string: "https://meet.google.com/abc-defg-hij")!
        let resolver = BrowserURLResolver(meetingTabProvider: { browser in
            if browser == SupportedMeetingBrowser.chrome {
                firstStarted.fulfill()
                _ = releaseFirst.wait(timeout: .now() + 5)
                firstFinished.fulfill()
            }
            return [meeting]
        })

        let firstTask = Task { await resolver.meetingTabURLs(for: SupportedMeetingBrowser.chrome) }
        await fulfillment(of: [firstStarted], timeout: 2)
        let secondURLs = await resolver.meetingTabURLs(for: SupportedMeetingBrowser.safari)
        releaseFirst.signal()
        _ = await firstTask.value
        await fulfillment(of: [firstFinished], timeout: 2)

        XCTAssertEqual(secondURLs, [meeting])
    }

    func testMeetingQueriesBoundConcurrencyWithoutTimingOutQueuedRequests() async throws {
        let blockedStarted = expectation(description: "Two providers started")
        blockedStarted.expectedFulfillmentCount = 2
        let blockedFinished = expectation(description: "Two providers finished")
        blockedFinished.expectedFulfillmentCount = 2
        let thirdRequested = expectation(description: "Third request submitted")
        let releaseProviders = DispatchSemaphore(value: 0)
        defer {
            releaseProviders.signal()
            releaseProviders.signal()
        }
        let state = OSAllocatedUnfairLock(initialState: (active: 0, maximum: 0, thirdStarted: false))
        let meeting = URL(string: "https://meet.google.com/abc-defg-hij")!
        let resolver = BrowserURLResolver(meetingTabProvider: { browser in
            state.withLock {
                $0.active += 1
                $0.maximum = max($0.maximum, $0.active)
            }
            defer { state.withLock { $0.active -= 1 } }
            if browser == SupportedMeetingBrowser.brave {
                state.withLock { $0.thirdStarted = true }
            } else {
                blockedStarted.fulfill()
                _ = releaseProviders.wait(timeout: .now() + 8)
                blockedFinished.fulfill()
            }
            return [meeting]
        })

        let first = Task { await resolver.meetingTabURLs(for: SupportedMeetingBrowser.chrome) }
        let second = Task { await resolver.meetingTabURLs(for: SupportedMeetingBrowser.safari) }
        await fulfillment(of: [blockedStarted], timeout: 2)
        let third = Task {
            thirdRequested.fulfill()
            return await resolver.meetingTabURLs(for: SupportedMeetingBrowser.brave)
        }
        await fulfillment(of: [thirdRequested], timeout: 2)
        try await Task.sleep(for: .seconds(3))
        XCTAssertFalse(state.withLock { $0.thirdStarted })
        releaseProviders.signal()
        releaseProviders.signal()

        let firstURLs = await first.value
        let secondURLs = await second.value
        let thirdURLs = await third.value
        await fulfillment(of: [blockedFinished], timeout: 2)
        XCTAssertNil(firstURLs)
        XCTAssertNil(secondURLs)
        XCTAssertEqual(thirdURLs, [meeting])
        XCTAssertEqual(state.withLock { $0.maximum }, 2)
    }

    func testMeetingScriptPreservesOutputAndDistinguishesFailureFromEmptyResult() async {
        let output = await Task.detached {
            BrowserURLResolver.executeMeetingTabScript(
                "return \"https://example.com/?a=1,b=2\" & linefeed & \"https://example.com/c\""
            )
        }.value
        let empty = await Task.detached {
            BrowserURLResolver.executeMeetingTabScript("return \"\"")
        }.value
        let failure = await Task.detached {
            BrowserURLResolver.executeMeetingTabScript("error \"Test failure\"")
        }.value

        XCTAssertEqual(output, "https://example.com/?a=1,b=2\nhttps://example.com/c\n")
        XCTAssertEqual(empty, "\n")
        XCTAssertNil(failure)
    }

    func testMeetingScriptTimeoutDoesNotBlockTheNextQuery() async {
        let result = await Task.detached {
            BrowserURLResolver.executeMeetingTabScript("delay 10\nreturn \"late\"")
        }.value
        XCTAssertNil(result)

        let next = await Task.detached {
            BrowserURLResolver.executeMeetingTabScript("return \"next\"")
        }.value
        XCTAssertEqual(next, "next\n")
    }

    func testLiveMeetingTabsResolveWhileActiveAppleScriptIsBlocked() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let browser = environment["TYPEWHISPER_TEST_BROWSER_BUNDLE_ID"],
              let expectedString = environment["TYPEWHISPER_TEST_BROWSER_URL"],
              let expectedURL = URL(string: expectedString) else {
            throw XCTSkip("Live browser test requires an explicitly selected browser and test URL")
        }
        let activeStarted = expectation(description: "Active AppleScript started")
        let activeFinished = expectation(description: "Active AppleScript finished")
        let activeIsRunning = OSAllocatedUnfairLock(initialState: false)
        let resolver = BrowserURLResolver(resolutionProvider: { _, _ in
            activeIsRunning.withLock { $0 = true }
            activeStarted.fulfill()
            var error: NSDictionary?
            _ = NSAppleScript(source: "delay 4")?.executeAndReturnError(&error)
            XCTAssertNil(error)
            activeIsRunning.withLock { $0 = false }
            activeFinished.fulfill()
            return BrowserResolution(url: nil, title: nil)
        })

        let activeTask = Task { await resolver.activeURL(for: browser) }
        await fulfillment(of: [activeStarted], timeout: 2)
        let urls = await resolver.meetingTabURLs(for: browser)
        XCTAssertTrue(urls?.contains(expectedURL) == true, "Expected test tab was not resolved")
        XCTAssertTrue(activeIsRunning.withLock { $0 }, "Meeting lookup waited for the active script")
        _ = await activeTask.value
        await fulfillment(of: [activeFinished], timeout: 6)
    }

    func testBrowserAudioProcessAttributionAcceptsExactMainBundleIdentifiers() {
        for bundleIdentifier in SupportedMeetingBrowser.automaticURLBundleIdentifiers {
            XCTAssertEqual(
                BrowserAudioProcessAttribution.canonicalBrowserBundleIdentifier(
                    for: bundleIdentifier
                ),
                bundleIdentifier
            )
        }
    }

    func testBrowserAudioProcessAttributionCanonicalizesSupportedHelpers() {
        let helperCapableBrowsers = SupportedMeetingBrowser.automaticURLBundleIdentifiers
            .subtracting([SupportedMeetingBrowser.safari])

        for bundleIdentifier in helperCapableBrowsers {
            for suffix in [".helper", ".helper.renderer"] {
                XCTAssertEqual(
                    BrowserAudioProcessAttribution.canonicalBrowserBundleIdentifier(
                        for: bundleIdentifier + suffix
                    ),
                    bundleIdentifier,
                    "Expected \(bundleIdentifier + suffix) to map to \(bundleIdentifier)"
                )
            }
        }
    }

    func testBrowserAudioProcessAttributionCanonicalizesSafariWebKitGPUProcess() {
        XCTAssertEqual(
            BrowserAudioProcessAttribution.canonicalBrowserBundleIdentifier(
                for: BrowserAudioProcessAttribution.safariWebKitGPUProcess
            ),
            SupportedMeetingBrowser.safari
        )
    }

    func testBrowserAudioProcessAttributionRejectsServicesAndLookalikes() {
        let rejected = [
            "com.google.Chrome.updater",
            "com.google.Chrome.helper.alert",
            "com.google.Chrome.fake.helper",
            "com.brave.Browser.helper.updater",
            "com.microsoft.edgemac.framework",
            "com.apple.Safari.helper",
            "com.apple.WebKit.WebContent",
            "com.apple.WebKit.Networking",
            "com.apple.WebKit.GPU.fake",
            SupportedMeetingBrowser.firefox + ".helper",
            SupportedMeetingBrowser.zen + ".helper"
        ]

        for bundleIdentifier in rejected {
            XCTAssertNil(
                BrowserAudioProcessAttribution.canonicalBrowserBundleIdentifier(
                    for: bundleIdentifier
                ),
                "Unexpected attribution for \(bundleIdentifier)"
            )
        }
    }

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
