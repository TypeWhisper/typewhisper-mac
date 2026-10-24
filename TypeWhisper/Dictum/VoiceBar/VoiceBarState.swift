import Foundation

enum VoiceBarState: Equatable {
    case idle
    case preparing
    case listening
    case listeningWithText
    case translating
    case targetMenu
    case polishing(translating: Bool)
    case inserted(count: Int)
    case copied
    case recoveredError
    case translationFailed
    case blockingError(String, page: DictumPage)
    case failure(String, destination: Destination?)
    case noSpeech
    case downloading(Double?)
    case notDownloaded
    case modelFailed(String)
    case noAI
    case countdown(seconds: Int)
    case cancelled(remaining: Double)

    /// 限时错误状态里按钮的去向：dictum 的页面，或听写模型记录的高级设置页面和听写恢复。
    enum Destination: Equatable {
        case page(DictumPage)
        case advancedSettings
        case dictationRecovery

        init?(tab: SettingsTab?) {
            switch tab {
            case nil: return nil
            case .general?: self = .page(.general)
            case .dictation?, .installedPlugin?: self = .page(.speech)
            case .dictationRecovery?: self = .dictationRecovery
            default: self = .advancedSettings
            }
        }

        /// 按钮文案在 DictumHome 表里的键。
        var buttonTitleKey: String {
            switch self {
            case .dictationRecovery: "Open Dictation Recovery"
            case .page, .advancedSettings: "Open Settings"
            }
        }
    }

    /// 限时错误的文字行：消息按换行拆开，最多两行（转写失败附带的听写恢复说明在第二行）。
    var failureLines: [String] {
        guard case .failure(let message, _) = self else { return [] }
        return Array(message.split(separator: "\n", omittingEmptySubsequences: true).prefix(2).map(String.init))
    }

    /// 按钮行的高度：两行文字的限时错误比单行高 16pt，其余状态 44pt。
    var rowHeight: CGFloat { failureLines.count > 1 ? 60 : 44 }

    struct Input {
        enum Activity { case idle, preparing, recording, processing }
        enum Outcome {
            case inserted(Int), copied, recoveredError, translationFailed, noSpeech, noAI
            case blockingError(String, page: DictumPage)
            case failure(String, Destination?)
        }
        enum Model { case downloading(Double?), loading, notDownloaded, failed(String) }
        var activity: Activity = .idle
        var outcome: Outcome?
        var model: Model?
        var confirmedText = ""
        var tentativeText = ""
        var translation = false
        var targetMenuOpen = false
        var duration: TimeInterval = 0
        var cancellationRemaining: TimeInterval?
    }

    static func derive(_ input: Input) -> Self {
        if let remaining = input.cancellationRemaining, remaining > 0 {
            return .cancelled(remaining: min(1, remaining / 3))
        }
        if let outcome = input.outcome {
            switch outcome {
            case .inserted(let count): return .inserted(count: count)
            case .copied: return .copied
            case .recoveredError: return .recoveredError
            case .translationFailed: return .translationFailed
            case .blockingError(let message, let page): return .blockingError(message, page: page)
            case .failure(let message, let destination): return .failure(message, destination: destination)
            case .noSpeech: return .noSpeech
            case .noAI: return .noAI
            }
        }
        if let model = input.model {
            switch model {
            case .downloading(let progress): return .downloading(progress)
            case .loading: return .preparing
            case .notDownloaded: return .notDownloaded
            case .failed(let message): return .modelFailed(message)
            }
        }
        switch input.activity {
        case .idle: return .idle
        case .preparing: return .preparing
        case .processing: return .polishing(translating: input.translation)
        case .recording:
            if input.duration >= 480 { return .countdown(seconds: max(0, Int(ceil(540 - input.duration)))) }
            if input.translation { return input.targetMenuOpen ? .targetMenu : .translating }
            return input.confirmedText.isEmpty && input.tentativeText.isEmpty ? .listening : .listeningWithText
        }
    }
}

extension VoiceBarState.Input.Outcome {
    /// 后处理失败而插入原文：翻译会话是翻译失败，听写会话是润色失败。
    static func warning(translation: Bool) -> Self { translation ? .translationFailed : .recoveredError }

    /// 听写模型发布的反馈在语音条上的归类。阻断状态只给麦克风问题（设备错误、缺少麦克风权限，
    /// 后者由听写模型记录的设置页 `.home` 识别），其余错误是限时的错误状态。
    /// 返回 nil 表示不是需要特别归类的反馈，由调用方按插入结果处理。
    static func feedback(icon: String?, message: String, isError: Bool, settingsTab: SettingsTab?, translation: Bool) -> Self? {
        switch icon {
        case "mic.slash", "waveform.badge.exclamationmark": return isError ? .blockingError(message, page: .general) : .noSpeech
        case "exclamationmark.triangle.fill": return .warning(translation: translation)
        case "doc.on.clipboard", "doc.on.doc": return .copied
        default: break
        }
        guard isError else { return nil }
        if settingsTab == .home { return .blockingError(message, page: .home) }
        return .failure(message, VoiceBarState.Destination(tab: settingsTab))
    }
}
