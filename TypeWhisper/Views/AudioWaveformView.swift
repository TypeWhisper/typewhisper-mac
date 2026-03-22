import SwiftUI

/// Multi-bar audio waveform visualization with setup bounce animation.
struct AudioWaveformView: View {
    let audioLevel: Float
    let isSetup: Bool
    var compact: Bool = false

    private var barCount: Int { compact ? 5 : 8 }
    private var barWidth: CGFloat { compact ? 3 : 3 }
    private var barSpacing: CGFloat { compact ? 2 : 2 }
    private let minHeight: CGFloat = 2
    private var maxHeight: CGFloat { compact ? 16 : 16 }

    @State private var bounceIndex = 0
    @State private var bounceTimer: Timer?

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.primary)
                    .frame(width: barWidth, height: barHeight(for: i))
                    .animation(isSetup ? .easeInOut(duration: 0.3) : nil, value: bounceIndex)
            }
        }
        .frame(height: maxHeight)
        .accessibilityHidden(true)
        .onChange(of: isSetup) { _, newValue in
            if newValue {
                startBounce()
            } else {
                stopBounce()
            }
        }
        .onAppear {
            if isSetup {
                startBounce()
            }
        }
        .onDisappear {
            stopBounce()
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        if isSetup {
            return bounceHeight(for: index)
        }
        return waveformHeight(for: index)
    }

    // MARK: - Waveform (recording)

    private func waveformHeight(for index: Int) -> CGFloat {
        let level = audioLevel
        let phase = Double(index) / Double(barCount) * .pi * 2
        let waveOffset = sin(phase + .pi * 0.75 + Double(level) * 3) * 0.12 + 0.88
        var barLevel = CGFloat(level) * CGFloat(waveOffset)
        // Dampen first bar slightly
        if index == 0 {
            barLevel *= 0.85
        }
        let height = minHeight + barLevel * (maxHeight - minHeight)
        return max(minHeight, min(maxHeight, height))
    }

    // MARK: - Bounce (setup)

    private func bounceHeight(for index: Int) -> CGFloat {
        index == bounceIndex ? 14 : minHeight
    }

    private func startBounce() {
        bounceIndex = 0
        bounceTimer?.invalidate()
        bounceTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { _ in
            Task { @MainActor in
                bounceIndex = (bounceIndex + 1) % barCount
            }
        }
    }

    private func stopBounce() {
        bounceTimer?.invalidate()
        bounceTimer = nil
    }
}
