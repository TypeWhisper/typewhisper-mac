import Foundation
import AudioToolbox
import CoreGraphics
import os

enum AudioEngineRecoveryAction: Equatable {
    case none
    case performImmediateRecovery
    case schedule(generation: UInt64, delay: TimeInterval)
    case fail(AudioEngineRecoveryFailure)
}

enum AudioEngineRecoveryFailure: Equatable {
    case configurationChangeBurstLimitExceeded
}

enum AudioEngineRecoveryPolicy {
    static let configurationDebounce: TimeInterval = 0.15
    // Real BT-default/headset repros continue posting self-induced config
    // changes ~700ms after each successful restart, so the filter needs to
    // cover more than the initial engine.start() call itself. We defer a
    // single recovery until this window expires instead of immediately
    // re-entering the startup path.
    static let configurationChangeQuiescence: TimeInterval = 1.0
    static let configurationChangeBurstWindow: TimeInterval = 5.0
    static let configurationChangeBurstLimit = 4

    /// Backoff schedule used by the asynchronous observer-based recovery path,
    /// which runs on a dedicated dispatch queue. Blocking sleeps here are
    /// safe because they do not stall the main thread.
    static let retryBackoff: [TimeInterval] = [0.15, 0.30, 0.50]

    /// Bounded backoff used when the retry loop executes on the main thread
    /// (e.g. from `AudioRecordingService.startRecording()` or the selected
    /// input device validation). A single short wait keeps UI responsive;
    /// longer recovery is delegated to the observer path on the recovery
    /// queue. See release review M1.
    static let mainThreadRetryBackoff: [TimeInterval] = [0.05]

    /// Returns the appropriate backoff schedule for the current thread.
    static func retryBackoffForCurrentThread() -> [TimeInterval] {
        Thread.isMainThread ? mainThreadRetryBackoff : retryBackoff
    }

    private static let retryableOSStatusCodes: Set<OSStatus> = [
        kAudioUnitErr_FormatNotSupported,
        kAudioUnitErr_InvalidElement,
    ]

    static func isRetryable(error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == AudioEngineRecoveryErrorDomains.avfException
            || nsError.domain == AudioEngineRecoveryErrorDomains.transientFormatMismatch {
            return true
        }

        let detail = nsError.localizedDescription
        return isRetryable(detail: detail, osStatus: extractOSStatus(from: error))
    }

    static func isRetryable(detail: String, osStatus: OSStatus?) -> Bool {
        if let osStatus, retryableOSStatusCodes.contains(osStatus) {
            return true
        }

        let lowercasedDetail = detail.lowercased()
        return lowercasedDetail.contains("config change pending")
            || lowercasedDetail.contains("format mismatch")
            || lowercasedDetail.contains("error -10868")
            || lowercasedDetail.contains("error -10877")
    }

    static func extractOSStatus(from error: Error) -> OSStatus? {
        let nsError = error as NSError
        if nsError.domain == NSOSStatusErrorDomain {
            return OSStatus(nsError.code)
        }

        let detail = nsError.localizedDescription
        if detail.contains("-10868") { return kAudioUnitErr_FormatNotSupported }
        if detail.contains("-10877") { return kAudioUnitErr_InvalidElement }
        return nil
    }
}

/// Bounds how often the armed microphone pre-roll input is re-armed after its stream
/// stalled, was reconfigured by the system, or failed to start. Every failure waits a little
/// longer, and a burst of failures disarms the pre-roll until something external (setting,
/// device change, wake, a recording that worked) calls `reset()`. The normal prewarm and
/// cold-start paths keep working while it is disarmed.
struct MicrophonePrerollRearmPolicy: Equatable {
    enum Decision: Equatable {
        case retry(after: TimeInterval)
        case giveUp
    }

    static let maximumFailuresInWindow = 3
    static let failureWindow: TimeInterval = 60
    static let retryBackoff: [TimeInterval] = [0.5, 2, 5]

    private var failureTimestamps: [TimeInterval] = []
    private(set) var hasGivenUp = false

