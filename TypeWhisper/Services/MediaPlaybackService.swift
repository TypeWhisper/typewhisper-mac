#if !APPSTORE
import MediaRemoteAdapter
#endif
import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "MediaPlaybackService")

#if !APPSTORE
struct MediaPlaybackSnapshot: Equatable {
    let isApplicationPlaying: Bool?
    let playbackRate: Double?
    let bundleIdentifier: String?
    let trackIdentifier: String?

    init(
        isApplicationPlaying: Bool?,
        playbackRate: Double?,
        bundleIdentifier: String?,
        trackIdentifier: String?
    ) {
        self.isApplicationPlaying = isApplicationPlaying
        self.playbackRate = playbackRate
        self.bundleIdentifier = bundleIdentifier
        self.trackIdentifier = trackIdentifier
    }

    init(
        isApplicationPlaying: Bool?,
        playbackRate: Double?,
        bundleIdentifier: String?,
        title: String?,
        artist: String?,
        album: String?
    ) {
        self.init(
            isApplicationPlaying: isApplicationPlaying,
            playbackRate: playbackRate,
            bundleIdentifier: bundleIdentifier,
            trackIdentifier: Self.trackIdentifier(title: title, artist: artist, album: album)
        )
    }

    var isActivelyPlaying: Bool {
        guard isApplicationPlaying == true else { return false }
        guard let playbackRate else { return true }
        return playbackRate > 0
    }

    var logDescription: String {
        let playingDescription = isApplicationPlaying.map { String(describing: $0) } ?? "nil"
        let playbackRateDescription = playbackRate.map { String(format: "%.3f", $0) } ?? "nil"
        return "bundle=\(bundleIdentifier ?? "unknown"), track=\(trackIdentifier ?? "unknown"), isPlaying=\(playingDescription), playbackRate=\(playbackRateDescription)"
    }

    func matchesMediaContext(of other: MediaPlaybackSnapshot) -> Bool {
        guard bundleIdentifier == other.bundleIdentifier else { return false }
        return trackIdentifier == other.trackIdentifier
    }

