import Foundation

enum CalendarMeetingRecorderReadiness: Equatable, Sendable {
    case idle
    case recorderBusy
    case dictationBusy
    case finalizing
    case noAudioSource
    case microphoneDenied

    var isIdle: Bool { self == .idle }
}

enum CalendarMeetingJoinMatchQuality: Int, Equatable, Sendable {
    case cameraPresence = 0
    case nativeProvider = 1
    case exactBrowserIdentity = 2
}

enum CalendarMeetingJoinEvidence: Equatable, Sendable {
    case attributedAudio
    case cameraPresence
}

struct CalendarMeetingJoinSignal: Equatable, Sendable {
    let occurrenceDigest: String
    let meetingIdentity: CalendarMeetingCanonicalLink
    let quality: CalendarMeetingJoinMatchQuality
    let isRunningInput: Bool
    let isRunningOutput: Bool
    let evidence: CalendarMeetingJoinEvidence

    init(
        occurrenceDigest: String,
        meetingIdentity: CalendarMeetingCanonicalLink,
        quality: CalendarMeetingJoinMatchQuality,
        isRunningInput: Bool,
        isRunningOutput: Bool,
        evidence: CalendarMeetingJoinEvidence = .attributedAudio
    ) {
        self.occurrenceDigest = occurrenceDigest
        self.meetingIdentity = meetingIdentity
        self.quality = quality
        self.isRunningInput = isRunningInput
        self.isRunningOutput = isRunningOutput
        self.evidence = evidence
    }

    var permitsStart: Bool {
        isRunningInput || evidence == .cameraPresence
    }

    var countsForAutoStop: Bool {
        evidence == .attributedAudio && (isRunningInput || isRunningOutput)
    }
}

struct CalendarMeetingAutomationConfiguration: Equatable, Sendable {
    let startMode: CalendarMeetingStartMode
    let autoStopEnabled: Bool
    let calendarAuthorization: CalendarMeetingCalendarAuthorization
    let selectedCalendarIDs: Set<String>
    let enabledProviders: Set<MeetingProvider>
    let suppressedOccurrenceDigests: Set<String>
    var detectAdHocMeetings = false
    var confirmSoloEvents = false

    var isOperational: Bool {
        startMode != .off
            && (calendarAuthorization == .fullAccess || detectAdHocMeetings)
    }

    func permits(_ occurrence: CalendarMeetingOccurrence) -> Bool {
        let sourceEnabled = occurrence.isAdHoc
            ? detectAdHocMeetings
            : calendarAuthorization == .fullAccess && selectedCalendarIDs.contains(occurrence.calendarID)
        return sourceEnabled && !occurrence.providers.isDisjoint(with: enabledProviders)
    }

    /// With confirmation enabled, calendar events nobody else is invited to fall back to
    /// reminder behavior in automatic mode, so private blocks with a call link need consent.
    func startMode(for occurrence: CalendarMeetingOccurrence) -> CalendarMeetingStartMode {
        guard startMode == .automatic,
              confirmSoloEvents,
              !occurrence.isAdHoc,
              !occurrence.hasOtherParticipants else {
            return startMode
        }
        return .reminder
    }
}

struct CalendarMeetingUpcomingReminder: Equatable, Sendable {
    let occurrence: CalendarMeetingOccurrence
    let startMode: CalendarMeetingStartMode
}

enum CalendarMeetingRecordingStartFailure: Equatable, Sendable {
    case noAudioSource
    case microphoneDenied
    case captureFailed
}

enum CalendarMeetingAutomationUserAction: Equatable, Sendable {
    case armOccurrence(String)
    case suppressOccurrence(String)
    case cancelStartCountdown(String)
    case continueRecording(CalendarMeetingRecordingHandle)
}

enum CalendarMeetingAutomationEvent: Equatable, Sendable {
    case configure(
        CalendarMeetingAutomationConfiguration,
        occurrences: [CalendarMeetingOccurrence],
        now: Date
    )
    case activity(
        [CalendarMeetingJoinSignal],
        detectedOccurrences: [CalendarMeetingOccurrence]? = nil,
        now: Date
    )
    case activityUnavailable(now: Date)
    case cameraActivity(isRunning: Bool, now: Date)
    case cameraActivityUnavailable(now: Date)
    case recorderReadiness(CalendarMeetingRecorderReadiness, now: Date)
    case timeAdvanced(Date)
    case userAction(CalendarMeetingAutomationUserAction, now: Date)
    case recordingStarted(
        handle: CalendarMeetingRecordingHandle,
        occurrenceDigest: String,
        identity: CalendarMeetingCanonicalLink,
        autoStopArmed: Bool,
        now: Date
    )
    case recordingStartFailed(
        occurrenceDigest: String,
        failure: CalendarMeetingRecordingStartFailure
    )
    /// Consent or recorder readiness changed while the start was in flight. Unlike
    /// a failure, this permits a later retry and restores an eligible automatic reminder.
    case recordingStartCancelled(occurrenceDigest: String, now: Date)
    case recordingStartDeferred(
        occurrenceDigest: String,
        identity: CalendarMeetingCanonicalLink,
        readiness: CalendarMeetingRecorderReadiness,
        now: Date
    )
    case recordingStopped(CalendarMeetingRecordingHandle, now: Date)
}

