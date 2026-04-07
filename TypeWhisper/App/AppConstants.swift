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
        static let checkoutURLIndividual = "https://buy.polar.sh/polar_cl_Yfw7BSIXSNFESlrNPL0fNG8GHPqX9qhmxGce32wZfYJ"
        static let checkoutURLTeam = "https://buy.polar.sh/polar_cl_kSqGfvss0Ces3W7R4xw7hr5NdgvEbPbhhUGRH4ad3Hj"
        static let checkoutURLEnterprise = "https://buy.polar.sh/polar_cl_uzCNIsF0vY9gx2peWljyJU7JQoEzxHUueCPTA0MoOQe"
    }
}
