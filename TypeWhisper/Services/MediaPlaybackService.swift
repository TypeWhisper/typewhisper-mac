#if !APPSTORE
import MediaRemoteAdapter
#endif
import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "MediaPlaybackService")

@MainActor
class MediaPlaybackService {
    private var didPause = false

    #if !APPSTORE
    private var mediaController: MediaController?
    private var isMediaPlaying = false
    private var nowPlayingBundleID: String?
    private(set) var isListening = false

    init(startListening: Bool = true) {
        guard startListening else { return }
        setListeningEnabled(true)
    }

    func setListeningEnabled(_ enabled: Bool) {
        if enabled {
            guard !isListening else { return }

            let mediaController = MediaController()
            mediaController.onTrackInfoReceived = { [weak self] trackInfo in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let info = trackInfo {
                        let playing = info.payload.isPlaying ?? false
                        let rate = info.payload.playbackRate ?? 0
                        self.isMediaPlaying = playing || rate > 0
                        self.nowPlayingBundleID = info.payload.bundleIdentifier
                    } else {
                        self.isMediaPlaying = false
                        self.nowPlayingBundleID = nil
                    }
                }
            }
            mediaController.startListening()
            self.mediaController = mediaController
            self.isListening = true
            logger.info("MediaRemoteAdapter listener started")
            return
        }

        guard isListening else { return }
        mediaController?.stopListening()
        mediaController = nil
        isListening = false
        isMediaPlaying = false
        nowPlayingBundleID = nil
        logger.info("MediaRemoteAdapter listener stopped")
    }

    /// Pauses media playback only if something is actually playing.
    func pauseIfPlaying() {
        guard !didPause else { return }
        guard let mediaController else { return }

        guard isMediaPlaying else {
            logger.info("No media playing, skipping pause")
            return
        }

        mediaController.pause()
        didPause = true
        logger.info("Media paused (nowPlaying: \(self.nowPlayingBundleID ?? "unknown"))")
    }

    /// Resumes playback only if we previously paused it.
    func resumeIfWePaused() {
        guard didPause else { return }
        guard let mediaController else { return }
        mediaController.play()
        didPause = false
        logger.info("Media playback resumed")
    }
    #else
    init(startListening: Bool = true) {}
    func setListeningEnabled(_ enabled: Bool) {}
    func pauseIfPlaying() {}
    func resumeIfWePaused() {}
    #endif
}
