import Foundation

public enum PluginHuggingFaceTokenHelper {
    public static let storageKey = "hf-token"
    public static let environmentKeys = [
        "HF_TOKEN",
        "HUGGING_FACE_HUB_TOKEN",
        "HUGGINGFACEHUB_API_TOKEN",
    ]

    public static func normalizedToken(_ token: String?) -> String? {
        guard let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    public static func loadToken(from host: HostServices?) -> String? {
        guard let host else { return nil }
        return normalizedToken(host.loadSecret(key: storageKey))
    }

    @discardableResult
    public static func saveToken(_ token: String, to host: HostServices?) -> String? {
        let normalized = normalizedToken(token)
        guard let host else { return normalized }
        try? host.storeSecret(key: storageKey, value: normalized ?? "")
        return normalized
    }

    public static func clearToken(from host: HostServices?) {
        guard let host else { return }
        try? host.storeSecret(key: storageKey, value: "")
    }

    public static func validateToken(
        _ token: String,
        dataFetcher: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = PluginHTTPClient.data
    ) async -> Bool {
        guard let normalized = normalizedToken(token),
              let url = URL(string: "https://huggingface.co/api/whoami-v2") else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(normalized)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await dataFetcher(request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return false
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }

            return json["name"] != nil || json["type"] != nil || json["auth"] != nil
        } catch {
            return false
        }
    }

    public static func applyTokenToEnvironment(_ token: String?) {
        guard let normalized = normalizedToken(token) else {
            for key in environmentKeys {
                unsetenv(key)
            }
            return
        }

        for key in environmentKeys {
            setenv(key, normalized, 1)
        }
    }
}