    mutating func recordFailure(at timestamp: TimeInterval) -> Decision {
        failureTimestamps.removeAll { timestamp - $0 > Self.failureWindow }
        failureTimestamps.append(timestamp)
        guard failureTimestamps.count <= Self.maximumFailuresInWindow else {
            hasGivenUp = true
            return .giveUp
        }
        return .retry(after: Self.retryBackoff[min(failureTimestamps.count, Self.retryBackoff.count) - 1])
    }

    mutating func reset() {
        failureTimestamps.removeAll()
        hasGivenUp = false
    }

    /// A recording that delivered audio proves the input works, so earlier failures (and a
    /// given-up state, which keeps the pre-roll off until something external changes) no
    /// longer apply. Cold-start recordings never claim an armed stream, so they report here.
    mutating func noteWorkingRecording() {
        reset()
    }
}

/// Tracks stops that are still draining a recording. The recording is already inactive and
/// its engine already detached while a stop waits out the short-speech grace and finalizes,
/// yet the stop still owns the capture path. Input preparation (which would arm a second
/// stream) stays blocked until every stop has finished. A counter keeps overlapping stops
/// from releasing each other.
///
/// A Bluetooth release stop does not block preparation: it re-arms nothing, invalidates any
/// in-flight preparation itself and waits for its cleanup, so a preparation that overlaps it
/// is cancelled and cleaned up rather than colliding with a re-arm. Such a stop must not
/// re-arm the input afterwards either, which is why it never leaves a rejected request behind.
///
/// A preparation request that the stop gate rejects is remembered, because nothing else
/// retries it (for example a preference change while a stop drains, or a Bluetooth release
/// stop that schedules no follow-up). The last stop to finish reports it so the caller can
/// run the preparation once; the flag clears when a preparation pass runs with the gate open.
struct RecordingStopTracker: Equatable {
    private var activeStops = 0
    private var blockingStops = 0
    private(set) var hasRejectedPreparation = false

    var isStopping: Bool { blockingStops > 0 }

    mutating func begin(blocksPreparation: Bool = true) {
        activeStops += 1
        if blocksPreparation { blockingStops += 1 }
    }

    /// Returns true when this ended the last stop while a preparation request was rejected
    /// in the meantime, so the caller should run the preparation once.
    @discardableResult
    mutating func end(blocksPreparation: Bool = true) -> Bool {
        activeStops = max(0, activeStops - 1)
        if blocksPreparation { blockingStops = max(0, blockingStops - 1) }
        return activeStops == 0 && hasRejectedPreparation
    }

    /// Whether preparing or arming a microphone input is allowed right now.
    func allowsInputPreparation(isRecordingActive: Bool) -> Bool {
        !isRecordingActive && !isStopping
    }

    /// Gate check for a preparation request. A request rejected while a stop is draining is
    /// remembered for `end()`.
    mutating func evaluatePreparationRequest(isRecordingActive: Bool) -> Bool {
        let allowed = allowsInputPreparation(isRecordingActive: isRecordingActive)
        if !allowed, isStopping {
            hasRejectedPreparation = true
        }
        return allowed
    }

    /// A preparation pass is running with the gate open and re-evaluates eligibility itself,
    /// so a remembered request is satisfied.
    mutating func consumeRejectedPreparation() {
        hasRejectedPreparation = false
    }
}

/// A re-arm that cannot store its stream (slot taken, preparation generation changed) must
/// only disarm the capture it set up itself. When a different prepared stream is already
/// armed, disarming globally would route that stream's idle audio into the recording buffers.
enum MicrophonePrerollRearmStoreFailurePolicy {
    static func shouldDisarmCapture(otherStreamingInputIsPrepared: Bool) -> Bool {
        !otherStreamingInputIsPrepared
    }
}

