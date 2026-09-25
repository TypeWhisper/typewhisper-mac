import AppKit
import Combine
import Foundation

/// Drives the real indicator panels with a synthetic recording while the
/// Appearance settings page is open, so every change shows up in the actual
/// rendering on screen instead of a mock. A real dictation or recorder session
/// always wins; the preview only fills in while both are idle.
@MainActor
final class IndicatorPreviewSession: NSObject, ObservableObject {
    static let shared = IndicatorPreviewSession()

    @Published private(set) var isActive = false
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var partialText = ""

    nonisolated static let tickInterval: TimeInterval = 1.0 / 30.0
    nonisolated static let wordInterval: TimeInterval = 0.35
    nonisolated static let characterInterval: TimeInterval = 0.12
    nonisolated static let holdDuration: TimeInterval = 5

    let activeRuleName = localizedAppText("Polish Dictation", de: "Diktat glätten")
    let sampleText = String(localized: "Hello, this is a live preview of the streaming text...")

    var appIcon: NSImage? {
        NSApp?.applicationIconImage
    }

    private var timer: Timer?
    /// Monotonic start time so wall-clock adjustments cannot run the preview backwards.
    private var startedAt: TimeInterval?

    func start() {
        guard !isActive else { return }
        isActive = true
        startedAt = ProcessInfo.processInfo.systemUptime
        // Safety net: the preview must never outlive the Settings window.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func stop() {
        guard isActive else { return }
        timer?.invalidate()
        timer = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
        startedAt = nil
        isActive = false
        recordingDuration = 0
        audioLevel = 0
        partialText = ""
    }

    /// Window notifications are posted on the main thread.
    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.identifier?.rawValue.lowercased().contains("settings") == true else { return }
        stop()
    }

    private func tick() {
        guard let startedAt else { return }
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - startedAt)
        recordingDuration = elapsed
        audioLevel = Self.level(at: elapsed)
        partialText = Self.transcript(at: elapsed, text: sampleText)
    }

    /// Speech-like envelope: phrases of about two seconds with short pauses.
    nonisolated static func level(at time: TimeInterval) -> Float {
        let phrase = time.truncatingRemainder(dividingBy: 2.6)
        guard phrase < 2.0 else { return 0.02 }
        let syllables = 0.55 + 0.45 * sin(time * 9.1) * sin(time * 3.7)
        return Float(min(1, max(0.05, 0.3 + 0.45 * syllables)))
    }

    /// Reveals the sample sentence unit by unit, holds it, then starts over so
    /// the expand animation can be seen again. Negative times count as zero.
    nonisolated static func transcript(at time: TimeInterval, text: String) -> String {
        let reveal = revealUnits(of: text)
        guard !reveal.units.isEmpty else { return "" }
        let cycle = Double(reveal.units.count) * reveal.interval + holdDuration
        let elapsed = max(0, time).truncatingRemainder(dividingBy: cycle)
        let shown = min(reveal.units.count, max(0, Int(elapsed / reveal.interval)))
        return reveal.units.prefix(shown).joined(separator: reveal.separator)
    }

    /// Words for languages that separate them with spaces, otherwise single
    /// characters so the Japanese and Chinese samples still unfold gradually.
    nonisolated static func revealUnits(of text: String) -> (units: [String], separator: String, interval: TimeInterval) {
        if text.contains(" ") {
            return (text.split(separator: " ").map(String.init), " ", wordInterval)
        }
        return (text.map { String($0) }, "", characterInterval)
    }
}
