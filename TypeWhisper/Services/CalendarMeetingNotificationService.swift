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

    var permitsAutoStop: Bool {
        self == .authorized
    }
}

enum CalendarMeetingNotificationKind: String, Equatable, Sendable {
    case upcoming
    case detected
    case autoStop
}

enum CalendarMeetingNotificationCategory: Equatable, Sendable {
    case upcomingReminder
    case upcomingAutomatic
    case detected
    case autoStop

    var identifier: String {
        switch self {
        case .upcomingReminder:
            CalendarMeetingNotificationService.upcomingReminderCategoryIdentifier
        case .upcomingAutomatic:
            CalendarMeetingNotificationService.upcomingAutomaticCategoryIdentifier
        case .detected:
            CalendarMeetingNotificationService.detectedCategoryIdentifier
        case .autoStop:
            CalendarMeetingNotificationService.autoStopCategoryIdentifier
        }
    }
}

enum CalendarMeetingNotificationDelivery: Equatable, Sendable {
    case scheduled(Date)
    case immediate
}

struct CalendarMeetingNotificationRequest: Equatable, Sendable {
    let identifier: String
    let occurrenceDigest: String
    let kind: CalendarMeetingNotificationKind
    let category: CalendarMeetingNotificationCategory
    let title: String
    let body: String
    let fireDate: Date
    let delivery: CalendarMeetingNotificationDelivery

    init(
        identifier: String,
        occurrenceDigest: String,
        kind: CalendarMeetingNotificationKind,
        category: CalendarMeetingNotificationCategory,
        title: String,
        body: String,
        fireDate: Date,
        delivery: CalendarMeetingNotificationDelivery? = nil
    ) {
        self.identifier = identifier
        self.occurrenceDigest = occurrenceDigest
        self.kind = kind
        self.category = category
        self.title = title
        self.body = body
        self.fireDate = fireDate
        if let delivery {
            self.delivery = delivery
        } else {
            self.delivery = switch kind {
            case .upcoming:
                .scheduled(fireDate)
            case .detected, .autoStop:
                .immediate
            }
        }
    }
}

enum CalendarMeetingNotificationResponse: Equatable, Sendable {
    case armStart(String)
    case suppress(String)
    case continueRecording(String)
    case openPremiumSettings

    var keepsApplicationInBackground: Bool {
        switch self {
        case .armStart, .suppress, .continueRecording:
            true
        case .openPremiumSettings:
            false
        }
    }
}

enum CalendarMeetingNotificationResponseMapper {
    static func actionOptions(for actionIdentifier: String) -> UNNotificationActionOptions {
        switch actionIdentifier {
        case CalendarMeetingNotificationService.suppressActionIdentifier:
            [.destructive]
        case CalendarMeetingNotificationService.startActionIdentifier,
             CalendarMeetingNotificationService.armWhenJoinedActionIdentifier,
             CalendarMeetingNotificationService.continueRecordingActionIdentifier:
            // The action must wake the app without activating it. Foreground activation is
            // interpreted as a normal app reopen and would open the Settings window.
            []
        default:
            []
        }
    }

    static func response(
        actionIdentifier: String,
        occurrenceDigest: String?,
        kind: CalendarMeetingNotificationKind? = nil
    ) -> CalendarMeetingNotificationResponse? {
        switch actionIdentifier {
        case CalendarMeetingNotificationService.startActionIdentifier,
             CalendarMeetingNotificationService.armWhenJoinedActionIdentifier:
            occurrenceDigest.map(CalendarMeetingNotificationResponse.armStart)
        case CalendarMeetingNotificationService.suppressActionIdentifier:
            occurrenceDigest.map(CalendarMeetingNotificationResponse.suppress)
        case CalendarMeetingNotificationService.continueRecordingActionIdentifier:
            occurrenceDigest.map(CalendarMeetingNotificationResponse.continueRecording)
        case UNNotificationDismissActionIdentifier:
            kind == .autoStop
                ? nil
                : occurrenceDigest.map(CalendarMeetingNotificationResponse.suppress)
        case UNNotificationDefaultActionIdentifier:
            if kind == .autoStop {
                occurrenceDigest.map(CalendarMeetingNotificationResponse.continueRecording)
            } else {
                .openPremiumSettings
            }
        default:
            nil
        }
    }
}

