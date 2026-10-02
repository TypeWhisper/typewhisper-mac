import AVFoundation
import Combine
import Foundation

/// Plays a recording for the speaker workspace: with a speed, only the
/// stretches a `SpeakerPlaybackPlan` allows, or a single excerpt.
@MainActor
final class SpeakerPlaybackController: ObservableObject {
    static let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3]

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var rate: Float = 1

    /// The stretches that play; everything else is jumped over.
    var ranges: [ClosedRange<TimeInterval>] = [] {
        didSet { excerptEnd = nil }
    }

    private var player: AVPlayer?
    private var loadedURL: URL?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var excerptEnd: TimeInterval?

    func load(url: URL) {
        guard loadedURL != url else { return }
        unload()
        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .timeDomain
        let player = AVPlayer(playerItem: item)
        self.player = player
        loadedURL = url

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 20),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.tick(time.seconds)
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.finish()
            }
        }
        Task { [weak self] in
            let seconds = (try? await item.asset.load(.duration))?.seconds ?? 0
            guard let self, self.loadedURL == url else { return }
            self.duration = seconds.isFinite ? max(0, seconds) : 0
        }
    }

    func unload() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        player?.pause()
        player = nil
        loadedURL = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        excerptEnd = nil
    }

    func play() {
        guard let player else { return }
        if let start = SpeakerPlaybackPlan.position(from: currentTime, in: effectiveRanges), start > currentTime {
            seek(to: start)
        } else if !effectiveRanges.isEmpty, SpeakerPlaybackPlan.position(from: currentTime, in: effectiveRanges) == nil {
            seek(to: effectiveRanges[0].lowerBound)
        }
        player.playImmediately(atRate: rate)
        isPlaying = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
        excerptEnd = nil
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    /// Plays from `time`, leaving an excerpt.
    func play(from time: TimeInterval) {
        excerptEnd = nil
        seek(to: time)
        play()
    }

    /// Plays one excerpt and stops at its end, whatever the plan allows.
    func playExcerpt(from start: TimeInterval, until end: TimeInterval) {
        guard let player, end > start else { return }
        seek(to: start)
        excerptEnd = end
        player.playImmediately(atRate: rate)
        isPlaying = true
    }

    func seek(to time: TimeInterval) {
        let target = min(max(0, time), duration > 0 ? duration : time)
        currentTime = target
        player?.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    func skip(by seconds: TimeInterval) {
        excerptEnd = nil
        seek(to: currentTime + seconds)
    }

    func setRate(_ rate: Float) {
        self.rate = rate
        if isPlaying { player?.rate = rate }
    }

    func stepRate(by offset: Int) {
        let index = Self.rates.firstIndex(of: rate) ?? 2
        setRate(Self.rates[min(max(index + offset, 0), Self.rates.count - 1)])
    }

    private var effectiveRanges: [ClosedRange<TimeInterval>] {
        excerptEnd == nil ? ranges : []
    }

    private func tick(_ time: TimeInterval) {
        guard time.isFinite else { return }
        currentTime = time
        guard isPlaying else { return }
        if let excerptEnd {
            if time >= excerptEnd { pause() }
            return
        }
        guard !ranges.isEmpty else { return }
        guard let position = SpeakerPlaybackPlan.position(from: time, in: ranges) else {
            pause()
            return
        }
        if position > time + 0.02 { seek(to: position) }
    }

    private func finish() {
        isPlaying = false
        excerptEnd = nil
        seek(to: 0)
    }
}
