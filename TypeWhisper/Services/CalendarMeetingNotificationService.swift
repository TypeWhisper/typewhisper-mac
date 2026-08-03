import Combine
import Foundation
@preconcurrency import UserNotifications

enum CalendarMeetingNotificationAuthorization: String, Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral
    case unknown
}

enum CalendarMeetingNotificationKind: String, Equatable, Sendable {
    case upcoming
    case detected
}

struct CalendarMeetingNotificationRequest: Equatable, Sendable {
    let identifier: String
    let occurrenceDigest: String
    let kind: CalendarMeetingNotificationKind
    let title: String
    let body: String
    let fireDate: Date
}

enum CalendarMeetingNotificationResponse: Equatable, Sendable {
    case start(String)
    case suppress(String)
    case openPremiumSettings
}

enum CalendarMeetingNotificationResponseMapper {
    static func response(
        actionIdentifier: String,
        occurrenceDigest: String?
    ) -> CalendarMeetingNotificationResponse? {
        switch actionIdentifier {
        case CalendarMeetingNotificationService.startActionIdentifier:
            occurrenceDigest.map(CalendarMeetingNotificationResponse.start)
        case CalendarMeetingNotificationService.suppressActionIdentifier,
             UNNotificationDismissActionIdentifier:
            occurrenceDigest.map(CalendarMeetingNotificationResponse.suppress)
        case UNNotificationDefaultActionIdentifier:
            .openPremiumSettings
        default:
            nil
        }
    }
}

@MainActor
protocol CalendarMeetingNotificationClient: AnyObject {
    func installResponseHandler(
        _ handler: @escaping @MainActor (CalendarMeetingNotificationResponse) -> Void
    )
    func registerCategories()
    func authorizationStatus() async -> CalendarMeetingNotificationAuthorization
    func requestAuthorization() async throws -> Bool
    func pendingRequestIdentifiers() async -> [String]
    func add(_ request: CalendarMeetingNotificationRequest) async throws
    func removePendingRequests(withIdentifiers identifiers: [String])
}

private final class CalendarMeetingNotificationDelegateBridge:
    NSObject,
    UNUserNotificationCenterDelegate,
    @unchecked Sendable
{
    let handler: @MainActor (CalendarMeetingNotificationResponse) -> Void

    init(handler: @escaping @MainActor (CalendarMeetingNotificationResponse) -> Void) {
        self.handler = handler
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let digest = userInfo[CalendarMeetingNotificationService.digestUserInfoKey] as? String
        let action = CalendarMeetingNotificationResponseMapper.response(
            actionIdentifier: response.actionIdentifier,
            occurrenceDigest: digest
        )

        if let action {
            completionHandler()
            Task { @MainActor [handler] in
                handler(action)
            }
        } else {
            completionHandler()
        }
    }
}

@MainActor
private final class UserNotificationCenterClient: CalendarMeetingNotificationClient {
    private let center: UNUserNotificationCenter
    private var delegateBridge: CalendarMeetingNotificationDelegateBridge?

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func installResponseHandler(
        _ handler: @escaping @MainActor (CalendarMeetingNotificationResponse) -> Void
    ) {
        let bridge = CalendarMeetingNotificationDelegateBridge(handler: handler)
        delegateBridge = bridge
        center.delegate = bridge
    }

    func registerCategories() {
        let start = UNNotificationAction(
            identifier: CalendarMeetingNotificationService.startActionIdentifier,
            title: String(localized: "calendarMeeting.notification.startAction"),
            options: [.foreground]
        )
        let suppress = UNNotificationAction(
            identifier: CalendarMeetingNotificationService.suppressActionIdentifier,
            title: String(localized: "calendarMeeting.notification.suppressAction"),
            options: [.destructive]
        )
        let actions = [start, suppress]
        let upcoming = UNNotificationCategory(
            identifier: CalendarMeetingNotificationService.upcomingCategoryIdentifier,
            actions: actions,
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        let detected = UNNotificationCategory(
            identifier: CalendarMeetingNotificationService.detectedCategoryIdentifier,
            actions: actions,
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        center.setNotificationCategories([upcoming, detected])
    }

    func authorizationStatus() async -> CalendarMeetingNotificationAuthorization {
        let settings = await center.notificationSettings()
        return switch settings.authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        case .provisional: .provisional
        case .ephemeral: .ephemeral
        @unknown default: .unknown
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func pendingRequestIdentifiers() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier)
    }

    func add(_ request: CalendarMeetingNotificationRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        content.categoryIdentifier = request.kind == .upcoming
            ? CalendarMeetingNotificationService.upcomingCategoryIdentifier
            : CalendarMeetingNotificationService.detectedCategoryIdentifier
        content.userInfo = [
            CalendarMeetingNotificationService.digestUserInfoKey: request.occurrenceDigest,
            CalendarMeetingNotificationService.kindUserInfoKey: request.kind.rawValue
        ]
        let trigger: UNNotificationTrigger
        switch request.kind {
        case .upcoming:
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: request.fireDate
            )
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        case .detected:
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        }
        try await center.add(UNNotificationRequest(
            identifier: request.identifier,
            content: content,
            trigger: trigger
        ))
    }