    private static func trackIdentifier(title: String?, artist: String?, album: String?) -> String? {
        let parts = [title, artist, album].map { $0?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        guard parts.contains(where: { !$0.isEmpty }) else { return nil }
        return parts.joined(separator: "||")
    }
}

protocol MediaPlaybackControlling: AnyObject {
    func getPlaybackSnapshot(_ onReceive: @escaping (_ snapshot: MediaPlaybackSnapshot?) -> Void)
    func play()
    func pause()
    func togglePlayPause()
}

extension MediaController: MediaPlaybackControlling {
    func getPlaybackSnapshot(_ onReceive: @escaping (_ snapshot: MediaPlaybackSnapshot?) -> Void) {
        getTrackInfo { trackInfo in
            guard let payload = trackInfo?.payload else {
                onReceive(nil)
                return
            }

            onReceive(MediaPlaybackSnapshot(
                isApplicationPlaying: payload.isPlaying,
                playbackRate: payload.playbackRate,
                bundleIdentifier: payload.bundleIdentifier,
                title: payload.title,
                artist: payload.artist,
                album: payload.album
            ))
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
    private let pauseConfirmDelay: TimeInterval
    private let resumeConfirmDelay: TimeInterval
    private let resumeScheduler: ResumeScheduler
    private lazy var mediaController: MediaPlaybackControlling = controllerFactory()
    private var nowPlayingBundleID: String?
    private var pausedSnapshot: MediaPlaybackSnapshot?
    private var trackInfoRequestGeneration = 0
    private var resumeGeneration = 0

    init(
        startListening _: Bool = true,
        controllerFactory: @escaping () -> MediaPlaybackControlling = { MediaController() }
    ) {
        self.controllerFactory = controllerFactory
        self.resumeDelay = 0.6
        self.pauseConfirmDelay = 0.15
        self.resumeConfirmDelay = 0.25
        self.resumeScheduler = Self.defaultResumeScheduler
    }

    init(
        startListening _: Bool = true,
        resumeDelay: TimeInterval,
        pauseConfirmDelay: TimeInterval = 0.15,
        resumeConfirmDelay: TimeInterval = 0.25,
        resumeScheduler: @escaping ResumeScheduler,
        controllerFactory: @escaping () -> MediaPlaybackControlling = { MediaController() }
    ) {
        self.controllerFactory = controllerFactory
        self.resumeDelay = resumeDelay
        self.pauseConfirmDelay = pauseConfirmDelay
        self.resumeConfirmDelay = resumeConfirmDelay
        self.resumeScheduler = resumeScheduler
    }

    /// Uses short status probes to avoid keeping MediaRemote listener processes
    /// alive while TypeWhisper is idle in the menu bar.
    func pauseIfPlaying() {
        cancelPendingResume()
        guard !didPause else { return }
        trackInfoRequestGeneration += 1
        let generation = trackInfoRequestGeneration

        mediaController.getPlaybackSnapshot { [weak self] initialSnapshot in
            guard let self else { return }
            guard generation == self.trackInfoRequestGeneration else { return }
            guard let initialSnapshot, initialSnapshot.isActivelyPlaying else {
                self.logSkippedPause(stage: "initial", snapshot: initialSnapshot)
                return
            }

            self.resumeScheduler(self.pauseConfirmDelay) { [weak self] in
                guard let self else { return }
                guard generation == self.trackInfoRequestGeneration else { return }
                guard !self.didPause else { return }

                self.mediaController.getPlaybackSnapshot { [weak self] confirmedSnapshot in
                    guard let self else { return }
                    guard generation == self.trackInfoRequestGeneration else { return }
                    guard !self.didPause else { return }
                    guard let confirmedSnapshot,
                          confirmedSnapshot.isActivelyPlaying,
                          confirmedSnapshot.matchesMediaContext(of: initialSnapshot) else {
                        self.logSkippedPause(stage: "confirm", snapshot: confirmedSnapshot)
                        return
                    }

                    self.nowPlayingBundleID = confirmedSnapshot.bundleIdentifier
                    self.pausedSnapshot = confirmedSnapshot
                    self.mediaController.pause()
                    self.didPause = true
                    logger.info("Media paused after confirmation (\(confirmedSnapshot.logDescription, privacy: .public))")
                }
            }
        }
    }

    /// Resumes playback only if we previously paused it.
    func resumeIfWePaused() {
        trackInfoRequestGeneration += 1
        guard didPause else { return }
        cancelPendingResume()
        let generation = resumeGeneration
        let snapshotToResume = pausedSnapshot

        resumeScheduler(resumeDelay) { [weak self] in
            guard let self else { return }
            guard generation == self.resumeGeneration else { return }
            guard self.didPause else { return }

            self.mediaController.play()
            logger.info("Media playback resumed")

            guard let snapshotToResume else {
                self.didPause = false
                self.pausedSnapshot = nil
                return
            }
            self.resumeScheduler(self.resumeConfirmDelay) { [weak self] in
                guard let self else { return }
                guard generation == self.resumeGeneration else { return }

                self.mediaController.getPlaybackSnapshot { [weak self] resumedSnapshot in
                    guard let self else { return }
                    guard generation == self.resumeGeneration else { return }

                    defer {
                        self.didPause = false
                        self.pausedSnapshot = nil
                    }

                    guard let resumedSnapshot,
                          resumedSnapshot.matchesMediaContext(of: snapshotToResume),
                          !resumedSnapshot.isActivelyPlaying else {
                        return
                    }

                    self.mediaController.togglePlayPause()
                    logger.info("Media resume fallback toggled playback (\(resumedSnapshot.logDescription, privacy: .public))")
                }
            }
        }

        logger.info("Scheduled media playback resume in \(self.resumeDelay, privacy: .public)s")
    }

    private func cancelPendingResume() {
        resumeGeneration += 1
    }

    private func logSkippedPause(stage: String, snapshot: MediaPlaybackSnapshot?) {
        logger.info("Media pause skipped at \(stage, privacy: .public) probe (\(snapshot?.logDescription ?? "nil", privacy: .public))")
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