enum CalendarMeetingAutomationEffect: Equatable, Sendable {
    case replaceScheduledReminders([CalendarMeetingUpcomingReminder])
    case retainDetectedNotifications(Set<String>)
    case startActivityCollector
    case stopActivityCollector
    case startCameraActivityCollector
    case stopCameraActivityCollector
    case publishDetectedMeeting(CalendarMeetingOccurrence)
    case dismissStartNotifications(String)
    case allowReminderRestoration(String)
    case showStartCountdown(CalendarMeetingOccurrence, deadline: Date)
    case dismissStartCountdown
    case startRecording(CalendarMeetingOccurrence, CalendarMeetingCanonicalLink)
    case persistSuppression(String)
    case showStopCountdown(CalendarMeetingRecordingHandle, deadline: Date)
    case dismissStopCountdown
    case stopRecording(CalendarMeetingRecordingHandle)
}

struct CalendarMeetingAutomationPolicy: Sendable {
    private static let autoStopSignalReturnDwell: TimeInterval = 3

    private struct DwellState: Equatable, Sendable {
        let identity: CalendarMeetingCanonicalLink
        let startedAt: Date
    }

    private struct PendingStart: Equatable, Sendable {
        let occurrenceDigest: String
        let identity: CalendarMeetingCanonicalLink
        let deadline: Date
    }

    private struct PendingIdleCandidate: Sendable {
        let digest: String
        let identity: CalendarMeetingCanonicalLink
        let reminderWasDismissed: Bool
    }

    private struct ActiveRecording: Equatable, Sendable {
        let handle: CalendarMeetingRecordingHandle
        let occurrenceDigest: String
        let identity: CalendarMeetingCanonicalLink
        var autoStopArmed: Bool
        var idleGrace: TimeInterval = 0
        var missingSince: Date?
        var stopDeadline: Date?
        var signalReturnSince: Date?
        var stickyVeto = false
        var stopRequested = false
        var hasObservedSignal = false
    }

    private var configuration = CalendarMeetingAutomationConfiguration(
        startMode: .off,
        autoStopEnabled: false,
        calendarAuthorization: .notDetermined,
        selectedCalendarIDs: [],
        enabledProviders: Set(MeetingProvider.allCases),
        suppressedOccurrenceDigests: []
    )
    private var occurrences: [CalendarMeetingOccurrence] = []
    private var signals: [CalendarMeetingJoinSignal] = []
    private var isCameraRunning = false
    private var cameraActivityAvailable = false
    private var recorderReadiness: CalendarMeetingRecorderReadiness = .idle
    private var dwellStates: [String: DwellState] = [:]
    private var detectedNotificationDigests = Set<String>()
    private var armedOccurrenceDigests = Set<String>()
    private var permanentStartFailureDigests = Set<String>()
    private var recordedOccurrenceDigests = Set<String>()
    private var idleRetryDigests = Set<String>()
    private var restoredAutomaticCatchUpDigests = Set<String>()
    private var reminderRestorationDeadlines: [String: Date] = [:]
    private var pendingIdleCandidate: PendingIdleCandidate?
    private var pendingStart: PendingStart?
    private var requestedStart: (digest: String, identity: CalendarMeetingCanonicalLink)?
    private var activeRecording: ActiveRecording?
    private var collectorRequested = false
    private var cameraCollectorRequested = false

