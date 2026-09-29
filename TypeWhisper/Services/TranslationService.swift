import Foundation
import os

#if canImport(Translation)
import Translation

/// Errors for strict translation requests (used by the HTTP API path).
/// Non-strict callers keep the historical graceful fallback to the source text.
enum TranslationError: Error {
    case timedOut
    case cancelled
    case noTranslation
    case batchCountMismatch(expected: Int, actual: Int)
}

@available(macOS 15, *)
@MainActor
final class TranslationService: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?
    @Published var viewId = UUID()

    /// Called by AppDelegate to temporarily switch the host window into an
    /// interactive mode when Translation.framework needs user approval/download UI.
    var setInteractiveHostMode: (@MainActor (Bool) -> Void)?

    private var sourceText = ""
    private var continuation: CheckedContinuation<String, Error>?
    private var pendingStrict = false
    private var activeRequestId = "-"
    private var batchRequest: BatchRequest?
    /// Test seam: replaces the Translation-framework availability check.
    var availabilityStub: ((String, Locale.Language?, Locale.Language) async -> LanguageAvailability.Status?)?
    /// Test seam: overrides the batch watchdog duration.
    var batchTimeoutOverride: Duration?
    /// Test hook: requestId of the currently claimed batch request, if any.
    var claimedBatchRequestId: String? { batchRequest?.requestId }
    private static let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "Translation")

    /// One claimed batch request. The record is registered atomically with
    /// the cancel-and-claim in `translateBatch` and stays registered while
    /// the framework session runs, so the session result, the watchdog
    /// timeout, and cancellation all funnel through `finish(with:)` and the
    /// first terminal event wins. A late session result after a timeout or
    /// cancellation is ignored instead of resuming twice.
    private final class BatchRequest {
        let requestId: String
        let texts: [String]
        let strict: Bool
        private var continuation: CheckedContinuation<[String], Error>?
        /// True only when the request completed via the framework session.
        /// Timeout/cancellation fallbacks return the source texts terminally
        /// and must not trigger the unchanged-result retry below.
        private(set) var finishedBySession = false

        init(requestId: String, texts: [String], strict: Bool, continuation: CheckedContinuation<[String], Error>) {
            self.requestId = requestId
            self.texts = texts
            self.strict = strict
            self.continuation = continuation
        }

        /// Resumes the continuation at most once; later calls are ignored.
        func finish(with result: Result<[String], Error>, fromSession: Bool = false) {
            guard let continuation else { return }
            self.continuation = nil
            finishedBySession = fromSession
            switch result {
            case .success(let values):
                continuation.resume(returning: values)
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }

        func cancel() {
            finish(with: strict ? .failure(TranslationError.cancelled) : .success(texts))
        }

        func timeOut() {
            finish(with: strict ? .failure(TranslationError.timedOut) : .success(texts))
        }
    }

    func translate(
        text: String,
        to target: Locale.Language,
        source sourceLanguage: Locale.Language? = nil,
        strict: Bool = false
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
                english: english,
                strict: strict
            )
        }

        let directResult = try await requestTranslation(
            requestId: requestId,
            text: normalizedText,
            source: sourceLanguage,
            target: target,
            availabilityStatus: directStatus,
            strict: strict
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
                    english: english,
                    strict: strict
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
        english: Locale.Language,
        strict: Bool
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
            availabilityStatus: toEnglishStatus,
            strict: strict
        )
        let normalizedEnglish = englishText.trimmingCharacters(in: .whitespacesAndNewlines)
        // A non-empty intermediate that matches the input just means the
        // source was already English; it still needs the target leg.
        guard !normalizedEnglish.isEmpty else {
            Self.logger.warning("Translation[\(requestId)] via-English produced no intermediate change")
            if strict { throw TranslationError.noTranslation }
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
            availabilityStatus: toTargetStatus,
            strict: strict
        )
        Self.logger.info("Translation[\(requestId)] completed via English")
        return final
    }

    /// Translates multiple texts through a single translation session.
    ///
    /// Unlike repeated `translate` calls, this performs the session reset only
    /// once, so long segment lists don't pay the per-request setup cost.
    /// Results keep the input order. When `strict` is true, timeouts,
    /// cancellations, and session failures throw instead of falling back to
    /// the source texts.
    func translateBatch(
        texts: [String],
        to target: Locale.Language,
        source sourceLanguage: Locale.Language? = nil,
        strict: Bool = false
    ) async throws -> [String] {
        try await translateBatch(
            texts: texts, to: target, source: sourceLanguage, strict: strict,
            english: Locale.Language(identifier: "en"), allowUnchangedFallback: true
        )
    }

    private func translateBatch(
        texts: [String],
        to target: Locale.Language,
        source sourceLanguage: Locale.Language?,
        strict: Bool,
        english: Locale.Language,
        allowUnchangedFallback: Bool
    ) async throws -> [String] {
        let requestId = String(UUID().uuidString.prefix(8))
        guard !texts.isEmpty else { return [] }
        Self.logger.info("Translation[\(requestId)] batch start \(sourceLanguage?.minimalIdentifier ?? "auto") -> \(target.minimalIdentifier), count=\(texts.count)")

        // Match translate's unsupported-pair behavior: a direct batch session
        // for an unsupported pair throws (HTTP 500 in strict mode), so go
        // through English in two batches instead.
        let directStatus = await availabilityStatus(
            for: String(texts.prefix(5).joined(separator: "\n").prefix(2000)),
            source: sourceLanguage,
            target: target,
            requestId: requestId
        )
        if directStatus == .unsupported, target.minimalIdentifier != english.minimalIdentifier {
            Self.logger.warning("Translation[\(requestId)] batch direct \(target.minimalIdentifier) unsupported, trying via English")
            let toEnglish = try await translateBatch(
                texts: texts, to: english, source: sourceLanguage, strict: strict,
                english: english, allowUnchangedFallback: false
            )
            return try await translateBatch(
                texts: toEnglish, to: target, source: english, strict: strict,
                english: english, allowUnchangedFallback: false
            )
        }

        // A batch never shares the session with another request. The cancel
        // runs after the reset sleep, immediately before the new request is
        // claimed, with no suspension in between: on the main actor that
        // makes cancel-and-claim atomic, so two requests overlapping inside
        // the reset window can never overwrite or orphan each other's
        // continuation. The preempted request is cancelled, never lost.
        configuration = nil
        viewId = UUID()
        try await Task.sleep(for: .milliseconds(100))

        cancelPending(reason: "new batch \(requestId)")

        // The record outlives the claim closure so the code below can tell
        // session results apart from timeout/cancellation fallbacks.
        var request: BatchRequest!
        let results = try await withCheckedThrowingContinuation { cont in
            request = BatchRequest(requestId: requestId, texts: texts, strict: strict, continuation: cont)
            self.batchRequest = request
            self.activeRequestId = requestId
            self.configuration = .init(source: sourceLanguage, target: target)
            Self.logger.info("Translation[\(requestId)] batch requested \(sourceLanguage?.minimalIdentifier ?? "auto") -> \(target.minimalIdentifier)")

            let timeout: Duration = self.batchTimeoutOverride ?? .seconds(15 + texts.count * 2)

            // Timeout watchdog. The request record stays registered while
            // the framework session runs, so a stalled session still hits
            // its deadline; finish(with:) lets the session result, the
            // timeout, and cancellation race for exactly one terminal
            // completion, and a late session result is safely ignored.
            Task { [weak self] in
                try await Task.sleep(for: timeout)
                guard let self, let pending = self.batchRequest, pending.requestId == requestId else { return }
                Self.logger.error("Translation[\(requestId)] batch timed out, \(strict ? "throwing" : "returning source texts")")
                pending.timeOut()
                self.batchRequest = nil
                self.configuration = nil
                self.activeRequestId = "-"
            }
        }

        guard request.finishedBySession else { return results }
        return try await batchUnchangedFallback(
            results: results, texts: texts, target: target, sourceLanguage: sourceLanguage,
            strict: strict, english: english, directStatus: directStatus,
            allowUnchangedFallback: allowUnchangedFallback, requestId: requestId
        )
    }

    /// Availability-aware unchanged-result fallback for the batch path,
    /// mirroring `translate()`: when the framework silently echoes the
    /// source text for a pair that isn't installed, the affected segments
    /// are retried through English instead of being reported under the
    /// target language. Installed pairs and blank segments keep their text;
    /// in strict mode a fallback that still can't produce the target
    /// language throws instead of returning untranslated segments.
    private func batchUnchangedFallback(
        results: [String],
        texts: [String],
        target: Locale.Language,
        sourceLanguage: Locale.Language?,
        strict: Bool,
        english: Locale.Language,
        directStatus: LanguageAvailability.Status?,
        allowUnchangedFallback: Bool,
        requestId: String
    ) async throws -> [String] {
        guard allowUnchangedFallback,
              target.minimalIdentifier != english.minimalIdentifier,
              directStatus != .installed,
              results.count == texts.count
        else { return results }

        var staleIndices: [Int] = []
        for (index, pair) in zip(texts, results).enumerated() {
            let source = pair.0.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = pair.1.trimmingCharacters(in: .whitespacesAndNewlines)
            if !result.isEmpty, result == source {
                staleIndices.append(index)
            }
        }
        guard !staleIndices.isEmpty else { return results }

        Self.logger.warning("Translation[\(requestId)] batch returned \(staleIndices.count) untranslated segment(s), retrying via English")
        let staleTexts = staleIndices.map { texts[$0] }
        let toEnglish = try await translateBatch(
            texts: staleTexts, to: english, source: sourceLanguage, strict: strict,
            english: english, allowUnchangedFallback: false
        )
        let toTarget = try await translateBatch(
            texts: toEnglish, to: target, source: english, strict: strict,
            english: english, allowUnchangedFallback: false
        )
        var final = results
        for (slot, index) in staleIndices.enumerated() {
            let original = texts[index].trimmingCharacters(in: .whitespacesAndNewlines)
            let intermediate = toEnglish[slot].trimmingCharacters(in: .whitespacesAndNewlines)
            // An empty English intermediate means the source had nothing to
            // translate: strict callers fail, others keep the source text.
            guard !intermediate.isEmpty else {
                if strict { throw TranslationError.noTranslation }
                continue
            }
            let backTranslated = toTarget[slot].trimmingCharacters(in: .whitespacesAndNewlines)
            if strict, !backTranslated.isEmpty, backTranslated == original {
                throw TranslationError.noTranslation
            }
            final[index] = toTarget[slot]
        }
        return final
    }

    /// Cancels any in-flight request, resuming it per its own strict flag.
    private func cancelPending(reason: String) {
        if let pending = continuation {
            Self.logger.warning("Translation[\(self.activeRequestId)] cancelled by \(reason)")
            if pendingStrict {
                pending.resume(throwing: TranslationError.cancelled)
            } else {
                pending.resume(returning: sourceText)
            }
            continuation = nil
            pendingStrict = false
        }
        if let request = batchRequest {
            Self.logger.warning("Translation[\(request.requestId)] batch cancelled by \(reason)")
            request.cancel()
            batchRequest = nil
        }
    }

    private func availabilityStatus(
        for text: String,
        source sourceLanguage: Locale.Language?,
        target: Locale.Language,
        requestId: String
    ) async -> LanguageAvailability.Status? {
        if let availabilityStub {
            return await availabilityStub(text, sourceLanguage, target)
        }
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
        availabilityStatus: LanguageAvailability.Status?,
        strict: Bool
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

        // Reset the session (nil configuration + new view identity forces
        // SwiftUI to recreate the .translationTask), then cancel-and-claim
        // atomically: the cancel runs after the reset sleep, immediately
        // before the new request is claimed, with no suspension in between,
        // so overlapping requests can never overwrite or orphan each
        // other's continuation on the main actor.
        configuration = nil
        viewId = UUID()
        try await Task.sleep(for: .milliseconds(100))

        cancelPending(reason: "new request \(requestId)")

        sourceText = text
        pendingStrict = strict

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
                if self.activeRequestId == requestId, let pending = self.continuation {
                    let seconds = needsInteractiveHost ? 90 : 15
                    Self.logger.error("Translation[\(requestId)] timed out after \(seconds)s, \(strict ? "throwing" : "returning original text")")
                    if strict {
                        pending.resume(throwing: TranslationError.timedOut)
                    } else {
                        pending.resume(returning: self.sourceText)
                    }
                    self.continuation = nil
                    self.pendingStrict = false
                    self.configuration = nil
                    self.activeRequestId = "-"
                }
            }
        }
    }

    /// Builds the framework batch request values off the main actor, so the
    /// non-Sendable request array handed to `translations(from:)` is a
    /// disconnected value instead of main-actor-isolated state.
    nonisolated private static func batchRequests(from texts: [String]) -> [TranslationSession.Request] {
        texts.map { TranslationSession.Request(sourceText: $0) }
    }

    /// Minimal batch surface of `TranslationSession` used by the batch path.
    /// Lets tests substitute a controllable double for the Apple framework.
    /// The framework session's methods are plain non-isolated async calls,
    /// so both the production adapter and test doubles stay non-isolated.
    protocol BatchSessionTranslator {
        func prepareTranslation() async throws
        func translateTexts(_ texts: [String]) async throws -> [String]
    }

    /// Production `BatchSessionTranslator` driving the real framework session.
    private struct FrameworkBatchTranslator: BatchSessionTranslator {
        let session: TranslationSession

        func prepareTranslation() async throws {
            try await session.prepareTranslation()
        }

        func translateTexts(_ texts: [String]) async throws -> [String] {
            let responses = try await session.translations(from: TranslationService.batchRequests(from: texts))
            guard responses.count == texts.count else {
                throw TranslationError.batchCountMismatch(expected: texts.count, actual: responses.count)
            }
            return responses.map(\.targetText)
        }
    }

    func handleSession(_ session: sending TranslationSession) async {
        if batchRequest != nil {
            await handleBatchSession(FrameworkBatchTranslator(session: session))
            return
        }

        let requestId = activeRequestId
        let strict = pendingStrict
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
            Self.logger.error("Translation[\(requestId)] failed: \(error.localizedDescription), \(strict ? "throwing" : "returning original text")")
            if strict {
                continuation?.resume(throwing: error)
            } else {
                continuation?.resume(returning: sourceText)
            }
        }
        // Only clear state that still belongs to this request: a stale
        // session must never wipe a newer request's configuration.
        if activeRequestId == requestId {
            continuation = nil
            pendingStrict = false
            configuration = nil
            activeRequestId = "-"
        }
    }

    /// Drives the currently claimed batch request with a session translator.
    /// Internal so tests can substitute a controllable double for the
    /// framework session. The request record stays registered for the whole
    /// session, so the session result, the watchdog timeout, and
    /// cancellation race for exactly one terminal completion through
    /// `finish(with:)`; a late session result is safely ignored.
    func handleBatchSession(_ translator: some BatchSessionTranslator) async {
        guard let request = batchRequest else {
            // Stale session with no claimed request (e.g. superseded before
            // the framework delivered it). Never touch another request's state.
            Self.logger.warning("Translation batch session arrived with no claimed request; ignoring")
            return
        }
        let requestId = request.requestId
        let texts = request.texts
        let strict = request.strict
        do {
            do {
                try await translator.prepareTranslation()
            } catch {
                Self.logger.warning("Translation[\(requestId)] batch prepare failed: \(error.localizedDescription)")
            }
            let translated = try await translator.translateTexts(texts)
            Self.logger.info("Translation[\(requestId)] batch completed, count=\(translated.count)")
            request.finish(with: .success(translated), fromSession: true)
        } catch {
            Self.logger.error("Translation[\(requestId)] batch failed: \(error.localizedDescription), \(strict ? "throwing" : "returning source texts")")
            request.finish(with: strict ? .failure(error) : .success(texts))
        }
        // Only clear state that still belongs to this request.
        if batchRequest === request {
            batchRequest = nil
            configuration = nil
            activeRequestId = "-"
        }
    }

    /// Languages available for translation via Apple Translation framework.
    static let availableTargetLanguages: [(code: String, name: String)] = {
        let codes = [
            "ar", "de", "en", "es", "fr", "hi", "id", "it", "ja", "ko",
            "nl", "pl", "pt", "ru", "th", "tr", "uk", "vi", "zh-Hans", "zh-Hant",
        ]
        return codes.compactMap { code in
            let name = Locale.current.localizedString(forIdentifier: code) ?? code
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
                if let localized = locale.localizedString(forIdentifier: code) {
                    map[foldLanguageToken(localized)] = code
                }
            }

            if let autonym = Locale(identifier: code).localizedString(forIdentifier: code) {
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
#endif
