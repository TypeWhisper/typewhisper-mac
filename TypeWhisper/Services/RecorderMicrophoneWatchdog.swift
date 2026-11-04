import Accelerate
@preconcurrency import AVFoundation
import Foundation
import UserNotifications
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "typewhisper-mac", category: "RecorderMicrophoneWatchdog")

/// The Recorder's microphone track stopped updating during a recording (#1863).
struct RecorderMicrophoneIncident: Equatable, Sendable {
    enum Cause: Equatable, Sendable {
        /// The capture kept delivering the same short piece of audio, as a frozen looping buffer does.
        case repeatedAudio
        /// The capture stopped delivering audio.
        case noAudio
    }

    /// Counts the incidents of one recording, starting at 1.
    let number: Int
    let cause: Cause
    /// Where the microphone track stopped updating, in seconds from the start of the recording.
    let stoppedAt: TimeInterval
    /// Where the restarted microphone records again; nil until it delivers audio.
    var resumedAt: TimeInterval?
    /// Restart attempts that failed so far; the Recorder keeps trying.
    var failedRestarts = 0

    var warningMessage: String {
        let stopped = Self.formattedPosition(stoppedAt)
        let whatHappened: String = switch cause {
        case .repeatedAudio:
            localizedAppText(
                "At \(stopped) in the recording, the microphone started repeating the same audio.",
                de: "Ab \(stopped) in der Aufnahme hat das Mikrofon immer wieder dasselbe Audio geliefert.",
                ja: "録音の\(stopped)の時点で、マイクが同じ音声を繰り返し始めました。",
                zh: "录音进行到 \(stopped) 时，麦克风开始重复同一段音频。",
                es: "En \(stopped) de la grabación, el micrófono empezó a repetir el mismo audio."
            )
        case .noAudio:
            localizedAppText(
                "At \(stopped) in the recording, the microphone stopped delivering audio.",
                de: "Ab \(stopped) in der Aufnahme hat das Mikrofon kein Audio mehr geliefert.",
                ja: "録音の\(stopped)の時点で、マイクから音声が届かなくなりました。",
                zh: "录音进行到 \(stopped) 时，麦克风停止传送音频。",
                es: "En \(stopped) de la grabación, el micrófono dejó de enviar audio."
            )
        }

        let outcome: String
        if let resumedAt {
            let resumed = Self.formattedPosition(resumedAt)
            outcome = localizedAppText(
                "TypeWhisper restarted it at \(resumed); the microphone track is silent in between.",
                de: "TypeWhisper hat es bei \(resumed) neu gestartet; dazwischen ist die Mikrofonspur still.",
                ja: "TypeWhisperが\(resumed)にマイクを再起動しました。その間のマイクトラックは無音です。",
                zh: "TypeWhisper 已在 \(resumed) 重新启动麦克风，其间的麦克风音轨为静音。",
                es: "TypeWhisper lo reinició en \(resumed); la pista del micrófono queda en silencio entre ambos momentos."
            )
        } else if failedRestarts > 0 {
            outcome = localizedAppText(
                "TypeWhisper could not restart it yet and keeps trying. Check the microphone.",
                de: "TypeWhisper konnte es noch nicht neu starten und versucht es weiter. Prüfe das Mikrofon.",
                ja: "TypeWhisperはまだマイクを再起動できず、再試行を続けています。マイクを確認してください。",
                zh: "TypeWhisper 尚未能重新启动麦克风，正在继续尝试。请检查麦克风。",
                es: "TypeWhisper todavía no pudo reiniciarlo y sigue intentándolo. Revisa el micrófono."
            )
        } else {
            outcome = localizedAppText(
                "TypeWhisper is restarting the microphone.",
                de: "TypeWhisper startet das Mikrofon neu.",
                ja: "TypeWhisperがマイクを再起動しています。",
                zh: "TypeWhisper 正在重新启动麦克风。",
                es: "TypeWhisper está reiniciando el micrófono."
            )
        }

        var sentences = [whatHappened, outcome]
        if number > 1 {
            sentences.append(localizedAppText(
                "This happened \(number) times in this recording.",
                de: "In dieser Aufnahme ist das \(number)-mal passiert.",
                ja: "この録音では\(number)回発生しました。",
                zh: "此录音中已发生 \(number) 次。",
                es: "Esto ha ocurrido \(number) veces en esta grabación."
            ))
        }
        return sentences.joined(separator: localizedAppText(" ", de: " ", ja: "", zh: "", es: " "))
    }

