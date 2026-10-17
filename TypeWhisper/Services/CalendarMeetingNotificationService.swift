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
    case openRecorder

    var keepsApplicationInBackground: Bool {
        switch self {
        case .armStart, .suppress, .continueRecording:
            true
        case .openRecorder:
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
                .openRecorder
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
    func deliveredRequestIdentifiers() async -> [String]
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

    func deliveredRequestIdentifiers() async -> [String] {
        await center.deliveredNotifications().map { $0.request.identifier }
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
        _ reminders: [CalendarMeetingUpcomingReminder],
        now: Date
    ) async
    func retainDetectedNotifications(eligibleDigests: Set<String>) async
    func publishDetectedMeeting(
        _ occurrence: CalendarMeetingOccurrence,
        now: Date
    ) async
    func removeStartNotifications(occurrenceDigest: String) async
    func allowReminderRestoration(occurrenceDigest: String)
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
        _ reminders: [CalendarMeetingUpcomingReminder],
        now: Date = Date()
    ) async {
        // Detected prompts are reconciled separately against their own eligibility,
        // including ad-hoc calls that have no upcoming reminder.
        await removePendingMeetingRequests(kinds: [.upcoming])
        let upperBound = now.addingTimeInterval(7 * 24 * 60 * 60)
        let requestedDigests: Set<String> = Set(
            defaults.stringArray(
                forKey: UserDefaultsKeys.calendarMeetingReminderRequestDigests
            ) ?? []
        )
        typealias ReminderCandidate = (
            reminder: CalendarMeetingUpcomingReminder,
            fireDate: Date
        )
        let datedReminders: [ReminderCandidate] = reminders.map { reminder in
            (
                reminder: reminder,
                fireDate: reminder.occurrence.startDate.addingTimeInterval(-5 * 60)
            )
        }
        let activeCandidates: [ReminderCandidate] = datedReminders.filter { candidate in
            candidate.fireDate <= upperBound
                && candidate.reminder.occurrence.endDate.addingTimeInterval(30 * 60) >= now
        }
        await removeDeliveredMeetingRequests(
            kinds: [.upcoming],
            retainingDigests: Set(activeCandidates.compactMap { candidate in
                guard candidate.reminder.startMode != .off else { return nil }
                return candidate.reminder.occurrence.occurrenceDigest
            })
        )
        let pendingCandidates: [ReminderCandidate] = activeCandidates.filter { candidate in
            candidate.fireDate > now
                || !requestedDigests.contains(candidate.reminder.occurrence.occurrenceDigest)
        }
        let sortedCandidates: [ReminderCandidate] = pendingCandidates.sorted { lhs, rhs in
            max(lhs.fireDate, now) < max(rhs.fireDate, now)
        }
        let candidates = sortedCandidates.prefix(48)

        for (reminder, fireDate) in candidates {
            guard !Task.isCancelled else { return }
            let occurrence = reminder.occurrence
            let isCatchUp = fireDate <= now
            let title = occurrence.title.trimmingCharacters(
                in: CharacterSet.whitespacesAndNewlines
            )
            let category: CalendarMeetingNotificationCategory
            let notificationTitle: String
            let body: String
            switch reminder.startMode {
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
                    kind: .upcoming,
                    generation: UUID().uuidString
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
        let title = occurrence.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = CalendarMeetingNotificationRequest(
            identifier: Self.requestIdentifier(
                digest: occurrence.occurrenceDigest,
                kind: .detected,
                generation: UUID().uuidString
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
        do {
            try await client.add(request)
        } catch {
            // Keep the existing consent prompt if its replacement cannot be added.
            return
        }
        // Retire older generations only after the new prompt was accepted. Its unique
        // identifier also survives delayed cleanup if a temporarily missing event returns.
        await removeStartNotifications(
            occurrenceDigest: occurrence.occurrenceDigest,
            kinds: [.upcoming, .detected], excluding: request.identifier
        )
    }

    func retainDetectedNotifications(eligibleDigests: Set<String>) async {
        let pending = await client.pendingRequestIdentifiers()
        let delivered = await client.deliveredRequestIdentifiers()
        let prefix = Self.requestIdentifierPrefix
        let identifiers = Set((pending + delivered).filter { identifier in
            guard identifier.hasPrefix(prefix), identifier.hasSuffix(".detected") else { return false }
            let digest = String(identifier.dropFirst(prefix.count).prefix { $0 != "." })
            return !eligibleDigests.contains(digest)
        }).sorted()
        guard !identifiers.isEmpty else { return }
        client.removePendingRequests(withIdentifiers: identifiers)
        client.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func removeStartNotifications(occurrenceDigest: String) async {
        await removeStartNotifications(occurrenceDigest: occurrenceDigest, kinds: [.upcoming, .detected])
    }

    private func removeStartNotifications(
        occurrenceDigest: String,
        kinds: [CalendarMeetingNotificationKind],
        excluding retainedIdentifier: String? = nil
    ) async {
        let pending = await client.pendingRequestIdentifiers()
        let delivered = await client.deliveredRequestIdentifiers()
        let prefix = "\(Self.requestIdentifierPrefix)\(occurrenceDigest)."
        // Query the notification center so restored generations can also be cleared
        // after a relaunch, without persisting request identifiers in app defaults.
        // Remove only existing copies, including legacy identifiers. A removal for
        // an absent detected prompt could otherwise delete a later publication.
        let identifiers = Set((pending + delivered).filter { identifier in
            identifier.hasPrefix(prefix)
                && identifier != retainedIdentifier
                && kinds.contains { identifier.hasSuffix(".\($0.rawValue)") }
        }).sorted()
        guard !identifiers.isEmpty else { return }
        client.removePendingRequests(withIdentifiers: identifiers)
        client.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func allowReminderRestoration(occurrenceDigest: String) {
        // Only an explicit restoration resets delivery history; accepting a reminder
        // must keep it deduplicated even when the in-memory arm is lost on restart.
        removeReminderRequestDigest(occurrenceDigest)
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
        await removePendingMeetingRequests(kinds: [.upcoming, .detected])
        await removeDeliveredMeetingRequests(kinds: [.upcoming, .detected])
    }

    private func removePendingMeetingRequests(kinds: [CalendarMeetingNotificationKind]) async {
        let identifiers = await client.pendingRequestIdentifiers().filter { identifier in
            identifier.hasPrefix(Self.requestIdentifierPrefix)
                && kinds.contains { identifier.hasSuffix(".\($0.rawValue)") }
        }
        guard !identifiers.isEmpty else { return }
        client.removePendingRequests(withIdentifiers: identifiers)
    }

    private func removeDeliveredMeetingRequests(
        kinds: [CalendarMeetingNotificationKind],
        retainingDigests: Set<String> = []
    ) async {
        let prefix = Self.requestIdentifierPrefix
        let identifiers = await client.deliveredRequestIdentifiers().filter { identifier in
            guard identifier.hasPrefix(prefix),
                  kinds.contains(where: { identifier.hasSuffix(".\($0.rawValue)") }) else {
                return false
            }
            // Match both legacy identifiers and requests with a generation component.
            return !retainingDigests.contains { identifier.hasPrefix("\(prefix)\($0).") }
        }
        guard !identifiers.isEmpty else { return }
        client.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    private static func requestIdentifier(
        digest: String,
        kind: CalendarMeetingNotificationKind,
        generation: String? = nil
    ) -> String {
        // Every start prompt gets a fresh identifier so an asynchronous removal
        // of an earlier generation cannot delete a restored or refreshed request.
        let generationComponent = generation.map { ".\($0)" } ?? ""
        return "\(requestIdentifierPrefix)\(digest)\(generationComponent).\(kind.rawValue)"
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
