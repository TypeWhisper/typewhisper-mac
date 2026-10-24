import Foundation

/// 历史里的翻译记录用记录自己的语言对重新翻译原话，旧译文保存为历史版本。
@MainActor
enum HistoryTranslationRetry {
    enum Failure: Error {
        case notTranslation
        case noModel
        case emptyResult
    }

    static func run(
        record: TranscriptionRecord,
        history: HistoryService,
        processor: any TranslationModelProcessing,
        style: ResolvedStyle,
        level: PolishLevel,
        vocabulary: [String]
    ) async throws {
        guard record.mode == .translation, let target = record.targetLanguage else { throw Failure.notTranslation }
        guard let handler = TranslationHandler.make(
            pair: TranslationPair(spoken: record.spokenLanguage, target: target),
            processor: processor, style: style, level: level, vocabulary: vocabulary,
            app: .init(appName: record.appName, bundleID: record.appBundleIdentifier, browserURL: record.appURL)
        ) else { throw Failure.noModel }
        let translated = try await handler(record.rawText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translated.isEmpty else { throw Failure.emptyResult }
        let expected = HistoryTranscriptionVersion.capture(record)
        var version = expected
        version.id = UUID()
        version.createdAt = Date()
        version.finalText = translated
        version.processingFailureCategory = nil
        version.processingFailureMessage = nil
        try history.appendTranscriptionVersion(version, to: record, expected: expected)
        try history.promoteTranscriptionVersion(version.id, in: record)
    }
}

extension HistoryTranslationRetry.Failure: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notTranslation: String(localized: "This record is not a translation.", table: "DictumTranslation")
        case .noModel: TranslationStrings.noModel
        case .emptyResult: String(localized: "The model returned no translation.", table: "DictumTranslation")
        }
    }
}
