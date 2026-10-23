import Foundation
import UserNotifications
import XCTest
@testable import TypeWhisper

@MainActor
private final class FakeCalendarMeetingNotificationClient: CalendarMeetingNotificationClient {
    var authorization: CalendarMeetingNotificationAuthorization = .notDetermined
    var pendingIdentifiers: [String] = []
    var deliveredIdentifiers: [String] = []
    var added: [CalendarMeetingNotificationRequest] = []
    var categoriesByIdentifier: [String: String] = [:]
    var removed: [[String]] = []
    var removedDelivered: [[String]] = []
    var defersPendingRemovals = false
    private var deferredPendingRemovals: [String] = []
    var defersDeliveredRemovals = false
    private var deferredDeliveredRemovals: [String] = []
    var addError: Error?
    var registerCount = 0
    var requestCount = 0
    var pendingQueryCount = 0
    var deliveredQueryCount = 0
    var responseHandler: (@MainActor (CalendarMeetingNotificationResponse) -> Void)?

    func installResponseHandler(
        _ handler: @escaping @MainActor (CalendarMeetingNotificationResponse) -> Void
    ) {
        responseHandler = handler
    }

    func registerCategories() { registerCount += 1 }
    func authorizationStatus() async -> CalendarMeetingNotificationAuthorization { authorization }
    func requestAuthorization() async throws -> Bool {
        requestCount += 1
        return true
    }
    func pendingRequests() async -> [CalendarMeetingNotificationRequestSnapshot] {
        pendingQueryCount += 1
        return pendingIdentifiers.map {
            CalendarMeetingNotificationRequestSnapshot(
                identifier: $0, categoryIdentifier: categoriesByIdentifier[$0] ?? ""
            )
        }
    }
    func deliveredRequests() async -> [CalendarMeetingNotificationRequestSnapshot] {
        deliveredQueryCount += 1
        return deliveredIdentifiers.map {
            CalendarMeetingNotificationRequestSnapshot(
                identifier: $0, categoryIdentifier: categoriesByIdentifier[$0] ?? ""
            )
        }
    }
    func add(_ request: CalendarMeetingNotificationRequest) async throws {
        if let addError { throw addError }
        added.append(request)
        categoriesByIdentifier[request.identifier] = request.category.identifier
        if !pendingIdentifiers.contains(request.identifier) {
            pendingIdentifiers.append(request.identifier)
        }
    }
    func removePendingRequests(withIdentifiers identifiers: [String]) {
        removed.append(identifiers)
        deferredPendingRemovals.append(contentsOf: identifiers)
        if !defersPendingRemovals {
            completePendingRemovals()
        }
    }
    func completePendingRemovals() {
        let identifiers = Set(deferredPendingRemovals)
        pendingIdentifiers.removeAll { identifiers.contains($0) }
        deferredPendingRemovals.removeAll()
    }
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        removedDelivered.append(identifiers)
        deferredDeliveredRemovals.append(contentsOf: identifiers)
        if !defersDeliveredRemovals { completeDeliveredRemovals() }
    }
    func completeDeliveredRemovals() {
        let identifiers = Set(deferredDeliveredRemovals)
        deliveredIdentifiers.removeAll { identifiers.contains($0) }
        deferredDeliveredRemovals.removeAll()
    }
}

private extension CalendarMeetingNotificationService {
    func applyNotificationEffects(_ effects: [CalendarMeetingAutomationEffect], at date: Date) async {
        for effect in effects {
            switch effect {
            case .replaceScheduledReminders(let reminders):
                await replaceScheduledReminders(reminders, now: date)
            case .retainDetectedNotifications(let digests):
                await retainDetectedNotifications(eligibleDigests: digests)
            case .dismissStartNotifications(let digest):
                await removeStartNotifications(occurrenceDigest: digest)
            case .allowReminderRestoration(let digest):
                allowReminderRestoration(occurrenceDigest: digest)
            case .publishDetectedMeeting(let occurrence):
                await publishDetectedMeeting(occurrence, now: date)
            default:
                break
            }
        }
    }

    func replaceScheduledReminders(
        _ occurrences: [CalendarMeetingOccurrence],
        startMode: CalendarMeetingStartMode = .reminder,
        now: Date
    ) async {
        await replaceScheduledReminders(
            occurrences.map { CalendarMeetingUpcomingReminder(occurrence: $0, startMode: startMode) },
            now: now
        )
    }
}

@MainActor
final class CalendarMeetingNotificationServiceTests: XCTestCase {
    private enum RefreshInterruption {
        case missing, declined
    }

    private enum RecorderBusyTiming {
        case beforeCountdown, atDeadline, afterStartRequest
    }

    func testAutomaticCountdownSignalLossRestoresFutureReminderWithoutCalendarRefresh() async throws {
        try await assertCountdownSignalLossRestoresReminder()
    }

    func testCancelledAutomaticStartRestoresFutureReminderWithoutCalendarRefresh() async throws {
        try await assertCountdownSignalLossRestoresReminder(cancelledRequest: true)
    }

    func testCancelledAutomaticStartRestoresCatchUpReminder() async throws {
        try await assertCountdownSignalLossRestoresReminder(startDelay: 120, cancelledRequest: true)
    }

    func testCancelledArmedStartKeepsReminderDismissedAndIgnoresLateCancellation() async throws {
        try await assertCountdownSignalLossRestoresReminder(startMode: .reminder, cancelledRequest: true)
    }

    func testAutomaticCountdownSignalLossRestoresCatchUpReminderOnce() async throws {
        try await assertCountdownSignalLossRestoresReminder(startDelay: 120)
    }

    func testRepeatedAutomaticCountdownLossDoesNotRepeatCatchUpBanner() async throws {
        try await assertCountdownSignalLossRestoresReminder(startDelay: 120, repeatLoss: true)
    }

    func testRepeatedDeferredStartLossDoesNotRepeatCatchUpBanner() async throws {
        try await assertCountdownSignalLossRestoresReminder(startDelay: 120, deferred: true, repeatLoss: true)
    }

    func testRepeatedCancelledStartDoesNotRepeatCatchUpBanner() async throws {
        try await assertCountdownSignalLossRestoresReminder(startDelay: 120, cancelledRequest: true, repeatLoss: true)
    }

    func testRepeatedAutomaticCountdownLossKeepsReschedulingFutureReminder() async throws {
        try await assertCountdownSignalLossRestoresReminder(repeatLoss: true)
    }

    func testArmedCountdownSignalLossKeepsReminderDismissed() async throws {
        try await assertCountdownSignalLossRestoresReminder(startMode: .reminder)
    }

    func testDeferredAutomaticStartSignalLossRestoresReminder() async throws {
        try await assertCountdownSignalLossRestoresReminder(deferred: true)
    }

    func testAutomaticCameraCountdownLossRestoresFutureReminder() async throws {
        try await assertCountdownSignalLossRestoresReminder(cameraEvidence: true)
    }

    func testDeferredAutomaticStartRestoresReminderWhenActivityBecomesUnavailable() async throws {
        try await assertCountdownSignalLossRestoresReminder(deferred: true, activityUnavailable: true)
    }

