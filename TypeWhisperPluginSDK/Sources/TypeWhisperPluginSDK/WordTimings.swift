import Foundation
import os

// MARK: - Word Timings

/// One spoken word with its time in the transcribed audio.
public struct PluginWordTiming: Sendable, Equatable {
    public let text: String
    public let start: Double
    public let end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// Receives the word timings of one transcription call.
public final class PluginWordTimingCollector: Sendable {
    private let state = OSAllocatedUnfairLock<[PluginWordTiming]>(initialState: [])

    public init() {}

    public var words: [PluginWordTiming] {
        state.withLock { $0 }
    }

    /// Replaces earlier words; the last report of a call is its result.
    public func record(_ words: [PluginWordTiming]) {
        state.withLock { $0 = words }
    }
}

/// Optional capability for transcription engines that know when each word
/// was spoken.
///
/// The existing result types stay as they are: an engine reports its words
/// from inside any `transcribe` call, and the host reads them when it asked
/// for them. Without a host collector the report does nothing, so engines
/// call it unconditionally. The collector is task-local; report from the
/// task that runs `transcribe`, not from a detached task.
public enum PluginWordTimings {
    @TaskLocal public static var collector: PluginWordTimingCollector?

    public static func report(_ words: [PluginWordTiming]) {
        collector?.record(words)
    }
}
