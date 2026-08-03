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
    case nativeProvider = 1
    case exactBrowserIdentity = 2
}

struct CalendarMeetingJoinSignal: Equatable, Sendable {
    let occurrenceDigest: String
    let meetingIdentity: CalendarMeetingCanonicalLink
    let quality: CalendarMeetingJoinMatchQuality
    let isRunningInput: Bool
    let isRunningOutput: Bool
}

struct CalendarMeetingAutomationConfiguration: Equatable, Sendable {
    let hasPremiumAccess: Bool
    let startMode: CalendarMeetingStartMode
    let autoStopEnabled: Bool
    let calendarAuthorization: CalendarMeetingCalendarAuthorization
    let selectedCalendarIDs: Set<String>
    let enabledProviders: Set<MeetingProvider>
    let suppressedOccurrenceDigests: Set<String>

    var isOperational: Bool {
        hasPremiumAccess && startMode != .off && calendarAuthorization == .fullAccess
    }
}

enum CalendarMeetingRecordingStartFailure: Equatable, Sendable {
    case noAudioSource
    case microphoneDenied
    case captureFailed
}

enum CalendarMeetingAutomationUserAction: Equatable, Sendable {
    case startOccurrence(String)
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
    case activity([CalendarMeetingJoinSignal], now: Date)
    case activityUnavailable(now: Date)
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
    case recordingStartDeferred(
        occurrenceDigest: String,
        identity: CalendarMeetingCanonicalLink,
        readiness: CalendarMeetingRecorderReadiness,
        now: Date
    )
    case recordingStopped(CalendarMeetingRecordingHandle, now: Date)
}

enum CalendarMeetingAutomationEffect: Equatable, Sendable {
    case replaceScheduledReminders([CalendarMeetingOccurrence])
    case startActivityCollector
    case stopActivityCollector
    case publishDetectedMeeting(CalendarMeetingOccurrence)
    case showStartCountdown(CalendarMeetingOccurrence, deadline: Date)
    case dismissStartCountdown
    case startRecording(CalendarMeetingOccurrence, CalendarMeetingCanonicalLink)
    case persistSuppression(String)
    case showStopCountdown(CalendarMeetingRecordingHandle, deadline: Date)
    case dismissStopCountdown
    case stopRecording(CalendarMeetingRecordingHandle)
}

struct CalendarMeetingAutomationPolicy: Sendable {
    private struct DwellState: Equatable, Sendable {
        let identity: CalendarMeetingCanonicalLink
        let startedAt: Date
    }

    private struct PendingStart: Equatable, Sendable {
        let occurrenceDigest: String
        let identity: CalendarMeetingCanonicalLink
        let deadline: Date
    }

    private struct ActiveRecording: Equatable, Sendable {
        let handle: CalendarMeetingRecordingHandle
        let occurrenceDigest: String
        let identity: CalendarMeetingCanonicalLink
        var autoStopArmed: Bool
        var missingSince: Date?
        var stopDeadline: Date?
        var stickyVeto = false
        var stopRequested = false
        var hasObservedSignal = false
    }

    private var configuration = CalendarMeetingAutomationConfiguration(
        hasPremiumAccess: false,
        startMode: .off,
        autoStopEnabled: false,
        calendarAuthorization: .notDetermined,
        selectedCalendarIDs: [],
        enabledProviders: Set(MeetingProvider.allCases),
        suppressedOccurrenceDigests: []
    )
    private var occurrences: [CalendarMeetingOccurrence] = []
    private var signals: [CalendarMeetingJoinSignal] = []
    private var recorderReadiness: CalendarMeetingRecorderReadiness = .idle
    private var dwellStates: [String: DwellState] = [:]
    private var detectedNotificationDigests = Set<String>()
    private var permanentStartFailureDigests = Set<String>()
    private var recordedOccurrenceDigests = Set<String>()
    private var idleRetryDigests = Set<String>()
    private var pendingIdleCandidate: (digest: String, identity: CalendarMeetingCanonicalLink)?
    private var pendingStart: PendingStart?
    private var startRequestedDigest: String?
    private var activeRecording: ActiveRecording?
    private var collectorRequested = false