/// Whether the armed pre-roll input still belongs to the route a recording is about to use.
/// Automatic selection follows the system default, which can change between watchdog ticks:
/// the recording then selects another route while the old input stays armed, and the global
/// armed flag would route the new route's audio into the pre-roll ring instead of the recording.
enum MicrophonePrerollRouteConsistencyPolicy {
    enum ArmedInput: Equatable {
        /// Built-in default input kept running through the engine path.
        case engine(defaultInputDeviceID: AudioDeviceID)
        /// Input-only HAL session for one device.
        case inputOnly(deviceID: AudioDeviceID)
    }

    /// `currentEngineDeviceID` is the system default input that is currently eligible for the
    /// engine pre-roll (nil when none is).
    static func armedInputMatches(
        _ armedInput: ArmedInput,
        route: AudioInputCaptureRoute,
        currentEngineDeviceID: AudioDeviceID?
    ) -> Bool {
        switch (armedInput, route) {
        case (.engine(let armedID), .avAudioEngine(let preferredDeviceID)):
            return preferredDeviceID == nil && currentEngineDeviceID == armedID
        case (.inputOnly(let armedID), .inputOnlyDevice(let routeID)):
            return armedID == routeID
        default:
            return false
        }
    }

    /// True when a prepared streaming input exists and does not match the selected route.
    static func shouldInvalidate(
        armedInput: ArmedInput?,
        route: AudioInputCaptureRoute,
        currentEngineDeviceID: AudioDeviceID?
    ) -> Bool {
        guard let armedInput else { return false }
        return !armedInputMatches(armedInput, route: route, currentEngineDeviceID: currentEngineDeviceID)
    }
}

/// Freshness bookkeeping for the armed microphone pre-roll stream. The timestamp is the
/// uptime of the last real converted buffer from the stream, whether it landed in the ring or
/// in a recording. Re-arming after a recording never synthesizes freshness: a stream that
/// stalled during the recording while its engine still reports running stays stale.
enum MicrophonePrerollFreshnessPolicy {
    /// Timestamp (0 = no buffer seen) to keep after the armed state was set.
    static func lastBufferUptimeAfterArming(
        armed: Bool,
        retainingLastBuffer: Bool,
        previous: UInt64
    ) -> UInt64 {
        armed && retainingLastBuffer ? previous : 0
    }

    static func isFresh(lastBufferUptime: UInt64, now: UInt64, within interval: TimeInterval) -> Bool {
        guard lastBufferUptime != 0, now >= lastBufferUptime else { return false }
        return Double(now - lastBufferUptime) / 1_000_000_000 <= interval
    }
}

/// Decides whether an engine configuration-change notification can be ignored while the
/// microphone pre-roll is armed. Only a notification that left the engine running with the
/// prepared tap format is benign; anything else invalidates the stream. A stalled stream is
/// still caught by the watchdog.
enum MicrophonePrerollConfigurationChangePolicy {
    static func isFormatPreserving(
        engineIsRunning: Bool,
        tapSampleRate: Double,
        tapChannelCount: UInt32,
        liveSampleRate: Double,
        liveChannelCount: UInt32
    ) -> Bool {
        engineIsRunning
            && liveSampleRate > 0
            && liveChannelCount > 0
            && liveSampleRate == tapSampleRate
            && liveChannelCount == tapChannelCount
    }
}

/// Binds a failure callback of an armed pre-roll stream to the stream it came from. The
/// generation changes whenever prepared inputs are invalidated, so a callback of a stream that
/// was already replaced is stale and must neither release nor penalize the replacement.
enum MicrophonePrerollStreamScopePolicy {
    static func isCurrent(streamGeneration: UInt64, currentGeneration: UInt64) -> Bool {
        streamGeneration == currentGeneration
    }
}

/// Why the armed microphone pre-roll input is released. Sleep and screen lock are tracked
/// separately: waking the Mac must not re-arm the microphone while the screen is still locked.
enum MicrophonePrerollSuspensionReason: String, Equatable {
    case sleep = "system-sleep"
    case screenLock = "screen-locked"
}

struct MicrophonePrerollSuspension: Equatable {
    private(set) var isAsleep = false
    private(set) var isScreenLocked = false

