import Foundation
import os

/// Fixed-capacity, in-memory ring of the most recent mono samples. It backs the opt-in
/// microphone pre-roll: while the input is armed between dictations, converted audio lands
/// here and nowhere else, and the oldest samples are overwritten once it is full. The next
/// dictation takes the contents with `drain()` and prepends them to the recording.
final class MicrophonePrerollRingBuffer: @unchecked Sendable {
    private struct State {
        var storage: [Float]
        /// Index of the next write; also the index of the oldest sample once the ring is full.
        var writeIndex = 0
        var count = 0
    }

    let capacity: Int
    private let state: OSAllocatedUnfairLock<State>

    init(capacity: Int) {
        let capacity = max(1, capacity)
        self.capacity = capacity
        state = OSAllocatedUnfairLock(initialState: State(storage: [Float](repeating: 0, count: capacity)))
    }

    convenience init(duration: TimeInterval, sampleRate: Double) {
        self.init(capacity: Int((duration * sampleRate).rounded()))
    }

    var count: Int {
        state.withLock { $0.count }
    }

    var isEmpty: Bool {
        count == 0
    }

    /// Appends `samples`, dropping the oldest samples when the ring would overflow.
    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        state.withLock { state in
            let capacity = state.storage.count
            // Only the newest `capacity` samples can survive, so skip the rest up front.
            let incoming = samples.count > capacity ? samples[(samples.count - capacity)...] : samples[...]
            let writeIndex = state.writeIndex
            let firstChunk = min(incoming.count, capacity - writeIndex)
            state.storage.replaceSubrange(writeIndex..<(writeIndex + firstChunk), with: incoming.prefix(firstChunk))
            let secondChunk = incoming.count - firstChunk
            if secondChunk > 0 {
                state.storage.replaceSubrange(0..<secondChunk, with: incoming.dropFirst(firstChunk))
            }
            state.writeIndex = (writeIndex + incoming.count) % capacity
            state.count = min(capacity, state.count + incoming.count)
        }
    }

    /// Returns the contents oldest first and empties the ring.
    func drain() -> [Float] {
        state.withLock { state in
            let samples = Self.orderedSamples(of: state)
            state.writeIndex = 0
            state.count = 0
            return samples
        }
    }

    /// Returns the contents oldest first without emptying the ring.
    func snapshot() -> [Float] {
        state.withLock { Self.orderedSamples(of: $0) }
    }

    /// Drops all contents.
    func reset() {
        state.withLock { state in
            state.writeIndex = 0
            state.count = 0
        }
    }

    private static func orderedSamples(of state: State) -> [Float] {
        guard state.count > 0 else { return [] }
        let capacity = state.storage.count
        let start = (state.writeIndex - state.count + capacity) % capacity
        if start + state.count <= capacity {
            return Array(state.storage[start..<(start + state.count)])
        }
        return Array(state.storage[start..<capacity]) + Array(state.storage[0..<(start + state.count - capacity)])
    }
}
