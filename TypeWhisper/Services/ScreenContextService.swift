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
    /// Upper bound for the text handed to the LLM, so a dense window cannot blow up the prompt.
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
            return text.isEmpty ? nil : String(text.prefix(maxCharacters))
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