enum CalendarMeetingNotificationPresentationPolicy {
    static func foregroundOptions(
        for kind: CalendarMeetingNotificationKind?
    ) -> UNNotificationPresentationOptions {
        kind == .autoStop ? [.banner, .list, .sound] : [.banner, .sound]
    }

    static func interruptionLevel(
        for kind: CalendarMeetingNotificationKind
    ) -> UNNotificationInterruptionLevel? {
        kind == .autoStop ? .timeSensitive : nil
    }

    static func userInfo(
        occurrenceDigest: String,
        kind: CalendarMeetingNotificationKind
    ) -> [AnyHashable: Any] {
        [
            CalendarMeetingNotificationService.digestUserInfoKey: occurrenceDigest,
            CalendarMeetingNotificationService.kindUserInfoKey: kind.rawValue
        ]
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
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
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
        let kind = (notification.request.content.userInfo[
            CalendarMeetingNotificationService.kindUserInfoKey
        ] as? String).flatMap(CalendarMeetingNotificationKind.init(rawValue:))
        completionHandler(
            CalendarMeetingNotificationPresentationPolicy.foregroundOptions(for: kind)
        )
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let digest = userInfo[CalendarMeetingNotificationService.digestUserInfoKey] as? String
        let kind = (userInfo[CalendarMeetingNotificationService.kindUserInfoKey] as? String)
            .flatMap(CalendarMeetingNotificationKind.init(rawValue:))
        let action = CalendarMeetingNotificationResponseMapper.response(
            actionIdentifier: response.actionIdentifier,
            occurrenceDigest: digest,
            kind: kind
        )

        if let action {
            if action.keepsApplicationInBackground {
                ManagedAppReopenSuppression.shared.markBackgroundInteraction()
            }
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
        let legacyStart = UNNotificationAction(
            identifier: CalendarMeetingNotificationService.startActionIdentifier,
            title: String(localized: "calendarMeeting.notification.startAction"),
            options: CalendarMeetingNotificationResponseMapper.actionOptions(
                for: CalendarMeetingNotificationService.startActionIdentifier
            )
        )
        let armWhenJoined = UNNotificationAction(
            identifier: CalendarMeetingNotificationService.armWhenJoinedActionIdentifier,
            title: String(localized: "calendarMeeting.notification.armWhenJoinedAction"),
            options: CalendarMeetingNotificationResponseMapper.actionOptions(
                for: CalendarMeetingNotificationService.armWhenJoinedActionIdentifier
            )
        )
        let suppress = UNNotificationAction(
            identifier: CalendarMeetingNotificationService.suppressActionIdentifier,
            title: String(localized: "calendarMeeting.notification.suppressAction"),
            options: CalendarMeetingNotificationResponseMapper.actionOptions(
                for: CalendarMeetingNotificationService.suppressActionIdentifier
            )
        )
        let continueRecording = UNNotificationAction(
            identifier: CalendarMeetingNotificationService.continueRecordingActionIdentifier,
            title: String(localized: "calendarMeeting.notification.continueAction"),
            options: CalendarMeetingNotificationResponseMapper.actionOptions(
                for: CalendarMeetingNotificationService.continueRecordingActionIdentifier
            )
        )
        let legacyUpcoming = UNNotificationCategory(
            identifier: CalendarMeetingNotificationService.upcomingCategoryIdentifier,
            actions: [legacyStart, suppress],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        let upcomingReminder = UNNotificationCategory(
            identifier: CalendarMeetingNotificationService.upcomingReminderCategoryIdentifier,
            actions: [armWhenJoined, suppress],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        let upcomingAutomatic = UNNotificationCategory(
            identifier: CalendarMeetingNotificationService.upcomingAutomaticCategoryIdentifier,
            actions: [suppress],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        let detected = UNNotificationCategory(
            identifier: CalendarMeetingNotificationService.detectedCategoryIdentifier,
            actions: [legacyStart, suppress],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        let autoStop = UNNotificationCategory(
            identifier: CalendarMeetingNotificationService.autoStopCategoryIdentifier,
            actions: [continueRecording],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        center.setNotificationCategories([
            legacyUpcoming,
            upcomingReminder,
            upcomingAutomatic,
            detected,
            autoStop,
        ])
    }

    func authorizationStatus() async -> CalendarMeetingNotificationAuthorization {
        let settings = await center.notificationSettings()
        return switch settings.authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized:
            settings.alertSetting == .enabled ? .authorized : .denied
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
        if let interruptionLevel = CalendarMeetingNotificationPresentationPolicy
            .interruptionLevel(for: request.kind) {
            content.interruptionLevel = interruptionLevel
        }
        content.categoryIdentifier = request.category.identifier
        content.userInfo = CalendarMeetingNotificationPresentationPolicy.userInfo(
            occurrenceDigest: request.occurrenceDigest,
            kind: request.kind
        )
        let trigger: UNNotificationTrigger?
        switch request.delivery {
        case .scheduled(let fireDate):
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: fireDate
            )
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        case .immediate where request.kind == .autoStop:
            trigger = nil
        case .immediate:
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

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
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
        startMode: CalendarMeetingStartMode,
        now: Date
    ) async
    func publishDetectedMeeting(
        _ occurrence: CalendarMeetingOccurrence,
        now: Date
    ) async
    func publishAutoStopWarning(
        occurrenceDigest: String,
        now: Date
    ) async -> Bool
    func removeAutoStopWarning(occurrenceDigest: String)
    func removeScheduledMeetingRequests() async
}

@MainActor
final class CalendarMeetingNotificationService: ObservableObject, CalendarMeetingNotifying {
    nonisolated static let requestIdentifierPrefix = "com.typewhisper.calendar-meeting."
    // Kept registered so notifications scheduled by earlier builds remain actionable. Its
    // former direct-start action now maps to the same in-memory arm behavior as new requests.
    nonisolated static let upcomingCategoryIdentifier = "TYPEWHISPER_CALENDAR_MEETING_UPCOMING"
    nonisolated static let upcomingReminderCategoryIdentifier =
        "TYPEWHISPER_CALENDAR_MEETING_UPCOMING_REMINDER"
    nonisolated static let upcomingAutomaticCategoryIdentifier =
        "TYPEWHISPER_CALENDAR_MEETING_UPCOMING_AUTOMATIC"
    nonisolated static let detectedCategoryIdentifier = "TYPEWHISPER_CALENDAR_MEETING_DETECTED"
    nonisolated static let autoStopCategoryIdentifier = "TYPEWHISPER_CALENDAR_MEETING_AUTO_STOP"
    nonisolated static let startActionIdentifier = "TYPEWHISPER_CALENDAR_MEETING_START"
    nonisolated static let armWhenJoinedActionIdentifier =
        "TYPEWHISPER_CALENDAR_MEETING_ARM_WHEN_JOINED"
    nonisolated static let suppressActionIdentifier = "TYPEWHISPER_CALENDAR_MEETING_SUPPRESS"
    nonisolated static let continueRecordingActionIdentifier =
        "TYPEWHISPER_CALENDAR_MEETING_CONTINUE_RECORDING"
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
        startMode: CalendarMeetingStartMode = .reminder,
        now: Date = Date()
    ) async {
        await removeScheduledMeetingRequests()
        guard startMode != .off else { return }
        let upperBound = now.addingTimeInterval(7 * 24 * 60 * 60)
        let requestedDigests: Set<String> = Set(
            defaults.stringArray(
                forKey: UserDefaultsKeys.calendarMeetingReminderRequestDigests
            ) ?? []
        )
        typealias ReminderCandidate = (
            occurrence: CalendarMeetingOccurrence,
            fireDate: Date
        )
        let datedOccurrences: [ReminderCandidate] = occurrences.map { occurrence in
            (
                occurrence: occurrence,
                fireDate: occurrence.startDate.addingTimeInterval(-5 * 60)
            )
        }
        let activeCandidates: [ReminderCandidate] = datedOccurrences.filter { candidate in
            candidate.fireDate <= upperBound
                && candidate.occurrence.endDate.addingTimeInterval(30 * 60) >= now
        }
        let pendingCandidates: [ReminderCandidate] = activeCandidates.filter { candidate in
            candidate.fireDate > now
                || !requestedDigests.contains(candidate.occurrence.occurrenceDigest)
        }
        let sortedCandidates: [ReminderCandidate] = pendingCandidates.sorted { lhs, rhs in
            max(lhs.fireDate, now) < max(rhs.fireDate, now)
        }
        let candidates = sortedCandidates.prefix(48)

        for (occurrence, fireDate) in candidates {
            guard !Task.isCancelled else { return }
            let isCatchUp = fireDate <= now
            let title = occurrence.title.trimmingCharacters(
                in: CharacterSet.whitespacesAndNewlines
            )
            let category: CalendarMeetingNotificationCategory
            let notificationTitle: String
            let body: String
            switch startMode {
            case .off:
                continue
            case .reminder:
                category = .upcomingReminder
                notificationTitle = String(localized: isCatchUp
                    ? "calendarMeeting.notification.inProgressTitle"
                    : "calendarMeeting.notification.upcomingTitle")
                body = title.isEmpty
                    ? String(localized: "calendarMeeting.notification.untitledBody")
                    : title
            case .automatic:
                category = .upcomingAutomatic
                notificationTitle = title.isEmpty
                    ? String(localized: isCatchUp
                        ? "calendarMeeting.notification.inProgressTitle"
                        : "calendarMeeting.notification.upcomingTitle")
                    : title
                body = String(localized: "calendarMeeting.notification.upcomingAutomaticBody")
            }
            let request = CalendarMeetingNotificationRequest(
                identifier: Self.requestIdentifier(
                    digest: occurrence.occurrenceDigest,
                    kind: .upcoming
                ),
                occurrenceDigest: occurrence.occurrenceDigest,
                kind: .upcoming,
                category: category,
                title: notificationTitle,
                body: body,
                fireDate: isCatchUp ? now : fireDate,
                delivery: isCatchUp ? .immediate : .scheduled(fireDate)
            )
            do {
                try await client.add(request)
                persistReminderRequestDigest(occurrence.occurrenceDigest)
            } catch {
                removeReminderRequestDigest(occurrence.occurrenceDigest)
                continue
            }
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
            category: .detected,
            title: String(localized: "calendarMeeting.notification.detectedTitle"),
            body: title.isEmpty
                ? String(localized: "calendarMeeting.notification.untitledBody")
                : title,
            fireDate: now.addingTimeInterval(1)
        )
        try? await client.add(request)
    }

    func publishAutoStopWarning(
        occurrenceDigest: String,
        now: Date = Date()
    ) async -> Bool {
        authorization = await client.authorizationStatus()
        guard authorization.permitsAutoStop else { return false }
        removeAutoStopWarning(occurrenceDigest: occurrenceDigest)
        let request = CalendarMeetingNotificationRequest(
            identifier: Self.requestIdentifier(
                digest: occurrenceDigest,
                kind: .autoStop
            ),
            occurrenceDigest: occurrenceDigest,
            kind: .autoStop,
            category: .autoStop,
            title: String(localized: "calendarMeeting.notification.autoStopTitle"),
            body: String(localized: "calendarMeeting.notification.autoStopBody"),
            fireDate: now
        )
        do {
            try await client.add(request)
            return true
        } catch {
            return false
        }
    }

    func removeAutoStopWarning(occurrenceDigest: String) {
        let identifiers = [Self.requestIdentifier(digest: occurrenceDigest, kind: .autoStop)]
        client.removePendingRequests(withIdentifiers: identifiers)
        client.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func removeScheduledMeetingRequests() async {
        let identifiers = await client.pendingRequestIdentifiers().filter {
            $0.hasPrefix(Self.requestIdentifierPrefix)
                && ($0.hasSuffix(".\(CalendarMeetingNotificationKind.upcoming.rawValue)")
                    || $0.hasSuffix(".\(CalendarMeetingNotificationKind.detected.rawValue)"))
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

    private func persistReminderRequestDigest(_ digest: String) {
        let existing = defaults.stringArray(
            forKey: UserDefaultsKeys.calendarMeetingReminderRequestDigests
        ) ?? []
        defaults.set(
            CalendarMeetingReminderRequestLedger.appending(digest, to: existing),
            forKey: UserDefaultsKeys.calendarMeetingReminderRequestDigests
        )
    }

    private func removeReminderRequestDigest(_ digest: String) {
        let existing = defaults.stringArray(
            forKey: UserDefaultsKeys.calendarMeetingReminderRequestDigests
        ) ?? []
        defaults.set(
            existing.filter { $0 != digest },
            forKey: UserDefaultsKeys.calendarMeetingReminderRequestDigests
        )
    }
}