    mutating func reduce(_ event: CalendarMeetingAutomationEvent) -> [CalendarMeetingAutomationEffect] {
        var effects: [CalendarMeetingAutomationEffect] = []
        switch event {
        case .configure(let configuration, let occurrences, let now):
            let previousConfiguration = self.configuration
            let wasOperational = previousConfiguration.isOperational
            let interruptedStart = pendingStart.map { (digest: $0.occurrenceDigest, identity: $0.identity) }
                ?? requestedStart ?? pendingIdleCandidate.map { (digest: $0.digest, identity: $0.identity) }
            let interruptedReminderWasDismissed = pendingStart != nil || requestedStart != nil
                || pendingIdleCandidate?.reminderWasDismissed == true
            let interruptedOccurrence = interruptedStart.flatMap { occurrence(for: $0.digest) }
            let autoStopSettingsChangedDuringRecording = activeRecording != nil
                && (
                    previousConfiguration.startMode != configuration.startMode
                        || previousConfiguration.autoStopEnabled != configuration.autoStopEnabled
                        || previousConfiguration.calendarAuthorization != configuration.calendarAuthorization
                        || previousConfiguration.selectedCalendarIDs != configuration.selectedCalendarIDs
                        || previousConfiguration.enabledProviders != configuration.enabledProviders
                        || previousConfiguration.detectAdHocMeetings != configuration.detectAdHocMeetings
                )
            self.configuration = configuration
            self.occurrences = occurrences.filter(configuration.permits)
            pruneArmedOccurrences(at: now)

            let refreshedStartIsInvalid = interruptedStart.map {
                consentedStartOccurrence(digest: $0.digest, identity: $0.identity, at: now) == nil
            } ?? false
            if !configuration.isOperational
                || refreshedStartIsInvalid
                || previousConfiguration.startMode != configuration.startMode
                || previousConfiguration.confirmSoloEvents != configuration.confirmSoloEvents {
                if interruptedReminderWasDismissed,
                   let interruptedOccurrence, !interruptedOccurrence.isAdHoc {
                    reminderRestorationDeadlines[interruptedOccurrence.id] =
                        interruptedOccurrence.endDate.addingTimeInterval(30 * 60)
                }
                clearPendingStart(effects: &effects)
                dwellStates.removeAll()
                pendingIdleCandidate = nil
                requestedStart = nil
                if !configuration.isOperational {
                    isCameraRunning = false
                    cameraActivityAvailable = false
                }
            }
            // Turning automation off or temporarily losing the calendar can leave no
            // eligible reminders yet. Retain the interrupted occurrence until it returns
            // within its join window, then restore it only once.
            reminderRestorationDeadlines = reminderRestorationDeadlines.filter { $0.value >= now }
            let reminders = upcomingReminders(at: now)
            for reminder in reminders {
                let digest = reminder.occurrence.occurrenceDigest
                if reminderRestorationDeadlines.removeValue(forKey: digest) != nil {
                    effects.append(.allowReminderRestoration(digest))
                }
            }
            retainEligibleDetectedNotifications(at: now, alwaysEmit: true, effects: &effects)
            effects.append(.replaceScheduledReminders(reminders))
            if (wasOperational && !configuration.isOperational)
                || !configuration.autoStopEnabled
                || autoStopSettingsChangedDuringRecording {
                disarmAutoStop(effects: &effects)
            }
            updateCollector(at: now, effects: &effects)
            evaluateStart(at: now, effects: &effects)
            evaluateAutoStop(at: now, effects: &effects)

        case .activity(let signals, let detectedOccurrences, let now):
            self.signals = signals
            if let detectedOccurrences {
                let previousAdHocDigests = Set(occurrences.filter(\.isAdHoc).map(\.id))
                occurrences.removeAll(where: \.isAdHoc)
                occurrences.append(contentsOf: detectedOccurrences.filter(configuration.permits))
                let adHocDigestsChanged =
                    previousAdHocDigests != Set(occurrences.filter(\.isAdHoc).map(\.id))
                pruneSessionState()
                retainEligibleDetectedNotifications(
                    at: now, alwaysEmit: adHocDigestsChanged, effects: &effects
                )
            }
            evaluateStart(at: now, effects: &effects)
            evaluateAutoStop(at: now, effects: &effects)

        case .activityUnavailable(let now):
            signals = []
            disarmAutoStop(effects: &effects)
            updateCollector(at: now, effects: &effects)
            evaluateStart(at: now, effects: &effects)

        case .cameraActivity(let isRunning, let now):
            cameraActivityAvailable = true
            isCameraRunning = isRunning
            evaluateStart(at: now, effects: &effects)

        case .cameraActivityUnavailable(let now):
            cameraActivityAvailable = false
            isCameraRunning = false
            evaluateStart(at: now, effects: &effects)

        case .recorderReadiness(let readiness, let now):
            let becameIdle = !recorderReadiness.isIdle && readiness.isIdle
            recorderReadiness = readiness
            discardInvalidDeferredStart(at: now, effects: &effects)
            if becameIdle,
               let candidate = pendingIdleCandidate,
               !idleRetryDigests.contains(candidate.digest) {
                idleRetryDigests.insert(candidate.digest)
                pendingIdleCandidate = nil
                beginStartCountdown(
                    digest: candidate.digest,
                    identity: candidate.identity,
                    at: now,
                    effects: &effects
                )
            }
            evaluateStart(at: now, effects: &effects)

        case .timeAdvanced(let now):
            retainEligibleDetectedNotifications(at: now, effects: &effects)
            updateCollector(at: now, effects: &effects)
            evaluateStart(at: now, effects: &effects)
            evaluateAutoStop(at: now, effects: &effects)

        case .userAction(let action, let now):
            handle(action: action, at: now, effects: &effects)

        case .recordingStarted(
            let handle,
            let occurrenceDigest,
            let identity,
            let autoStopArmed,
            let now
        ):
            requestedStart = nil
            clearPendingStart(effects: &effects)
            armedOccurrenceDigests.remove(occurrenceDigest)
            activeRecording = ActiveRecording(
                handle: handle,
                occurrenceDigest: occurrenceDigest,
                identity: identity,
                autoStopArmed: autoStopArmed && configuration.autoStopEnabled,
                idleGrace: occurrence(for: occurrenceDigest)?.isAdHoc == true ? 90 : 0,
                missingSince: nil,
                stopDeadline: nil,
                signalReturnSince: nil,
                hasObservedSignal: false
            )
            recordedOccurrenceDigests.insert(occurrenceDigest)
            effects.append(.replaceScheduledReminders(upcomingReminders(at: now)))
            updateCollector(at: now, effects: &effects)
            evaluateAutoStop(at: now, effects: &effects)

        case .recordingStartFailed(let digest, _):
            if requestedStart?.digest == digest {
                requestedStart = nil
            }
            armedOccurrenceDigests.remove(digest)
            permanentStartFailureDigests.insert(digest)
            clearPendingStart(effects: &effects)

        case .recordingStartCancelled(let digest, let now):
            guard requestedStart?.digest == digest else { break }
            requestedStart = nil
            clearPendingStart(effects: &effects)
            restoreAutomaticReminder(for: digest, at: now, effects: &effects)

        case .recordingStartDeferred(let digest, let identity, let readiness, _):
            guard requestedStart?.digest == digest else { break }
            requestedStart = nil
            recorderReadiness = readiness
            switch readiness {
            case .recorderBusy, .dictationBusy, .finalizing:
                if !idleRetryDigests.contains(digest) {
                    pendingIdleCandidate = PendingIdleCandidate(
                        digest: digest, identity: identity, reminderWasDismissed: true
                    )
                }
            case .noAudioSource, .microphoneDenied:
                armedOccurrenceDigests.remove(digest)
                permanentStartFailureDigests.insert(digest)
            case .idle:
                break
            }

        case .recordingStopped(let handle, let now):
            guard activeRecording?.handle == handle else { break }
            if activeRecording?.stopDeadline != nil {
                effects.append(.dismissStopCountdown)
            }
            activeRecording = nil
            updateCollector(at: now, effects: &effects)
        }
        return effects
    }

