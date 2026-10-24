import AppKit
import os
import TypeWhisperPluginSDK

/// 退出前关闭本地识别门：取消正在运行的识别，等它在当前分段结束后再回复退出请求。
/// 等待期间再次请求退出沿用同一次等待，回复只发出一次。
@MainActor
final class TerminationPreparation {
    private let gate: PluginLocalInferenceGate
    private var isWaiting = false
    private let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "AppLifecycle")

    init(gate: PluginLocalInferenceGate = .shared) {
        self.gate = gate
    }

    func requestTermination(reply: @escaping @MainActor () -> Void) -> NSApplication.TerminateReply {
        guard !isWaiting else {
            logger.notice("Termination request joined the running local inference wait")
            return .terminateLater
        }
        isWaiting = true
        let start = ContinuousClock.now
        Task {
            await gate.close()
            let elapsed = start.duration(to: .now)
            logger.notice(
                "Local inference stopped for termination elapsedMs=\(Int(elapsed / .milliseconds(1)), privacy: .public)"
            )
            reply()
        }
        return .terminateLater
    }
}
