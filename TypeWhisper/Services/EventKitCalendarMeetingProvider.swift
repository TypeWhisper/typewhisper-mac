@preconcurrency import EventKit
import Foundation
import os

enum CalendarMeetingEventProviderError: LocalizedError {
    case fullAccessRequired

    var errorDescription: String? {
        switch self {
        case .fullAccessRequired:
            "Full calendar access is required."
        }
    }
}

private final class EventKitChangeBridge: @unchecked Sendable {
    private final class ObserverToken: @unchecked Sendable {
        let value: NSObjectProtocol

        init(_ value: NSObjectProtocol) {
            self.value = value
        }
    }

    private struct State {
        var token: ObserverToken?
        var continuation: AsyncStream<Void>.Continuation?
    }

    let stream: AsyncStream<Void>
    private let state: OSAllocatedUnfairLock<State>
    private let notificationCenter: NotificationCenter

    init(store: EKEventStore, notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        var capturedContinuation: AsyncStream<Void>.Continuation?
        stream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            capturedContinuation = continuation
        }
        state = OSAllocatedUnfairLock(initialState: State(
            token: nil,
            continuation: capturedContinuation
        ))

        let token = notificationCenter.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: nil
        ) { [weak self] _ in
            _ = self?.state.withLock { $0.continuation?.yield() }
        }
        let tokenBox = ObserverToken(token)
        state.withLock { $0.token = tokenBox }
    }

    deinit {
        let finalState = state.withLock { current -> State in
            let copy = current
            current.token = nil
            current.continuation = nil
            return copy
        }
        if let token = finalState.token {
            notificationCenter.removeObserver(token.value)
        }
        finalState.continuation?.finish()
    }
}

actor EventKitCalendarMeetingProvider: CalendarMeetingEventProviding {
    private let store: EKEventStore
    private let linkParser: MeetingLinkParser
    private let changeBridge: EventKitChangeBridge

    init(
        store: EKEventStore = EKEventStore(),
        linkParser: MeetingLinkParser = MeetingLinkParser()
    ) {
        self.store = store
        self.linkParser = linkParser
        changeBridge = EventKitChangeBridge(store: store)
    }

    func authorizationStatus() -> CalendarMeetingCalendarAuthorization {
        Self.mapAuthorization(EKEventStore.authorizationStatus(for: .event))
    }

    func requestFullAccess() async throws -> Bool {
        if authorizationStatus() == .fullAccess {
            return true
        }
        return try await store.requestFullAccessToEvents()
    }

    func calendars() throws -> [CalendarMeetingCalendar] {
        try requireFullAccess()
        return store.calendars(for: .event)
            .map {
                CalendarMeetingCalendar(
                    id: $0.calendarIdentifier,
                    title: $0.title,
                    sourceTitle: $0.source.title
                )
            }
            .sorted {
                let lhs = "\($0.sourceTitle)\u{0}\($0.title)\u{0}\($0.id)"
                let rhs = "\($1.sourceTitle)\u{0}\($1.title)\u{0}\($1.id)"
                return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
            }
    }

    func occurrences(
        in interval: DateInterval,
        calendarIDs: Set<String>
    ) throws -> [CalendarMeetingOccurrence] {
        try requireFullAccess()
        guard interval.duration > 0, !calendarIDs.isEmpty else { return [] }

        let selectedCalendars = store.calendars(for: .event).filter {
            calendarIDs.contains($0.calendarIdentifier)
        }
        guard !selectedCalendars.isEmpty else { return [] }

        let predicate = store.predicateForEvents(
            withStart: interval.start,
            end: interval.end,
            calendars: selectedCalendars
        )
        let detached = store.events(matching: predicate).compactMap(detachOccurrence)
        var seen = Set<String>()
        return detached
            .sorted {
                if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
                return $0.occurrenceDigest < $1.occurrenceDigest
            }
            .filter { seen.insert($0.occurrenceDigest).inserted }
    }

    func changes() -> AsyncStream<Void> {
        changeBridge.stream
    }

    private func requireFullAccess() throws {
        guard authorizationStatus() == .fullAccess else {
            throw CalendarMeetingEventProviderError.fullAccessRequired
        }
    }

    private func detachOccurrence(_ event: EKEvent) -> CalendarMeetingOccurrence? {
        guard !event.isAllDay,
              event.status != .canceled,
              event.availability != .free,
              let eventIdentifier = event.eventIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !eventIdentifier.isEmpty,
              let startDate = event.startDate,
              let endDate = event.endDate,
              endDate > startDate else {
            return nil
        }

        let participationStatus = Self.participationStatus(for: event)
        guard participationStatus.permitsReminder else { return nil }

        let links = linkParser.parse(
            eventURL: event.url,
            location: event.location,
            notes: event.notes
        )
        guard !links.isEmpty else { return nil }

        return CalendarMeetingOccurrence(
            eventIdentifier: eventIdentifier,
            occurrenceStart: startDate,
            startDate: startDate,
            endDate: endDate,
            title: event.title ?? "",
            calendarID: event.calendar.calendarIdentifier,
            participationStatus: participationStatus,
            meetingLinks: links,
            location: Self.normalized(event.location),
            organizer: event.organizer.map(Self.participantMetadata),
            attendees: (event.attendees ?? []).map(Self.participantMetadata)
        )
    }

    private static func participantMetadata(
        _ participant: EKParticipant
    ) -> CalendarMeetingParticipant {
        CalendarMeetingParticipant(
            name: normalized(participant.name),
            emailAddress: emailAddress(from: participant.url),
            status: participantStatusMetadata(participant.participantStatus),
            isCurrentUser: participant.isCurrentUser
        )
    }

    private static func emailAddress(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "mailto" else { return nil }
        var address = String(url.absoluteString.dropFirst("mailto:".count))
        if address.hasPrefix("//") {
            address.removeFirst(2)
        }
        address = address
            .split(whereSeparator: { $0 == "?" || $0 == "#" })
            .first
            .map(String.init) ?? ""
        return normalized(address.removingPercentEncoding ?? address)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func participantStatusMetadata(
        _ status: EKParticipantStatus
    ) -> CalendarMeetingParticipantStatus {
        switch status {
        case .accepted: .accepted
        case .tentative: .tentative
        case .pending: .pending
        case .declined: .declined
        case .delegated: .delegated
        case .completed: .completed
        case .inProcess: .inProcess
        case .unknown: .unknown
        @unknown default: .unknown
        }
    }

    nonisolated static func mapAuthorization(
        _ status: EKAuthorizationStatus
    ) -> CalendarMeetingCalendarAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .fullAccess: .fullAccess
        case .writeOnly: .writeOnly
        @unknown default: .unknown
        }
    }

    nonisolated private static func participationStatus(
        for event: EKEvent
    ) -> CalendarMeetingParticipationStatus {
        guard let attendees = event.attendees, !attendees.isEmpty else {
            return .noCurrentUser
        }
        guard let attendee = attendees.first(where: \.isCurrentUser) else { return .unknown }
        return switch attendee.participantStatus {
        case .accepted: .accepted
        case .tentative: .tentative
        case .pending: .pending
        case .declined: .declined
        case .delegated: .delegated
        case .unknown, .completed, .inProcess: .unknown
        @unknown default: .unknown
        }
    }
}
