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
        return "TypeWhisper-Dev"
        #else
        return "TypeWhisper"
        #endif
    }()

    static let keychainServicePrefix: String = {
        if isScreenshotAutomation {
            return "com.typewhisper.mac.screenshots.apikey."
        }
        #if DEBUG
        return "com.typewhisper.mac.dev.apikey."
        #else
        return "com.typewhisper.mac.apikey."
        #endif
    }()

    static let premiumAccountKeychainService = resolvePremiumAccountKeychainService(
        isScreenshotAutomation: isScreenshotAutomation,
        isRunningTests: isRunningTests,
        isDevelopment: isDevelopment
    )

    static func resolvePremiumAccountKeychainService(
        isScreenshotAutomation: Bool,
        isRunningTests: Bool,
        isDevelopment: Bool
    ) -> String {
        if isScreenshotAutomation {
            return "com.typewhisper.mac.screenshots.premium-account"
        }
        if isRunningTests {
            return "com.typewhisper.mac.tests.premium-account"
        }
        if isDevelopment {
            return "com.typewhisper.mac.dev.premium-account"
        }
        return "com.typewhisper.mac.premium-account"
    }

    static let loggerSubsystem: String = Bundle.main.bundleIdentifier ?? "com.typewhisper.mac"

    static var appSupportDirectory: URL {
        if let override = testAppSupportDirectoryOverride {
            return override
        }
        if isScreenshotAutomation {
            return screenshotAppSupportDirectory
        }
        return defaultAppSupportDirectory
    }

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
        string: "https://github.com/TypeWhisper/typewhisper-mac/releases/tag"
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

    static var effectiveUpdateChannel: ReleaseChannel {
        selectedUpdateChannel()
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

    // MARK: - Polar.sh Licensing
    enum Polar {
        static let organizationId = "96de503c-3c8b-4d08-9ded-c7f6e20fdde4"
        static let checkoutURL = "https://polar.sh/typewhisper"
        static let customerPortalURL = "https://polar.sh/typewhisper/portal"

        // Business Monthly
        static let checkoutURLIndividual = "https://buy.polar.sh/polar_cl_Yfw7BSIXSNFESlrNPL0fNG8GHPqX9qhmxGce32wZfYJ"
        static let checkoutURLTeam = "https://buy.polar.sh/polar_cl_kSqGfvss0Ces3W7R4xw7hr5NdgvEbPbhhUGRH4ad3Hj"
        static let checkoutURLEnterprise = "https://buy.polar.sh/polar_cl_uzCNIsF0vY9gx2peWljyJU7JQoEzxHUueCPTA0MoOQe"

        // Business Lifetime
        static let checkoutURLIndividualLifetime = "https://buy.polar.sh/polar_cl_Uiv5AnvLoQjx4JowO3gGciT7MLOovY4oY4ESz3PIxgI"
        static let checkoutURLTeamLifetime = "https://buy.polar.sh/polar_cl_GjG4jf1fT9HGQn051cgN6xsWH9Xm6Z7oe0Ke71xq6Po"
        static let checkoutURLEnterpriseLifetime = "https://buy.polar.sh/polar_cl_ngagiyJjXtxDBqv19EooEGJOLRcgzBWKBFYrZ2V2Xm7"

        // Private Supporter
        static let checkoutURLSupporterBronze = "https://buy.polar.sh/polar_cl_yilyo1V90RnuUX59V2PyLUIg45FpzYI8aMhG824wYn8"
        static let checkoutURLSupporterSilver = "https://buy.polar.sh/polar_cl_lXFAqnanhrrPd1RZ95SCb2L05L3lNrUQIkYVd0ZmK5b"
        static let checkoutURLSupporterGold = "https://buy.polar.sh/polar_cl_FpojMlLmyF73gOqpXLihSE0lNYnoQoaMxGp724IIor4"

        static func attributedCheckoutURL(
            baseURL: String,
            source: String,
            medium: String,
            content: String
        ) -> URL? {
            guard var components = URLComponents(string: baseURL) else { return nil }
            var queryItems = components.queryItems ?? []
            queryItems.removeAll { item in
                ["utm_source", "utm_medium", "utm_content"].contains(item.name)
            }
            queryItems.append(contentsOf: [
                URLQueryItem(name: "utm_source", value: source),
                URLQueryItem(name: "utm_medium", value: medium),
                URLQueryItem(name: "utm_content", value: content),
            ])
            components.queryItems = queryItems
            return components.url
        }

        static func appCheckoutURL(baseURL: String, content: String) -> URL? {
            attributedCheckoutURL(
                baseURL: baseURL,
                source: "typewhisper_mac",
                medium: "app",
                content: "mac_\(content)"
            )
        }
    }

    enum Website {
        private static var localeSegment: String {
            let preferred = UserDefaults.standard.string(forKey: UserDefaultsKeys.preferredAppLanguage)
                ?? Bundle.main.preferredLocalizations.first
                ?? Locale.preferredLanguages.first
                ?? "en"
            return preferred.hasPrefix("de") ? "de" : "en"
        }

        private static let rootURL = "https://www.typewhisper.com"
        static let licensingEmailURL = URL(string: "mailto:licensing@typewhisper.com")!

        static var pricingURL: URL {
            URL(string: "\(rootURL)/\(localeSegment)/pricing/")!
        }

        static var teamContactURL: URL {
            URL(string: "\(rootURL)/\(localeSegment)/business/") ?? licensingEmailURL
        }
    }

    // MARK: - Discord Claim Service
    enum DiscordClaim {
        static let defaultBaseURLString = "http://127.0.0.1:8787"
        static let callbackScheme = "typewhisper"
        static let callbackHost = "community"
        static let callbackPath = "/claim-result"

        static var baseURL: URL {
            let environment = ProcessInfo.processInfo.environment
            let configured = environment["TYPEWHISPER_DISCORD_CLAIM_BASE_URL"]
                ?? Bundle.main.object(forInfoDictionaryKey: "TypeWhisperDiscordClaimBaseURL") as? String
                ?? defaultBaseURLString

            return URL(string: configured) ?? URL(string: defaultBaseURLString)!
        }

        static var callbackURL: URL {
            URL(string: "\(callbackScheme)://\(callbackHost)\(callbackPath)")!
        }

        static var githubSponsorsURL: URL {
            baseURL.appendingPathComponent("claims").appendingPathComponent("github")
        }

        static func isCallbackURL(_ url: URL) -> Bool {
            url.scheme == callbackScheme &&
                url.host == callbackHost &&
                url.path == callbackPath
        }
    }
}

private let factoryLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "SwiftDataStoreFactory")

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
