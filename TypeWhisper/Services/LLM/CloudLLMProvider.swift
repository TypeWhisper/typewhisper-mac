import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TypeWhisper", category: "CloudLLMProvider")

final class CloudLLMProvider: LLMProvider, @unchecked Sendable {
    let baseURL: String
    let model: String
    private let keychainId: String
    private let chatEndpoint: String

    var isAvailable: Bool {
        let apiKey = KeychainService.load(service: keychainId)
        return apiKey != nil && !apiKey!.isEmpty
    }

    init(config: CloudProviderConfig, model: String? = nil) {
        self.baseURL = config.baseURL
        self.chatEndpoint = config.chatEndpoint
        self.model = model ?? config.defaultModel
        self.keychainId = config.keychainId
    }

    func process(systemPrompt: String, userText: String) async throws -> String {
        guard let apiKey = KeychainService.load(service: keychainId), !apiKey.isEmpty else {
            throw LLMError.noApiKey
        }

        let endpoint = "\(baseURL)\(chatEndpoint)"
        guard let url = URL(string: endpoint) else {
            throw LLMError.providerError("Invalid URL: \(endpoint)")
        }

        let requestBody: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userText]
            ],
            "temperature": 0.3,
            "max_tokens": 4096
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.providerError("Invalid response")
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 401:
            throw LLMError.noApiKey
        case 429:
            throw LLMError.providerError("Rate limit exceeded. Please wait and try again.")
        default:
            let errorBody = String(data: data, encoding: .utf8) ?? ""
            logger.error("Cloud LLM error HTTP \(httpResponse.statusCode): \(errorBody)")
            // Extract human-readable message from JSON error response
            var displayMessage = "HTTP \(httpResponse.statusCode)"
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                displayMessage = message
            }
            throw LLMError.providerError(displayMessage)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw LLMError.providerError("Failed to parse response")
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
