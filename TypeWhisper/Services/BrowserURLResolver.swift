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
private let meetingTabResolutionQueue = DispatchQueue(
    label: "com.typewhisper.meeting-tab-resolution",
    qos: .utility
)

private final class BrowserResolutionCompletion<Value: Sendable>: @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<Value, Never>?
    }

    private let state: OSAllocatedUnfairLock<State>

    init(continuation: CheckedContinuation<Value, Never>) {
        state = OSAllocatedUnfairLock(initialState: State(continuation: continuation))
    }

    @discardableResult
    func resume(returning resolution: Value) -> Bool {
        let continuation = state.withLock { state -> CheckedContinuation<Value, Never>? in
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
    typealias MeetingTabProvider = @Sendable (String) -> [URL]?

    private let resolutionProvider: ResolutionProvider
    private let meetingTabProvider: MeetingTabProvider

    init(
        resolutionProvider: ResolutionProvider? = nil,
        meetingTabProvider: MeetingTabProvider? = nil
    ) {
        self.resolutionProvider = resolutionProvider ?? { bundleIdentifier, includeTitle in
            Self.resolve(bundleIdentifier: bundleIdentifier, includeTitle: includeTitle)
        }
        self.meetingTabProvider = meetingTabProvider ?? Self.resolveMeetingTabs
    }

    func activeURL(for bundleIdentifier: String) async -> URL? {
        await resolve(bundleIdentifier: bundleIdentifier, includeTitle: false).url
    }

    func activeBrowserInfo(for bundleIdentifier: String) async -> BrowserResolution {
        await resolve(bundleIdentifier: bundleIdentifier, includeTitle: true)
    }

    func meetingTabURLs(for bundleIdentifier: String) async -> [URL]? {
        let provider = meetingTabProvider
        return await withCheckedContinuation { continuation in
            let completion = BrowserResolutionCompletion(continuation: continuation)
            meetingTabResolutionQueue.async {
                completion.resume(returning: provider(bundleIdentifier))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.5) {
                if completion.resume(returning: nil) {
                    browserURLResolverLogger.warning("Browser meeting-tab resolution timed out")
                }
            }
        }
    }

    private static func resolveMeetingTabs(bundleIdentifier: String) -> [URL]? {
        let browserType = identifyBrowser(bundleIdentifier)
        guard browserType != .notABrowser, browserType != .unsupportedURLBrowser else {
            return nil
        }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty else {
            return []
        }
        // This separate query is only used by meeting detection. Dictation and
        // website workflows must continue to resolve the active tab exclusively.
        let identifier = bundleIdentifier.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
            with timeout of 2 seconds
                tell application id "\(identifier)"
                    set tabURLs to {}
                    set windowURLs to get URL of every tab of every window
                    repeat with urlsInWindow in windowURLs
                        repeat with tabURL in urlsInWindow
                            set tabValue to contents of tabURL
                            if class of tabValue is text then
                                if tabValue contains linefeed or tabValue contains return then error "Invalid tab URL"
                                if (length of tabValue) < 2048 then set end of tabURLs to tabValue
                            end if
                            if (count of tabURLs) > 512 then error "Too many tabs"
                        end repeat
                    end repeat
                    set AppleScript's text item delimiters to linefeed
                    return tabURLs as text
                end tell
            end timeout
            """
        guard let output = executeMeetingTabScript(script) else { return nil }
        return output.split(separator: "\n").compactMap { validURL(String($0)) }
    }

    // Isolate the AppleScript runtime as well as the queue: concurrent in-process
    // NSAppleScript calls must not contend with a stalled dictation URL query.
    static func executeMeetingTabScript(_ source: String) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        defer { try? output.fileHandleForReading.close() }
        do {
            try process.run()
        } catch {
            browserURLResolverLogger.warning("Browser meeting-tab AppleScript could not start")
            return nil
        }

        let timeout = DispatchWorkItem {
            if process.isRunning {
                browserURLResolverLogger.warning("Browser meeting-tab AppleScript timed out")
                process.terminate()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: timeout)
        defer { timeout.cancel() }

        let data: Data
        do {
            data = try output.fileHandleForReading.readToEnd() ?? Data()
        } catch {
            process.terminate()
            process.waitUntilExit()
            return nil
        }
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            browserURLResolverLogger.warning("Browser meeting-tab AppleScript failed")
            return nil
        }
        return String(data: data, encoding: .utf8)
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