    private mutating func retainEligibleDetectedNotifications(
        at now: Date,
        alwaysEmit: Bool = false,
        effects: inout [CalendarMeetingAutomationEffect]
    ) {
        // This set includes ad-hoc calls and is independent of the 48 scheduled-reminder limit.
        let eligibleDigests = Set(occurrences.filter { occurrence in
            configuration.isOperational
                && configuration.startMode(for: occurrence) == .reminder
                && !armedOccurrenceDigests.contains(occurrence.id)
                && occurrence.meetingLinks.contains { identity in
                    eligibleStartOccurrence(digest: occurrence.id, identity: identity, at: now) != nil
                }
        }.map(\.id))
        if alwaysEmit || !detectedNotificationDigests.isSubset(of: eligibleDigests) {
            effects.append(.retainDetectedNotifications(eligibleDigests))
        }
        detectedNotificationDigests.formIntersection(eligibleDigests)
    }

    private func upcomingReminders(at now: Date) -> [CalendarMeetingUpcomingReminder] {
        guard configuration.isOperational else { return [] }
        let horizon = now.addingTimeInterval(7 * 24 * 60 * 60)
        let eligibleOccurrences = occurrences
            .filter { !$0.isAdHoc }
            .filter { $0.participationStatus.permitsReminder }
            .filter { !configuration.suppressedOccurrenceDigests.contains($0.occurrenceDigest) }
            .filter { !recordedOccurrenceDigests.contains($0.occurrenceDigest) }
            .filter { !armedOccurrenceDigests.contains($0.occurrenceDigest) }
            .filter { !permanentStartFailureDigests.contains($0.occurrenceDigest) }
            .filter { $0.occurrenceDigest != pendingStart?.occurrenceDigest }
            .filter { $0.occurrenceDigest != requestedStart?.digest }
            .filter {
                $0.occurrenceDigest != pendingIdleCandidate?.digest
                    || pendingIdleCandidate?.reminderWasDismissed != true
            }
        return eligibleOccurrences
            .filter {
                $0.endDate.addingTimeInterval(30 * 60) >= now
                    && $0.startDate.addingTimeInterval(-5 * 60) <= horizon
            }
            .sorted { $0.startDate < $1.startDate }
            .prefix(48)
            .map {
                CalendarMeetingUpcomingReminder(
                    occurrence: $0,
                    startMode: configuration.startMode(for: $0)
                )
            }
    }

