import Foundation

/// Speech or quiet in recorded dictation audio, judged by RMS in 100 ms frames of the
/// 16 kHz recording. The live preview and the toggle silence stop share this rule, so a
/// recording only stops on the kind of silence the preview already treats as silence.
enum DictationSpeechActivity {
    /// 100 ms frames.
    static let framesPerSecond = 10
    static let frameSampleCount = Int(AudioRecordingService.targetSampleRate) / framesPerSecond
    /// Frames at or above this RMS count as speech.
    static let speechRMSFloor: Float = 0.004

    static func frameContainsSpeech(_ frame: ArraySlice<Float>) -> Bool {
        guard !frame.isEmpty else { return false }
        let rms = sqrt(frame.reduce(Float(0)) { $0 + $1 * $1 } / Float(frame.count))
        return rms >= speechRMSFloor
    }
}

/// Decides when trailing silence ends a toggle dictation (#1023). It reads only the
/// recorded samples, so its time is audio time: an input that stalls or reconnects
/// delivers no frames and never counts as silence.
struct DictationSilenceEndpointDetector: Sendable {
    enum Phase: Equatable, Sendable {
        /// No speech yet. A session never stops on its own before the user speaks.
        case waitingForSpeech
        /// The user speaks, or pauses for less than the warning window.
        case listening
        /// The trailing silence is about to reach the limit; the indicator counts down.
        case stopping(remaining: TimeInterval)
        /// The trailing silence reached the configured duration.
        case endpointReached
    }

    /// Bounds of the silence duration the settings offer. Stored values are clamped into it.
    static let silenceDurationRange: ClosedRange<TimeInterval> = 1...10
    static let defaultSilenceDuration: TimeInterval = 3
    /// Speech needed before silence can end the session, so a key click or a short noise
    /// at the start cannot arm the stop.
    static let minimumSpeechDuration: TimeInterval = 0.3
    /// The countdown runs for the last two seconds at most, and for at most half the
    /// silence duration, so a short pause does not bring it up.
    static let maximumWarningDuration: TimeInterval = 2

    static func clampedSilenceDuration(_ value: TimeInterval?) -> TimeInterval {
        guard let value, value.isFinite else { return defaultSilenceDuration }
        return min(max(value, silenceDurationRange.lowerBound), silenceDurationRange.upperBound)
    }

    /// Whole seconds the indicator shows for a remaining time, rounded up.
    static func countdownSeconds(for remaining: TimeInterval) -> Int {
        max(1, Int((remaining - 0.000_001).rounded(.up)))
    }

    let silenceDuration: TimeInterval
    private let requiredSpeechFrames: Int
    private let requiredSilentFrames: Int
    private let warningFrames: Int
    private var pendingSamples: [Float] = []
    /// Speech frames in a row; a silent frame starts the count again.
    private var speechRunFrames = 0
    /// Set once one continuous run of speech reached the minimum duration.
    private var heardSpeech = false
    private var trailingSilentFrames = 0
    private(set) var phase: Phase = .waitingForSpeech

    init(silenceDuration: TimeInterval) {
        let silenceDuration = Self.clampedSilenceDuration(silenceDuration)
        self.silenceDuration = silenceDuration
        requiredSpeechFrames = Self.frameCount(for: Self.minimumSpeechDuration)
        requiredSilentFrames = max(1, Self.frameCount(for: silenceDuration))
        warningFrames = Self.frameCount(for: min(Self.maximumWarningDuration, silenceDuration / 2))
    }

    private static func frameCount(for duration: TimeInterval) -> Int {
        Int((duration * Double(DictationSpeechActivity.framesPerSecond)).rounded())
    }

    /// Judges newly recorded samples in whole frames; a shorter rest waits for the next call.
    /// Once the endpoint is reached, the phase stays there.
    @discardableResult
    mutating func append(_ samples: [Float]) -> Phase {
        guard phase != .endpointReached else { return phase }
        pendingSamples.append(contentsOf: samples)

        let frameSize = DictationSpeechActivity.frameSampleCount
        var offset = 0
        while pendingSamples.count - offset >= frameSize {
            let frame = pendingSamples[offset..<(offset + frameSize)]
            offset += frameSize
            if DictationSpeechActivity.frameContainsSpeech(frame) {
                speechRunFrames += 1
                if speechRunFrames >= requiredSpeechFrames { heardSpeech = true }
                trailingSilentFrames = 0
            } else {
                // Separate noise bursts (a click, a cough) never add up to speech.
                speechRunFrames = 0
                trailingSilentFrames += 1
            }
            // The first frame that completes the silence ends the session, even when the
            // same delivery continues with speech.
            if heardSpeech, trailingSilentFrames >= requiredSilentFrames {
                break
            }
        }
        pendingSamples.removeFirst(offset)
        phase = currentPhase
        if phase == .endpointReached {
            pendingSamples.removeAll()
        }
        return phase
    }

