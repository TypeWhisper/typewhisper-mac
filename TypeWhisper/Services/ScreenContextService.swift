import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision
import os.log

private let screenContextLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper",
    category: "ScreenContextService"
)

/// Reads the text of the target app's front window for workflows that opt in to
/// screen context. The window image is recognized on-device with Vision and
/// discarded right away; only the recognized text is returned.
enum ScreenContextService {
    /// Upper bound for the screen text in the LLM prompt, so a dense window cannot blow up the prompt.
    static let maxCharacters = 6_000

    static var hasPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Shows the macOS Screen Recording prompt the first time; afterwards macOS only
    /// lists TypeWhisper in System Settings.
    @discardableResult
    static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    @MainActor private static var didRequestPermissionThisLaunch = false

    /// Asks for Screen Recording at most once per launch, so saving several workflows
    /// or relaunching with a denied permission does not keep prompting.
    @MainActor
    static func requestPermissionIfNeeded() {
        guard !didRequestPermissionThisLaunch, !hasPermission else { return }
        didRequestPermissionThisLaunch = true
        requestPermission()
    }

    static func openPermissionSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Returns the recognized text of the frontmost window of `bundleIdentifier`,
    /// or nil without permission, without a matching window, or without text.
    static func captureFrontWindowText(bundleIdentifier: String?) async -> String? {
        guard hasPermission else {
            screenContextLogger.info("Screen context skipped: no Screen Recording permission")
            return nil
        }
        guard let processID = targetProcessID(bundleIdentifier: bundleIdentifier),
              let windowID = frontWindowID(processID: processID) else {
            screenContextLogger.info("Screen context skipped: no window for the target app")
            return nil
        }

        let start = CFAbsoluteTimeGetCurrent()
        do {
            guard let image = try await captureWindow(windowID: windowID) else {
                screenContextLogger.info("Screen context skipped: window not shareable")
                return nil
            }
            let text = try await recognizeText(in: image)
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
            screenContextLogger.info(
                "Screen context captured: \(text.count, privacy: .public) chars in \(String(format: "%.0f", elapsedMs), privacy: .public)ms"
            )
            // The full text stays available for spelling hints; the prompt gets `promptExcerpt`.
            return text.isEmpty ? nil : text
        } catch {
            screenContextLogger.error("Screen context capture failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func targetProcessID(bundleIdentifier: String?) -> pid_t? {
        // Never read TypeWhisper's own windows, for example when dictation starts in Settings.
        if let bundleIdentifier, bundleIdentifier == Bundle.main.bundleIdentifier {
            return nil
        }
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           bundleIdentifier == nil || frontmost.bundleIdentifier == bundleIdentifier,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            return frontmost.processIdentifier
        }
        guard let bundleIdentifier else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first?.processIdentifier
    }

    /// The window list is ordered front to back, so the first normal-layer window
    /// of the process is the one the user is looking at.
    private static func frontWindowID(processID: pid_t) -> CGWindowID? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == processID,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let number = window[kCGWindowNumber as String] as? CGWindowID else { continue }
            if let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
               (bounds["Width"] ?? 0) < 100 || (bounds["Height"] ?? 0) < 100 {
                continue
            }
            return number
        }
        return nil
    }

    private static func captureWindow(windowID: CGWindowID) async throws -> CGImage? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else { return nil }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = max(1, Int(filter.contentRect.width * scale))
        configuration.height = max(1, Int(filter.contentRect.height * scale))
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    private static func recognizeText(in image: CGImage) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            try VNImageRequestHandler(cgImage: image).perform([request])
            let observations = request.results ?? []
            return observations
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
}

// MARK: - Prompt text

extension ScreenContextService {
    /// `text` cut to `limit` characters for the prompt. A longer text keeps its start and
    /// its end: Vision returns a window block by block, left column first, so the panes on
    /// the right and at the bottom, such as a chat popup or the message being answered,
    /// come last and a plain prefix dropped them.
    static func promptExcerpt(_ text: String, limit: Int = maxCharacters) -> String {
        guard text.count > limit else { return text }
        let half = limit / 2
        var head = text.prefix(half)
        if let lineEnd = head.lastIndex(of: "\n") {
            head = head[..<lineEnd]
        }
        var tail = text.suffix(half)
        if let lineStart = tail.firstIndex(of: "\n") {
            tail = tail[tail.index(after: lineStart)...]
        }
        return String(head) + "\n…\n" + String(tail)
    }

    /// A dictated name and the different spelling of it on screen.
    struct SpellingHint: Equatable {
        let dictated: String
        let screen: String
    }

    static let maxSpellingHints = 8