    private mutating func updateCollector(
        at now: Date,
        effects: inout [CalendarMeetingAutomationEffect]
    ) {
        let needsAutoStopSignal = activeRecording?.autoStopArmed == true
        let hasOpenJoinWindow = activeRecording == nil && occurrences.contains {
            $0.isInsideJoinWindow(at: now)
                && (configuration.startMode(for: $0) == .automatic
                    ? $0.participationStatus.permitsAutomaticStart
                    : $0.participationStatus.permitsReminder)
                && !configuration.suppressedOccurrenceDigests.contains($0.occurrenceDigest)
                && !recordedOccurrenceDigests.contains($0.occurrenceDigest)
                && !permanentStartFailureDigests.contains($0.occurrenceDigest)
        }
        let shouldCollectAudio = configuration.isOperational
            && (needsAutoStopSignal || hasOpenJoinWindow || configuration.detectAdHocMeetings)
        if shouldCollectAudio != collectorRequested {
            collectorRequested = shouldCollectAudio
            effects.append(
                shouldCollectAudio ? .startActivityCollector : .stopActivityCollector
            )
        }

        let shouldCollectCamera = configuration.isOperational && activeRecording == nil
            && occurrences.contains { !$0.isAdHoc && $0.isInsideJoinWindow(at: now) }
            && hasOpenJoinWindow
        if shouldCollectCamera != cameraCollectorRequested {
            cameraCollectorRequested = shouldCollectCamera
            effects.append(
                shouldCollectCamera
                    ? .startCameraActivityCollector
                    : .stopCameraActivityCollector
            )
        }
    }

    private mutating func evaluateStart(
        at now: Date,
        effects: inout [CalendarMeetingAutomationEffect]
    ) {
        pruneArmedOccurrences(at: now)
        guard configuration.isOperational, activeRecording == nil else {
            clearPendingStart(effects: &effects)
            return
        }
        discardInvalidDeferredStart(at: now, effects: &effects)

        if let pendingStart {
            let signalStillPresent = startEvidenceIsPresent(
                digest: pendingStart.occurrenceDigest,
                identity: pendingStart.identity,
                at: now
            )
            guard signalStillPresent,
                  let occurrence = consentedStartOccurrence(
                      digest: pendingStart.occurrenceDigest,
                      identity: pendingStart.identity,
                      at: now
                  ) else {
                dwellStates.removeValue(forKey: pendingStart.occurrenceDigest)
                clearPendingStart(effects: &effects)
                restoreAutomaticReminder(for: pendingStart.occurrenceDigest, at: now, effects: &effects)
                return
            }
            if now >= pendingStart.deadline, requestedStart == nil {
                guard recorderReadiness.isIdle else {
                    pendingIdleCandidate = PendingIdleCandidate(
                        digest: pendingStart.occurrenceDigest, identity: pendingStart.identity,
                        reminderWasDismissed: true
                    )
                    clearPendingStart(effects: &effects)
                    return
                }
                requestedStart = (occurrence.occurrenceDigest, pendingStart.identity)
                effects.append(.startRecording(occurrence, pendingStart.identity))
                clearPendingStart(effects: &effects)
            }
            return
        }

        guard requestedStart == nil,
              let candidate = uniqueAutomaticCandidate(at: now) else {
            dwellStates.removeAll()
            return
        }

        let digest = candidate.occurrence.occurrenceDigest
        if dwellStates[digest]?.identity != candidate.signal.meetingIdentity {
            dwellStates = [digest: DwellState(
                identity: candidate.signal.meetingIdentity,
                startedAt: now
            )]
            return
        }
        let dwell: TimeInterval = candidate.occurrence.isAdHoc
            ? (candidate.signal.quality == .exactBrowserIdentity ? 20 : 5)
            : 3
        guard let dwellState = dwellStates[digest],
              now.timeIntervalSince(dwellState.startedAt) >= dwell else {
            return
        }

        switch configuration.startMode(for: candidate.occurrence) {
        case .off:
            break
        case .reminder:
            if armedOccurrenceDigests.contains(digest) {
                handleStableStartCandidate(
                    digest: digest,
                    identity: candidate.signal.meetingIdentity,
                    at: now,
                    effects: &effects
                )
            } else if detectedNotificationDigests.insert(digest).inserted {
                effects.append(.publishDetectedMeeting(candidate.occurrence))
            }
        case .automatic:
            handleStableStartCandidate(
                digest: digest,
                identity: candidate.signal.meetingIdentity,
                at: now,
                effects: &effects
            )
        }
    }

