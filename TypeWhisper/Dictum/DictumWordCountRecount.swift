import Foundation
import os.log

private let recountLogger = Logger(subsystem: AppConstants.loggerSubsystem, category: "DictumWordCountRecount")

/// 存量记录的字数重算。顺序固定：内存重算 → 用量统计套用变化量并写入记录键 → 保存历史库 → 写入启动标记。
/// 任何一步中断，下次启动都能接上：
/// - 用量统计保存失败：历史库没有保存，下次重新计算并套用。
/// - 用量统计已保存、历史库未保存：下次重新计算，记录键已存在，只保存历史库。
/// - 历史库已保存、标记未写入：下次没有差异，只写入标记。
@MainActor
enum DictumWordCountRecount {
    static func runIfPending(
        history: HistoryService,
        usageStatistics: UsageStatisticsService,
        calendar: Calendar = .current
    ) {
        guard history.wordCountRecountPending else { return }
        do {
            let deltas = try history.recountWords(calendar: calendar)
            guard usageStatistics.adjustWords(byDay: deltas, recountKey: history.wordCountRecountStatisticsKey) else {
                history.discardWordCountRecount()
                return
            }
            try history.commitWordCountRecount()
            history.markWordCountRecountCompleted()
        } catch {
            history.discardWordCountRecount()
            recountLogger.error("History word recount failed: \(error.localizedDescription)")
        }
    }
}
