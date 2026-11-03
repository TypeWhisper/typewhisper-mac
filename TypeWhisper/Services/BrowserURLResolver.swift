import AppKit
import Foundation
#if !APPSTORE
import OSAKit
#endif
import os

private let browserURLResolverLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper",
    category: "BrowserURLResolver"
)
private let browserURLResolutionQueue = DispatchQueue(
    label: "com.typewhisper.browser-url-resolution",
    qos: .utility
)
private let meetingTabResolutionQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "com.typewhisper.meeting-tab-resolution"
    queue.qualityOfService = .utility
    queue.maxConcurrentOperationCount = 2
    return queue
}()

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
    private let extensionContext: BrowserExtensionContextStore

    init(
        resolutionProvider: ResolutionProvider? = nil,
        meetingTabProvider: MeetingTabProvider? = nil,
        extensionContext: BrowserExtensionContextStore = .shared
    ) {
        self.extensionContext = extensionContext
#if APPSTORE
        // The App Store edition cannot send Apple Events or run osascript, so browsers report
        // no URL and no open tabs unless a browser extension reports the active tab. Meeting
        // detection keeps its native signals.
        self.resolutionProvider = resolutionProvider ?? { _, _ in
            BrowserResolution(url: nil, title: nil)
        }
        self.meetingTabProvider = meetingTabProvider ?? { _ in [] }
#else
        self.resolutionProvider = resolutionProvider ?? { bundleIdentifier, includeTitle in
            Self.resolve(bundleIdentifier: bundleIdentifier, includeTitle: includeTitle)
        }
        self.meetingTabProvider = meetingTabProvider ?? Self.resolveMeetingTabs
#endif
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
            meetingTabResolutionQueue.addOperation {
                // Queue admission is not a browser failure. Give each query its
                // full execution budget once a bounded worker is available.
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.5) {
                    if completion.resume(returning: nil) {
                        browserURLResolverLogger.warning("Browser meeting-tab resolution timed out")
                    }
                }
                completion.resume(returning: provider(bundleIdentifier))
            }
        }
    }

#if !APPSTORE
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
        guard let output = meetingTabScriptRunner.run(script) else { return nil }
        return output.split(separator: "\n").compactMap { validURL(String($0)) }
    }

    // The meeting-tab query runs every second while a browser plays audio, so
    // its script is compiled once per browser and reused in process.
    private static let meetingTabScriptRunner = MeetingTabScriptRunner()
#endif

    private func resolve(
        bundleIdentifier: String,
        includeTitle: Bool
    ) async -> BrowserResolution {
        if let reported = extensionContext.resolution(for: bundleIdentifier) {
            return BrowserResolution(url: reported.url, title: includeTitle ? reported.title : nil)
        }

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

#if !APPSTORE
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
        default:
            // Every other supported browser is Chromium-based. Reading the shared
            // list keeps audio attribution and tab queries in sync.
            return SupportedMeetingBrowser.supportsAutomaticURLResolution(bundleIdentifier)
                ? .chromiumBased
                : .notABrowser
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
#endif

    nonisolated static func validURL(_ value: String) -> URL? {
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

#if !APPSTORE
/// Runs the meeting-tab AppleScript in process. Each distinct script is compiled
/// once and reused, instead of starting and compiling an `osascript` process for
/// every query. Every script gets its own AppleScript instance, so it shares no
/// interpreter state with the NSAppleScript calls of the dictation URL lookup.
final class MeetingTabScriptRunner: Sendable {
    private final class CompiledScript: @unchecked Sendable {
        // Only the call that holds its slot as running touches the script.
        let script: OSAScript

        init(_ script: OSAScript) {
            self.script = script
        }
    }

    private enum Slot: Sendable {
        case idle(CompiledScript)
        case running
    }

    private enum Claim: Sendable {
        case busy
        case claimed(CompiledScript?)
    }

    private let executionTimeout: TimeInterval
    private let slots = OSAllocatedUnfairLock(initialState: [String: Slot]())
    private let executionQueue = DispatchQueue(
        label: "com.typewhisper.meeting-tab-script",
        qos: .utility,
        attributes: .concurrent
    )

    init(executionTimeout: TimeInterval = 2) {
        self.executionTimeout = executionTimeout
    }

    /// Returns the script's text result, or "" when the result is not text.
    /// Returns nil when the script cannot compile, fails, does not finish within
    /// the execution timeout, or is still running from an earlier call.
    func run(_ source: String) -> String? {
        let claim = slots.withLock { slots -> Claim in
            switch slots[source] {
            case .running:
                return .busy
            case .idle(let compiled):
                slots[source] = .running
                return .claimed(compiled)
            case nil:
                slots[source] = .running
                return .claimed(nil)
            }
        }
        guard case .claimed(let compiled) = claim else {
            browserURLResolverLogger.warning("Browser meeting-tab AppleScript is still running")
            return nil
        }

        let output = OSAllocatedUnfairLock<String?>(initialState: nil)
        let finished = DispatchSemaphore(value: 0)
        executionQueue.async { [slots] in
            let (reusable, result) = Self.execute(source, compiled: compiled)
            output.withLock { $0 = result }
            slots.withLock { $0[source] = reusable.map(Slot.idle) }
            finished.signal()
        }
        // A hung Apple Event cannot be terminated in process. Stop waiting after
        // the timeout so the caller's worker is free again. The slot stays busy
        // until the script returns, so a stuck browser runs one script at most.
        guard finished.wait(timeout: .now() + executionTimeout) == .success else {
            browserURLResolverLogger.warning("Browser meeting-tab AppleScript timed out")
            return nil
        }
        return output.withLock { $0 }
    }

    /// Returns the script to reuse for the next call (nil after any failure, so
    /// the next call starts from a fresh compile) and the result.
    private static func execute(
        _ source: String,
        compiled: CompiledScript?
    ) -> (CompiledScript?, String?) {
        autoreleasepool {
            guard let compiled = compiled ?? compile(source) else { return (nil, nil) }
            var errorInfo: NSDictionary?
            let descriptor = compiled.script.executeAndReturnError(&errorInfo)
            if let errorInfo {
                let number = (errorInfo[OSAScriptErrorNumberKey] as? NSNumber)?.intValue ?? 0
                browserURLResolverLogger.warning(
                    "Browser meeting-tab AppleScript failed (\(number, privacy: .public))"
                )
                return (nil, nil)
            }
            return (compiled, descriptor?.stringValue ?? "")
        }
    }

    private static func compile(_ source: String) -> CompiledScript? {
        guard let language = OSALanguage(forName: "AppleScript") else {
            browserURLResolverLogger.warning("Browser meeting-tab AppleScript is unavailable")
            return nil
        }
        let script = OSAScript(
            source: source,
            from: nil,
            languageInstance: OSALanguageInstance(language: language),
            using: []
        )
        var errorInfo: NSDictionary?
        guard script.compileAndReturnError(&errorInfo) else {
            browserURLResolverLogger.warning("Browser meeting-tab AppleScript could not compile")
            return nil
        }
        return CompiledScript(script)
    }
}
#endif
