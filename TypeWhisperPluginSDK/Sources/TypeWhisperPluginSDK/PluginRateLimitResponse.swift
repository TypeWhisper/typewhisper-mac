import Foundation

/// Reads the provider's own explanation out of an HTTP 429 body.
///
/// Providers answer 429 both for real rate limiting and for an exhausted quota,
/// an empty credit balance, or an expired trial. Only the body tells them apart,
/// so the provider's message is surfaced instead of a generic rate-limit text.
public enum PluginRateLimitResponse {
    static let statusCode = 429

    /// The provider's message, or nil when the body carries none.
    public static func providerMessage(from data: Data) -> String? {
        let json = try? JSONSerialization.jsonObject(with: data)

        let object: [String: Any]?
        if let dictionary = json as? [String: Any] {
            object = dictionary
        } else if let array = json as? [Any] {
            object = array.first as? [String: Any]
        } else {
            object = nil
        }

        guard let object, let message = message(fromErrorObject: object) else { return nil }
        return PluginHTTPErrorBodyFormatter.summary(from: message)
    }

    private static func message(fromErrorObject object: [String: Any]) -> String? {
        if let detail = nonEmptyString(object["detail"]) {
            return detail
        }
        if let error = object["error"] as? [String: Any],
           let message = nonEmptyString(error["message"]) {
            return message
        }
        if let error = nonEmptyString(object["error"]) {
            return error
        }
        return nonEmptyString(object["message"]) ?? nonEmptyString(object["error_message"])
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func describedMessage(from data: Data) -> String? {
        providerMessage(from: data).map { "HTTP \(statusCode): \($0)" }
    }
}

public extension PluginTranscriptionError {
    /// Error for an HTTP 429 response: the provider's message when the body has one,
    /// otherwise the generic `.rateLimited`.
    static func rateLimitOrQuota(from responseData: Data) -> PluginTranscriptionError {
        PluginRateLimitResponse.describedMessage(from: responseData).map { .apiError($0) } ?? .rateLimited
    }
}

public extension PluginChatError {
    /// Error for an HTTP 429 response: the provider's message when the body has one,
    /// otherwise the generic `.rateLimited`.
    static func rateLimitOrQuota(from responseData: Data) -> PluginChatError {
        PluginRateLimitResponse.describedMessage(from: responseData).map { .apiError($0) } ?? .rateLimited
    }
}
