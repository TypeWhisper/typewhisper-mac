import Foundation
import os
import Translation

@MainActor
final class TranslationService: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?
    @Published var viewId = UUID()

    /// Called by AppDelegate to temporarily switch the host window into an
    /// interactive mode when Translation.framework needs user approval/download UI.
    var setInteractiveHostMode: (@MainActor (Bool) -> Void)?

    private var sourceText = ""
    private var continuation: CheckedContinuation<String, Error>?
    private var activeRequestId = "-"
    private static let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "Translation")

    func translate(
        text: String,
        to target: Locale.Language,
        source sourceLanguage: Locale.Language? = nil
    ) async throws -> String {
        let requestId = String(UUID().uuidString.prefix(8))
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else { return text }

        let english = Locale.Language(identifier: "en")
        let sourceId = sourceLanguage?.minimalIdentifier ?? "auto"
        Self.logger.info("Translation[\(requestId)] start \(sourceId) -> \(target.minimalIdentifier), chars=\(normalizedText.count)")

        let directStatus = await availabilityStatus(
            for: normalizedText,
            source: sourceLanguage,
            target: target,
            requestId: requestId
        )

        if directStatus == .unsupported, target.minimalIdentifier != english.minimalIdentifier {
            Self.logger.warning("Translation[\(requestId)] direct \(target.minimalIdentifier) unsupported, trying via English")
            return try await translateViaEnglish(
                requestId: requestId,
                text: normalizedText,
                source: sourceLanguage,
                target: target,
                english: english
            )
        }

        let directResult = try await requestTranslation(
            requestId: requestId,
            text: normalizedText,
            source: sourceLanguage,
            target: target,
            availabilityStatus: directStatus
        )

        // Some language pairs report "supported" but still produce unchanged text.
        if target.minimalIdentifier != english.minimalIdentifier,
           directResult.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedText {
            let status: LanguageAvailability.Status
            if let directStatus {
                status = directStatus
            } else if let computedStatus = await availabilityStatus(
                for: normalizedText,
                source: sourceLanguage,
                target: target,
                requestId: requestId
            ) {
                status = computedStatus
            } else {
                status = .supported
            }

            if status != .installed {
                Self.logger.warning("Translation[\(requestId)] direct result unchanged, retrying via English")
                return try await translateViaEnglish(
                    requestId: requestId,
                    text: normalizedText,
                    source: sourceLanguage,
                    target: target,
                    english: english
                )
            }
        }

        Self.logger.info("Translation[\(requestId)] completed without fallback")
        return directResult
    }

    private func translateViaEnglish(
        requestId: String,
        text: String,
        source sourceLanguage: Locale.Language?,
        target: Locale.Language,
        english: Locale.Language
    ) async throws -> String {
        let toEnglishStatus = await availabilityStatus(
            for: text,
            source: sourceLanguage,
            target: english,
            requestId: requestId
        )
        let englishText = try await requestTranslation(
            requestId: requestId,
            text: text,
            source: sourceLanguage,
            target: english,
            availabilityStatus: toEnglishStatus
        )
        let normalizedEnglish = englishText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedEnglish.isEmpty, normalizedEnglish != text else {
            Self.logger.warning("Translation[\(requestId)] via-English produced no intermediate change")
            return text
        }

        let toTargetStatus = await availabilityStatus(
            for: normalizedEnglish,
            source: english,
            target: target,
            requestId: requestId
        )

        let final = try await requestTranslation(
            requestId: requestId,
            text: normalizedEnglish,
            source: english,
            target: target,
            availabilityStatus: toTargetStatus
        )
        Self.logger.info("Translation[\(requestId)] completed via English")
        return final
    }

    private func availabilityStatus(
        for text: String,
        source sourceLanguage: Locale.Language?,
        target: Locale.Language,
        requestId: String
    ) async -> LanguageAvailability.Status? {
        let availability = LanguageAvailability()

        if let sourceLanguage {
            let status = await availability.status(from: sourceLanguage, to: target)
            Self.logger.info("Translation[\(requestId)] availability \(sourceLanguage.minimalIdentifier) -> \(target.minimalIdentifier): \(String(describing: status))")
            return status
        }

        do {
            let status = try await availability.status(for: text, to: target)
            Self.logger.info("Translation[\(requestId)] availability auto -> \(target.minimalIdentifier): \(String(describing: status))")
            return status
        } catch {
            Self.logger.warning("Translation[\(requestId)] availability check failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func requestTranslation(
        requestId: String,
        text: String,
        source sourceLanguage: Locale.Language?,
        target: Locale.Language,
        availabilityStatus: LanguageAvailability.Status?
    ) async throws -> String {
        let needsInteractiveHost = availabilityStatus == .supported
        if needsInteractiveHost {
            Self.logger.notice("Translation[\(requestId)] assets for \(target.minimalIdentifier) need user action; enabling interactive host")
            setInteractiveHostMode?(true)
        }
        defer {
            if needsInteractiveHost {
                setInteractiveHostMode?(false)
            }
        }

        // Cancel any pending translation — resume with original text
        if let pending = continuation {
            let previousRequestId = self.activeRequestId
            Self.logger.warning("Translation[\(previousRequestId)] cancelled by new request \(requestId)")
            pending.resume(returning: self.sourceText)
            self.continuation = nil
        }

        // Force SwiftUI to recreate the .translationTask by changing the view identity.
        // Without this, subsequent translations with the same target language may not
        // re-trigger the task even with a nil reset.
        configuration = nil
        viewId = UUID()
        try await Task.sleep(for: .milliseconds(100))

        sourceText = text

        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            self.activeRequestId = requestId
            self.configuration = .init(source: sourceLanguage, target: target)
            Self.logger.info("Translation[\(requestId)] requested \(sourceLanguage?.minimalIdentifier ?? "auto") -> \(target.minimalIdentifier)")

            let timeout: Duration = needsInteractiveHost ? .seconds(90) : .seconds(15)

            // Timeout watchdog.
            Task { [weak self] in
                try await Task.sleep(for: timeout)
                guard let self else { return }
                if let pending = self.continuation {
                    let seconds = needsInteractiveHost ? 90 : 15
                    Self.logger.error("Translation[\(requestId)] timed out after \(seconds)s, returning original text")
                    pending.resume(returning: self.sourceText)
                    self.continuation = nil
                    self.configuration = nil
                    self.activeRequestId = "-"
                }
            }
        }
    }

    func handleSession(_ session: sending TranslationSession) async {
        let requestId = activeRequestId
        do {
            do {
                try await session.prepareTranslation()
            } catch {
                Self.logger.warning("Translation[\(requestId)] prepare failed: \(error.localizedDescription)")
            }

            let result = try await session.translate(sourceText)
            Self.logger.info("Translation[\(requestId)] session completed")
            continuation?.resume(returning: result.targetText)
        } catch {
            Self.logger.error("Translation[\(requestId)] failed: \(error.localizedDescription), returning original text")
            continuation?.resume(returning: sourceText)
        }
        continuation = nil
        configuration = nil
        activeRequestId = "-"
    }

    /// Languages available for translation via Apple Translation framework.
    static let availableTargetLanguages: [(code: String, name: String)] = {
        let codes = [
            "ar", "de", "en", "es", "fr", "hi", "id", "it", "ja", "ko",
            "nl", "pl", "pt", "ru", "th", "tr", "uk", "vi", "zh-Hans", "zh-Hant",
        ]
        return codes.compactMap { code in
            let name = Locale.current.localizedString(forLanguageCode: code) ?? code
            return (code: code, name: name)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }()

    /// Tries to normalize language inputs like "de-DE", "german", "deutsch"
    /// to a BCP-47-like identifier accepted by Translation.framework.
    nonisolated static func makeLanguage(from rawIdentifier: String?) -> Locale.Language? {
        guard let id = normalizeLanguageIdentifier(rawIdentifier) else { return nil }
        return Locale.Language(identifier: id)
    }

    nonisolated static func normalizedLanguageIdentifier(from rawIdentifier: String?) -> String? {
        normalizeLanguageIdentifier(rawIdentifier)
    }

    nonisolated private static func normalizeLanguageIdentifier(_ rawIdentifier: String?) -> String? {
        guard var raw = rawIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }

        raw = raw.replacingOccurrences(of: "_", with: "-")

        // Keep script-specific identifiers used by translation target picker.
        let scriptSpecific = ["zh-Hans", "zh-Hant"]
        if let exact = scriptSpecific.first(where: { $0.caseInsensitiveCompare(raw) == .orderedSame }) {
            return exact
        }

        let foldedRaw = foldLanguageToken(raw)
        if foldedRaw == "auto" { return nil }

        // Direct locale identifier (e.g. de, de-DE, en_US) -> take primary language subtag.
        let primary = raw.split(separator: "-").first.map(String.init) ?? raw
        let primaryLower = primary.lowercased()
        if isoLanguageCodes.contains(primaryLower) {
            return primaryLower
        }

        if let mapped = languageAliasMap[foldedRaw] {
            return mapped
        }

        return nil
    }

    nonisolated private static func foldLanguageToken(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .lowercased()
    }

    nonisolated private static let languageAliasMap: [String: String] = {
        var map: [String: String] = [:]
        let helperLocales = [
            Locale(identifier: "en_US"),
            Locale(identifier: "de_DE"),
            Locale.current,
        ]

        for code in isoLanguageCodes {
            map[foldLanguageToken(code)] = code

            for locale in helperLocales {
                if let localized = locale.localizedString(forLanguageCode: code) {
                    map[foldLanguageToken(localized)] = code
                }
            }

            if let autonym = Locale(identifier: code).localizedString(forLanguageCode: code) {
                map[foldLanguageToken(autonym)] = code
            }
        }

        // Frequent explicit aliases seen in logs/user settings.
        map[foldLanguageToken("german")] = "de"
        map[foldLanguageToken("deutsch")] = "de"
        map[foldLanguageToken("english")] = "en"
        map[foldLanguageToken("englisch")] = "en"
        map[foldLanguageToken("spanish")] = "es"
        map[foldLanguageToken("spanisch")] = "es"
        map[foldLanguageToken("espanol")] = "es"
        map[foldLanguageToken("español")] = "es"

        // Script aliases.
        map[foldLanguageToken("chinese simplified")] = "zh-Hans"
        map[foldLanguageToken("simplified chinese")] = "zh-Hans"
        map[foldLanguageToken("chinese traditional")] = "zh-Hant"
        map[foldLanguageToken("traditional chinese")] = "zh-Hant"

        return map
    }()

    nonisolated private static var isoLanguageCodes: [String] {
        Locale.LanguageCode.isoLanguageCodes.map(\.identifier)
    }
}