    func removePendingRequests(withIdentifiers identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}

@MainActor
protocol CalendarMeetingNotifying: AnyObject {
    var authorization: CalendarMeetingNotificationAuthorization { get }
    func installRouter(
        responseHandler: @escaping @MainActor (CalendarMeetingNotificationResponse) -> Void
    )
    func configureAndRequestAuthorization() async -> CalendarMeetingNotificationAuthorization
    func refreshAuthorizationStatus() async
    func replaceScheduledReminders(
        _ occurrences: [CalendarMeetingOccurrence],
        now: Date
    ) async
    func publishDetectedMeeting(
        _ occurrence: CalendarMeetingOccurrence,
        now: Date
    ) async
    func removeScheduledMeetingRequests() async
}

@MainActor
final class CalendarMeetingNotificationService: ObservableObject, CalendarMeetingNotifying {
    nonisolated static let requestIdentifierPrefix = "com.typewhisper.calendar-meeting."
    nonisolated static let upcomingCategoryIdentifier = "TYPEWHISPER_CALENDAR_MEETING_UPCOMING"
    nonisolated static let detectedCategoryIdentifier = "TYPEWHISPER_CALENDAR_MEETING_DETECTED"
    nonisolated static let startActionIdentifier = "TYPEWHISPER_CALENDAR_MEETING_START"
    nonisolated static let suppressActionIdentifier = "TYPEWHISPER_CALENDAR_MEETING_SUPPRESS"
    nonisolated static let digestUserInfoKey = "occurrenceDigest"
    nonisolated static let kindUserInfoKey = "actionType"

    @Published private(set) var authorization: CalendarMeetingNotificationAuthorization = .notDetermined

    private let client: any CalendarMeetingNotificationClient
    private let defaults: UserDefaults
    private var responseHandler: (@MainActor (CalendarMeetingNotificationResponse) -> Void)?

    init(defaults: UserDefaults = .standard) {
        client = UserNotificationCenterClient()
        self.defaults = defaults
    }

    init(
        client: any CalendarMeetingNotificationClient,
        defaults: UserDefaults
    ) {
        self.client = client
        self.defaults = defaults
    }

    static func shouldInstallRouter(defaults: UserDefaults = .standard) -> Bool {
        let mode = CalendarMeetingStartMode(
            rawValue: defaults.string(forKey: UserDefaultsKeys.calendarMeetingStartMode) ?? ""
        ) ?? .off
        return mode != .off
            || defaults.bool(forKey: UserDefaultsKeys.calendarMeetingNotificationsConfigured)
    }

    func installRouter(
        responseHandler: @escaping @MainActor (CalendarMeetingNotificationResponse) -> Void
    ) {
        self.responseHandler = responseHandler
        client.installResponseHandler(responseHandler)
        client.registerCategories()
    }

    @discardableResult
    func configureAndRequestAuthorization() async -> CalendarMeetingNotificationAuthorization {
        client.registerCategories()
        defaults.set(true, forKey: UserDefaultsKeys.calendarMeetingNotificationsConfigured)
        authorization = await client.authorizationStatus()
        if authorization == .notDetermined {
            _ = try? await client.requestAuthorization()
            authorization = await client.authorizationStatus()
        }
        return authorization
    }

    func refreshAuthorizationStatus() async {
        authorization = await client.authorizationStatus()
    }

    func replaceScheduledReminders(
        _ occurrences: [CalendarMeetingOccurrence],
        now: Date = Date()
    ) async {
        await removeScheduledMeetingRequests()
        let upperBound = now.addingTimeInterval(7 * 24 * 60 * 60)
        let candidates = occurrences
            .map { ($0, $0.startDate.addingTimeInterval(-5 * 60)) }
            .filter { $0.1 > now && $0.1 <= upperBound }
            .sorted { $0.1 < $1.1 }
            .prefix(48)

        for (occurrence, fireDate) in candidates {
            guard !Task.isCancelled else { return }
            let title = occurrence.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let request = CalendarMeetingNotificationRequest(
                identifier: Self.requestIdentifier(
                    digest: occurrence.occurrenceDigest,
                    kind: .upcoming
                ),
                occurrenceDigest: occurrence.occurrenceDigest,
                kind: .upcoming,
                title: String(localized: "calendarMeeting.notification.upcomingTitle"),
                body: title.isEmpty
                    ? String(localized: "calendarMeeting.notification.untitledBody")
                    : title,
                fireDate: fireDate
            )
            try? await client.add(request)
        }
    }

    func publishDetectedMeeting(
        _ occurrence: CalendarMeetingOccurrence,
        now: Date = Date()
    ) async {
        client.removePendingRequests(withIdentifiers: [
            Self.requestIdentifier(digest: occurrence.occurrenceDigest, kind: .upcoming)
        ])
        let title = occurrence.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = CalendarMeetingNotificationRequest(
            identifier: Self.requestIdentifier(
                digest: occurrence.occurrenceDigest,
                kind: .detected
            ),
            occurrenceDigest: occurrence.occurrenceDigest,
            kind: .detected,
            title: String(localized: "calendarMeeting.notification.detectedTitle"),
            body: title.isEmpty
                ? String(localized: "calendarMeeting.notification.untitledBody")
                : title,
            fireDate: now.addingTimeInterval(1)
        )
        try? await client.add(request)
    }

    func removeScheduledMeetingRequests() async {
        let identifiers = await client.pendingRequestIdentifiers().filter {
            $0.hasPrefix(Self.requestIdentifierPrefix)
        }
        guard !identifiers.isEmpty else { return }
        client.removePendingRequests(withIdentifiers: identifiers)
    }

    private static func requestIdentifier(
        digest: String,
        kind: CalendarMeetingNotificationKind
    ) -> String {
        "\(requestIdentifierPrefix)\(digest).\(kind.rawValue)"
    }
}