    var notificationTitle: String {
        resumedAt == nil
            ? localizedAppText(
                "Microphone stopped",
                de: "Mikrofon ausgefallen",
                ja: "マイクが停止しました",
                zh: "麦克风已停止",
                es: "El micrófono se detuvo"
            )
            : localizedAppText(
                "Microphone restarted",
                de: "Mikrofon neu gestartet",
                ja: "マイクを再起動しました",
                zh: "麦克风已重新启动",
                es: "Micrófono reiniciado"
            )
    }

    /// A position in the recording the way the Recorder shows durations: 16:00 or 1:02:03.
    static func formattedPosition(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainder = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }
}

/// When the Recorder restarts its microphone capture.
enum RecorderMicrophoneWatchdogPolicy {
    static let checkInterval: DispatchTimeInterval = .seconds(1)
    /// Looking for repeated audio costs more than the other checks, so it runs less often.
    static let repetitionCheckInterval: TimeInterval = 2
    /// A capture that delivered audio and then nothing for this long has stopped.
    static let stallTimeout: TimeInterval = 3
    /// A capture's first buffer can take longer, for example from a Bluetooth headset.
    static let firstBufferTimeout: TimeInterval = 6
    /// Audio that keeps repeating this long means the capture froze.
    static let repetitionDuration: TimeInterval = 15
    /// The waits between restart attempts that fail.
    static let restartRetryDelays: [TimeInterval] = [2, 5, 10]

    static func hasStalled(lastBufferUptime: UInt64?, captureStartUptime: UInt64, now: UInt64) -> Bool {
        let reference = lastBufferUptime ?? captureStartUptime
        guard now > reference else { return false }
        let timeout = lastBufferUptime == nil ? firstBufferTimeout : stallTimeout
        return seconds(from: reference, to: now) >= timeout
    }

    static func retryDelay(afterFailedRestarts failedRestarts: Int) -> TimeInterval {
        restartRetryDelays[min(max(failedRestarts, 1), restartRetryDelays.count) - 1]
    }

    static func seconds(from start: UInt64, to end: UInt64) -> TimeInterval {
        guard end > start else { return 0 }
        return TimeInterval(end - start) / 1_000_000_000
    }

    static func uptime(_ start: UInt64, advancedBy seconds: TimeInterval) -> UInt64 {
        start + UInt64(max(0, seconds) * 1_000_000_000)
    }
}

/// Finds a microphone stream that froze into a looping buffer: its newest audio repeats samples
/// it delivered moments earlier, nearly bit for bit. Speech and room noise never repeat that
/// exactly. A sound that plays again through loudspeakers comes back with fresh room noise,
/// so the quiet parts between its repeats differ and end the repeating stretch.
enum RecorderMicrophoneRepetitionDetector {
    struct Configuration: Equatable, Sendable {
        /// The newest samples that are compared with earlier audio (0.5 s at 16 kHz).
        var probeLength = 8_000
        /// The shortest and longest distance between a sample and its earlier copy (2 ms to 6 s).
        var minimumLag = 32
        var maximumLag = 96_000
        /// The repeating stretch is measured in blocks of 50 ms.
        var blockLength = 800
        /// Audio repeats when it differs from its earlier copy by 30 dB less than it carries...
        var relativeResidual: Float = 1e-3
        /// ...or by less than -80 dBFS, which covers the quiet parts of a looping buffer.
        var silentResidualMeanSquare: Float = 1e-8
        /// A probe quieter than about -100 dBFS, such as digital silence, tells nothing.
        var minimumProbeMeanSquare: Float = 1e-10
        /// Single blocks may differ, for example where the capture picked another input
        /// channel for one buffer; more than this many in a row end the repeating stretch.
        var maximumDifferingBlocksInRow = 2
        /// At most this share of a repeating stretch's blocks may differ.
        var maximumDifferingBlockShare: Float = 0.2
    }

    /// Picks every n-th sample of a capture for the check, so audio at 44.1 or 48 kHz is looked
    /// at with about 16000 samples per second. Unlike resampling, picking keeps a looping
    /// buffer's samples exactly as they repeat, whatever the capture's sample rate.
    static func decimation(forSampleRate sampleRate: Double) -> Int {
        max(1, Int((sampleRate / 16_000).rounded()))
    }

    private static let anchorLength = 32
    private static let residualChunkLength = 512

