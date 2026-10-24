import Foundation
import TypeWhisperPluginSDK

enum SpeechCredentialCheck {
    enum Result: Equatable { case connected, invalid, unavailable }

    static func check(pluginId: String, key: String, sonioxRegion: String? = nil,
                      deepgramBaseURL: String? = nil, deepgramAuthHeader: String? = nil) async throws -> Result {
        guard let request = request(pluginId: pluginId, key: key, sonioxRegion: sonioxRegion,
                                    deepgramBaseURL: deepgramBaseURL, deepgramAuthHeader: deepgramAuthHeader) else { return .unavailable }
        let (data, response) = try await PluginHTTPClient.data(for: request, retry: .disabled)
        guard let response = response as? HTTPURLResponse else { return .unavailable }
        return result(pluginId: pluginId, statusCode: response.statusCode, data: data)
    }

    static func request(pluginId: String, key: String, sonioxRegion: String? = nil,
                        deepgramBaseURL: String? = nil, deepgramAuthHeader: String? = nil) -> URLRequest? {
        let endpoint: String
        var header = "Authorization"
        var credential = "Bearer \(key)"
        switch pluginId {
        case "com.typewhisper.openai": endpoint = "https://api.openai.com/v1/models"
        case "com.typewhisper.groq": endpoint = "https://api.groq.com/openai/v1/models"
        case "com.typewhisper.deepgram":
            let base = deepgramBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            endpoint = (base.isEmpty ? "https://api.deepgram.com" : base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) + "/v1/projects"
            let customHeader = deepgramAuthHeader?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            header = customHeader.isEmpty ? "Authorization" : customHeader
            credential = header == "Authorization" ? "Token \(key)" : key
        case "com.typewhisper.openrouter": endpoint = "https://openrouter.ai/api/v1/auth/key"
        case "com.typewhisper.gemini":
            endpoint = "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1"
            header = "x-goog-api-key"
            credential = key
        case "com.typewhisper.assemblyai":
            endpoint = "https://api.assemblyai.com/v2/transcript?limit=1"
            credential = key
        case "com.typewhisper.elevenlabs":
            endpoint = "https://api.elevenlabs.io/v1/user"
            header = "xi-api-key"
            credential = key
        case "com.typewhisper.soniox":
            let host = ["eu": "api.eu.soniox.com", "jp": "api.jp.soniox.com"][sonioxRegion ?? ""] ?? "api.soniox.com"
            endpoint = "https://\(host)/v1/files"
        default: return nil
        }
        guard let url = URL(string: endpoint) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(credential, forHTTPHeaderField: header)
        return request
    }

    static func result(pluginId: String, statusCode: Int, data: Data) -> Result {
        if statusCode == 200 { return .connected }
        if pluginId == "com.typewhisper.elevenlabs", statusCode == 401,
           let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let detail = body["detail"] as? [String: Any], detail["status"] as? String == "missing_permissions",
           (detail["message"] as? String)?.caseInsensitiveCompare("The API key you used is missing the permission user_read to execute this operation.") == .orderedSame {
            return .connected
        }
        return [401, 403].contains(statusCode) ? .invalid : .unavailable
    }
}