    var isSuspended: Bool { isAsleep || isScreenLocked }

    mutating func suspend(for reason: MicrophonePrerollSuspensionReason) {
        switch reason {
        case .sleep: isAsleep = true
        case .screenLock: isScreenLocked = true
        }
    }

    /// Clears only the given reason. Returns true when this call lifted the last reason.
    @discardableResult
    mutating func resume(from reason: MicrophonePrerollSuspensionReason) -> Bool {
        let wasSuspended = isSuspended
        switch reason {
        case .sleep: isAsleep = false
        case .screenLock: isScreenLocked = false
        }
        return wasSuspended && !isSuspended
    }
}

/// Reads whether the login session's screen is locked, so the microphone pre-roll does not
/// arm at launch on a locked screen (the lock notifications only report later transitions).
enum MicrophonePrerollScreenLockProbe {
    static let lockedKey = "CGSSessionScreenIsLocked"

    /// Fails open: a missing dictionary or key means "not locked".
    static func isLocked(sessionDictionary: [String: Any]?) -> Bool {
        guard let value = sessionDictionary?[lockedKey] else { return false }
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }

    static func currentlyLocked() -> Bool {
        let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any]
        return isLocked(sessionDictionary: dictionary)
    }
}

/// Identifies one capture stream (an engine tap or an input-only HAL session). Callbacks of a
/// stream that was torn down can still arrive afterwards; once retired, the token tells the
/// sample path to drop them instead of appending them to a recording or another input's ring.
final class CaptureStreamToken: @unchecked Sendable {
    private let retired = OSAllocatedUnfairLock(initialState: false)

    var isRetired: Bool { retired.withLock { $0 } }

    func retire() {
        retired.withLock { $0 = true }
    }
}

/// Maps the engine or session object behind a stream to its token, so every teardown path can
/// retire the right stream without threading tokens through the prepared-input records.
final class CaptureStreamRegistry: @unchecked Sendable {
    private let tokens = OSAllocatedUnfairLock(initialState: [ObjectIdentifier: CaptureStreamToken]())

    func register(_ token: CaptureStreamToken, for stream: AnyObject) {
        let key = ObjectIdentifier(stream)
        tokens.withLock { $0[key] = token }
    }

    /// Removes and returns the token of `stream`; nil when it was never registered or already retired.
    func take(for stream: AnyObject) -> CaptureStreamToken? {
        let key = ObjectIdentifier(stream)
        return tokens.withLock { $0.removeValue(forKey: key) }
    }
}

enum AudioEngineRecoveryErrorDomains {
    static let avfException = "com.typewhisper.AVFException"
    static let transientFormatMismatch = "com.typewhisper.AudioRecordingRecovery"
}

enum AudioEngineRecoveryErrorUserInfoKeys {
    static let exceptionName = "NSExceptionName"
    static let exceptionUserInfo = "NSExceptionUserInfo"
}

final class DelayedReleaseRetainer<Object: AnyObject>: @unchecked Sendable {
    private final class RetainedObjectBox: @unchecked Sendable {
        let object: Object

        init(_ object: Object) {
            self.object = object
        }
    }

    private let queue: DispatchQueue

    init(label: String, qos: DispatchQoS = .utility) {
        queue = DispatchQueue(label: label, qos: qos)
    }

    func retain(_ object: Object, for duration: TimeInterval) {
        let retainedObject = RetainedObjectBox(object)
        queue.asyncAfter(deadline: .now() + duration) {
            withExtendedLifetime(retainedObject) {}
        }
    }
}

final class AudioEngineRecoveryCoordinator: @unchecked Sendable {
    private enum LifecycleState {
        case idle
        case starting
        case running
    }

    private struct State {
        var lifecycle: LifecycleState = .idle
        var pendingConfigurationChange = false
        var recoveryInFlight = false
        var generation: UInt64 = 0
        var lastEngineStartTimestamp: TimeInterval?
        var scheduledRecoveryTimestamps: [TimeInterval] = []
    }