    private var currentPhase: Phase {
        guard heardSpeech else { return .waitingForSpeech }
        let remainingFrames = requiredSilentFrames - trailingSilentFrames
        if remainingFrames <= 0 {
            return .endpointReached
        }
        if remainingFrames <= warningFrames {
            return .stopping(remaining: Double(remainingFrames) / Double(DictationSpeechActivity.framesPerSecond))
        }
        return .listening
    }
}

/// The silence duration as typed in Settings (#1023): digits with at most one decimal
/// place, applied rounded to tenths and clamped to the offered range.
enum DictationSilenceDurationInput {
    /// Keeps up to two digits, the first decimal separator ("." or ",") and one digit after it.
    static func filtered(_ text: String) -> String {
        var result = ""
        var hasSeparator = false
        var integerDigits = 0
        var fractionDigits = 0
        for character in text {
            if character.isASCII, character.isNumber {
                if hasSeparator {
                    guard fractionDigits < 1 else { continue }
                    fractionDigits += 1
                } else {
                    guard integerDigits < 2 else { continue }
                    integerDigits += 1
                }
                result.append(character)
            } else if character == "." || character == ",", !hasSeparator {
                hasSeparator = true
                result.append(character)
            }
        }
        return result
    }

    /// The typed value, rounded to tenths and clamped; nil when the text holds no number.
    static func duration(from text: String) -> TimeInterval? {
        guard let value = Double(text.replacingOccurrences(of: ",", with: ".")), value.isFinite else {
            return nil
        }
        return DictationSilenceEndpointDetector.clampedSilenceDuration((value * 10).rounded() / 10)
    }

    static func text(for duration: TimeInterval, locale: Locale) -> String {
        duration.formatted(.number.precision(.fractionLength(0...1)).grouping(.never).locale(locale))
    }
}

/// Watches the recording of one dictation for its silence endpoint (#1023). The poll
/// clock is injectable, so tests step through a recording without waiting.
@MainActor
final class DictationSilenceEndpointMonitor {
    typealias Sleep = @MainActor (Duration) async throws -> Void
    typealias ReadSamples = @MainActor (_ sampleOffset: Int) -> (samples: [Float], nextOffset: Int)
    typealias Phase = DictationSilenceEndpointDetector.Phase

    private struct Session {
        let id: UUID
        var detector: DictationSilenceEndpointDetector
        var sampleOffset = 0
    }

    var pollInterval: Duration
    private let sleep: Sleep
    private let readSamples: ReadSamples
    private var session: Session?
    private var pollTask: Task<Void, Never>?

    /// Reports each phase change of the monitored session.
    var onPhaseChange: (@MainActor (_ sessionID: UUID, _ phase: Phase) -> Void)?
    /// Reports once that the session's trailing silence reached the configured duration.
    /// The monitor has stopped by then; the receiver decides whether the session ends.
    var onEndpoint: (@MainActor (_ sessionID: UUID) -> Void)?

    init(
        pollInterval: Duration = .milliseconds(100),
        sleep: @escaping Sleep = { duration in
            try await Task.sleep(for: duration)
        },
        readSamples: @escaping ReadSamples
    ) {
        self.pollInterval = pollInterval
        self.sleep = sleep
        self.readSamples = readSamples
    }

    var monitoredSessionID: UUID? { session?.id }
    var phase: Phase? { session?.detector.phase }

    /// Watches a new session from the start of its recording and ends any previous one.
    func start(sessionID: UUID, silenceDuration: TimeInterval) {
        stop()
        session = Session(
            id: sessionID,
            detector: DictationSilenceEndpointDetector(silenceDuration: silenceDuration)
        )
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.pollInterval, let sleep = self?.sleep else { return }
                do {
                    try await sleep(interval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.poll(sessionID: sessionID)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        session = nil
    }

    /// Reads the audio recorded since the last poll. A poll for a session that ended or was
    /// replaced, such as one that was already due when the recording stopped, does nothing.
    func poll(sessionID: UUID) {
        guard var session, session.id == sessionID else { return }
        let previousPhase = session.detector.phase
        let delta = readSamples(session.sampleOffset)
        session.sampleOffset = delta.nextOffset
        let phase = session.detector.append(delta.samples)
        self.session = session

        if phase != previousPhase {
            onPhaseChange?(sessionID, phase)
        }
        guard phase == .endpointReached, self.session?.id == sessionID else { return }
        stop()
        onEndpoint?(sessionID)
    }
}