    /// The shortest distance at which the newest probe repeats earlier audio in `samples`.
    static func repeatingLag(
        in samples: UnsafeBufferPointer<Float>,
        configuration: Configuration = Configuration()
    ) -> Int? {
        let probeLength = configuration.probeLength
        guard probeLength >= anchorLength,
              configuration.minimumLag > 0,
              let base = samples.baseAddress,
              samples.count >= probeLength + configuration.minimumLag else { return nil }

        let probeStart = samples.count - probeLength
        let probe = base + probeStart
        var probeEnergy: Float = 0
        vDSP_svesq(probe, 1, &probeEnergy, vDSP_Length(probeLength))
        guard probeEnergy / Float(probeLength) >= configuration.minimumProbeMeanSquare else { return nil }
        let limit = probeEnergy * configuration.relativeResidual

        // A lag matches the probe only if it matches the probe's loudest samples, which rules out
        // nearly every lag after one short comparison.
        let anchor = probe + loudestWindowOffset(in: probe, count: probeLength, window: anchorLength)
        let maximumLag = min(configuration.maximumLag, probeStart)
        guard maximumLag >= configuration.minimumLag else { return nil }

        for lag in configuration.minimumLag...maximumLag {
            var anchorResidual: Float = 0
            vDSP_distancesq(anchor, 1, anchor - lag, 1, &anchorResidual, vDSP_Length(anchorLength))
            guard anchorResidual <= limit else { continue }
            if residual(of: probe, against: probe - lag, count: probeLength, stoppingAbove: limit) <= limit {
                return lag
            }
        }
        return nil
    }

    /// How many of the newest samples in `samples` repeat the samples `lag` before them.
    static func repeatingSampleCount(
        in samples: UnsafeBufferPointer<Float>,
        lag: Int,
        configuration: Configuration = Configuration()
    ) -> Int {
        let blockLength = configuration.blockLength
        guard lag > 0, blockLength > 0, let base = samples.baseAddress else { return 0 }

        var blockEnd = samples.count
        var stretchStart = samples.count
        var matchingBlocks = 0
        var differingBlocks = 0
        var differingInRow = 0
        while blockEnd - blockLength - lag >= 0 {
            let blockStart = blockEnd - blockLength
            let block = base + blockStart
            var difference: Float = 0
            vDSP_distancesq(block, 1, block - lag, 1, &difference, vDSP_Length(blockLength))
            var energy: Float = 0
            vDSP_svesq(block, 1, &energy, vDSP_Length(blockLength))
            let limit = max(
                energy * configuration.relativeResidual,
                configuration.silentResidualMeanSquare * Float(blockLength)
            )
            if difference <= limit {
                matchingBlocks += 1
                differingInRow = 0
                stretchStart = blockStart
            } else {
                differingBlocks += 1
                differingInRow += 1
                if differingInRow > configuration.maximumDifferingBlocksInRow { break }
            }
            blockEnd = blockStart
        }

        // The differing blocks before the stretch's first repeating block are not part of it.
        let differingInStretch = differingBlocks - differingInRow
        let stretchBlocks = matchingBlocks + differingInStretch
        guard matchingBlocks > 0,
              Float(differingInStretch) <= configuration.maximumDifferingBlockShare * Float(stretchBlocks) else {
            return 0
        }
        return samples.count - stretchStart
    }

    private static func loudestWindowOffset(in samples: UnsafePointer<Float>, count: Int, window: Int) -> Int {
        guard count > window else { return 0 }
        var energy: Float = 0
        for index in 0..<window {
            energy += samples[index] * samples[index]
        }
        var loudestEnergy = energy
        var loudestOffset = 0
        for offset in 1...(count - window) {
            let leaving = samples[offset - 1]
            let entering = samples[offset + window - 1]
            energy += entering * entering - leaving * leaving
            if energy > loudestEnergy {
                loudestEnergy = energy
                loudestOffset = offset
            }
        }
        return loudestOffset
    }

    private static func residual(
        of samples: UnsafePointer<Float>,
        against earlier: UnsafePointer<Float>,
        count: Int,
        stoppingAbove limit: Float
    ) -> Float {
        var total: Float = 0
        var offset = 0
        while offset < count {
            let length = min(residualChunkLength, count - offset)
            var chunk: Float = 0
            vDSP_distancesq(samples + offset, 1, earlier + offset, 1, &chunk, vDSP_Length(length))
            total += chunk
            if total > limit { return total }
            offset += length
        }
        return total
    }
}

extension RecorderMicrophoneRepetitionDetector.Configuration {
    /// The same durations for audio at `sampleRate`; the defaults are for 16 kHz.
    init(sampleRate: Double) {
        self.init()
        probeLength = max(1, Int(sampleRate * 0.5))
        minimumLag = max(1, Int(sampleRate * 0.002))
        maximumLag = max(minimumLag, Int(sampleRate * 6))
        blockLength = max(1, Int(sampleRate * 0.05))
    }
}

