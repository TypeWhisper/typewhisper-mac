import Foundation

enum AppConstants {
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

    nonisolated(unsafe) static var testAppSupportDirectoryOverride: URL?

    static let appSupportDirectoryName: String = {
        #if DEBUG
        return "TypeWhisper-Dev"
        #else
        return "TypeWhisper"
        #endif
    }()

    static let keychainServicePrefix: String = {
        #if DEBUG
        return "com.typewhisper.mac.dev.apikey."
        #else
        return "com.typewhisper.mac.apikey."
        #endif
    }()

    static let loggerSubsystem: String = Bundle.main.bundleIdentifier ?? "com.typewhisper.mac"

    static var appSupportDirectory: URL {
        if let override = testAppSupportDirectoryOverride {
            return override
        }
        return defaultAppSupportDirectory
    }

    static let defaultAppSupportDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent(appSupportDirectoryName, isDirectory: true)
    }()

    static let appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    static let buildVersion: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
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