    private func uniqueAutomaticCandidate(
        at now: Date
    ) -> (occurrence: CalendarMeetingOccurrence, signal: CalendarMeetingJoinSignal)? {
        var eligible = signals.compactMap {
            signal -> (CalendarMeetingOccurrence, CalendarMeetingJoinSignal)? in
            guard signal.permitsStart,
                  let occurrence = eligibleStartOccurrence(
                      digest: signal.occurrenceDigest,
                      identity: signal.meetingIdentity,
                      at: now
                  ) else {
                return nil
            }
            return (occurrence, signal)
        }
        if cameraActivityAvailable && isCameraRunning {
            eligible.append(contentsOf: signals.compactMap { signal in
                guard !signal.permitsStart,
                      signal.isRunningOutput,
                      let occurrence = eligibleStartOccurrence(
                          digest: signal.occurrenceDigest,
                          identity: signal.meetingIdentity,
                          at: now
                      ), !occurrence.isAdHoc else {
                    return nil
                }
                return (
                    occurrence,
                    CalendarMeetingJoinSignal(
                        occurrenceDigest: signal.occurrenceDigest,
                        meetingIdentity: signal.meetingIdentity,
                        quality: signal.quality,
                        isRunningInput: false,
                        isRunningOutput: signal.isRunningOutput,
                        evidence: .cameraPresence
                    )
                )
            })
            eligible.append(contentsOf: occurrences.compactMap { occurrence in
                guard !occurrence.isAdHoc, occurrence.meetingLinks.count == 1,
                      let identity = occurrence.meetingLinks.first,
                      eligibleStartOccurrence(
                          digest: occurrence.occurrenceDigest,
                          identity: identity,
                          at: now
                      ) != nil else {
                    return nil
                }
                return (
                    occurrence,
                    CalendarMeetingJoinSignal(
                        occurrenceDigest: occurrence.occurrenceDigest,
                        meetingIdentity: identity,
                        quality: .cameraPresence,
                        isRunningInput: false,
                        isRunningOutput: false,
                        evidence: .cameraPresence
                    )
                )
            })
        }
        // Arming is explicit consent, so it breaks ties. Automatic occurrences get no such
        // preference: an overlap with an event that still waits for consent stays ambiguous.
        let armed = eligible.filter {
            armedOccurrenceDigests.contains($0.0.occurrenceDigest)
        }
        let ranked = armed.isEmpty ? eligible : armed
        guard let bestQuality = ranked.map({ $0.1.quality.rawValue }).max() else { return nil }
        let best = ranked.filter { $0.1.quality.rawValue == bestQuality }
        let digests = Set(best.map { $0.0.occurrenceDigest })
        guard digests.count == 1 else { return nil }
        return best.sorted { $0.1.meetingIdentity.id < $1.1.meetingIdentity.id }.first
    }

    private func eligibleStartOccurrence(
        digest: String,
        identity: CalendarMeetingCanonicalLink,
        at now: Date
    ) -> CalendarMeetingOccurrence? {
        guard let occurrence = occurrence(for: digest),
              occurrence.isInsideJoinWindow(at: now),
              occurrence.meetingLinks.contains(identity),
              configuration.enabledProviders.contains(identity.provider),
              configuration.startMode(for: occurrence) == .automatic
                ? occurrence.participationStatus.permitsAutomaticStart
                : occurrence.participationStatus.permitsReminder,
              !configuration.suppressedOccurrenceDigests.contains(digest),
              !recordedOccurrenceDigests.contains(digest),
              !permanentStartFailureDigests.contains(digest) else {
            return nil
        }
        return occurrence
    }

    /// Lets the controller check consent again after awaiting the recorder start, because a
    /// calendar refresh can arrive while the start is in flight.
    func permitsStart(
        of digest: String,
        identity: CalendarMeetingCanonicalLink,
        at now: Date
    ) -> Bool {
        consentedStartOccurrence(digest: digest, identity: identity, at: now) != nil
    }

    /// Calendar refreshes can change an occurrence while a start waits for its countdown or
    /// an idle recorder, so consent is checked again: automatic occurrences may start on
    /// their own, reminder occurrences only after the user armed them.
    private func consentedStartOccurrence(
        digest: String,
        identity: CalendarMeetingCanonicalLink,
        at now: Date
    ) -> CalendarMeetingOccurrence? {
        guard let occurrence = eligibleStartOccurrence(digest: digest, identity: identity, at: now),
              configuration.startMode(for: occurrence) == .automatic
                || armedOccurrenceDigests.contains(digest) else {
            return nil
        }
        return occurrence
    }

    private func startEvidenceIsPresent(
        digest: String,
        identity: CalendarMeetingCanonicalLink,
        at now: Date
    ) -> Bool {
        if signals.contains(where: {
            $0.occurrenceDigest == digest
                && $0.meetingIdentity == identity
                && $0.permitsStart
        }) {
            return true
        }
        guard cameraActivityAvailable,
              isCameraRunning,
              let candidate = uniqueAutomaticCandidate(at: now) else {
            return false
        }
        return candidate.occurrence.occurrenceDigest == digest
            && candidate.signal.meetingIdentity == identity
    }

