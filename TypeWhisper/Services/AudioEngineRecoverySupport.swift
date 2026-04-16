import Foundation
import AudioToolbox
import os

enum AudioEngineRecoveryAction: Equatable {
    case none
    case performImmediateRecovery
    case schedule(generation: UInt64, delay: TimeInterval)
}

enum AudioEngineRecoveryPolicy {
    static let configurationDebounce: TimeInterval = 0.15

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

enum AudioEngineRecoveryErrorDomains {
    static let avfException = "com.typewhisper.AVFException"
    static let transientFormatMismatch = "com.typewhisper.AudioRecordingRecovery"
}

enum AudioEngineRecoveryErrorUserInfoKeys {
    static let exceptionName = "NSExceptionName"
    static let exceptionUserInfo = "NSExceptionUserInfo"
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
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func beginStarting() {
        state.withLock { state in
            state.lifecycle = .starting
            state.pendingConfigurationChange = false
            state.recoveryInFlight = false
            state.generation &+= 1
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

                state.generation &+= 1
                return .schedule(generation: state.generation, delay: AudioEngineRecoveryPolicy.configurationDebounce)
            }
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

            state.generation &+= 1
            return .schedule(generation: state.generation, delay: AudioEngineRecoveryPolicy.configurationDebounce)
        }
    }

    func transitionToIdle() {
        state.withLock { state in
            state.lifecycle = .idle
            state.pendingConfigurationChange = false
            state.recoveryInFlight = false
            state.generation &+= 1
        }
    }
}