@MainActor
protocol RecorderMicrophoneIncidentNotifying: AnyObject {
    func notify(_ incident: RecorderMicrophoneIncident)
}

/// Tells the user with a macOS notification: the Recorder page is rarely open during a meeting,
/// and meeting recordings often start on their own.
@MainActor
final class RecorderMicrophoneIncidentNotifier: RecorderMicrophoneIncidentNotifying {
    /// One identifier, so a newer incident replaces the notification of an earlier one.
    static let notificationIdentifier = "recorder-microphone-incident"

    private let presenter = ForegroundPresenter()

    func notify(_ incident: RecorderMicrophoneIncident) {
        let title = incident.notificationTitle
        let body = incident.warningMessage
        let center = UNUserNotificationCenter.current()
        // Without a delegate, macOS drops the notification while TypeWhisper is the active app.
        // The calendar meeting notifications install their own, which shows it too.
        if center.delegate == nil {
            center.delegate = presenter
        }
        Task {
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .denied:
                return
            case .notDetermined:
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
                guard granted else { return }
            default:
                break
            }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            do {
                try await center.add(UNNotificationRequest(
                    identifier: Self.notificationIdentifier,
                    content: content,
                    trigger: nil
                ))
            } catch {
                logger.error("Could not post the Recorder microphone notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
        nonisolated func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification,
            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
        ) {
            completionHandler([.banner, .list, .sound])
        }
    }
}

#if DEBUG
/// Breaks the first microphone capture of a recording on purpose, so the restart can be tried
/// without a device that freezes. In the dev app:
///
///     defaults write com.typewhisper.mac.dev debugRecorderMicrophoneFault repeat   # or: stall
///     defaults write com.typewhisper.mac.dev debugRecorderMicrophoneFaultDelay -float 20
///     defaults delete com.typewhisper.mac.dev debugRecorderMicrophoneFault
///
/// After the delay (seconds of captured audio, 20 by default), `repeat` replays the next 0.37 s
/// over and over, like a frozen looping buffer, and `stall` drops every buffer. The restarted
/// capture works normally.
final class RecorderMicrophoneDebugFault: @unchecked Sendable {
    enum Kind: String {
        case repeatAudio = "repeat"
        case stall
    }

    static let kindKey = "debugRecorderMicrophoneFault"
    static let delayKey = "debugRecorderMicrophoneFaultDelay"
    private static let defaultDelay: TimeInterval = 20
    private static let loopDuration: TimeInterval = 0.37

    let kind: Kind
    private let delay: TimeInterval
    // Touched only from the capture's serial delivery.
    private var deliveredFrames = 0
    private var loop: [Float] = []
    private var loopFrameCount = 0
    private var loopPosition = 0

    init(kind: Kind, delay: TimeInterval) {
        self.kind = kind
        self.delay = delay
    }

    static func configured(in defaults: UserDefaults = .standard) -> RecorderMicrophoneDebugFault? {
        guard let rawKind = defaults.string(forKey: kindKey), let kind = Kind(rawValue: rawKind) else {
            return nil
        }
        let delay = defaults.object(forKey: delayKey) == nil ? defaultDelay : defaults.double(forKey: delayKey)
        logger.warning("Debug microphone fault \(rawKind, privacy: .public) armed after \(delay, privacy: .public)s")
        return RecorderMicrophoneDebugFault(kind: kind, delay: delay)
    }

    /// The buffer to record in place of `buffer`, or nil to drop it.
    func apply(to buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frameCount = Int(buffer.frameLength)
        let delayFrames = Int(delay * buffer.format.sampleRate)
        let firstFrame = deliveredFrames
        deliveredFrames += frameCount
        guard firstFrame + frameCount > delayFrames else { return buffer }

        switch kind {
        case .stall:
            return nil
        case .repeatAudio:
            guard let source = buffer.floatChannelData?[0],
                  let replayed = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
                  let target = replayed.floatChannelData?[0] else { return buffer }
            replayed.frameLength = buffer.frameLength
            if loopFrameCount == 0 {
                loopFrameCount = max(1, Int(Self.loopDuration * buffer.format.sampleRate))
            }
            for index in 0..<frameCount {
                if firstFrame + index < delayFrames || loop.count < loopFrameCount {
                    if firstFrame + index >= delayFrames { loop.append(source[index]) }
                    target[index] = source[index]
                } else {
                    target[index] = loop[loopPosition]
                    loopPosition = (loopPosition + 1) % loopFrameCount
                }
            }
            return replayed
        }
    }
}
#endif