    mutating func reduce(_ event: CalendarMeetingAutomationEvent) -> [CalendarMeetingAutomationEffect] {
        var effects: [CalendarMeetingAutomationEffect] = []
        switch event {
        case .configure(let configuration, let occurrences, let now):
            let previousConfiguration = self.configuration
            let wasOperational = previousConfiguration.isOperational
            let autoStopSettingsChangedDuringRecording = activeRecording != nil
                && (
                    previousConfiguration.hasPremiumAccess != configuration.hasPremiumAccess
                        || previousConfiguration.startMode != configuration.startMode
                        || previousConfiguration.autoStopEnabled != configuration.autoStopEnabled
                        || previousConfiguration.calendarAuthorization != configuration.calendarAuthorization
                        || previousConfiguration.selectedCalendarIDs != configuration.selectedCalendarIDs
                        || previousConfiguration.enabledProviders != configuration.enabledProviders
                )
            self.configuration = configuration
            self.occurrences = occurrences
                .filter { configuration.selectedCalendarIDs.contains($0.calendarID) }
                .filter { !$0.providers.isDisjoint(with: configuration.enabledProviders) }
            effects.append(.replaceScheduledReminders(reminderOccurrences(at: now)))

            if !configuration.isOperational
                || previousConfiguration.startMode != configuration.startMode {
                clearPendingStart(effects: &effects)
                dwellStates.removeAll()
                pendingIdleCandidate = nil
                startRequestedDigest = nil
            }
            if (wasOperational && !configuration.isOperational)
                || !configuration.autoStopEnabled
                || autoStopSettingsChangedDuringRecording {
                disarmAutoStop(effects: &effects)
            }
            updateCollector(at: now, effects: &effects)
            evaluateStart(at: now, effects: &effects)
            evaluateAutoStop(at: now, effects: &effects)

        case .activity(let signals, let now):
            self.signals = signals
            if let candidate = pendingIdleCandidate,
               !signals.contains(where: {
                   $0.occurrenceDigest == candidate.digest
                       && $0.meetingIdentity == candidate.identity
                       && $0.isRunningInput
               }) {
                pendingIdleCandidate = nil
            }
            evaluateStart(at: now, effects: &effects)
            evaluateAutoStop(at: now, effects: &effects)

        case .activityUnavailable(let now):
            signals = []
            dwellStates.removeAll()
            pendingIdleCandidate = nil
            clearPendingStart(effects: &effects)
            disarmAutoStop(effects: &effects)
            updateCollector(at: now, effects: &effects)

        case .recorderReadiness(let readiness, let now):
            let becameIdle = !recorderReadiness.isIdle && readiness.isIdle
            recorderReadiness = readiness
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
            startRequestedDigest = nil
            clearPendingStart(effects: &effects)
            activeRecording = ActiveRecording(
                handle: handle,
                occurrenceDigest: occurrenceDigest,
                identity: identity,
                autoStopArmed: autoStopArmed && configuration.autoStopEnabled,
                missingSince: nil,
                stopDeadline: nil,
                hasObservedSignal: false
            )
            recordedOccurrenceDigests.insert(occurrenceDigest)
            effects.append(.replaceScheduledReminders(reminderOccurrences(at: now)))
            updateCollector(at: now, effects: &effects)
            evaluateAutoStop(at: now, effects: &effects)

        case .recordingStartFailed(let digest, _):
            if startRequestedDigest == digest {
                startRequestedDigest = nil
            }
            permanentStartFailureDigests.insert(digest)
            clearPendingStart(effects: &effects)

        case .recordingStartDeferred(let digest, let identity, let readiness, _):
            guard startRequestedDigest == digest else { break }
            startRequestedDigest = nil
            recorderReadiness = readiness
            switch readiness {
            case .recorderBusy, .dictationBusy, .finalizing:
                if !idleRetryDigests.contains(digest) {
                    pendingIdleCandidate = (digest, identity)
                }
            case .noAudioSource, .microphoneDenied:
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

    private func reminderOccurrences(at now: Date) -> [CalendarMeetingOccurrence] {
        guard configuration.isOperational else { return [] }
        let horizon = now.addingTimeInterval(7 * 24 * 60 * 60)
        return occurrences
            .filter { $0.participationStatus.permitsReminder }
            .filter { !configuration.suppressedOccurrenceDigests.contains($0.occurrenceDigest) }
            .filter { !recordedOccurrenceDigests.contains($0.occurrenceDigest) }
            .filter {
                $0.endDate.addingTimeInterval(30 * 60) >= now
                    && $0.startDate.addingTimeInterval(-5 * 60) <= horizon
            }
            .sorted { $0.startDate < $1.startDate }
            .prefix(48)
            .map { $0 }
    }

    private mutating func updateCollector(
        at now: Date,
        effects: inout [CalendarMeetingAutomationEffect]
    ) {
        let needsAutoStopSignal = activeRecording?.autoStopArmed == true
        let hasOpenJoinWindow = activeRecording == nil && occurrences.contains {
            $0.isInsideJoinWindow(at: now)
                && (configuration.startMode == .automatic
                    ? $0.participationStatus.permitsAutomaticStart
                    : $0.participationStatus.permitsReminder)
                && !configuration.suppressedOccurrenceDigests.contains($0.occurrenceDigest)
                && !recordedOccurrenceDigests.contains($0.occurrenceDigest)
                && !permanentStartFailureDigests.contains($0.occurrenceDigest)
        }
        let shouldCollect = configuration.isOperational && (needsAutoStopSignal || hasOpenJoinWindow)
        guard shouldCollect != collectorRequested else { return }
        collectorRequested = shouldCollect
        effects.append(shouldCollect ? .startActivityCollector : .stopActivityCollector)
    }

    private mutating func evaluateStart(
        at now: Date,
        effects: inout [CalendarMeetingAutomationEffect]
    ) {
        guard configuration.isOperational, activeRecording == nil else {
            clearPendingStart(effects: &effects)
            return
        }

        if let pendingStart {
            let signalStillPresent = signals.contains {
                $0.occurrenceDigest == pendingStart.occurrenceDigest
                    && $0.meetingIdentity == pendingStart.identity
                    && $0.isRunningInput
            }
            guard signalStillPresent,
                  occurrence(for: pendingStart.occurrenceDigest)?.isInsideJoinWindow(at: now) == true,
                  !configuration.suppressedOccurrenceDigests.contains(
                      pendingStart.occurrenceDigest
                  ),
                  !recordedOccurrenceDigests.contains(pendingStart.occurrenceDigest),
                  !permanentStartFailureDigests.contains(pendingStart.occurrenceDigest) else {
                dwellStates.removeValue(forKey: pendingStart.occurrenceDigest)
                clearPendingStart(effects: &effects)
                return
            }
            if now >= pendingStart.deadline, startRequestedDigest == nil {
                guard recorderReadiness.isIdle else {
                    pendingIdleCandidate = (pendingStart.occurrenceDigest, pendingStart.identity)
                    clearPendingStart(effects: &effects)
                    return
                }
                if let occurrence = occurrence(for: pendingStart.occurrenceDigest) {
                    startRequestedDigest = occurrence.occurrenceDigest
                    effects.append(.startRecording(occurrence, pendingStart.identity))
                    clearPendingStart(effects: &effects)
                }
            }
            return
        }

        guard startRequestedDigest == nil,
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
        guard let dwellState = dwellStates[digest],
              now.timeIntervalSince(dwellState.startedAt) >= 3 else {
            return
        }

        switch configuration.startMode {
        case .off:
            break
        case .reminder:
            if detectedNotificationDigests.insert(digest).inserted {
                effects.append(.publishDetectedMeeting(candidate.occurrence))
            }
        case .automatic:
            guard !permanentStartFailureDigests.contains(digest) else { return }
            switch recorderReadiness {
            case .idle:
                beginStartCountdown(
                    digest: digest,
                    identity: candidate.signal.meetingIdentity,
                    at: now,
                    effects: &effects
                )
            case .recorderBusy, .dictationBusy, .finalizing:
                if !idleRetryDigests.contains(digest) {
                    pendingIdleCandidate = (digest, candidate.signal.meetingIdentity)
                }
            case .noAudioSource, .microphoneDenied:
                permanentStartFailureDigests.insert(digest)
            }
        }
    }

    private func uniqueAutomaticCandidate(
        at now: Date
    ) -> (occurrence: CalendarMeetingOccurrence, signal: CalendarMeetingJoinSignal)? {
        let eligible = signals.compactMap { signal -> (CalendarMeetingOccurrence, CalendarMeetingJoinSignal)? in
            guard signal.isRunningInput,
                  let occurrence = occurrence(for: signal.occurrenceDigest),
                  occurrence.isInsideJoinWindow(at: now),
                  occurrence.meetingLinks.contains(signal.meetingIdentity),
                  configuration.startMode == .automatic
                    ? occurrence.participationStatus.permitsAutomaticStart
                    : occurrence.participationStatus.permitsReminder,
                  !configuration.suppressedOccurrenceDigests.contains(signal.occurrenceDigest),
                  !recordedOccurrenceDigests.contains(signal.occurrenceDigest),
                  !permanentStartFailureDigests.contains(signal.occurrenceDigest) else {
                return nil
            }
            return (occurrence, signal)
        }
        guard let bestQuality = eligible.map({ $0.1.quality.rawValue }).max() else { return nil }
        let best = eligible.filter { $0.1.quality.rawValue == bestQuality }
        let digests = Set(best.map { $0.0.occurrenceDigest })
        guard digests.count == 1 else { return nil }
        return best.sorted { $0.1.meetingIdentity.id < $1.1.meetingIdentity.id }.first
    }

    private mutating func beginStartCountdown(
        digest: String,
        identity: CalendarMeetingCanonicalLink,
        at now: Date,
        effects: inout [CalendarMeetingAutomationEffect]
    ) {
        guard pendingStart == nil,
              let occurrence = occurrence(for: digest),
              occurrence.isInsideJoinWindow(at: now),
              !configuration.suppressedOccurrenceDigests.contains(digest),
              !recordedOccurrenceDigests.contains(digest),
              !permanentStartFailureDigests.contains(digest),
              signals.contains(where: {
                  $0.occurrenceDigest == digest
                      && $0.meetingIdentity == identity
                      && $0.isRunningInput
              }) else {
            return
        }
        let deadline = now.addingTimeInterval(5)
        pendingStart = PendingStart(
            occurrenceDigest: digest,
            identity: identity,
            deadline: deadline
        )
        effects.append(.showStartCountdown(occurrence, deadline: deadline))
    }

    private mutating func handle(
        action: CalendarMeetingAutomationUserAction,
        at now: Date,
        effects: inout [CalendarMeetingAutomationEffect]
    ) {
        switch action {
        case .startOccurrence(let digest):
            guard configuration.isOperational,
                  recorderReadiness.isIdle,
                  startRequestedDigest == nil,
                  let occurrence = occurrence(for: digest),
                  occurrence.isInsideJoinWindow(at: now),
                  !configuration.suppressedOccurrenceDigests.contains(digest),
                  !recordedOccurrenceDigests.contains(digest),
                  let identity = occurrence.meetingLinks.first(where: {
                      configuration.enabledProviders.contains($0.provider)
                  }) else {
                return
            }
            startRequestedDigest = digest
            effects.append(.startRecording(occurrence, identity))

        case .suppressOccurrence(let digest), .cancelStartCountdown(let digest):
            guard occurrence(for: digest) != nil else { return }
            if pendingStart?.occurrenceDigest == digest {
                clearPendingStart(effects: &effects)
            }
            dwellStates.removeValue(forKey: digest)
            pendingIdleCandidate = nil
            effects.append(.persistSuppression(digest))

        case .continueRecording(let handle):
            guard activeRecording?.handle == handle else { return }
            activeRecording?.stickyVeto = true
            activeRecording?.missingSince = nil
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
                && ($0.isRunningInput || $0.isRunningOutput)
        }
        if signalPresent {
            if recording.stopDeadline != nil {
                effects.append(.dismissStopCountdown)
            }
            recording.missingSince = nil
            recording.stopDeadline = nil
            recording.hasObservedSignal = true
            activeRecording = recording
            return
        }

        guard recording.hasObservedSignal else {
            activeRecording = recording
            return
        }

        if recording.missingSince == nil {
            recording.missingSince = now
            activeRecording = recording
            return
        }
        guard let missingSince = recording.missingSince,
              now.timeIntervalSince(missingSince) >= 30 else {
            activeRecording = recording
            return
        }

        if recording.stopDeadline == nil {
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
    }

    private mutating func clearPendingStart(
        effects: inout [CalendarMeetingAutomationEffect]
    ) {
        guard pendingStart != nil else { return }
        pendingStart = nil
        effects.append(.dismissStartCountdown)
    }

    private func occurrence(for digest: String) -> CalendarMeetingOccurrence? {
        occurrences.first { $0.occurrenceDigest == digest }
    }
}