    private func assertCountdownSignalLossRestoresReminder(
        startMode: CalendarMeetingStartMode = .automatic,
        startDelay: TimeInterval = 600,
        cameraEvidence: Bool = false,
        deferred: Bool = false,
        activityUnavailable: Bool = false,
        cancelledRequest: Bool = false,
        repeatLoss: Bool = false
    ) async throws {
        let suiteName = "CalendarMeetingSignalLossTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        let service = CalendarMeetingNotificationService(client: client, defaults: defaults)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(start: now.addingTimeInterval(startDelay))
        let configuration = CalendarMeetingAutomationConfiguration(
            startMode: startMode, autoStopEnabled: false,
            calendarAuthorization: .fullAccess, selectedCalendarIDs: [occurrence.calendarID],
            enabledProviders: [.zoom], suppressedOccurrenceDigests: []
        )
        var policy = CalendarMeetingAutomationPolicy()
        await service.applyNotificationEffects(
            policy.reduce(.configure(configuration, occurrences: [occurrence], now: now)), at: now
        )
        let original = try XCTUnwrap(client.added.last)
        if startDelay <= 300 {
            client.deliveredIdentifiers = client.pendingIdentifiers
            client.pendingIdentifiers.removeAll()
        }
        client.added.removeAll()
        if startMode == .reminder {
            await service.applyNotificationEffects(
                policy.reduce(.userAction(.armOccurrence(occurrence.id), now: now)), at: now
            )
        }
        let signal = CalendarMeetingJoinSignal(
            occurrenceDigest: occurrence.id, meetingIdentity: try XCTUnwrap(occurrence.meetingLinks.first),
            quality: .nativeProvider, isRunningInput: true, isRunningOutput: false
        )
        _ = policy.reduce(cameraEvidence ? .cameraActivity(isRunning: true, now: now) : .activity([signal], now: now))
        let countdown = policy.reduce(.timeAdvanced(now.addingTimeInterval(3)))
        XCTAssertTrue(countdown.contains(.showStartCountdown(occurrence, deadline: now.addingTimeInterval(8))))
        await service.applyNotificationEffects(countdown, at: now.addingTimeInterval(3))
        XCTAssertTrue(client.pendingIdentifiers.isEmpty)
        XCTAssertTrue(client.deliveredIdentifiers.isEmpty)
        if deferred {
            _ = policy.reduce(.recorderReadiness(.recorderBusy, now: now.addingTimeInterval(4)))
            await service.applyNotificationEffects(
                policy.reduce(.timeAdvanced(now.addingTimeInterval(8))), at: now.addingTimeInterval(8)
            )
        }
        if cancelledRequest {
            let start = policy.reduce(.timeAdvanced(now.addingTimeInterval(8)))
            XCTAssertTrue(start.contains(.startRecording(occurrence, signal.meetingIdentity)))
            await service.applyNotificationEffects(start, at: now.addingTimeInterval(8))
            _ = policy.reduce(.recorderReadiness(.dictationBusy, now: now.addingTimeInterval(8.5)))
        }
        let lostAt = now.addingTimeInterval(deferred || cancelledRequest ? 9 : 4)
        let loss: CalendarMeetingAutomationEvent = cameraEvidence
            ? .cameraActivityUnavailable(now: lostAt)
            : activityUnavailable ? .activityUnavailable(now: lostAt) : .activity([], now: lostAt)
        var lostEffects = policy.reduce(loss)
        if cancelledRequest {
            lostEffects += policy.reduce(.recordingStartCancelled(occurrenceDigest: occurrence.id, now: lostAt))
        }
        if !deferred && !cancelledRequest { XCTAssertTrue(lostEffects.contains(.dismissStartCountdown)) }
        await service.applyNotificationEffects(lostEffects, at: lostAt)
        XCTAssertEqual(client.added.count, startMode == .automatic ? 1 : 0)
        if startMode == .automatic {
            let restored = try XCTUnwrap(client.added.last)
            XCTAssertNotEqual(restored.identifier, original.identifier)
            XCTAssertEqual(restored.kind, .upcoming)
            XCTAssertEqual(restored.delivery, startDelay > 300
                ? .scheduled(occurrence.startDate.addingTimeInterval(-300)) : .immediate)
            XCTAssertEqual(client.pendingIdentifiers, [restored.identifier])
        }
        await service.applyNotificationEffects(
            policy.reduce(.timeAdvanced(lostAt.addingTimeInterval(1))), at: lostAt.addingTimeInterval(1)
        )
        XCTAssertEqual(client.added.count, startMode == .automatic ? 1 : 0,
            "Repeated signal-free ticks must not repeat the restored reminder")
        _ = policy.reduce(.recorderReadiness(.idle, now: lostAt.addingTimeInterval(1)))
        let rejoinedAt = lostAt.addingTimeInterval(2)
        _ = policy.reduce(cameraEvidence
            ? .cameraActivity(isRunning: true, now: rejoinedAt) : .activity([signal], now: rejoinedAt))
        let retryAt = rejoinedAt.addingTimeInterval(3)
        let retry = policy.reduce(.timeAdvanced(retryAt))
        XCTAssertTrue(retry.contains(.showStartCountdown(occurrence, deadline: retryAt.addingTimeInterval(5))))
        await service.applyNotificationEffects(retry, at: retryAt)
        XCTAssertTrue(client.pendingIdentifiers.isEmpty)
        if cancelledRequest {
            XCTAssertTrue(policy.reduce(.recordingStartCancelled(occurrenceDigest: occurrence.id, now: retryAt)).isEmpty,
                "A late cancellation must not dismiss a newer countdown")
        }
        if repeatLoss {
            if deferred {
                _ = policy.reduce(.recorderReadiness(.recorderBusy, now: retryAt.addingTimeInterval(1)))
            }
            if deferred || cancelledRequest {
                await service.applyNotificationEffects(
                    policy.reduce(.timeAdvanced(retryAt.addingTimeInterval(5))), at: retryAt.addingTimeInterval(5)
                )
            }
            let secondLossAt = retryAt.addingTimeInterval(deferred || cancelledRequest ? 6 : 1)
            var secondLoss = policy.reduce(.activity([], now: secondLossAt))
            if cancelledRequest {
                secondLoss += policy.reduce(.recordingStartCancelled(occurrenceDigest: occurrence.id, now: secondLossAt))
            }
            await service.applyNotificationEffects(secondLoss, at: secondLossAt)
            XCTAssertEqual(client.added.count, startDelay > 300 ? 2 : 1,
                "Repeated handoff loss may reschedule future reminders but must not repeat audible catch-up banners")
            if startDelay <= 300 {
                await service.applyNotificationEffects(
                    policy.reduce(.configure(configuration, occurrences: [occurrence], now: secondLossAt)), at: secondLossAt
                )
                XCTAssertEqual(client.added.count, 1, "Refresh must preserve catch-up deduplication")
            }
        }
    }

    func testDeliveredAutomaticReminderChangesToReminderActions() async throws {
        try await assertReminderCategoryChange(from: .automatic, to: .reminder)
    }

    func testDeliveredReminderChangesToAutomaticActions() async throws {
        try await assertReminderCategoryChange(from: .reminder, to: .automatic)
    }

    func testPendingCatchUpReminderChangesToReminderActions() async throws {
        try await assertReminderCategoryChange(from: .automatic, to: .reminder, delivered: false)
    }

    func testReminderCategoryChangeSurvivesServiceRestart() async throws {
        try await assertReminderCategoryChange(from: .automatic, to: .reminder, restart: true)
    }

    func testReminderCategoryReplacementSurvivesDelayedRemovalWithoutRepeating() async throws {
        try await assertReminderCategoryChange(from: .automatic, to: .reminder, delayedRemoval: true)
    }

    func testFailedReminderCategoryReplacementKeepsFallbackUntilRetry() async throws {
        try await assertReminderCategoryChange(from: .automatic, to: .reminder, failFirstAdd: true)
    }

    func testUnchangedDeliveredReminderCategoryKeepsOriginalPrompt() async throws {
        try await assertReminderCategoryChange(from: .reminder, to: .reminder)
    }

    func testAcceptedReminderIsNotRestoredByCategoryChangeDuringDelayedCleanup() async throws {
        try await assertReminderCategoryChange(from: .automatic, to: .reminder,
            delayedRemoval: true, accepted: true)
    }

    func testLegacyUpcomingCategoryIsReplacedWithCurrentReminderActions() async throws {
        try await assertReminderCategoryChange(from: .reminder, to: .reminder, legacyCategory: true)
    }

    private func assertReminderCategoryChange(
        from oldMode: CalendarMeetingStartMode,
        to newMode: CalendarMeetingStartMode,
        delivered: Bool = true,
        restart: Bool = false,
        delayedRemoval: Bool = false,
        failFirstAdd: Bool = false,
        accepted: Bool = false,
        legacyCategory: Bool = false
    ) async throws {
        let suiteName = "CalendarMeetingCategoryChangeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        var service = CalendarMeetingNotificationService(client: client, defaults: defaults)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(start: now.addingTimeInterval(120))
        let other = makeCalendarMeetingTestOccurrence(eventID: "other", start: now.addingTimeInterval(120))
        await service.replaceScheduledReminders([
            CalendarMeetingUpcomingReminder(occurrence: occurrence, startMode: oldMode),
            CalendarMeetingUpcomingReminder(occurrence: other, startMode: .reminder)
        ], now: now)
        let original = try XCTUnwrap(client.added.first { $0.occurrenceDigest == occurrence.id })
        let otherRequest = try XCTUnwrap(client.added.first { $0.occurrenceDigest == other.id })
        if legacyCategory {
            client.categoriesByIdentifier[original.identifier] = CalendarMeetingNotificationService.upcomingCategoryIdentifier
        }
        if delivered {
            client.deliveredIdentifiers = client.pendingIdentifiers
            client.pendingIdentifiers.removeAll()
        }
        client.added.removeAll()
        client.defersPendingRemovals = delayedRemoval
        client.defersDeliveredRemovals = delayedRemoval
        if accepted { await service.removeStartNotifications(occurrenceDigest: occurrence.id) }
        if restart { service = CalendarMeetingNotificationService(client: client, defaults: defaults) }
        let reminders = [
            CalendarMeetingUpcomingReminder(occurrence: occurrence, startMode: newMode),
            CalendarMeetingUpcomingReminder(occurrence: other, startMode: .reminder)
        ]
        if failFirstAdd {
            client.addError = NSError(domain: "ReminderCategoryAdd", code: 1)
            await service.replaceScheduledReminders(reminders, now: now.addingTimeInterval(1))
            XCTAssertTrue(client.added.isEmpty)
            XCTAssertTrue((client.pendingIdentifiers + client.deliveredIdentifiers).contains(original.identifier),
                "The existing prompt must survive a failed replacement")
            client.addError = nil
            await service.replaceScheduledReminders([
                CalendarMeetingUpcomingReminder(occurrence: occurrence, startMode: oldMode),
                CalendarMeetingUpcomingReminder(occurrence: other, startMode: .reminder)
            ], now: now.addingTimeInterval(1.5))
            XCTAssertTrue(client.added.isEmpty,
                "Returning to the original category must preserve the still-delivered fallback without repeating it")
        }
        await service.replaceScheduledReminders(reminders, now: now.addingTimeInterval(2))
        let expectsReplacement = !accepted && (oldMode != newMode || legacyCategory)
        XCTAssertEqual(client.added.count, expectsReplacement ? 1 : 0)
        if expectsReplacement {
            let replacement = try XCTUnwrap(client.added.last)
            XCTAssertNotEqual(replacement.identifier, original.identifier)
            XCTAssertEqual(replacement.category, newMode == .automatic ? .upcomingAutomatic : .upcomingReminder)
            XCTAssertEqual(replacement.delivery, .immediate)
            XCTAssertTrue(client.pendingIdentifiers.contains(replacement.identifier))
            await service.replaceScheduledReminders(reminders, now: now.addingTimeInterval(3))
            XCTAssertEqual(client.added.count, 1, "An old category awaiting removal must not cause a second replacement")
        }
        client.completePendingRemovals()
        client.completeDeliveredRemovals()
        let remaining = Set(client.pendingIdentifiers + client.deliveredIdentifiers)
        XCTAssertTrue(remaining.contains(otherRequest.identifier))
        if expectsReplacement || accepted {
            XCTAssertFalse(remaining.contains(original.identifier))
        } else {
            XCTAssertTrue(remaining.contains(original.identifier))
        }
    }

    private enum DetectedReminderRemoval {
        case missing, declined, shutdown, accepted
    }

    func testMissingDetectedReplacementRestoresReminderWithoutJoinEvidence() async throws {
        try await assertDetectedReplacementRestoresReminder(removal: .missing)
    }

    func testDeclinedDetectedReplacementRestoresReminderWithoutJoinEvidence() async throws {
        try await assertDetectedReplacementRestoresReminder(removal: .declined)
    }

    func testDeliveredDetectedReplacementRestoresReminderAfterShutdown() async throws {
        try await assertDetectedReplacementRestoresReminder(removal: .shutdown)
    }

    func testAcceptedDetectedReplacementKeepsLedgerDuringDelayedCleanup() async throws {
        try await assertDetectedReplacementRestoresReminder(removal: .accepted)
    }

