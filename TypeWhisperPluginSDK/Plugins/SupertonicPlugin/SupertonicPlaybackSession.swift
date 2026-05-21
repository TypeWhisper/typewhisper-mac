import AVFoundation
import Foundation
import TypeWhisperPluginSDK
import os

final class SupertonicPlaybackSession: TTSPlaybackSession, @unchecked Sendable {
    private struct State {
        var isActive = true
        var onFinish: (@Sendable () -> Void)?
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let state = OSAllocatedUnfairLock(initialState: State())

    var isActive: Bool {
        state.withLock { $0.isActive }
    }

    var onFinish: (@Sendable () -> Void)? {
        get { state.withLock { $0.onFinish } }
        set {
            let shouldNotify = state.withLock { state in
                state.onFinish = newValue
                return !state.isActive
            }
            if shouldNotify {
                newValue?()
            }
        }
    }

    init(samples: [Float], sampleRate: Int) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw SupertonicPluginError.playbackUnavailable
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channel = buffer.floatChannelData?[0] else {
            throw SupertonicPluginError.playbackUnavailable
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        for index in samples.indices {
            channel[index] = max(-1, min(1, samples[index]))
        }

        try engine.start()
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.finish()
        }
        player.play()
    }

    func stop() {
        let wasActive = state.withLock { state -> Bool in
            guard state.isActive else { return false }
            state.isActive = false
            return true
        }
        guard wasActive else { return }

        player.stop()
        engine.stop()
        engine.detach(player)
        onFinish?()
    }

    private func finish() {
        let callback = state.withLock { state -> (@Sendable () -> Void)? in
            guard state.isActive else { return nil }
            state.isActive = false
            return state.onFinish
        }
        callback?()
    }
}
