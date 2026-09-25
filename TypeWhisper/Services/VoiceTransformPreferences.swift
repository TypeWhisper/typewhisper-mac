import AppKit
import Foundation

/// Local transform preferences. Provider-specific byte/token bounds still apply.
struct VoiceTransformLimits: Equatable {
    static let instructionRange = 100...20_000
    static let sourceRange = 100...100_000
    static let resultRange = 100...100_000
    static let recordingRange = 10...300

    var instructionCharacters: Int
    var sourceCharacters: Int
    var resultCharacters: Int
    var recordingSeconds: Int

    init(instructionCharacters: Int = 2_000, sourceCharacters: Int = 12_000,
         resultCharacters: Int = 24_000, recordingSeconds: Int = 60) {
        self.instructionCharacters = Self.clamp(instructionCharacters, to: Self.instructionRange)
        self.sourceCharacters = Self.clamp(sourceCharacters, to: Self.sourceRange)
        self.resultCharacters = Self.clamp(resultCharacters, to: Self.resultRange)
        self.recordingSeconds = Self.clamp(recordingSeconds, to: Self.recordingRange)
    }

    static func clamp(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(range.upperBound, max(range.lowerBound, value))
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(
            instructionCharacters: defaults.object(forKey: UserDefaultsKeys.transformInstructionLimit) as? Int ?? 2_000,
            sourceCharacters: defaults.object(forKey: UserDefaultsKeys.transformSourceLimit) as? Int ?? 12_000,
            resultCharacters: defaults.object(forKey: UserDefaultsKeys.transformResultLimit) as? Int ?? 24_000,
            recordingSeconds: defaults.object(forKey: UserDefaultsKeys.transformRecordingLimit) as? Int ?? 60
        )
    }
}

enum VoiceTransformWindowPreferences {
    static let defaultReviewSize = NSSize(width: 560, height: 400)
    static let resetNotification = Notification.Name("VoiceTransformWindowSizeReset")

    static func startsCompact(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: UserDefaultsKeys.transformStartCompact) as? Bool ?? true
    }

    static func remembersSize(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: UserDefaultsKeys.transformRememberReviewSize) as? Bool ?? true
    }

    static func reviewSize(_ defaults: UserDefaults) -> NSSize {
        guard remembersSize(defaults) else { return defaultReviewSize }
        let width = defaults.double(forKey: UserDefaultsKeys.transformReviewWidth)
        let height = defaults.double(forKey: UserDefaultsKeys.transformReviewHeight)
        guard width.isFinite, height.isFinite, width >= 380, height >= 280 else { return defaultReviewSize }
        return NSSize(width: min(width, 2400), height: min(height, 1800))
    }

    static func saveReviewSize(_ size: NSSize, to defaults: UserDefaults) {
        guard remembersSize(defaults), size.width.isFinite, size.height.isFinite else { return }
        defaults.set(min(2400, max(380, size.width)), forKey: UserDefaultsKeys.transformReviewWidth)
        defaults.set(min(1800, max(280, size.height)), forKey: UserDefaultsKeys.transformReviewHeight)
    }

    static func resetSize(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: UserDefaultsKeys.transformReviewWidth)
        defaults.removeObject(forKey: UserDefaultsKeys.transformReviewHeight)
        NotificationCenter.default.post(name: resetNotification, object: defaults)
    }

    @MainActor
    static func size(for state: VoiceTransformCoordinator.State, defaults: UserDefaults) -> NSSize {
        switch state {
        case .preview, .applying: reviewSize(defaults)
        case .failed: NSSize(width: 460, height: 300)
        default: startsCompact(defaults) ? NSSize(width: 420, height: 180) : reviewSize(defaults)
        }
    }
}

extension UserDefaultsKeys {
    // MARK: - Voice Transform
    static let transformStartCompact = "transformStartCompact"
    static let transformRememberReviewSize = "transformRememberReviewSize"
    static let transformReviewWidth = "transformReviewWidth"
    static let transformReviewHeight = "transformReviewHeight"
    static let transformInstructionLimit = "transformInstructionLimit"
    static let transformSourceLimit = "transformSourceLimit"
    static let transformResultLimit = "transformResultLimit"
    static let transformRecordingLimit = "transformRecordingLimit"

    static let voiceTransformHotkey = "voiceTransformHotkey"
    static let voiceTransformHotkeys = "voiceTransformHotkeys"
}