    private func assertDetectedReplacementRestoresReminder(removal: DetectedReminderRemoval) async throws {
        let suiteName = "CalendarMeetingDetectedRestorationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        let service = CalendarMeetingNotificationService(client: client, defaults: defaults)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(start: now.addingTimeInterval(120))
        let configuration = CalendarMeetingAutomationConfiguration(
            startMode: .reminder, autoStopEnabled: false,
            calendarAuthorization: .fullAccess, selectedCalendarIDs: [occurrence.calendarID],
            enabledProviders: [.zoom], suppressedOccurrenceDigests: []
        )
        var policy = CalendarMeetingAutomationPolicy()
        await service.applyNotificationEffects(
            policy.reduce(.configure(configuration, occurrences: [occurrence], now: now)), at: now
        )
        client.deliveredIdentifiers = client.pendingIdentifiers
        client.pendingIdentifiers.removeAll()
        let signal = CalendarMeetingJoinSignal(
            occurrenceDigest: occurrence.id, meetingIdentity: try XCTUnwrap(occurrence.meetingLinks.first),
            quality: .nativeProvider, isRunningInput: true, isRunningOutput: false
        )
        _ = policy.reduce(.activity([signal], now: now))
        await service.applyNotificationEffects(
            policy.reduce(.timeAdvanced(now.addingTimeInterval(3))), at: now.addingTimeInterval(3)
        )
        let detected = try XCTUnwrap(client.added.last)
        XCTAssertEqual(detected.kind, .detected)
        XCTAssertTrue(client.deliveredIdentifiers.isEmpty)
        if removal != .missing {
            client.deliveredIdentifiers = client.pendingIdentifiers
            client.pendingIdentifiers.removeAll()
        }
        client.added.removeAll()
        _ = policy.reduce(.activity([], now: now.addingTimeInterval(4)))
        let removedAt = now.addingTimeInterval(5)
        if removal == .accepted {
            client.defersDeliveredRemovals = true
            await service.applyNotificationEffects(
                policy.reduce(.userAction(.armOccurrence(occurrence.id), now: removedAt)), at: removedAt
            )
        }
        if removal == .shutdown {
            await service.removeScheduledMeetingRequests()
        } else {
            let declined = makeCalendarMeetingTestOccurrence(start: occurrence.startDate, participation: .declined)
            await service.applyNotificationEffects(
                policy.reduce(.configure(configuration,
                    occurrences: removal == .declined ? [declined] : [], now: removedAt)), at: removedAt
            )
        }
        client.completeDeliveredRemovals()
        XCTAssertTrue(client.pendingIdentifiers.isEmpty)
        XCTAssertTrue(client.deliveredIdentifiers.isEmpty)
        let restarted = CalendarMeetingNotificationService(client: client, defaults: defaults)
        if removal == .accepted { policy = CalendarMeetingAutomationPolicy() }
        let returnedAt = now.addingTimeInterval(6)
        await restarted.applyNotificationEffects(
            policy.reduce(.configure(configuration, occurrences: [occurrence], now: returnedAt)), at: returnedAt
        )
        XCTAssertEqual(client.added.count, removal == .accepted ? 0 : 1)
        guard removal != .accepted else { return }
        let restored = try XCTUnwrap(client.added.last)
        XCTAssertEqual(restored.category, .upcomingReminder)
        XCTAssertEqual(restored.delivery, .immediate)
        await restarted.applyNotificationEffects(
            policy.reduce(.configure(configuration, occurrences: [occurrence], now: returnedAt)), at: returnedAt
        )
        XCTAssertEqual(client.added.count, 1)
        XCTAssertEqual(client.pendingIdentifiers, [restored.identifier])
    }

    func testBusyAtCountdownDeadlineDoesNotRestoreFutureReminder() async throws {
        try await assertBusyRecorderReminderRefresh(timing: .atDeadline)
    }

    func testDeferredRecordingStartDoesNotRestoreFutureReminder() async throws {
        try await assertBusyRecorderReminderRefresh(timing: .afterStartRequest)
    }

    func testBusyBeforeCountdownKeepsFutureReminder() async throws {
        try await assertBusyRecorderReminderRefresh(timing: .beforeCountdown)
    }

    private func assertBusyRecorderReminderRefresh(timing: RecorderBusyTiming) async throws {
        let suiteName = "CalendarMeetingBusyHandoffTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        let service = CalendarMeetingNotificationService(client: client, defaults: defaults)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(start: now.addingTimeInterval(600))
        let configuration = CalendarMeetingAutomationConfiguration(
            startMode: .automatic, autoStopEnabled: false,
            calendarAuthorization: .fullAccess, selectedCalendarIDs: [occurrence.calendarID],
            enabledProviders: [.zoom], suppressedOccurrenceDigests: []
        )
        var policy = CalendarMeetingAutomationPolicy()
        await service.applyNotificationEffects(
            policy.reduce(.configure(configuration, occurrences: [occurrence], now: now)), at: now
        )
        XCTAssertEqual(client.pendingIdentifiers.count, 1)
        if timing == .beforeCountdown {
            _ = policy.reduce(.recorderReadiness(.recorderBusy, now: now))
        }
        let identity = try XCTUnwrap(occurrence.meetingLinks.first)
        let signal = CalendarMeetingJoinSignal(occurrenceDigest: occurrence.id, meetingIdentity: identity,
            quality: .nativeProvider, isRunningInput: true, isRunningOutput: true)
        _ = policy.reduce(.activity([signal], now: now))
        await service.applyNotificationEffects(
            policy.reduce(.timeAdvanced(now.addingTimeInterval(3))), at: now.addingTimeInterval(3)
        )
        if timing == .atDeadline {
            _ = policy.reduce(.recorderReadiness(.recorderBusy, now: now.addingTimeInterval(4)))
        }
        let start = policy.reduce(.timeAdvanced(now.addingTimeInterval(8)))
        if timing == .afterStartRequest {
            XCTAssertTrue(start.contains(.startRecording(occurrence, identity)))
            _ = policy.reduce(.recordingStartDeferred(occurrenceDigest: occurrence.id,
                identity: identity, readiness: .recorderBusy, now: now.addingTimeInterval(8)))
        }
        // Repeated stable evidence must not downgrade a candidate that already handed off.
        _ = policy.reduce(.activity([signal], now: now.addingTimeInterval(9)))
        let refresh = policy.reduce(.configure(configuration, occurrences: [occurrence], now: now.addingTimeInterval(10)))
        await service.applyNotificationEffects(refresh, at: now.addingTimeInterval(10))
        XCTAssertEqual(client.pendingIdentifiers.count, timing == .beforeCountdown ? 1 : 0)
        XCTAssertTrue(refresh.contains(.replaceScheduledReminders(timing == .beforeCountdown
            ? [CalendarMeetingUpcomingReminder(occurrence: occurrence, startMode: .automatic)] : [])))
        let retryAt = now.addingTimeInterval(11)
        XCTAssertTrue(policy.reduce(.recorderReadiness(.idle, now: retryAt)).contains(
            .showStartCountdown(occurrence, deadline: retryAt.addingTimeInterval(5))
        ))
    }

    func testDeliveredReminderReturnsOnceAfterTransientEmptyRefresh() async throws {
        try await assertDeliveredReminderRestoresAfterRemoval(shutdown: false)
    }

    func testDeliveredReminderReturnsOnceAfterAutomationShutdown() async throws {
        try await assertDeliveredReminderRestoresAfterRemoval(shutdown: true)
    }

    func testPendingReminderReturnsOnceAfterTransientEmptyRefresh() async throws {
        try await assertDeliveredReminderRestoresAfterRemoval(shutdown: false, delivered: false)
    }

    private func assertDeliveredReminderRestoresAfterRemoval(
        shutdown: Bool, delivered: Bool = true
    ) async throws {
        let suiteName = "CalendarMeetingDeliveredRestorationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        let service = CalendarMeetingNotificationService(client: client, defaults: defaults)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(start: now.addingTimeInterval(120))
        await service.replaceScheduledReminders([occurrence], now: now)
        let original = try XCTUnwrap(client.added.last)
        if delivered {
            client.pendingIdentifiers.removeAll()
            client.deliveredIdentifiers = [original.identifier]
        }
        client.added.removeAll()

        if shutdown {
            await service.removeScheduledMeetingRequests()
        } else {
            await service.replaceScheduledReminders([], now: now.addingTimeInterval(1))
        }
        XCTAssertTrue(client.deliveredIdentifiers.isEmpty)
        XCTAssertTrue(client.pendingIdentifiers.isEmpty)
        let recreated = CalendarMeetingNotificationService(client: client, defaults: defaults)
        await recreated.replaceScheduledReminders([occurrence], now: now.addingTimeInterval(2))
        XCTAssertEqual(client.added.count, 1)
        let restored = try XCTUnwrap(client.added.last)
        XCTAssertEqual(restored.delivery, .immediate)
        XCTAssertNotEqual(restored.identifier, original.identifier)
        await recreated.replaceScheduledReminders([occurrence], now: now.addingTimeInterval(2.5))
        XCTAssertEqual(client.pendingIdentifiers, [restored.identifier],
            "A refresh before delivery must preserve the restored prompt")
        client.pendingIdentifiers.removeAll()
        client.deliveredIdentifiers = [restored.identifier]
        await recreated.replaceScheduledReminders([occurrence], now: now.addingTimeInterval(4))
        XCTAssertEqual(client.added.count, 1)
        XCTAssertEqual(client.deliveredIdentifiers, [restored.identifier])
    }

    func testDelayedHandoffCleanupDoesNotResetAcceptedReminderLedger() async throws {
        let suiteName = "CalendarMeetingDelayedAcceptedRemovalTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        let service = CalendarMeetingNotificationService(client: client, defaults: defaults)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(start: now.addingTimeInterval(120))
        await service.replaceScheduledReminders([occurrence], now: now)
        client.deliveredIdentifiers = client.pendingIdentifiers
        client.pendingIdentifiers.removeAll()
        client.added.removeAll()
        client.defersDeliveredRemovals = true
        await service.removeStartNotifications(occurrenceDigest: occurrence.id)
        // The notification center can still return the accepted banner during reconciliation.
        await service.replaceScheduledReminders([], now: now.addingTimeInterval(1))
        client.completeDeliveredRemovals()
        let restarted = CalendarMeetingNotificationService(client: client, defaults: defaults)
        await restarted.replaceScheduledReminders([occurrence], now: now.addingTimeInterval(2))
        XCTAssertTrue(client.added.isEmpty, "Accepted reminders must remain deduplicated after restart")
    }

