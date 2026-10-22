#if DEBUG
@preconcurrency import AVFoundation
import Foundation
import os

enum DictumDebugAudioConfiguration {
    private static let override = OSAllocatedUnfairLock<URL?>(initialState: nil)

    static var fileURL: URL? {
        if let url = override.withLock({ $0 }) { return url }
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--audio-file"), arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: arguments[index + 1])
        }
        return ProcessInfo.processInfo.environment["DICTUM_AUDIO_FILE"].map { URL(fileURLWithPath: $0) }
    }

    static func select(_ url: URL) { override.withLock { $0 = url } }
}

final class DictumAudioFileInput: @unchecked Sendable {
    private let queue: DispatchQueue
    private let file: AVAudioFile
    private let converter: AudioInputSliceConverter
    private var timer: DispatchSourceTimer?
    private let consume: ([Float]) -> Void
    private let completion: (Error?) -> Void

    init(url: URL, queue: DispatchQueue, consume: @escaping ([Float]) -> Void, completion: @escaping (Error?) -> Void) throws {
        self.queue = queue
        file = try AVAudioFile(forReading: url)
        guard file.length > 0,
              let converter = AudioInputSliceConverter(inputFormat: file.processingFormat, targetSampleRate: 16_000) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.converter = converter
        self.consume = consume
        self.completion = completion
    }

    func start() {
        queue.async { [self] in
            let timer = DispatchSource.makeTimerSource(queue: queue)
            self.timer = timer
            timer.setEventHandler { [weak self] in self?.readSlice() }
            timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(1))
            timer.resume()
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    private func readSlice() {
        do {
            let remaining = file.length - file.framePosition
            guard remaining > 0 else { finish(nil); return }
            let frames = AVAudioFrameCount(min(remaining, AVAudioFramePosition(max(1, file.processingFormat.sampleRate * 0.02))))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try file.read(into: buffer, frameCount: frames)
            if buffer.frameLength == 0 {
                finish(nil)
                return
            }
            guard let samples = converter.convert(buffer) else { throw CocoaError(.fileReadCorruptFile) }
            consume(samples)
        } catch {
            finish(error)
        }
    }

    private func finish(_ error: Error?) {
        timer?.cancel()
        timer = nil
        completion(error)
    }
}
#endif
