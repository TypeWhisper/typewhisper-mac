import SwiftUI

/// Bar heights for the audio waveform, in `0...1` per bar.
///
/// The bars follow the audio level with a center-weighted shape and a slow
/// per-bar drift so they keep moving while the level holds. Attack and release
/// smoothing keeps them from jumping between the 30 Hz level updates. During
/// microphone setup a single bar bounces from left to right instead.
struct AudioWaveformBarModel {
    let barCount: Int
    private(set) var heights: [CGFloat]
    private var lastTick: TimeInterval?

    static let attack: Double = 0.04
    static let release: Double = 0.16
    static let bounceInterval: Double = 0.06
    static let bounceHeight: CGFloat = 0.85

    init(barCount: Int) {
        self.barCount = max(1, barCount)
        heights = Array(repeating: 0, count: self.barCount)
    }

    mutating func advance(to now: TimeInterval, level: Float, setup: Bool) -> [CGFloat] {
        let elapsed = lastTick.map { min(0.1, max(0.001, now - $0)) } ?? 1.0 / 60.0
        lastTick = now
        let level = CGFloat(min(1, max(0, level)))
        let bouncingBar = Int((now / Self.bounceInterval).rounded(.down)) % barCount

        for index in 0..<barCount {
            let target: CGFloat
            if setup {
                target = index == bouncingBar ? Self.bounceHeight : 0
            } else {
                target = level * Self.shape(index, count: barCount) * Self.drift(index, at: now)
            }
            let timeConstant = target > heights[index] ? Self.attack : Self.release
            heights[index] += (target - heights[index]) * CGFloat(1 - exp(-elapsed / timeConstant))
        }
        return heights
    }

    /// Bars near the center reach higher than the outer ones.
    static func shape(_ index: Int, count: Int) -> CGFloat {
        guard count > 1 else { return 1 }
        let position = (Double(index) + 0.5) / Double(count)
        return 0.55 + 0.45 * CGFloat(sin(.pi * position))
    }

    /// Slow oscillation with a different rate per bar, in `0.6...1`.
    static func drift(_ index: Int, at now: TimeInterval) -> CGFloat {
        let rate = 2.2 + 0.65 * Double(index)
        let phase = Double(index) * 2.1
        return 0.8 + 0.2 * CGFloat(sin(now * rate + phase))
    }
}

/// Multi-bar audio waveform visualization with setup bounce animation.
struct AudioWaveformView: View {
    let audioLevel: Float
    let isSetup: Bool
    var compact: Bool = false

    private var barCount: Int { compact ? 5 : 8 }
    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 2
    private let maxHeight: CGFloat = 16

    /// Reference holder so the bar model can advance inside the canvas renderer
    /// without publishing view state on every frame.
    private final class ModelBox {
        var model: AudioWaveformBarModel
        init(barCount: Int) { model = AudioWaveformBarModel(barCount: barCount) }
    }

    @State private var box: ModelBox

    init(audioLevel: Float, isSetup: Bool, compact: Bool = false) {
        self.audioLevel = audioLevel
        self.isSetup = isSetup
        self.compact = compact
        _box = State(initialValue: ModelBox(barCount: compact ? 5 : 8))
    }

    private var totalWidth: CGFloat {
        CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
            Canvas { graphics, size in
                let now = context.date.timeIntervalSinceReferenceDate
                let heights = box.model.advance(to: now, level: audioLevel, setup: isSetup)
                for (index, height) in heights.enumerated() {
                    let barHeight = barWidth + (maxHeight - barWidth) * height
                    let rect = CGRect(
                        x: CGFloat(index) * (barWidth + barSpacing),
                        y: (size.height - barHeight) / 2,
                        width: barWidth,
                        height: barHeight
                    )
                    graphics.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .foreground)
                }
            }
        }
        .frame(width: totalWidth, height: maxHeight)
        .accessibilityHidden(true)
    }
}