    func testReminderPlanningIsSortedLimitedToSevenDaysAndFortyEight() async throws {
        let suiteName = "CalendarMeetingNotificationServiceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        let service = CalendarMeetingNotificationService(client: client, defaults: defaults)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrences = (0..<60).reversed().map { index in
            makeCalendarMeetingTestOccurrence(
                eventID: "event-\(index)",
                start: now.addingTimeInterval(600 + Double(index * 60))
            )
        } + [
            makeCalendarMeetingTestOccurrence(
                eventID: "too-late",
                start: now.addingTimeInterval(8 * 24 * 60 * 60)
            )
        ]

        await service.replaceScheduledReminders(occurrences, now: now)

        XCTAssertEqual(client.added.count, 48)
        XCTAssertEqual(client.added.map(\.fireDate), client.added.map(\.fireDate).sorted())
        XCTAssertTrue(client.added.allSatisfy { $0.fireDate <= now.addingTimeInterval(7 * 24 * 60 * 60) })
        XCTAssertTrue(client.added.allSatisfy { $0.identifier.hasPrefix(
            CalendarMeetingNotificationService.requestIdentifierPrefix
        ) })
        XCTAssertTrue(client.added.allSatisfy { $0.category == .upcomingReminder })
        XCTAssertTrue(client.added.allSatisfy {
            if case .scheduled(let fireDate) = $0.delivery {
                return fireDate == $0.fireDate
            }
            return false
        })
    }

    func testLateCreatedOccurrenceGetsOneImmediateCatchUpReminder() async throws {
        let suiteName = "CalendarMeetingCatchUpTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        let service = CalendarMeetingNotificationService(client: client, defaults: defaults)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(
            eventID: "late-created",
            start: now.addingTimeInterval(-10 * 60)
        )

        await service.replaceScheduledReminders([occurrence], now: now)

        let request = try XCTUnwrap(client.added.first)
        XCTAssertEqual(client.added.count, 1)
        XCTAssertEqual(request.delivery, .immediate)
        XCTAssertEqual(request.fireDate, now)
        XCTAssertEqual(
            request.title,
            String(localized: "calendarMeeting.notification.inProgressTitle")
        )
        XCTAssertEqual(
            defaults.stringArray(
                forKey: UserDefaultsKeys.calendarMeetingReminderRequestDigests
            ),
            [occurrence.occurrenceDigest]
        )

        client.added.removeAll()
        await service.replaceScheduledReminders(
            [occurrence],
            now: now.addingTimeInterval(1)
        )
        XCTAssertTrue(client.added.isEmpty)
    }

    func testPreviouslyScheduledReminderDoesNotBecomeDuplicateCatchUpReminder() async throws {
        let suiteName = "CalendarMeetingScheduledLedgerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        let service = CalendarMeetingNotificationService(client: client, defaults: defaults)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(
            eventID: "scheduled-before-fire",
            start: now.addingTimeInterval(10 * 60)
        )

        await service.replaceScheduledReminders([occurrence], now: now)
        XCTAssertEqual(client.added.count, 1)
        client.added.removeAll()

        await service.replaceScheduledReminders(
            [occurrence],
            now: now.addingTimeInterval(6 * 60)
        )
        XCTAssertTrue(client.added.isEmpty)
    }

    func testModeChangeRestoresCatchUpReminderAfterAutomaticCountdown() async throws {
        try await assertCountdownConfigurationChangeRestoresReminder(
            startMode: .reminder,
            confirmSoloEvents: false
        )
    }

    func testArmedReminderIsNotRepeatedAfterServiceAndPolicyRestart() async throws {
        let suiteName = "CalendarMeetingArmedRestartTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        let service = CalendarMeetingNotificationService(client: client, defaults: defaults)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(start: now.addingTimeInterval(2 * 60))
        let configuration = CalendarMeetingAutomationConfiguration(
            startMode: .reminder, autoStopEnabled: false,
            calendarAuthorization: .fullAccess, selectedCalendarIDs: [occurrence.calendarID],
            enabledProviders: [.zoom], suppressedOccurrenceDigests: []
        )
        var policy = CalendarMeetingAutomationPolicy()
        await service.applyNotificationEffects(
            policy.reduce(.configure(configuration, occurrences: [occurrence], now: now)),
            at: now
        )
        let original = try XCTUnwrap(client.added.first)
        client.pendingIdentifiers.removeAll()
        client.deliveredIdentifiers = [original.identifier]
        await service.applyNotificationEffects(
            policy.reduce(.userAction(.armOccurrence(occurrence.id), now: now)),
            at: now
        )
        XCTAssertTrue(client.deliveredIdentifiers.isEmpty)

        let restartedClient = FakeCalendarMeetingNotificationClient()
        let restartedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let restartedService = CalendarMeetingNotificationService(
            client: restartedClient, defaults: restartedDefaults
        )
        var restartedPolicy = CalendarMeetingAutomationPolicy()
        let restartedAt = now.addingTimeInterval(30)
        await restartedService.applyNotificationEffects(
            restartedPolicy.reduce(.configure(
                configuration, occurrences: [occurrence], now: restartedAt
            )),
            at: restartedAt
        )

        XCTAssertTrue(restartedClient.added.isEmpty,
            "Losing the in-memory arm on restart must not repeat an already accepted reminder")
    }

    func testSoloConfirmationRestoresCatchUpReminderAfterAutomaticCountdown() async throws {
        try await assertCountdownConfigurationChangeRestoresReminder(
            startMode: .automatic,
            confirmSoloEvents: true
        )
    }

    func testModeChangeRestoresCatchUpReminderDuringRecordingStartup() async throws {
        try await assertCountdownConfigurationChangeRestoresReminder(
            startMode: .reminder,
            confirmSoloEvents: false,
            startRequested: true
        )
    }

    func testModeChangeRestoresCatchUpReminderAfterRecordingStartupIsDeferred() async throws {
        try await assertCountdownConfigurationChangeRestoresReminder(
            startMode: .reminder,
            confirmSoloEvents: false,
            startRequested: true,
            deferStartup: true
        )
    }

    func testInterruptedCountdownRestoresReminderAfterSwitchingOffAndBackOn() async throws {
        try await assertCountdownConfigurationChangeRestoresReminder(
            startMode: .reminder, confirmSoloEvents: false, switchOffFirst: true
        )
    }

    func testRestoredReminderSurvivesDelayedCountdownDismissal() async throws {
        try await assertCountdownConfigurationChangeRestoresReminder(
            startMode: .reminder, confirmSoloEvents: false, deferRemovals: true
        )
    }

    func testMissingOccurrenceRestoresReminderAfterCountdown() async throws {
        try await assertCountdownConfigurationChangeRestoresReminder(
            startMode: .automatic, confirmSoloEvents: false, interruption: .missing
        )
    }

    func testMissingOccurrenceRestoresReminderDuringRecordingStartup() async throws {
        try await assertCountdownConfigurationChangeRestoresReminder(
            startMode: .automatic, confirmSoloEvents: false,
            startRequested: true, interruption: .missing
        )
    }

    func testDeclinedOccurrenceRestoresReminderAfterDeferredStartup() async throws {
        try await assertCountdownConfigurationChangeRestoresReminder(
            startMode: .automatic, confirmSoloEvents: false,
            startRequested: true, deferStartup: true, interruption: .declined
        )
    }

    private func assertCountdownConfigurationChangeRestoresReminder(
        startMode: CalendarMeetingStartMode,
        confirmSoloEvents: Bool,
        startRequested: Bool = false,
        deferStartup: Bool = false,
        switchOffFirst: Bool = false,
        deferRemovals: Bool = false,
        interruption: RefreshInterruption? = nil
    ) async throws {
        let suiteName = "CalendarMeetingRestoredReminderTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        let service = CalendarMeetingNotificationService(client: client, defaults: defaults)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(
            start: now.addingTimeInterval(2 * 60),
            hasOtherParticipants: false
        )
        let automatic = CalendarMeetingAutomationConfiguration(
            startMode: .automatic, autoStopEnabled: false,
            calendarAuthorization: .fullAccess, selectedCalendarIDs: [occurrence.calendarID],
            enabledProviders: [.zoom], suppressedOccurrenceDigests: []
        )
        let changed = CalendarMeetingAutomationConfiguration(
            startMode: startMode, autoStopEnabled: false,
            calendarAuthorization: .fullAccess, selectedCalendarIDs: [occurrence.calendarID],
            enabledProviders: [.zoom], suppressedOccurrenceDigests: [],
            confirmSoloEvents: confirmSoloEvents
        )
        var policy = CalendarMeetingAutomationPolicy()
        await service.applyNotificationEffects(
            policy.reduce(.configure(automatic, occurrences: [occurrence], now: now)),
            at: now
        )
        let original = try XCTUnwrap(client.added.first)
        XCTAssertEqual(original.category, .upcomingAutomatic)
        client.pendingIdentifiers.removeAll()
        client.deliveredIdentifiers = [original.identifier]
        client.added.removeAll()
        client.defersPendingRemovals = deferRemovals

        let signal = CalendarMeetingJoinSignal(
            occurrenceDigest: occurrence.id,
            meetingIdentity: try XCTUnwrap(occurrence.meetingLinks.first),
            quality: .nativeProvider, isRunningInput: true, isRunningOutput: false
        )
        _ = policy.reduce(.activity([signal], now: now))
        let countdown = policy.reduce(.timeAdvanced(now.addingTimeInterval(3)))
        XCTAssertTrue(countdown.contains(.showStartCountdown(
            occurrence, deadline: now.addingTimeInterval(8)
        )))
        await service.applyNotificationEffects(countdown, at: now.addingTimeInterval(3))
        XCTAssertTrue(client.deliveredIdentifiers.isEmpty)

        if startRequested {
            let start = policy.reduce(.timeAdvanced(now.addingTimeInterval(8)))
            XCTAssertTrue(start.contains(.startRecording(occurrence, signal.meetingIdentity)))
            await service.applyNotificationEffects(start, at: now.addingTimeInterval(8))
            if deferStartup {
                _ = policy.reduce(.recordingStartDeferred(
                    occurrenceDigest: occurrence.id,
                    identity: signal.meetingIdentity,
                    readiness: .recorderBusy,
                    now: now.addingTimeInterval(8)
                ))
            }
        }
        var changedAt = now.addingTimeInterval(startRequested ? 9 : 4)
        if let interruption {
            let declined = makeCalendarMeetingTestOccurrence(
                start: occurrence.startDate, participation: .declined, hasOtherParticipants: false
            )
            let invalidated = policy.reduce(.configure(
                automatic, occurrences: interruption == .missing ? [] : [declined], now: changedAt
            ))
            if !startRequested {
                XCTAssertTrue(invalidated.contains(.dismissStartCountdown))
            }
            await service.applyNotificationEffects(invalidated, at: changedAt)
            XCTAssertTrue(client.added.isEmpty, "An ineligible occurrence cannot restore a reminder")
            _ = policy.reduce(.activity([], now: changedAt))
            changedAt = changedAt.addingTimeInterval(1)
        }
        if switchOffFirst {
            let off = CalendarMeetingAutomationConfiguration(
                startMode: .off, autoStopEnabled: false,
                calendarAuthorization: .fullAccess, selectedCalendarIDs: [occurrence.calendarID],
                enabledProviders: [.zoom], suppressedOccurrenceDigests: []
            )
            await service.applyNotificationEffects(
                policy.reduce(.configure(off, occurrences: [], now: changedAt)), at: changedAt
            )
            XCTAssertTrue(client.added.isEmpty, "Switching off must not restore any reminder")
            changedAt = changedAt.addingTimeInterval(1)
            await service.applyNotificationEffects(
                policy.reduce(.configure(changed, occurrences: [], now: changedAt)), at: changedAt
            )
            XCTAssertTrue(client.added.isEmpty, "Wait until the occurrence is fetched again")
            changedAt = changedAt.addingTimeInterval(1)
        }
        let effects = policy.reduce(.configure(changed, occurrences: [occurrence], now: changedAt))
        if !startRequested && !switchOffFirst && interruption == nil {
            XCTAssertTrue(effects.contains(.dismissStartCountdown))
        }
        await service.applyNotificationEffects(effects, at: changedAt)

        XCTAssertEqual(client.added.count, 1, "Clearing the countdown must restore the consent prompt")
        let restored = try XCTUnwrap(client.added.first)
        XCTAssertNotEqual(restored.identifier, original.identifier)
        XCTAssertEqual(restored.category,
            changed.startMode(for: occurrence) == .reminder ? .upcomingReminder : .upcomingAutomatic)
        XCTAssertEqual(restored.delivery, .immediate)
        XCTAssertEqual(restored.fireDate, changedAt)
        client.completePendingRemovals()
        XCTAssertEqual(client.pendingIdentifiers, [restored.identifier],
            "An earlier countdown dismissal must not delete the restored reminder")

        // Delivery followed by another refresh must not repeat the catch-up prompt.
        client.pendingIdentifiers.removeAll()
        client.deliveredIdentifiers = [restored.identifier]
        client.added.removeAll()
        await service.applyNotificationEffects(
            policy.reduce(.configure(changed, occurrences: [occurrence], now: changedAt)),
            at: changedAt
        )
        XCTAssertTrue(client.added.isEmpty)
        XCTAssertEqual(client.deliveredIdentifiers, [restored.identifier])

        let restartedService = CalendarMeetingNotificationService(client: client, defaults: defaults)
        await restartedService.removeStartNotifications(occurrenceDigest: occurrence.id)
        client.completePendingRemovals()
        XCTAssertTrue(client.deliveredIdentifiers.isEmpty,
            "A fresh service must find and clear the restored request's generation")
        XCTAssertTrue(client.pendingIdentifiers.isEmpty)
    }

    func testExplicitRestorationDoesNotRepeatAnotherOccurrencesReminder() async throws {
        let suiteName = "CalendarMeetingScopedRestorationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        let service = CalendarMeetingNotificationService(client: client, defaults: defaults)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let restored = makeCalendarMeetingTestOccurrence(start: now)
        let other = makeCalendarMeetingTestOccurrence(eventID: "other", start: now)
        defaults.set([restored.id, other.id], forKey: UserDefaultsKeys.calendarMeetingReminderRequestDigests)

        service.allowReminderRestoration(occurrenceDigest: restored.id)
        await service.replaceScheduledReminders([restored, other], now: now)

        XCTAssertEqual(client.added.map(\.occurrenceDigest), [restored.id])
    }

    func testRescheduledOccurrenceDigestCanReceiveNewCatchUpReminder() async throws {
        let suiteName = "CalendarMeetingRescheduledCatchUpTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        let service = CalendarMeetingNotificationService(client: client, defaults: defaults)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let original = makeCalendarMeetingTestOccurrence(
            eventID: "rescheduled",
            start: now.addingTimeInterval(-20 * 60)
        )
        let moved = makeCalendarMeetingTestOccurrence(
            eventID: "rescheduled",
            start: now.addingTimeInterval(-10 * 60)
        )

        await service.replaceScheduledReminders([original], now: now)
        client.added.removeAll()
        await service.replaceScheduledReminders([moved], now: now)

        XCTAssertNotEqual(original.occurrenceDigest, moved.occurrenceDigest)
        XCTAssertEqual(client.added.map(\.occurrenceDigest), [moved.occurrenceDigest])
    }

    func testCatchUpReminderFailsClosedAfterJoinWindow() async throws {
        let suiteName = "CalendarMeetingExpiredCatchUpTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        let service = CalendarMeetingNotificationService(client: client, defaults: defaults)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(
            eventID: "expired",
            start: now.addingTimeInterval(-2 * 60 * 60),
            duration: 30 * 60
        )

        await service.replaceScheduledReminders([occurrence], now: now)

        XCTAssertTrue(client.added.isEmpty)
    }

    func testReminderRequestLedgerIsUniqueAndBounded() {
        let initial = (0..<CalendarMeetingReminderRequestLedger.capacity).map {
            "digest-\($0)"
        }
        let refreshed = CalendarMeetingReminderRequestLedger.appending(
            "digest-10",
            to: initial
        )
        XCTAssertEqual(refreshed.count, CalendarMeetingReminderRequestLedger.capacity)
        XCTAssertEqual(refreshed.last, "digest-10")
        XCTAssertEqual(refreshed.filter { $0 == "digest-10" }.count, 1)

        let overflow = CalendarMeetingReminderRequestLedger.appending(
            "digest-new",
            to: refreshed
        )
        XCTAssertEqual(overflow.count, CalendarMeetingReminderRequestLedger.capacity)
        XCTAssertFalse(overflow.contains("digest-0"))
        XCTAssertEqual(overflow.last, "digest-new")
    }

    func testFailedReminderReplacementIsEligibleForLaterRetry() async throws {
        struct AddError: Error {}

        let suiteName = "CalendarMeetingReminderRetryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        client.addError = AddError()
        let service = CalendarMeetingNotificationService(client: client, defaults: defaults)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(
            eventID: "retry-after-add-failure",
            start: now.addingTimeInterval(10 * 60)
        )
        defaults.set(
            [occurrence.occurrenceDigest],
            forKey: UserDefaultsKeys.calendarMeetingReminderRequestDigests
        )

        await service.replaceScheduledReminders([occurrence], now: now)

        XCTAssertEqual(
            defaults.stringArray(
                forKey: UserDefaultsKeys.calendarMeetingReminderRequestDigests
            ),
            []
        )
    }

    func testUpcomingNotificationCategoryAndCopyReflectStartMode() async throws {
        let suiteName = "CalendarMeetingNotificationModeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        let service = CalendarMeetingNotificationService(client: client, defaults: defaults)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(
            start: now.addingTimeInterval(10 * 60)
        )

        await service.replaceScheduledReminders(
            [occurrence],
            startMode: .automatic,
            now: now
        )

        let request = try XCTUnwrap(client.added.last)
        XCTAssertEqual(request.category, .upcomingAutomatic)
        XCTAssertEqual(
            request.body,
            String(localized: "calendarMeeting.notification.upcomingAutomaticBody")
        )

        client.added.removeAll()
        await service.replaceScheduledReminders(
            [occurrence],
            startMode: .reminder,
            now: now
        )
        XCTAssertEqual(client.added.last?.category, .upcomingReminder)
    }

    func testUpcomingNotificationCategoryFollowsEachReminderStartMode() async throws {
        let suiteName = "CalendarMeetingNotificationMixedModeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        let service = CalendarMeetingNotificationService(client: client, defaults: defaults)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let solo = makeCalendarMeetingTestOccurrence(
            eventID: "solo",
            start: now.addingTimeInterval(10 * 60),
            title: "Dentist",
            hasOtherParticipants: false
        )
        let team = makeCalendarMeetingTestOccurrence(
            eventID: "team",
            start: now.addingTimeInterval(20 * 60)
        )

        await service.replaceScheduledReminders([
            CalendarMeetingUpcomingReminder(occurrence: solo, startMode: .reminder),
            CalendarMeetingUpcomingReminder(occurrence: team, startMode: .automatic),
        ], now: now)

        XCTAssertEqual(client.added.map(\.occurrenceDigest), [solo.id, team.id])
        XCTAssertEqual(client.added.map(\.category), [.upcomingReminder, .upcomingAutomatic])
        XCTAssertEqual(client.added.first?.body, "Dentist")
        XCTAssertEqual(
            client.added.last?.body,
            String(localized: "calendarMeeting.notification.upcomingAutomaticBody")
        )
    }

    func testRefreshOnlyRemovesCalendarMeetingRequests() async throws {
        let suiteName = "CalendarMeetingNotificationRemovalTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        client.pendingIdentifiers = [
            "external.notification",
            CalendarMeetingNotificationService.requestIdentifierPrefix + "one.upcoming",
            CalendarMeetingNotificationService.requestIdentifierPrefix + "one.generation.upcoming",
            CalendarMeetingNotificationService.requestIdentifierPrefix + "two.detected",
            CalendarMeetingNotificationService.requestIdentifierPrefix + "two.generation.detected",
            CalendarMeetingNotificationService.requestIdentifierPrefix + "three.autoStop"
        ]
        client.deliveredIdentifiers = client.pendingIdentifiers
        let service = CalendarMeetingNotificationService(client: client, defaults: defaults)

        await service.removeScheduledMeetingRequests()

        XCTAssertEqual(client.removed, [[
            CalendarMeetingNotificationService.requestIdentifierPrefix + "one.upcoming",
            CalendarMeetingNotificationService.requestIdentifierPrefix + "one.generation.upcoming",
            CalendarMeetingNotificationService.requestIdentifierPrefix + "two.detected",
            CalendarMeetingNotificationService.requestIdentifierPrefix + "two.generation.detected"
        ]])
        XCTAssertEqual(client.removedDelivered, client.removed)
        let retained = ["external.notification",
            CalendarMeetingNotificationService.requestIdentifierPrefix + "three.autoStop"]
        XCTAssertEqual(client.pendingIdentifiers, retained)
        XCTAssertEqual(client.deliveredIdentifiers, retained)
    }

    func testRefreshRemovesOnlyIneligibleDeliveredUpcomingPrompts() async throws {
        let suiteName = "CalendarMeetingDeliveredRefreshTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        let service = CalendarMeetingNotificationService(client: client, defaults: defaults)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let eligible = makeCalendarMeetingTestOccurrence(eventID: "eligible", start: now)
        let automatic = makeCalendarMeetingTestOccurrence(eventID: "automatic", start: now)
        let removed = makeCalendarMeetingTestOccurrence(eventID: "removed", start: now)
        let off = makeCalendarMeetingTestOccurrence(eventID: "off", start: now)
        let expired = makeCalendarMeetingTestOccurrence(eventID: "expired", start: now.addingTimeInterval(-7200))
        let beyondHorizon = makeCalendarMeetingTestOccurrence(eventID: "later", start: now.addingTimeInterval(8 * 86400))
        let prefix = CalendarMeetingNotificationService.requestIdentifierPrefix
        func identifiers(_ occurrence: CalendarMeetingOccurrence) -> [String] {
            ["\(prefix)\(occurrence.id).upcoming", "\(prefix)\(occurrence.id).generation.upcoming"]
        }
        let unrelated = ["external.notification", "\(prefix)other.detected", "\(prefix)other.autoStop"]
        let occurrences = [eligible, automatic, removed, off, expired, beyondHorizon]
        client.deliveredIdentifiers = occurrences.flatMap(identifiers) + unrelated
        for identifier in identifiers(eligible) {
            client.categoriesByIdentifier[identifier] = CalendarMeetingNotificationCategory.upcomingReminder.identifier
        }
        for identifier in identifiers(automatic) {
            client.categoriesByIdentifier[identifier] = CalendarMeetingNotificationCategory.upcomingAutomatic.identifier
        }
        defaults.set(occurrences.map(\.id), forKey: UserDefaultsKeys.calendarMeetingReminderRequestDigests)

        await service.replaceScheduledReminders([
            CalendarMeetingUpcomingReminder(occurrence: eligible, startMode: .reminder),
            CalendarMeetingUpcomingReminder(occurrence: automatic, startMode: .automatic),
            CalendarMeetingUpcomingReminder(occurrence: off, startMode: .off),
            CalendarMeetingUpcomingReminder(occurrence: expired, startMode: .reminder),
            CalendarMeetingUpcomingReminder(occurrence: beyondHorizon, startMode: .reminder)
        ], now: now)

        XCTAssertEqual(Set(client.deliveredIdentifiers),
            Set(identifiers(eligible) + identifiers(automatic) + unrelated))
        XCTAssertTrue(client.added.isEmpty, "Delivered eligible reminders remain deduplicated")
    }

    func testUnchangedCalendarActivityDoesNotQueryNotificationCenter() async throws {
        try await assertUnchangedActivityDoesNotQueryNotificationCenter(isAdHoc: false)
    }

    func testUnchangedAdHocActivityDoesNotQueryNotificationCenterButVanishedSessionDoes() async throws {
        try await assertUnchangedActivityDoesNotQueryNotificationCenter(isAdHoc: true)
    }

    private func assertUnchangedActivityDoesNotQueryNotificationCenter(isAdHoc: Bool) async throws {
        let suiteName = "CalendarMeetingActivityQueriesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        let service = CalendarMeetingNotificationService(client: client, defaults: defaults)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let identity = CalendarMeetingCanonicalLink(provider: .zoom, identity: "j/123456789")
        let occurrence = CalendarMeetingOccurrence(
            eventIdentifier: "activity-queries", occurrenceStart: now,
            startDate: now, endDate: now.addingTimeInterval(1800), title: "Meeting",
            calendarID: "calendar", participationStatus: .accepted,
            meetingLinks: [identity], isAdHoc: isAdHoc
        )
        let configuration = CalendarMeetingAutomationConfiguration(
            startMode: .reminder, autoStopEnabled: false,
            calendarAuthorization: .fullAccess, selectedCalendarIDs: [occurrence.calendarID],
            enabledProviders: [.zoom], suppressedOccurrenceDigests: [], detectAdHocMeetings: isAdHoc
        )
        var policy = CalendarMeetingAutomationPolicy()
        await service.applyNotificationEffects(
            policy.reduce(.configure(configuration, occurrences: isAdHoc ? [] : [occurrence], now: now)),
            at: now
        )
        let signal = CalendarMeetingJoinSignal(occurrenceDigest: occurrence.id, meetingIdentity: identity,
            quality: .nativeProvider, isRunningInput: true, isRunningOutput: true)
        let detectedOccurrences = isAdHoc ? [occurrence] : []
        await service.applyNotificationEffects(
            policy.reduce(.activity([signal], detectedOccurrences: detectedOccurrences, now: now)), at: now
        )
        let publishedAt = now.addingTimeInterval(5)
        await service.applyNotificationEffects(policy.reduce(.timeAdvanced(publishedAt)), at: publishedAt)
        let prompt = try XCTUnwrap(client.added.last)
        XCTAssertEqual(prompt.kind, .detected)
        client.pendingQueryCount = 0
        client.deliveredQueryCount = 0

        for second in 1...60 {
            let tick = publishedAt.addingTimeInterval(Double(second))
            await service.applyNotificationEffects(
                policy.reduce(.activity([signal], detectedOccurrences: detectedOccurrences, now: tick)), at: tick
            )
            await service.applyNotificationEffects(policy.reduce(.timeAdvanced(tick)), at: tick)
        }
        XCTAssertEqual(client.pendingQueryCount, 0)
        XCTAssertEqual(client.deliveredQueryCount, 0)
        XCTAssertEqual(client.pendingIdentifiers, [prompt.identifier])

        // A vanished ad-hoc session or expired calendar occurrence still triggers cleanup.
        client.pendingQueryCount = 0
        client.deliveredQueryCount = 0
        let invalidatedAt = isAdHoc ? publishedAt.addingTimeInterval(61) : occurrence.endDate.addingTimeInterval(1801)
        let invalidated = isAdHoc
            ? policy.reduce(.activity([], detectedOccurrences: [], now: invalidatedAt))
            : policy.reduce(.timeAdvanced(invalidatedAt))
        await service.applyNotificationEffects(invalidated, at: invalidatedAt)
        XCTAssertEqual(client.pendingQueryCount, 1)
        XCTAssertEqual(client.deliveredQueryCount, 1)
        XCTAssertTrue(client.pendingIdentifiers.isEmpty)
    }

    func testOccurrenceFiveMinutesBeyondFetchHorizonStillFiresWithinSevenDays() async throws {
        let suiteName = "CalendarMeetingNotificationBoundaryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        let service = CalendarMeetingNotificationService(client: client, defaults: defaults)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(
            start: now.addingTimeInterval(7 * 24 * 60 * 60 + 5 * 60)
        )

        await service.replaceScheduledReminders([occurrence], now: now)

        XCTAssertEqual(client.added.map(\.fireDate), [now.addingTimeInterval(7 * 24 * 60 * 60)])
    }

    func testDetectedNotificationReplacesPendingAndDeliveredUpcomingNotifications() async throws {
        let suiteName = "CalendarMeetingDetectedTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        let service = CalendarMeetingNotificationService(client: client, defaults: defaults)
        let occurrence = makeCalendarMeetingTestOccurrence()
        let now = Date(timeIntervalSince1970: 2_000_000_010)
        let upcomingIdentifier = "\(CalendarMeetingNotificationService.requestIdentifierPrefix)"
            + "\(occurrence.id).\(CalendarMeetingNotificationKind.upcoming.rawValue)"
        client.pendingIdentifiers = [upcomingIdentifier]
        client.deliveredIdentifiers = [upcomingIdentifier]

        await service.publishDetectedMeeting(occurrence, now: now)

        XCTAssertEqual(client.removed, [[upcomingIdentifier]])
        XCTAssertEqual(client.removedDelivered, [[upcomingIdentifier]])
        XCTAssertEqual(client.added.count, 1)
        XCTAssertEqual(client.added.first?.kind, .detected)
        XCTAssertEqual(client.added.first?.category, .detected)
        XCTAssertEqual(client.added.first?.occurrenceDigest, occurrence.id)
        XCTAssertEqual(client.added.first?.fireDate, now.addingTimeInterval(1))
        XCTAssertEqual(client.added.first?.delivery, .immediate)
    }

    func testDetectedNotificationSurvivesDelayedRemovalOfUpcomingReminder() async throws {
        let suiteName = "CalendarMeetingDelayedRemovalTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        client.defersPendingRemovals = true
        let service = CalendarMeetingNotificationService(client: client, defaults: defaults)
        let occurrence = makeCalendarMeetingTestOccurrence()
        let prefix = "\(CalendarMeetingNotificationService.requestIdentifierPrefix)\(occurrence.id)."
        let upcomingIdentifier = prefix + CalendarMeetingNotificationKind.upcoming.rawValue
        client.pendingIdentifiers = [upcomingIdentifier]

        await service.publishDetectedMeeting(occurrence)
        let detectedIdentifier = try XCTUnwrap(client.added.last?.identifier)
        XCTAssertTrue(client.pendingIdentifiers.contains(detectedIdentifier))

        client.completePendingRemovals()

        XCTAssertEqual(client.pendingIdentifiers, [detectedIdentifier])
    }

    func testFailedDetectedNotificationPreservesDeliveredReminder() async throws {
        try await assertFailedDetectedNotificationPreservesReminder(delivered: true)
    }

    func testDetectedPromptAfterRestorationSurvivesEarlierCountdownDismissal() async throws {
        let suiteName = "CalendarMeetingRestoredDetectedTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        let service = CalendarMeetingNotificationService(client: client, defaults: defaults)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(start: now)
        await service.replaceScheduledReminders([occurrence], now: now)
        let upcoming = try XCTUnwrap(client.added.last)
        client.deliveredIdentifiers = [upcoming.identifier]
        client.pendingIdentifiers.removeAll()
        client.defersPendingRemovals = true

        await service.removeStartNotifications(occurrenceDigest: occurrence.id)
        service.allowReminderRestoration(occurrenceDigest: occurrence.id)
        await service.replaceScheduledReminders([occurrence], now: now.addingTimeInterval(1))
        await service.publishDetectedMeeting(occurrence, now: now.addingTimeInterval(2))
        let detected = try XCTUnwrap(client.added.last)
        XCTAssertEqual(detected.kind, .detected)
        client.completePendingRemovals()

        XCTAssertEqual(client.pendingIdentifiers, [detected.identifier],
            "Dismissing an earlier countdown must not remove a later detected prompt")
    }

    func testCalendarRefreshKeepsDetectedPromptUntilDeliveryAfterUpcomingReminder() async throws {
        try await assertCalendarRefreshKeepsDetectedPromptUntilDelivery(isAdHoc: false)
    }

    func testCalendarRefreshKeepsAdHocDetectedPromptUntilDelivery() async throws {
        try await assertCalendarRefreshKeepsDetectedPromptUntilDelivery(isAdHoc: true)
    }

    func testCalendarRefreshRemovesDetectedPromptForMissingOccurrence() async throws {
        try await assertCalendarRefreshKeepsDetectedPromptUntilDelivery(
            isAdHoc: false, interruption: .missing
        )
    }

    func testCalendarRefreshRemovesDetectedPromptForDeclinedOccurrence() async throws {
        try await assertCalendarRefreshKeepsDetectedPromptUntilDelivery(
            isAdHoc: false, interruption: .declined
        )
    }

    func testReturningOccurrenceKeepsNewDetectedPromptAfterDelayedStaleRemoval() async throws {
        try await assertCalendarRefreshKeepsDetectedPromptUntilDelivery(
            isAdHoc: false, interruption: .missing, deferRemovalUntilReturn: true
        )
    }

    private func assertCalendarRefreshKeepsDetectedPromptUntilDelivery(
        isAdHoc: Bool, interruption: RefreshInterruption? = nil,
        deferRemovalUntilReturn: Bool = false
    ) async throws {
        let suiteName = "CalendarMeetingDetectedRefreshTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        let service = CalendarMeetingNotificationService(client: client, defaults: defaults)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let identity = CalendarMeetingCanonicalLink(provider: .zoom, identity: "j/123456789")
        let occurrence = CalendarMeetingOccurrence(
            eventIdentifier: "detected-refresh", occurrenceStart: now,
            startDate: now, endDate: now.addingTimeInterval(30 * 60),
            title: "Meeting", calendarID: "calendar", participationStatus: .accepted,
            meetingLinks: [identity], isAdHoc: isAdHoc
        )
        let configuration = CalendarMeetingAutomationConfiguration(
            startMode: .reminder, autoStopEnabled: false,
            calendarAuthorization: .fullAccess, selectedCalendarIDs: [occurrence.calendarID],
            enabledProviders: [.zoom], suppressedOccurrenceDigests: [],
            detectAdHocMeetings: isAdHoc
        )
        var policy = CalendarMeetingAutomationPolicy()
        await service.applyNotificationEffects(
            policy.reduce(.configure(configuration, occurrences: [occurrence], now: now)),
            at: now
        )
        if !isAdHoc {
            let upcoming = try XCTUnwrap(client.added.first)
            XCTAssertEqual(upcoming.kind, .upcoming)
            client.deliveredIdentifiers = [upcoming.identifier]
            client.pendingIdentifiers.removeAll()
        } else {
            XCTAssertTrue(client.added.isEmpty)
        }
        client.added.removeAll()
        let signal = CalendarMeetingJoinSignal(
            occurrenceDigest: occurrence.id, meetingIdentity: identity,
            quality: .nativeProvider, isRunningInput: true, isRunningOutput: false
        )
        _ = policy.reduce(.activity([signal], now: now))
        let detectedAt = now.addingTimeInterval(isAdHoc ? 5 : 3)
        await service.applyNotificationEffects(
            policy.reduce(.timeAdvanced(detectedAt)), at: detectedAt
        )
        let detected = try XCTUnwrap(client.added.last)
        XCTAssertEqual(detected.kind, .detected)
        XCTAssertEqual(client.pendingIdentifiers, [detected.identifier])
        XCTAssertTrue(client.deliveredIdentifiers.isEmpty)

        // Refresh before the one-second notification trigger fires. The policy has
        // already deduplicated this detected prompt and will not publish it again.
        let refreshedAt = detectedAt.addingTimeInterval(0.5)
        if let interruption {
            client.defersPendingRemovals = deferRemovalUntilReturn
            let declined = CalendarMeetingOccurrence(
                eventIdentifier: "detected-refresh", occurrenceStart: now,
                startDate: now, endDate: occurrence.endDate,
                title: occurrence.title, calendarID: occurrence.calendarID,
                participationStatus: .declined, meetingLinks: [identity]
            )
            await service.applyNotificationEffects(
                policy.reduce(.configure(configuration,
                    occurrences: interruption == .missing ? [] : [declined], now: refreshedAt)),
                at: refreshedAt
            )
            if deferRemovalUntilReturn {
                XCTAssertTrue(client.removed.contains { $0.contains(detected.identifier) })
                await service.applyNotificationEffects(
                    policy.reduce(.configure(configuration, occurrences: [occurrence], now: refreshedAt)),
                    at: refreshedAt
                )
                let returnedAt = refreshedAt.addingTimeInterval(3)
                await service.applyNotificationEffects(
                    policy.reduce(.timeAdvanced(returnedAt)), at: returnedAt
                )
                let replacement = try XCTUnwrap(client.added.last)
                XCTAssertEqual(replacement.kind, .detected)
                XCTAssertNotEqual(replacement.identifier, detected.identifier)
                client.completePendingRemovals()
                XCTAssertEqual(client.pendingIdentifiers, [replacement.identifier],
                    "Removing a stale prompt must not delete its later replacement")
            } else {
                XCTAssertFalse(client.pendingIdentifiers.contains(detected.identifier),
                    "An invalidated occurrence must not deliver an unusable consent prompt")
            }
            XCTAssertTrue(client.deliveredIdentifiers.isEmpty)
            return
        }
        await service.applyNotificationEffects(
            policy.reduce(.configure(configuration, occurrences: [occurrence], now: refreshedAt)),
            at: refreshedAt
        )
        client.completePendingRemovals()
        XCTAssertEqual(client.pendingIdentifiers, [detected.identifier],
            "A calendar refresh must leave the pending consent prompt available for delivery")
        XCTAssertEqual(client.added.map(\.identifier), [detected.identifier],
            "The refresh must retain the original request without posting a duplicate")

        // Model delivery, then accept it through the policy to verify handoff cleanup.
        client.deliveredIdentifiers = client.pendingIdentifiers
        client.pendingIdentifiers.removeAll()
        XCTAssertEqual(client.deliveredIdentifiers, [detected.identifier])
        let acceptedAt = detectedAt.addingTimeInterval(1)
        let accepted = policy.reduce(.userAction(.armOccurrence(occurrence.id), now: acceptedAt))
        XCTAssertTrue(accepted.contains(.showStartCountdown(
            occurrence, deadline: acceptedAt.addingTimeInterval(5)
        )))
        await service.applyNotificationEffects(accepted, at: acceptedAt)
        XCTAssertTrue(client.pendingIdentifiers.isEmpty)
        XCTAssertTrue(client.deliveredIdentifiers.isEmpty)
    }

    func testFailedDetectedNotificationPreservesPendingReminder() async throws {
        try await assertFailedDetectedNotificationPreservesReminder(delivered: false)
    }

    private func assertFailedDetectedNotificationPreservesReminder(delivered: Bool) async throws {
        let suiteName = "CalendarMeetingFailedReplacementTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        let service = CalendarMeetingNotificationService(client: client, defaults: defaults)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let occurrence = makeCalendarMeetingTestOccurrence(
            start: now.addingTimeInterval(delivered ? 2 * 60 : 10 * 60)
        )
        await service.replaceScheduledReminders([occurrence], now: now)
        let original = try XCTUnwrap(client.added.first)
        if delivered {
            client.pendingIdentifiers.removeAll()
            client.deliveredIdentifiers = [original.identifier]
        }
        client.added.removeAll()
        client.addError = NSError(domain: "NotificationAddFailure", code: 1)

        await service.publishDetectedMeeting(occurrence, now: now)

        XCTAssertTrue(client.added.isEmpty)
        XCTAssertEqual(
            delivered ? client.deliveredIdentifiers : client.pendingIdentifiers,
            [original.identifier],
            "A failed replacement must leave the user's existing consent prompt available"
        )
        XCTAssertEqual(
            defaults.stringArray(forKey: UserDefaultsKeys.calendarMeetingReminderRequestDigests),
            [occurrence.id]
        )
    }

    func testStartNotificationRemovalIsScopedToAcceptedOccurrenceAndLeavesAutoStopAlone() async throws {
        let suiteName = "CalendarMeetingStartRemovalTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        let service = CalendarMeetingNotificationService(client: client, defaults: defaults)
        let digest = String(repeating: "a", count: 64)
        let otherDigest = String(repeating: "b", count: 64)
        defaults.set([digest, otherDigest], forKey: UserDefaultsKeys.calendarMeetingReminderRequestDigests)
        let expected = [CalendarMeetingNotificationKind.upcoming, .detected].map {
            "\(CalendarMeetingNotificationService.requestIdentifierPrefix)\(digest).\($0.rawValue)"
        }
        let untouched = [
            "\(CalendarMeetingNotificationService.requestIdentifierPrefix)\(otherDigest).upcoming",
            "\(CalendarMeetingNotificationService.requestIdentifierPrefix)\(digest).autoStop"
        ]
        client.pendingIdentifiers = expected + untouched
        client.deliveredIdentifiers = expected + untouched

        await service.removeStartNotifications(occurrenceDigest: digest)

        XCTAssertEqual(client.removed, [expected.sorted()])
        XCTAssertEqual(client.removedDelivered, [expected.sorted()])
        XCTAssertEqual(client.pendingIdentifiers, untouched)
        XCTAssertEqual(client.deliveredIdentifiers, untouched)
        XCTAssertTrue(client.added.isEmpty)
        XCTAssertEqual(
            defaults.stringArray(forKey: UserDefaultsKeys.calendarMeetingReminderRequestDigests),
            [digest, otherDigest]
        )
    }

    func testConfigurationRequestsAuthorizationOnlyWhenUndetermined() async throws {
        let suiteName = "CalendarMeetingAuthorizationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        client.authorization = .denied
        let deniedService = CalendarMeetingNotificationService(client: client, defaults: defaults)
        let denied = await deniedService.configureAndRequestAuthorization()
        XCTAssertEqual(denied, .denied)
        XCTAssertEqual(client.requestCount, 0)

        client.authorization = .notDetermined
        let undeterminedService = CalendarMeetingNotificationService(client: client, defaults: defaults)
        let undetermined = await undeterminedService.configureAndRequestAuthorization()
        XCTAssertEqual(undetermined, .notDetermined)
        XCTAssertEqual(client.requestCount, 1)
        XCTAssertTrue(defaults.bool(forKey: UserDefaultsKeys.calendarMeetingNotificationsConfigured))
    }

    func testAutoStopWarningRequiresAuthorizationAndRemovesPendingAndDeliveredCopies() async throws {
        let suiteName = "CalendarMeetingAutoStopNotificationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        let service = CalendarMeetingNotificationService(client: client, defaults: defaults)
        let digest = String(repeating: "b", count: 64)
        let now = Date(timeIntervalSince1970: 2_000_000_020)

        client.authorization = .denied
        let denied = await service.publishAutoStopWarning(
            occurrenceDigest: digest,
            now: now
        )
        XCTAssertFalse(denied)
        XCTAssertTrue(client.added.isEmpty)

        client.authorization = .authorized
        let authorized = await service.publishAutoStopWarning(
            occurrenceDigest: digest,
            now: now
        )
        XCTAssertTrue(authorized)
        let request = try XCTUnwrap(client.added.last)
        XCTAssertEqual(request.kind, .autoStop)
        XCTAssertEqual(request.occurrenceDigest, digest)
        XCTAssertEqual(request.fireDate, now)
        XCTAssertEqual(request.delivery, .immediate)
        XCTAssertTrue(request.identifier.hasSuffix(".autoStop"))
        XCTAssertEqual(client.removed.last, [request.identifier])
        XCTAssertEqual(client.removedDelivered.last, [request.identifier])

        let removedCountBeforeExplicitCall = client.removed.count
        let removedDeliveredCountBeforeExplicitCall = client.removedDelivered.count
        service.removeAutoStopWarning(occurrenceDigest: digest)
        XCTAssertEqual(client.removed.count, removedCountBeforeExplicitCall + 1)
        XCTAssertEqual(
            client.removedDelivered.count,
            removedDeliveredCountBeforeExplicitCall + 1
        )
        XCTAssertEqual(client.removed.last, [request.identifier])
        XCTAssertEqual(client.removedDelivered.last, [request.identifier])
    }

    func testAutoStopWarningFailsClosedWhenNotificationCannotBePublished() async throws {
        struct AddError: Error {}

        let suiteName = "CalendarMeetingAutoStopNotificationFailureTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = FakeCalendarMeetingNotificationClient()
        client.authorization = .authorized
        client.addError = AddError()
        let service = CalendarMeetingNotificationService(client: client, defaults: defaults)

        let published = await service.publishAutoStopWarning(
            occurrenceDigest: String(repeating: "c", count: 64)
        )

        XCTAssertFalse(published)
        XCTAssertTrue(client.added.isEmpty)
    }

    func testColdLaunchActionsRequireDigestAndDefaultClickNeverStarts() {
        let digest = String(repeating: "a", count: 64)
        XCTAssertEqual(
            CalendarMeetingNotificationResponseMapper.response(
                actionIdentifier: CalendarMeetingNotificationService.startActionIdentifier,
                occurrenceDigest: digest
            ),
            .armStart(digest)
        )
        XCTAssertNil(CalendarMeetingNotificationResponseMapper.response(
            actionIdentifier: CalendarMeetingNotificationService.startActionIdentifier,
            occurrenceDigest: nil
        ))
        XCTAssertEqual(
            CalendarMeetingNotificationResponseMapper.response(
                actionIdentifier: CalendarMeetingNotificationService
                    .armWhenJoinedActionIdentifier,
                occurrenceDigest: digest
            ),
            .armStart(digest)
        )
        XCTAssertEqual(
            CalendarMeetingNotificationResponseMapper.response(
                actionIdentifier: UNNotificationDefaultActionIdentifier,
                occurrenceDigest: digest
            ),
            .openRecorder
        )
        XCTAssertEqual(
            CalendarMeetingNotificationResponseMapper.response(
                actionIdentifier: UNNotificationDismissActionIdentifier,
                occurrenceDigest: digest
            ),
            .suppress(digest)
        )
        XCTAssertEqual(
            CalendarMeetingNotificationResponseMapper.response(
                actionIdentifier: CalendarMeetingNotificationService
                    .continueRecordingActionIdentifier,
                occurrenceDigest: digest,
                kind: .autoStop
            ),
            .continueRecording(digest)
        )
        XCTAssertEqual(
            CalendarMeetingNotificationResponseMapper.response(
                actionIdentifier: UNNotificationDefaultActionIdentifier,
                occurrenceDigest: digest,
                kind: .autoStop
            ),
            .continueRecording(digest)
        )
        XCTAssertNil(CalendarMeetingNotificationResponseMapper.response(
            actionIdentifier: UNNotificationDismissActionIdentifier,
            occurrenceDigest: digest,
            kind: .autoStop
        ))
    }

    func testStartActionDoesNotActivateAppOrOpenSettings() {
        let startOptions = CalendarMeetingNotificationResponseMapper.actionOptions(
            for: CalendarMeetingNotificationService.startActionIdentifier
        )
        let armOptions = CalendarMeetingNotificationResponseMapper.actionOptions(
            for: CalendarMeetingNotificationService.armWhenJoinedActionIdentifier
        )
        let suppressOptions = CalendarMeetingNotificationResponseMapper.actionOptions(
            for: CalendarMeetingNotificationService.suppressActionIdentifier
        )
        let continueOptions = CalendarMeetingNotificationResponseMapper.actionOptions(
            for: CalendarMeetingNotificationService.continueRecordingActionIdentifier
        )

        XCTAssertFalse(startOptions.contains(.foreground))
        XCTAssertFalse(armOptions.contains(.foreground))
        XCTAssertTrue(suppressOptions.contains(.destructive))
        XCTAssertFalse(suppressOptions.contains(.foreground))
        XCTAssertFalse(continueOptions.contains(.foreground))
    }

    func testOnlyRecorderResponseAllowsManagedWindowReopen() {
        let digest = String(repeating: "a", count: 64)

        XCTAssertTrue(
            CalendarMeetingNotificationResponse.armStart(digest).keepsApplicationInBackground
        )
        XCTAssertTrue(
            CalendarMeetingNotificationResponse.suppress(digest).keepsApplicationInBackground
        )
        XCTAssertTrue(
            CalendarMeetingNotificationResponse.continueRecording(digest)
                .keepsApplicationInBackground
        )
        XCTAssertFalse(
            CalendarMeetingNotificationResponse.openRecorder.keepsApplicationInBackground
        )
    }

    func testOnlyAutoStopUsesTimeSensitiveInterruptionLevel() {
        XCTAssertEqual(
            CalendarMeetingNotificationPresentationPolicy.interruptionLevel(for: .autoStop),
            .timeSensitive
        )
        XCTAssertNil(
            CalendarMeetingNotificationPresentationPolicy.interruptionLevel(for: .upcoming)
        )
        XCTAssertNil(
            CalendarMeetingNotificationPresentationPolicy.interruptionLevel(for: .detected)
        )
    }

    func testForegroundAutoStopIncludesBannerListAndSound() {
        let autoStop = CalendarMeetingNotificationPresentationPolicy.foregroundOptions(
            for: .autoStop
        )
        XCTAssertTrue(autoStop.contains(.banner))
        XCTAssertTrue(autoStop.contains(.list))
        XCTAssertTrue(autoStop.contains(.sound))

        let reminder = CalendarMeetingNotificationPresentationPolicy.foregroundOptions(
            for: .upcoming
        )
        XCTAssertTrue(reminder.contains(.banner))
        XCTAssertFalse(reminder.contains(.list))
        XCTAssertTrue(reminder.contains(.sound))
    }

    func testAutoStopMetadataContainsOnlyDigestAndKind() {
        let digest = String(repeating: "d", count: 64)
        let userInfo = CalendarMeetingNotificationPresentationPolicy.userInfo(
            occurrenceDigest: digest,
            kind: .autoStop
        )

        XCTAssertEqual(
            Set(userInfo.keys.compactMap { $0 as? String }),
            [
                CalendarMeetingNotificationService.digestUserInfoKey,
                CalendarMeetingNotificationService.kindUserInfoKey
            ]
        )
        XCTAssertEqual(
            userInfo[CalendarMeetingNotificationService.digestUserInfoKey] as? String,
            digest
        )
        XCTAssertEqual(
            userInfo[CalendarMeetingNotificationService.kindUserInfoKey] as? String,
            CalendarMeetingNotificationKind.autoStop.rawValue
        )
    }
}