    private let now: @Sendable () -> TimeInterval
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }) {
        self.now = now
    }

    func beginStarting() {
        state.withLock { state in
            state.lifecycle = .starting
            state.pendingConfigurationChange = false
            state.recoveryInFlight = false
            state.generation &+= 1
            state.lastEngineStartTimestamp = nil
            state.scheduledRecoveryTimestamps.removeAll(keepingCapacity: false)
        }
    }

    func noteEngineStarted() {
        state.withLock { state in
            state.lastEngineStartTimestamp = now()
        }
    }

    func finishStartingSuccessfully() -> AudioEngineRecoveryAction {
        state.withLock { state in
            state.lifecycle = .running
            guard state.pendingConfigurationChange else {
                return .none
            }

            state.pendingConfigurationChange = false
            state.recoveryInFlight = true
            return .performImmediateRecovery
        }
    }

    func noteConfigurationChange() -> AudioEngineRecoveryAction {
        state.withLock { state in
            switch state.lifecycle {
            case .idle:
                return .none
            case .starting:
                state.pendingConfigurationChange = true
                return .none
            case .running:
                state.pendingConfigurationChange = true
                guard !state.recoveryInFlight else {
                    return .none
                }

                return makeScheduledRecoveryAction(for: &state)
            }
        }
    }

    var hasPendingConfigurationChange: Bool {
        state.withLock { $0.pendingConfigurationChange }
    }

    func consumePendingConfigurationChangeForEngineReplacement() {
        state.withLock { state in
            state.pendingConfigurationChange = false
        }
    }

    func beginScheduledRecovery(generation: UInt64) -> Bool {
        state.withLock { state in
            guard state.lifecycle == .running,
                  !state.recoveryInFlight,
                  state.generation == generation,
                  state.pendingConfigurationChange else {
                return false
            }

            state.pendingConfigurationChange = false
            state.recoveryInFlight = true
            return true
        }
    }

    func finishRecovery() -> AudioEngineRecoveryAction {
        state.withLock { state in
            state.recoveryInFlight = false
            guard state.lifecycle == .running, state.pendingConfigurationChange else {
                return .none
            }

            return makeScheduledRecoveryAction(for: &state)
        }
    }

    func transitionToIdle() {
        state.withLock { state in
            state.lifecycle = .idle
            state.pendingConfigurationChange = false
            state.recoveryInFlight = false
            state.generation &+= 1
            state.lastEngineStartTimestamp = nil
            state.scheduledRecoveryTimestamps.removeAll(keepingCapacity: false)
        }
    }

    private func makeScheduledRecoveryAction(for state: inout State) -> AudioEngineRecoveryAction {
        pruneScheduledRecoveryTimestamps(in: &state)
        if state.scheduledRecoveryTimestamps.count >= AudioEngineRecoveryPolicy.configurationChangeBurstLimit - 1 {
            state.pendingConfigurationChange = false
            return .fail(.configurationChangeBurstLimitExceeded)
        }

        state.generation &+= 1
        state.scheduledRecoveryTimestamps.append(now())
        return .schedule(generation: state.generation, delay: recoveryDelay(for: state))
    }

    private func recoveryDelay(for state: State) -> TimeInterval {
        guard let lastEngineStartTimestamp = state.lastEngineStartTimestamp else {
            return AudioEngineRecoveryPolicy.configurationDebounce
        }

        let elapsedSinceStart = now() - lastEngineStartTimestamp
        let remainingQuiescence = AudioEngineRecoveryPolicy.configurationChangeQuiescence - elapsedSinceStart
        return max(AudioEngineRecoveryPolicy.configurationDebounce, remainingQuiescence)
    }

    private func pruneScheduledRecoveryTimestamps(in state: inout State) {
        let cutoff = now() - AudioEngineRecoveryPolicy.configurationChangeBurstWindow
        state.scheduledRecoveryTimestamps.removeAll { $0 < cutoff }
    }
}
