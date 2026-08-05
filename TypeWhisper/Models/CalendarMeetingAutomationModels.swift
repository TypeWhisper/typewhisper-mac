import CryptoKit
import Foundation

enum CalendarMeetingStartMode: String, Codable, Sendable, CaseIterable {
    case off
    case reminder
    case automatic
}

enum CalendarMeetingPremiumAccess {
    static func isGranted(
        hasCommercialLicense: Bool,
        hasPremiumEntitlement: Bool
    ) -> Bool {
        hasCommercialLicense || hasPremiumEntitlement
    }
}

enum CalendarMeetingSuppressionList {
    static let capacity = 256

    static func appending(_ digest: String, to existing: [String]) -> [String] {
        var result = existing.filter { $0 != digest }
        result.append(digest)
        if result.count > capacity {
            result.removeFirst(result.count - capacity)
        }
        return result
    }
}

enum CalendarMeetingReminderRequestLedger {
    static let capacity = 256

    static func appending(_ digest: String, to existing: [String]) -> [String] {
        var result = existing.filter { $0 != digest }
        result.append(digest)
        if result.count > capacity {
            result.removeFirst(result.count - capacity)
        }
        return result
    }
}

enum MeetingProvider: String, Codable, Sendable, CaseIterable, Identifiable {
    case zoom
    case teams
    case googleMeet
    case faceTime

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .zoom: "Zoom"
        case .teams: "Microsoft Teams"
        case .googleMeet: "Google Meet"
        case .faceTime: "FaceTime"
        }
    }
}

enum CalendarMeetingParticipationStatus: String, Codable, Sendable {
    case accepted
    case tentative
    case pending
    case declined
    case delegated
    case unknown
    case noCurrentUser

    var permitsReminder: Bool { self != .declined }

    var permitsAutomaticStart: Bool {
        switch self {
        case .accepted, .tentative, .noCurrentUser:
            true
        case .pending, .declined, .delegated, .unknown:
            false
        }
    }
}

struct CalendarMeetingCanonicalLink: Codable, Hashable, Sendable, Identifiable {
    let provider: MeetingProvider
    let identity: String

    var id: String { "\(provider.rawValue):\(identity)" }
}

struct CalendarMeetingOccurrence: Identifiable, Equatable, Sendable {
    let eventIdentifier: String
    let occurrenceStart: Date
    let startDate: Date
    let endDate: Date
    let title: String
    let calendarID: String
    let participationStatus: CalendarMeetingParticipationStatus
    let meetingLinks: [CalendarMeetingCanonicalLink]
    let occurrenceDigest: String

    var id: String { occurrenceDigest }

    init(
        eventIdentifier: String,
        occurrenceStart: Date,
        startDate: Date,
        endDate: Date,
        title: String,
        calendarID: String,
        participationStatus: CalendarMeetingParticipationStatus,
        meetingLinks: [CalendarMeetingCanonicalLink]
    ) {
        self.eventIdentifier = eventIdentifier
        self.occurrenceStart = occurrenceStart
        self.startDate = startDate
        self.endDate = endDate
        self.title = title
        self.calendarID = calendarID
        self.participationStatus = participationStatus
        self.meetingLinks = meetingLinks
        occurrenceDigest = CalendarMeetingOccurrenceDigest.make(
            eventIdentifier: eventIdentifier,
            occurrenceStart: occurrenceStart
        )
    }

    var providers: Set<MeetingProvider> {
        Set(meetingLinks.map(\.provider))
    }

    func isInsideJoinWindow(at date: Date) -> Bool {
        let interval = DateInterval(
            start: startDate.addingTimeInterval(-10 * 60),
            end: endDate.addingTimeInterval(30 * 60)
        )
        return interval.contains(date)
    }
}

enum CalendarMeetingOccurrenceDigest {
    static func make(eventIdentifier: String, occurrenceStart: Date) -> String {
        let utcMicroseconds = Int64((occurrenceStart.timeIntervalSince1970 * 1_000_000).rounded())
        let input = Data("\(eventIdentifier)\u{0}\(utcMicroseconds)".utf8)
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }
}

struct CalendarMeetingCalendar: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let sourceTitle: String
}

enum CalendarMeetingCalendarAuthorization: String, Equatable, Sendable {
    case notDetermined
    case fullAccess
    case denied
    case restricted
    case writeOnly
    case unknown
}

struct MeetingAudioProcess: Equatable, Hashable, Sendable {
    let audioObjectID: UInt32
    let processID: pid_t
    let bundleIdentifier: String
    let isRunningInput: Bool
    let isRunningOutput: Bool
}

enum MeetingActivityAvailability: String, Equatable, Sendable {
    case available
    case unsupported
    case failed
}

