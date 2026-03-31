import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "MediaPlaybackService")

@MainActor
class MediaPlaybackService {
    private var didPause = false

    #if !APPSTORE
    private let sendCommand: (@convention(c) (Int, CFDictionary?) -> Bool)?

    init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
        if let handle, let sym = dlsym(handle, "MRMediaRemoteSendCommand") {
            sendCommand = unsafeBitCast(sym, to: (@convention(c) (Int, CFDictionary?) -> Bool).self)
        } else {
            sendCommand = nil
            logger.info("MediaRemote framework not available - media pause disabled")
        }
    }

    /// Pauses media playback. kMRPause (1) is an explicit pause - safe to send even if nothing plays.
    /// Note: All MediaRemote query APIs (isPlaying, NowPlayingInfo) return empty/false inside signed
    /// apps, so we send pause unconditionally and always resume. This means manually-paused media
    /// will be resumed after recording - an acceptable trade-off since the command APIs are the only
    /// ones that work.
    func pauseIfPlaying() {
        guard !didPause, let sendCommand else { return }
        let result = sendCommand(1, nil)
        didPause = result
        logger.info("Media pause sent, result=\(result)")
    }

    /// Resumes playback only if we previously paused it.
    func resumeIfWePaused() {
        guard didPause, let sendCommand else { return }
        _ = sendCommand(0, nil)
        didPause = false
        logger.info("Media playback resumed")
    }
    #else
    init() {}
    func pauseIfPlaying() {}
    func resumeIfWePaused() {}
    #endif
}
