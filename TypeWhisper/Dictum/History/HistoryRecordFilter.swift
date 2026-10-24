import Foundation

enum HistoryRecordFilter: Int, CaseIterable {
    case all, dictation, translation

    func includes(_ record: TranscriptionRecord) -> Bool {
        switch self {
        case .all, .dictation: true
        case .translation: false
        }
    }
}