struct MeetingActivitySnapshot: Equatable, Sendable {
    let capturedAt: Date
    let availability: MeetingActivityAvailability
    let processes: [MeetingAudioProcess]

    static func unsupported(at date: Date = Date()) -> Self {
        Self(capturedAt: date, availability: .unsupported, processes: [])
    }

    static func failed(at date: Date = Date()) -> Self {
        Self(capturedAt: date, availability: .failed, processes: [])
    }
}

struct MeetingCameraActivitySnapshot: Equatable, Sendable {
    let capturedAt: Date
    let availability: MeetingActivityAvailability
    let isAnyCameraRunning: Bool

    static func unsupported(at date: Date = Date()) -> Self {
        Self(
            capturedAt: date,
            availability: .unsupported,
            isAnyCameraRunning: false
        )
    }

    static func failed(at date: Date = Date()) -> Self {
        Self(
            capturedAt: date,
            availability: .failed,
            isAnyCameraRunning: false
        )
    }
}

struct CalendarMeetingRecordingHandle: Equatable, Sendable {
    let id: UUID
    let outputURL: URL
}

protocol CalendarMeetingEventProviding: Sendable {
    func authorizationStatus() async -> CalendarMeetingCalendarAuthorization
    func requestFullAccess() async throws -> Bool
    func calendars() async throws -> [CalendarMeetingCalendar]
    func occurrences(
        in interval: DateInterval,
        calendarIDs: Set<String>
    ) async throws -> [CalendarMeetingOccurrence]
    func changes() async -> AsyncStream<Void>
}

protocol MeetingAudioActivityCollecting: Sendable {
    func startCollecting() async -> AsyncStream<MeetingActivitySnapshot>
    func stopCollecting() async
}

protocol MeetingCameraActivityCollecting: Sendable {
    func startCollecting() async -> AsyncStream<MeetingCameraActivitySnapshot>
    func stopCollecting() async
}

protocol BrowserURLResolving: Sendable {
    func activeURL(for bundleIdentifier: String) async -> URL?
}

enum SupportedMeetingBrowser {
    static let safari = "com.apple.Safari"
    static let arc = "company.thebrowser.Browser"
    static let chrome = "com.google.Chrome"
    static let chromeCanary = "com.google.Chrome.canary"
    static let brave = "com.brave.Browser"
    static let edge = "com.microsoft.edgemac"
    static let opera = "com.operasoftware.Opera"
    static let vivaldi = "com.vivaldi.Vivaldi"
    static let chromium = "org.chromium.Chromium"
    static let wavebox = "com.bookry.wavebox"
    static let firefox = "org.mozilla.firefox"
    static let firefoxDeveloperEdition = "org.mozilla.firefoxdeveloperedition"
    static let firefoxNightly = "org.mozilla.nightly"
    static let zen = "app.zen-browser.zen"

    static let automaticURLBundleIdentifiers: Set<String> = [
        safari, arc, chrome, chromeCanary, brave, edge, opera, vivaldi, chromium, wavebox
    ]

    static let reminderOnlyBundleIdentifiers: Set<String> = [
        firefox, firefoxDeveloperEdition, firefoxNightly, zen
    ]

    static func supportsAutomaticURLResolution(_ bundleIdentifier: String) -> Bool {
        automaticURLBundleIdentifiers.contains(bundleIdentifier)
    }

    static func isKnownBrowser(_ bundleIdentifier: String) -> Bool {
        supportsAutomaticURLResolution(bundleIdentifier)
            || reminderOnlyBundleIdentifiers.contains(bundleIdentifier)
    }
}

enum BrowserAudioProcessAttribution {
    // Current Safari/WebKit versions attribute browser meeting audio to the
    // GPU XPC process rather than to Safari itself. This attribution only
    // selects Safari for URL resolution; the controller still requires the
    // active Safari URL to match the canonical calendar meeting identity.
    static let safariWebKitGPUProcess = "com.apple.WebKit.GPU"

    private static let supportedHelperSuffixes = [
        ".helper",
        ".helper.renderer"
    ]

    static func canonicalBrowserBundleIdentifier(
        for audioProcessBundleIdentifier: String
    ) -> String? {
        if audioProcessBundleIdentifier == safariWebKitGPUProcess {
            return SupportedMeetingBrowser.safari
        }

        if SupportedMeetingBrowser.supportsAutomaticURLResolution(
            audioProcessBundleIdentifier
        ) {
            return audioProcessBundleIdentifier
        }

        return SupportedMeetingBrowser.automaticURLBundleIdentifiers
            .subtracting([SupportedMeetingBrowser.safari])
            .sorted { $0.count > $1.count }
            .first { browserBundleIdentifier in
                supportedHelperSuffixes.contains { suffix in
                    audioProcessBundleIdentifier == browserBundleIdentifier + suffix
                }
            }
    }
}
