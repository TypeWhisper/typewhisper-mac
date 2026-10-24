import Foundation

enum HistoryRecordFilter: Int, CaseIterable {
    case all, dictation, translation

    func includes(_ record: TranscriptionRecord) -> Bool {
        switch self {
        case .all: true
        case .dictation: record.mode == .dictation
        case .translation: record.mode == .translation
        }
    }
}