    private mutating func handleStableStartCandidate(
        digest: String,
        identity: CalendarMeetingCanonicalLink,
        at now: Date,
        effects: inout [CalendarMeetingAutomationEffect]
    ) {
        guard !permanentStartFailureDigests.contains(digest) else { return }
        switch recorderReadiness {
        case .idle:
            beginStartCountdown(
                digest: digest,
                identity: identity,
                at: now,
                effects: &effects
            )
        case .recorderBusy, .dictationBusy, .finalizing:
            if !idleRetryDigests.contains(digest) {
                pendingIdleCandidate = PendingIdleCandidate(
                    digest: digest, identity: identity,
                    reminderWasDismissed: pendingIdleCandidate?.digest == digest
                        && pendingIdleCandidate?.reminderWasDismissed == true
                )
            }
        case .noAudioSource, .microphoneDenied:
            armedOccurrenceDigests.remove(digest)
            permanentStartFailureDigests.insert(digest)
        }
    }

    private mutating func discardInvalidDeferredStart(
        at now: Date,
        effects: inout [CalendarMeetingAutomationEffect]
    ) {
        guard let candidate = pendingIdleCandidate,
              !startEvidenceIsPresent(digest: candidate.digest, identity: candidate.identity, at: now)
                || consentedStartOccurrence(digest: candidate.digest, identity: candidate.identity, at: now) == nil else {
            return
        }
        pendingIdleCandidate = nil
        dwellStates.removeValue(forKey: candidate.digest)
        if candidate.reminderWasDismissed {
            restoreAutomaticReminder(for: candidate.digest, at: now, effects: &effects)
        }
    }

    private mutating func restoreAutomaticReminder(
        for digest: String,
        at now: Date,
        effects: inout [CalendarMeetingAutomationEffect]
    ) {
        let reminders = upcomingReminders(at: now)
        guard let reminder = reminders.first(where: {
            $0.occurrence.id == digest && $0.startMode == .automatic
        }) else { return }
        if reminder.occurrence.startDate.addingTimeInterval(-5 * 60) <= now {
            // Unstable evidence may repeatedly enter and abandon the countdown. Restore
            // one immediate prompt, without another audible banner for every rejoin.
            guard restoredAutomaticCatchUpDigests.insert(digest).inserted else { return }
        }
        // Signal loss can abort the handoff without a calendar refresh. Restore the
        // automatic reminder now; explicit reminder consent stays armed and deduplicated.
        effects.append(.allowReminderRestoration(digest))
        effects.append(.replaceScheduledReminders(reminders))
    }

    private mutating func beginStartCountdown(
        digest: String,
        identity: CalendarMeetingCanonicalLink,
        at now: Date,
        effects: inout [CalendarMeetingAutomationEffect]
    ) {
        guard pendingStart == nil,
              let occurrence = consentedStartOccurrence(digest: digest, identity: identity, at: now),
              startEvidenceIsPresent(digest: digest, identity: identity, at: now) else {
            return
        }
        let deadline = now.addingTimeInterval(5)
        pendingStart = PendingStart(
            occurrenceDigest: digest,
            identity: identity,
            deadline: deadline
        )
        effects.append(.dismissStartNotifications(digest))
        effects.append(.showStartCountdown(occurrence, deadline: deadline))
    }

    private mutating func handle(
        action: CalendarMeetingAutomationUserAction,
        at now: Date,
        effects: inout [CalendarMeetingAutomationEffect]
    ) {
        switch action {
        case .armOccurrence(let digest):
            guard configuration.isOperational,
                  let occurrence = occurrence(for: digest),
                  configuration.startMode(for: occurrence) == .reminder,
                  occurrence.isInsideJoinWindow(at: now),
                  occurrence.participationStatus.permitsReminder,
                  !configuration.suppressedOccurrenceDigests.contains(digest),
                  !recordedOccurrenceDigests.contains(digest),
                  !permanentStartFailureDigests.contains(digest),
                  occurrence.meetingLinks.contains(where: {
                      configuration.enabledProviders.contains($0.provider)
                  }) else {
                return
            }
            armedOccurrenceDigests.insert(digest)
            effects.append(.dismissStartNotifications(digest))
            effects.append(.replaceScheduledReminders(upcomingReminders(at: now)))
            updateCollector(at: now, effects: &effects)
            evaluateStart(at: now, effects: &effects)

        case .suppressOccurrence(let digest), .cancelStartCountdown(let digest):
            guard occurrence(for: digest) != nil else { return }
            armedOccurrenceDigests.remove(digest)
            if pendingStart?.occurrenceDigest == digest {
                clearPendingStart(effects: &effects)
            }
            dwellStates.removeValue(forKey: digest)
            if pendingIdleCandidate?.digest == digest {
                pendingIdleCandidate = nil
            }
            effects.append(.dismissStartNotifications(digest))
            effects.append(.persistSuppression(digest))

        case .continueRecording(let handle):
            guard activeRecording?.handle == handle else { return }
            activeRecording?.stickyVeto = true
            activeRecording?.missingSince = nil
            activeRecording?.signalReturnSince = nil
            if activeRecording?.stopDeadline != nil {
                effects.append(.dismissStopCountdown)
            }
            activeRecording?.autoStopArmed = false
            activeRecording?.stopDeadline = nil
            updateCollector(at: now, effects: &effects)
        }
    }