    /// Pairs dictated names with a name on screen that sounds the same but is spelled
    /// differently. Speech recognition writes the common spelling of a name it hears, so
    /// "Lynda" on screen arrives as "Linda". Language models tend to keep such a valid name
    /// even with the screen text in the prompt, but they follow an explicit pair.
    ///
    /// They follow it even where the word is no name ("Mark my words" with "Marc" on
    /// screen), so the match is strict: only capitalized dictated words that do not start
    /// a sentence count, because there speech recognition capitalizes names and not
    /// ordinary words. The screen word must be capitalized as well, sound the same and
    /// differ by a few letters, the dictated spelling must not appear on screen, and the
    /// screen must offer only one such spelling.
    static func spellingHints(dictation: String, screenText: String) -> [SpellingHint] {
        let screenWords = words(in: screenText)
        let screenSpellings = Set(screenWords.map { $0.text.lowercased() })
        var namesByKey: [String: [String]] = [:]
        for word in screenWords where isNameCandidate(word.text) {
            let key = soundKey(word.text)
            if !(namesByKey[key] ?? []).contains(where: { $0.lowercased() == word.text.lowercased() }) {
                namesByKey[key, default: []].append(word.text)
            }
        }
        guard !namesByKey.isEmpty else { return [] }

        var hints: [SpellingHint] = []
        var seen = Set<String>()
        for word in words(in: dictation) where !word.startsSentence && isNameCandidate(word.text) {
            let dictated = word.text.lowercased()
            guard !screenSpellings.contains(dictated), seen.insert(dictated).inserted else { continue }
            let matches = (namesByKey[soundKey(word.text)] ?? []).filter { name in
                let spelled = name.lowercased()
                return editDistance(dictated, spelled) <= (max(dictated.count, spelled.count) > 6 ? 3 : 2)
            }
            guard matches.count == 1 else { continue }
            hints.append(SpellingHint(dictated: word.text, screen: matches[0]))
            if hints.count == maxSpellingHints { break }
        }
        return hints
    }

    private static func isNameCandidate(_ word: String) -> Bool {
        word.count >= 3 && word.first?.isUppercase == true
    }

    /// The words of `text`, each marked when it starts a sentence or a line.
    private static func words(in text: String) -> [(text: String, startsSentence: Bool)] {
        let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr"]
        var result: [(text: String, startsSentence: Bool)] = []
        var startsSentence = true
        var current = ""
        for character in text + " " {
            if character.isLetter {
                current.append(character)
                continue
            }
            if !current.isEmpty {
                result.append((current, startsSentence))
                startsSentence = false
            }
            if character.isNewline || ".!?…".contains(character),
               !(character == "." && abbreviations.contains(current.lowercased())) {
                startsSentence = true
            }
            current = ""
        }
        return result
    }

    /// A rough sound key for names: "Linda" and "Lynda" give "landa", "John" and "Jon"
    /// give "jan", "Steven" and "Stephen" give "stafan", "Meier" and "Mayer" give "mar".
    static func soundKey(_ word: String) -> String {
        var spelled = String(
            word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .lowercased()
                .filter { ("a"..."z").contains($0) }
        )
        if spelled.hasPrefix("kn") || spelled.hasPrefix("wr") {
            spelled.removeFirst()
        }
        for (pattern, sound) in [
            ("ph", "f"), ("ch", "k"), ("ck", "k"), ("sh", "S"), ("th", "t"), ("wh", "w"),
            ("dg", "j"), ("qu", "kw"), ("q", "k"), ("x", "ks"), ("z", "s"), ("v", "f"),
        ] {
            spelled = spelled.replacingOccurrences(of: pattern, with: sound)
        }
        // A final silent e: "Clare" sounds like "Clair".
        if spelled.count > 3, spelled.hasSuffix("e"), !"aeiouy".contains(spelled.dropLast().last ?? "a") {
            spelled.removeLast()
        }

        let letters = Array(spelled)
        var key = ""
        for (index, letter) in letters.enumerated() {
            let softens = index + 1 < letters.count && "eiy".contains(letters[index + 1])
            let sound: Character? = switch letter {
            case "c": softens ? "s" : "k"
            case "g": softens ? "j" : "g"
            case "h": index == 0 ? "h" : nil
            case "a", "e", "i", "o", "u", "y": "a"
            default: letter
            }
            if let sound, key.last != sound {
                key.append(sound)
            }
        }
        return key
    }

    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let lhs = Array(lhs), rhs = Array(rhs)
        var previous = Array(0...rhs.count)
        for (i, left) in lhs.enumerated() {
            var current = [i + 1]
            for (j, right) in rhs.enumerated() {
                current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (left == right ? 0 : 1)))
            }
            previous = current
        }
        return previous[rhs.count]
    }
}
