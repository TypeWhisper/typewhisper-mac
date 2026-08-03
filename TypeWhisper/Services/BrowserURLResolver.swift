import AppKit
import Foundation
import os

private let browserURLResolverLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper",
    category: "BrowserURLResolver"
)
private let browserURLResolutionQueue = DispatchQueue(
    label: "com.typewhisper.browser-url-resolution",
    qos: .utility
)

private final class BrowserResolutionCompletion: @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<BrowserResolution, Never>?
    }

    private let state: OSAllocatedUnfairLock<State>

    init(continuation: CheckedContinuation<BrowserResolution, Never>) {
        state = OSAllocatedUnfairLock(initialState: State(continuation: continuation))
    }

    @discardableResult
    func resume(returning resolution: BrowserResolution) -> Bool {
        let continuation = state.withLock { state -> CheckedContinuation<BrowserResolution, Never>? in
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume(returning: resolution)
        return continuation != nil
    }
}

struct BrowserResolution: Equatable, Sendable {
    let url: URL?
    let title: String?
}

final class BrowserURLResolver: BrowserURLResolving, @unchecked Sendable {
    typealias ResolutionProvider = @Sendable (String, Bool) -> BrowserResolution

    private let resolutionProvider: ResolutionProvider

    init(resolutionProvider: ResolutionProvider? = nil) {
        self.resolutionProvider = resolutionProvider ?? { bundleIdentifier, includeTitle in
            Self.resolve(bundleIdentifier: bundleIdentifier, includeTitle: includeTitle)
        }
    }

    func activeURL(for bundleIdentifier: String) async -> URL? {
        await resolve(bundleIdentifier: bundleIdentifier, includeTitle: false).url
    }

    func activeBrowserInfo(for bundleIdentifier: String) async -> BrowserResolution {
        await resolve(bundleIdentifier: bundleIdentifier, includeTitle: true)
    }

    private func resolve(
        bundleIdentifier: String,
        includeTitle: Bool
    ) async -> BrowserResolution {
        let resolutionProvider = resolutionProvider
        return await withCheckedContinuation { continuation in
            let completion = BrowserResolutionCompletion(continuation: continuation)
            browserURLResolutionQueue.async {
                completion.resume(returning: resolutionProvider(bundleIdentifier, includeTitle))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.5) {
                if completion.resume(returning: BrowserResolution(url: nil, title: nil)) {
                    browserURLResolverLogger.warning("Browser URL AppleScript timed out")
                }
            }
        }
    }

    private enum BrowserType {
        case safari
        case arc
        case chromiumBased
        case unsupportedURLBrowser
        case notABrowser
    }

    nonisolated private static func identifyBrowser(_ bundleIdentifier: String) -> BrowserType {
        if SupportedMeetingBrowser.reminderOnlyBundleIdentifiers.contains(bundleIdentifier) {
            return .unsupportedURLBrowser
        }
        switch bundleIdentifier {
        case SupportedMeetingBrowser.safari:
            return .safari
        case SupportedMeetingBrowser.arc:
            return .arc
        case SupportedMeetingBrowser.chrome,
             SupportedMeetingBrowser.chromeCanary,
             SupportedMeetingBrowser.brave,
             SupportedMeetingBrowser.edge,
             SupportedMeetingBrowser.opera,
             SupportedMeetingBrowser.vivaldi,
             SupportedMeetingBrowser.chromium,
             SupportedMeetingBrowser.wavebox:
            return .chromiumBased
        default:
            return .notABrowser
        }
    }

    nonisolated private static func resolve(
        bundleIdentifier: String,
        includeTitle: Bool = false
    ) -> BrowserResolution {
        let browserType = identifyBrowser(bundleIdentifier)
        guard browserType != .notABrowser, browserType != .unsupportedURLBrowser else {
            return BrowserResolution(url: nil, title: nil)
        }

        let appName = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            .flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleName"] as? String }
            ?? bundleIdentifier
        let script = appleScript(
            appName: appName,
            browserType: browserType,
            includeTitle: includeTitle
        )
        guard let script,
              let result = executeAppleScript(script) else {
            return BrowserResolution(url: nil, title: nil)
        }

        let parts = result.components(separatedBy: "\n")
        let url = parts.first.flatMap(validURL)
        let title = includeTitle && parts.count > 1
            ? parts.dropFirst().joined(separator: "\n").nilIfEmpty
            : nil
        return BrowserResolution(url: url, title: title)
    }

    nonisolated private static func appleScript(
        appName: String,
        browserType: BrowserType,
        includeTitle: Bool
    ) -> String? {
        let escapedName = appName
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        let urlProperty: String
        let titleProperty: String
        switch browserType {
        case .safari:
            urlProperty = "URL of current tab of front window"
            titleProperty = "name of current tab of front window"
        case .arc, .chromiumBased:
            urlProperty = "URL of active tab of front window"
            titleProperty = "title of active tab of front window"
        case .unsupportedURLBrowser, .notABrowser:
            return nil
        }

        if includeTitle {
            return """
            tell application "\(escapedName)"
                if (count of windows) > 0 then
                    set tabURL to \(urlProperty)
                    set tabTitle to \(titleProperty)
                    return tabURL & "\\n" & tabTitle
                end if
            end tell
            return ""
            """
        }
        return """
        tell application "\(escapedName)"
            if (count of windows) > 0 then
                return \(urlProperty)
            end if
        end tell
        return ""
        """
    }

    nonisolated private static func executeAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        let descriptor = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if error != nil {
            browserURLResolverLogger.warning("Browser URL AppleScript failed")
        }
        return descriptor?.stringValue?.nilIfEmpty
    }

    nonisolated private static func validURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 3, trimmed.count < 2048,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "file"].contains(scheme) else {
            return nil
        }
        return url
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
