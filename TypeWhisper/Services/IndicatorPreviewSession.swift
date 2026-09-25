import AppKit
import Combine
import Foundation

/// Drives the real indicator panels with a synthetic recording while the
/// Appearance settings page is open, so every change shows up in the actual
/// rendering on screen instead of a mock. A real dictation or recorder session
/// always wins; the preview only fills in while both are idle.
@MainActor
final class IndicatorPreviewSession: ObservableObject {
    static let shared = IndicatorPreviewSession()

    @Published private(set) var isActive = false
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var partialText = ""

    nonisolated static let tickInterval: TimeInterval = 1.0 / 30.0
    nonisolated static let wordInterval: TimeInterval = 0.35
    nonisolated static let holdDuration: TimeInterval = 5

    let activeRuleName = localizedAppText("Polish Dictation", de: "Diktat glätten")
    let sampleText = String(localized: "Hello, this is a live preview of the streaming text...")

    var appIcon: NSImage? {
        NSApp?.applicationIconImage
    }

    private var timer: Timer?
    private var startedAt: Date?
    private var windowCloseObserver: NSObjectProtocol?

    func start() {
        guard !isActive else { return }
        isActive = true
        startedAt = Date()
        // Safety net: the preview must never outlive the Settings window.
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow,
                  window.identifier?.rawValue.lowercased().contains("settings") == true else { return }
            Task { @MainActor in self?.stop() }
        }
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
        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
            self.windowCloseObserver = nil
        }
        startedAt = nil
        isActive = false
        recordingDuration = 0
        audioLevel = 0
        partialText = ""
    }

    private func tick() {
        guard let startedAt else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
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

    /// Reveals the sample sentence word by word, holds it, then starts over so
    /// the expand animation can be seen again.
    nonisolated static func transcript(at time: TimeInterval, text: String) -> String {
        let words = text.split(separator: " ")
        guard !words.isEmpty else { return "" }
        let cycle = Double(words.count) * wordInterval + holdDuration
        let elapsed = time.truncatingRemainder(dividingBy: cycle)
        let shown = min(words.count, Int(elapsed / wordInterval))
        return words.prefix(shown).joined(separator: " ")
    }
}