    private mutating func evaluateAutoStop(
        at now: Date,
        effects: inout [CalendarMeetingAutomationEffect]
    ) {
        guard var recording = activeRecording,
              recording.autoStopArmed,
              !recording.stickyVeto,
              !recording.stopRequested else {
            return
        }

        let signalPresent = signals.contains {
            $0.occurrenceDigest == recording.occurrenceDigest
                && $0.meetingIdentity == recording.identity
                && $0.countsForAutoStop
        }
        if signalPresent {
            recording.hasObservedSignal = true
            guard recording.stopDeadline != nil else {
                recording.missingSince = nil
                recording.signalReturnSince = nil
                activeRecording = recording
                return
            }

            if recording.signalReturnSince == nil {
                recording.signalReturnSince = now
                activeRecording = recording
                return
            }
            guard let signalReturnSince = recording.signalReturnSince,
                  now.timeIntervalSince(signalReturnSince) >= Self.autoStopSignalReturnDwell else {
                activeRecording = recording
                return
            }

            effects.append(.dismissStopCountdown)
            recording.missingSince = nil
            recording.stopDeadline = nil
            recording.signalReturnSince = nil
            activeRecording = recording
            return
        }

        recording.signalReturnSince = nil
        activeRecording = recording

        guard recording.hasObservedSignal else {
            return
        }

        if recording.stopDeadline == nil {
            if recording.missingSince == nil { recording.missingSince = now }
            activeRecording = recording
            guard let missingSince = recording.missingSince,
                  now.timeIntervalSince(missingSince) >= recording.idleGrace else { return }
            let deadline = now.addingTimeInterval(15)
            recording.stopDeadline = deadline
            activeRecording = recording
            effects.append(.showStopCountdown(recording.handle, deadline: deadline))
            return
        }
        if let deadline = recording.stopDeadline, now >= deadline {
            recording.stopRequested = true
            activeRecording = recording
            effects.append(.stopRecording(recording.handle))
        }
    }

    private mutating func disarmAutoStop(
        effects: inout [CalendarMeetingAutomationEffect]
    ) {
        guard activeRecording != nil else { return }
        if activeRecording?.stopDeadline != nil {
            effects.append(.dismissStopCountdown)
        }
        activeRecording?.autoStopArmed = false
        activeRecording?.missingSince = nil
        activeRecording?.stopDeadline = nil
        activeRecording?.signalReturnSince = nil
    }

    private mutating func clearPendingStart(
        effects: inout [CalendarMeetingAutomationEffect]
    ) {
        guard pendingStart != nil else { return }
        pendingStart = nil
        effects.append(.dismissStartCountdown)
    }

    private mutating func pruneArmedOccurrences(at now: Date) {
        guard configuration.isOperational else {
            armedOccurrenceDigests.removeAll()
            return
        }
        let configuration = self.configuration
        let suppressedDigests = configuration.suppressedOccurrenceDigests
        let enabledProviders = configuration.enabledProviders
        let recordedDigests = recordedOccurrenceDigests
        let failedDigests = permanentStartFailureDigests
        let validDigests = Set(occurrences.filter {
            configuration.startMode(for: $0) == .reminder
                && $0.isInsideJoinWindow(at: now)
                && $0.participationStatus.permitsReminder
                && !suppressedDigests.contains($0.occurrenceDigest)
                && !recordedDigests.contains($0.occurrenceDigest)
                && !failedDigests.contains($0.occurrenceDigest)
                && $0.meetingLinks.contains(where: {
                    enabledProviders.contains($0.provider)
                })
        }.map(\.occurrenceDigest))
        armedOccurrenceDigests.formIntersection(validDigests)
    }

    private func occurrence(for digest: String) -> CalendarMeetingOccurrence? {
        occurrences.first { $0.occurrenceDigest == digest }
    }

    private mutating func pruneSessionState() {
        var retained = Set(occurrences.map(\.occurrenceDigest))
        if let activeRecording { retained.insert(activeRecording.occurrenceDigest) }
        detectedNotificationDigests.formIntersection(retained)
        armedOccurrenceDigests.formIntersection(retained)
        permanentStartFailureDigests.formIntersection(retained)
        recordedOccurrenceDigests.formIntersection(retained)
        idleRetryDigests.formIntersection(retained)
        restoredAutomaticCatchUpDigests.formIntersection(retained)
    }
}
