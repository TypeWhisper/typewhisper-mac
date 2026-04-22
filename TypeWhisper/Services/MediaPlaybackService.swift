#if !APPSTORE
import MediaRemoteAdapter
#endif
import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "MediaPlaybackService")

#if !APPSTORE
protocol MediaPlaybackControlling: AnyObject {
    func getPlaybackSnapshot(_ onReceive: @escaping (_ isPlaying: Bool, _ bundleIdentifier: String?) -> Void)
    func play()
    func pause()
}

extension MediaController: MediaPlaybackControlling {
    func getPlaybackSnapshot(_ onReceive: @escaping (_ isPlaying: Bool, _ bundleIdentifier: String?) -> Void) {
        getTrackInfo { trackInfo in
            let playing = (trackInfo?.payload.isPlaying ?? false) || ((trackInfo?.payload.playbackRate ?? 0) > 0)
            onReceive(playing, trackInfo?.payload.bundleIdentifier)
        }
    }
}
#endif

@MainActor
class MediaPlaybackService {
    private var didPause = false

    #if !APPSTORE
    typealias ResumeScheduler = @MainActor (_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> Void

    private let controllerFactory: () -> MediaPlaybackControlling
    private let resumeDelay: TimeInterval
    private let resumeScheduler: ResumeScheduler
    private lazy var mediaController: MediaPlaybackControlling = controllerFactory()
    private var nowPlayingBundleID: String?
    private var trackInfoRequestGeneration = 0
    private var resumeGeneration = 0

    init(
        startListening _: Bool = true,
        controllerFactory: @escaping () -> MediaPlaybackControlling = { MediaController() }
    ) {
        self.controllerFactory = controllerFactory
        self.resumeDelay = 0.6
        self.resumeScheduler = Self.defaultResumeScheduler
    }

    init(
        startListening _: Bool = true,
        resumeDelay: TimeInterval,
        resumeScheduler: @escaping ResumeScheduler,
        controllerFactory: @escaping () -> MediaPlaybackControlling = { MediaController() }
    ) {
        self.controllerFactory = controllerFactory
        self.resumeDelay = resumeDelay
        self.resumeScheduler = resumeScheduler
    }

    /// Uses a one-shot status probe to avoid keeping MediaRemote listener processes
    /// alive while TypeWhisper is idle in the menu bar.
    func pauseIfPlaying() {
        cancelPendingResume()
        guard !didPause else { return }
        trackInfoRequestGeneration += 1
        let generation = trackInfoRequestGeneration

        mediaController.getPlaybackSnapshot { [weak self] isPlaying, bundleIdentifier in
            guard let self else { return }
            guard generation == self.trackInfoRequestGeneration else { return }
            guard isPlaying else {
                logger.info("No media playing, skipping pause")
                return
            }

            self.nowPlayingBundleID = bundleIdentifier
            self.mediaController.pause()
            self.didPause = true
            logger.info("Media paused (nowPlaying: \(self.nowPlayingBundleID ?? "unknown"))")
        }
    }

    /// Resumes playback only if we previously paused it.
    func resumeIfWePaused() {
        trackInfoRequestGeneration += 1
        guard didPause else { return }
        cancelPendingResume()
        let generation = resumeGeneration

        resumeScheduler(resumeDelay) { [weak self] in
            guard let self else { return }
            guard generation == self.resumeGeneration else { return }
            guard self.didPause else { return }

            self.mediaController.play()
            self.didPause = false
            logger.info("Media playback resumed")
        }

        logger.info("Scheduled media playback resume in \(self.resumeDelay, privacy: .public)s")
    }

    private func cancelPendingResume() {
        resumeGeneration += 1
    }

    private static let defaultResumeScheduler: ResumeScheduler = { delay, action in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            Task { @MainActor in
                action()
            }
        }
    }
    #else
    init(startListening: Bool = true) {}
    func pauseIfPlaying() {}
    func resumeIfWePaused() {}
    #endif
}
