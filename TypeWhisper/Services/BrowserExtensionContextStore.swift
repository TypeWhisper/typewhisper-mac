import AppKit
import Foundation
import os

/// The active tab that a TypeWhisper browser extension reported through the local API.
///
/// Extensions report when their browser window gains or loses focus and when the active tab
/// changes, and repeat the report while the browser stays in front. A report belongs to the
/// app that was frontmost when it arrived, so it never describes a different browser. This
/// gives the sandboxed App Store edition, which cannot ask browsers for their URL, a website
/// context, and lets the direct build skip the AppleScript query.
final class BrowserExtensionContextStore: @unchecked Sendable {
    static let shared = BrowserExtensionContextStore()

    /// Extensions repeat their report every minute while the browser is in front; a report
    /// that is not repeated may come from an extension that was removed or stopped.
    static let reportLifetime: TimeInterval = 180

    struct Report: Equatable, Sendable {
        let clientID: String
        let bundleIdentifier: String
        let url: URL?
        let title: String?
        let receivedAt: Date
    }

    typealias FrontmostBundleIdentifierProvider = @MainActor @Sendable () -> String?
    typealias BrowserCheck = @Sendable (String) -> Bool

    private let state = OSAllocatedUnfairLock<Report?>(initialState: nil)
    private let frontmostBundleIdentifier: FrontmostBundleIdentifierProvider
    private let isBrowser: BrowserCheck
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date

    init(
        frontmostBundleIdentifier: @escaping FrontmostBundleIdentifierProvider = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        },
        isBrowser: @escaping BrowserCheck = BrowserExtensionContextStore.opensWebPages,
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.frontmostBundleIdentifier = frontmostBundleIdentifier
        self.isBrowser = isBrowser
        self.defaults = defaults
        self.now = now
    }

    /// Whether the app can open web pages. Unlike a fixed list, this also covers browsers
    /// without AppleScript support, such as Firefox.
    static func opensWebPages(_ bundleIdentifier: String) -> Bool {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
              let page = URL(string: "https://www.typewhisper.com") else {
            return false
        }
        let candidate = appURL.resolvingSymlinksInPath().standardizedFileURL
        return NSWorkspace.shared.urlsForApplications(toOpen: page).contains {
            $0.resolvingSymlinksInPath().standardizedFileURL == candidate
        }
    }

    /// Records a report from the extension identified by `clientID`.
    ///
    /// A focused report replaces the previous one and is assigned to the frontmost browser. A
    /// report without focus only removes this extension's own report, so a browser that loses
    /// focus cannot clear the report of the browser that just came to the front.
    /// - Returns: The stored report, or `nil` if nothing was stored.
    @discardableResult
    func report(clientID: String, focused: Bool, url: URL?, title: String?) async -> Report? {
        guard focused else {
            state.withLock { report in
                if report?.clientID == clientID {
                    report = nil
                }
            }
            return nil
        }

        // A report that arrives after the person switched apps must not describe the new app,
        // so it only counts while a browser is in front.
        let frontmostBundleIdentifier = await frontmostBundleIdentifier()
        guard let frontmostBundleIdentifier,
              frontmostBundleIdentifier != Bundle.main.bundleIdentifier,
              isBrowser(frontmostBundleIdentifier) else {
            return nil
        }

        let report = Report(
            clientID: clientID,
            bundleIdentifier: frontmostBundleIdentifier,
            url: url,
            title: title,
            receivedAt: now()
        )
        state.withLock { $0 = report }
        // Settings offer website triggers in the App Store edition once an extension reported.
        if !defaults.bool(forKey: UserDefaultsKeys.browserExtensionConnected) {
            defaults.set(true, forKey: UserDefaultsKeys.browserExtensionConnected)
        }
        return report
    }

    /// The tab the extension reported for `bundleIdentifier`, or `nil` if no current report
    /// belongs to that app. A report without a URL means the active tab shows no website.
    func resolution(for bundleIdentifier: String) -> BrowserResolution? {
        let currentDate = now()
        return state.withLock { report in
            guard let current = report,
                  current.bundleIdentifier == bundleIdentifier,
                  currentDate.timeIntervalSince(current.receivedAt) <= Self.reportLifetime else {
                return nil
            }
            return BrowserResolution(url: current.url, title: current.title)
        }
    }
}
