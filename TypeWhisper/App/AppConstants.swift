import Foundation
import SwiftData
import os.log

enum AppConstants {
    static let isPremiumSyncSmokeTest: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--premium-sync-smoke-test")
        #else
        false
        #endif
    }()

    static let isScreenshotAutomation: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--store-screenshots")
        #else
        false
        #endif
    }()

    /// Preferences domain of screenshot runs, also for their managed preferences. The fastlane
    /// screenshot lane uses it as the bundle identifier; see `ScreenshotPreferencesIsolation`.
    static let screenshotPreferencesDomain = "com.schneidervvv.dictum.screenshots"

    /// The domain whose managed preferences (configuration profiles) apply to this process.
    static let managedPreferencesDomain = resolveManagedPreferencesDomain(
        isScreenshotAutomation: isScreenshotAutomation,
        bundleIdentifier: Bundle.main.bundleIdentifier
    )

    static func resolveManagedPreferencesDomain(isScreenshotAutomation: Bool, bundleIdentifier: String?) -> String {
        if isScreenshotAutomation {
            return screenshotPreferencesDomain
        }
        return bundleIdentifier ?? "com.schneidervvv.dictum"
    }

    /// The persistent domain `UserDefaults.standard` writes to; the app's own domain unless a
    /// test or screenshot run replaced it.
    static var preferencesDomain: String {
        if isRunningTests {
            return TestHostIsolation.defaultsSuiteName
        }
        if isScreenshotAutomation {
            return screenshotPreferencesDomain
        }
        return Bundle.main.bundleIdentifier ?? "com.schneidervvv.dictum"
    }

    static let screenshotState: String? = {
        guard isScreenshotAutomation else { return nil }
        return screenshotArgumentValue(after: "--screenshot-state")
    }()

    static let screenshotPluginId: String? = {
        guard isScreenshotAutomation else { return nil }
        return screenshotArgumentValue(after: "--screenshot-plugin-id")
    }()

    static let screenshotPluginWindowSize: CGSize? = {
        guard isScreenshotAutomation,
              let widthValue = screenshotArgumentValue(after: "--screenshot-window-width"),
              let heightValue = screenshotArgumentValue(after: "--screenshot-window-height"),
              let width = Double(widthValue), width > 0,
              let height = Double(heightValue), height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }()

    static let screenshotReadyFileURL: URL? = {
        guard isScreenshotAutomation,
              let path = screenshotArgumentValue(after: "--screenshot-ready-file"),
              path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }()

    static let screenshotScrollCommandFileURL: URL? = {
        guard isScreenshotAutomation,
              let path = screenshotArgumentValue(after: "--screenshot-scroll-command-file"),
              path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }()

    #if DEBUG
    static let screenshotFixtureReferenceDate: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        return calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 18, hour: 12)
        ) ?? Date(timeIntervalSince1970: 0)
    }()
    #endif

    private static func screenshotArgumentValue(after name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
            return nil
        }
        let value = arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    enum ReleaseChannel: String, CaseIterable {
        case stable
        case releaseCandidate = "release-candidate"
        case daily

        var sparkleChannels: Set<String> {
            switch self {
            case .stable:
                return []
            case .releaseCandidate:
                return ["release-candidate"]
            case .daily:
                return ["release-candidate", "daily"]
            }
        }

        var selectionDisplayName: String {
            switch self {
            case .stable:
                return String(localized: "Stable")
            case .releaseCandidate:
                return String(localized: "Release Candidate")
            case .daily:
                return String(localized: "Daily")
            }
        }

        var versionDisplayName: String? {
            switch self {
            case .stable:
                return nil
            case .releaseCandidate, .daily:
                return selectionDisplayName
            }
        }

        var updateDescription: String {
            switch self {
            case .stable:
                return String(localized: "Stable gets production releases only.")
            case .releaseCandidate:
                return String(localized: "Release Candidate includes stable and preview builds.")
            case .daily:
                return String(localized: "Daily includes stable, release candidate, and daily builds.")
            }
        }
    }

    struct PreviewRelease: Equatable {
        let tag: String
        let url: URL
    }

    nonisolated(unsafe) static var testAppSupportDirectoryOverride: URL?

    static let appSupportDirectoryName: String = {
        #if DEBUG
        return "dictum-Dev"
        #else
        return "dictum"
        #endif
    }()

    static let keychainServicePrefix: String = {
        if isScreenshotAutomation {
            return "com.schneidervvv.dictum.screenshots.apikey."
        }
        // Tests must neither read nor delete the API keys of the installed app.
        if isRunningTests {
            return "com.schneidervvv.dictum.tests.apikey."
        }
        #if APPSTORE && DEBUG
        return "com.typewhisper.typewhisper-app.dev.apikey."
        #elseif APPSTORE
        return "com.typewhisper.typewhisper-app.apikey."
        #elseif DEBUG
        return "com.schneidervvv.dictum.apikey."
        #else
        return "com.schneidervvv.dictum.apikey."
        #endif
    }()

    static let loggerSubsystem: String = Bundle.main.bundleIdentifier ?? "com.schneidervvv.dictum"

    static var appSupportDirectory: URL {
        if let override = testAppSupportDirectoryOverride {
            return override
        }
        if isScreenshotAutomation {
            return screenshotAppSupportDirectory
        }
        if isRunningTests {
            return testHostAppSupportDirectory
        }
        return defaultAppSupportDirectory
    }

    /// The test host app is a Debug build and would otherwise open the dev
    /// app's stores. A test run from an older checkout then migrates them to
    /// its schema while the dev app is running.
    static let testHostAppSupportDirectory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "TypeWhisper-Tests-\(ProcessInfo.processInfo.processIdentifier)",
            isDirectory: true
        )

    private static let screenshotAppSupportDirectory: URL =
        resolveScreenshotAppSupportDirectory(
            override: screenshotArgumentValue(after: "--screenshot-app-support"),
            temporaryDirectory: FileManager.default.temporaryDirectory,
            processIdentifier: ProcessInfo.processInfo.processIdentifier
        )

    static func resolveScreenshotAppSupportDirectory(
        override: String?,
        temporaryDirectory: URL,
        processIdentifier: Int32
    ) -> URL {
        let fallback = temporaryDirectory
            .appendingPathComponent(
                "TypeWhisper-Screenshots-\(processIdentifier)",
                isDirectory: true
            )

        guard let override, override.hasPrefix("/") else { return fallback }

        let temporaryRoot = temporaryDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let candidate = URL(fileURLWithPath: override, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let temporaryPrefix = temporaryRoot.path.hasSuffix("/")
            ? temporaryRoot.path
            : temporaryRoot.path + "/"

        guard candidate.path.hasPrefix(temporaryPrefix) else { return fallback }
        return candidate
    }

    static let defaultAppSupportDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent(appSupportDirectoryName, isDirectory: true)
    }()

    static let appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    static let buildVersion: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    private static let githubReleaseTagsURL = URL(
        string: "https://github.com/schneidervvv/dictum/releases/tag"
    )!
    static let currentReleaseFingerprint: String = {
        let channel = bundledReleaseChannel()
        return "\(appVersion)+\(buildVersion)@\(channel.rawValue)"
    }()
    static func bundledReleaseChannel(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) -> ReleaseChannel {
        guard let rawValue = infoDictionary?["TypeWhisperReleaseChannel"] as? String,
              let channel = ReleaseChannel(rawValue: rawValue) else {
            return .stable
        }
        return channel
    }

    static func bundledPreviewRelease(
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> PreviewRelease? {
        let channel = bundledReleaseChannel(infoDictionary: infoDictionary)
        guard channel == .daily || channel == .releaseCandidate,
              let rawTag = infoDictionary?["TypeWhisperReleaseTag"] as? String else {
            return nil
        }

        let tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return nil }

        return PreviewRelease(
            tag: tag,
            url: githubReleaseTagsURL.appendingPathComponent(tag)
        )
    }

    static var previewRelease: PreviewRelease? {
        bundledPreviewRelease()
    }

    static func selectedUpdateChannel(
        defaults: UserDefaults = .standard,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> ReleaseChannel {
        guard let rawValue = defaults.string(forKey: UserDefaultsKeys.updateChannel),
              let channel = ReleaseChannel(rawValue: rawValue) else {
            return bundledReleaseChannel(infoDictionary: infoDictionary)
        }
        return channel
    }

    static var releaseChannel: ReleaseChannel {
        bundledReleaseChannel()
    }

    static let defaultReleaseChannel: ReleaseChannel = {
        guard let rawValue = Bundle.main.infoDictionary?["TypeWhisperReleaseChannel"] as? String,
              let channel = ReleaseChannel(rawValue: rawValue) else {
            return .stable
        }
        return channel
    }()

    static let isRunningTests: Bool = {
        if isScreenshotAutomation {
            return false
        }

        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil ||
            environment["XCTestBundlePath"] != nil ||
            environment["XCTestSessionIdentifier"] != nil {
            return true
        }

        if NSClassFromString("XCTestCase") != nil {
            return true
        }

        return Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
    }()

    static let isDevelopment: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

}

private let factoryLogger = Logger(subsystem: AppConstants.loggerSubsystem, category: "SwiftDataStoreFactory")

@MainActor
struct SwiftDataStoreFactory {
    static func create(
        for modelTypes: [any PersistentModel.Type],
        storeName: String,
        in directory: URL
    ) throws -> (ModelContainer, ModelContext) {
        let schema = Schema(modelTypes)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let storeURL = directory.appendingPathComponent("\(storeName).store")
        let config = ModelConfiguration(url: storeURL, cloudKitDatabase: .none)

        var container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            factoryLogger.error("Incompatible schema for \(storeName) store. Resetting store.")
            // Incompatible schema — delete old store and retry
            for suffix in ["", "-wal", "-shm"] {
                let url = directory.appendingPathComponent("\(storeName).store\(suffix)")
                try? FileManager.default.removeItem(at: url)
            }
            do {
                container = try ModelContainer(for: schema, configurations: [config])
            } catch {
                // If it still fails, there's a fundamental issue
                fatalError("Failed to create \(storeName) ModelContainer after reset: \(error)")
            }
        }

        let context = ModelContext(container)
        context.autosaveEnabled = true
        return (container, context)
    }
}
