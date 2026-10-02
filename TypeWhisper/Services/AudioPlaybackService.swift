import Foundation
import AVFoundation
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "AudioPlaybackService")

@MainActor
final class AudioPlaybackService: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying: Bool = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var progressTimer: Timer?

    func play(url: URL) {
        stop()

        do {
            let audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer.delegate = self
            self.player = audioPlayer
            self.duration = audioPlayer.duration
            audioPlayer.play()
            isPlaying = true
            startProgressTimer()
        } catch {
            logger.error("Failed to play audio: \(error.localizedDescription)")
        }
    }

    /// Starts playback at `time`, keeping an already loaded file.
    func play(url: URL, from time: TimeInterval) {
        if player?.url != url {
            play(url: url)
        } else if !isPlaying {
            resume()
        }
        seek(to: min(max(time, 0), duration))
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopProgressTimer()
    }

    func resume() {
        player?.play()
        isPlaying = true
        startProgressTimer()
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        stopProgressTimer()
    }

    func seek(to time: TimeInterval) {
        player?.currentTime = time
        currentTime = time
    }

    func togglePlayPause(url: URL) {
        if isPlaying {
            pause()
        } else if player != nil {
            resume()
        } else {
            play(url: url)
        }
    }

    // MARK: - AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.isPlaying = false
            self.currentTime = 0
            self.stopProgressTimer()
        }
    }

    // MARK: - Progress Timer

    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.currentTime = self.player?.currentTime ?? 0
            }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }
}
