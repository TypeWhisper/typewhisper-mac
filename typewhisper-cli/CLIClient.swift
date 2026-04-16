import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum CLIError: Error {
    case connectionFailed(port: UInt16)
    case serverError(statusCode: Int, message: String)
    case invalidResponse
    case fileNotFound(String)
    case stdinEmpty

    var exitCode: Int32 {
        switch self {
        case .connectionFailed: return 2
        case .serverError: return 3
        case .invalidResponse: return 3
        case .fileNotFound, .stdinEmpty: return 1
        }
    }

    var message: String {
        switch self {
        case .connectionFailed(let port):
            return """
                Error: Cannot connect to TypeWhisper on port \(port).

                Make sure TypeWhisper is running and the API server is enabled:
                  1. Open TypeWhisper
                  2. Go to Settings > Advanced
                  3. Enable "API Server"
                """
        case .serverError(let code, let message):
            if code == 503 {
                return "Error: No model loaded in TypeWhisper. Load a model first."
            }
            return "Error: Server returned \(code) - \(message)"
        case .invalidResponse:
            return "Error: Invalid response from server."
        case .fileNotFound(let path):
            return "Error: File not found: \(path)"
        case .stdinEmpty:
            return "Error: No data received from stdin."
        }
    }
}

struct CLIClient {
    let port: UInt16
    private var baseURL: String { "http://127.0.0.1:\(port)" }

    func status() async throws -> Data {
        try await get("/v1/status")
    }

    func models() async throws -> Data {
        try await get("/v1/models")
    }

    func transcribe(
        fileURL: URL?,
        language: String?,
        languageHints: [String],
        task: String?,
        targetLanguage: String?,
        engine: String? = nil,
        model: String? = nil,
        awaitDownload: Bool = false
    ) async throws -> Data {
        let audioData: Data
        let filename: String

        if let fileURL {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw CLIError.fileNotFound(fileURL.path)
            }
            audioData = try Data(contentsOf: fileURL)
            filename = fileURL.lastPathComponent
        } else {
            // Read from stdin
            let stdinData = FileHandle.standardInput.readDataToEndOfFile()
            guard !stdinData.isEmpty else {
                throw CLIError.stdinEmpty
            }
            audioData = stdinData
            filename = "audio.wav"
        }

        let boundary = UUID().uuidString
        var body = Data()

        // File field
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: application/octet-stream\r\n\r\n")
        body.append(audioData)
        body.append("\r\n")

        // Optional fields
        if let language {
            body.appendFormField("language", value: language, boundary: boundary)
        }
        for languageHint in languageHints {
            body.appendFormField("language_hint", value: languageHint, boundary: boundary)
        }
        if let task {
            body.appendFormField("task", value: task, boundary: boundary)
        }
        if let targetLanguage {
            body.appendFormField("target_language", value: targetLanguage, boundary: boundary)
        }
        if let engine {
            body.appendFormField("engine", value: engine, boundary: boundary)
        }
        if let model {
            body.appendFormField("model", value: model, boundary: boundary)
        }

        body.append("--\(boundary)--\r\n")

        var transcribePath = "/v1/transcribe"
        if awaitDownload {
            transcribePath += "?await_download=1"
        }
        let url = URL(string: "\(baseURL)\(transcribePath)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 300

        return try await performRequest(request)
    }

    // MARK: - Private

    private func get(_ path: String) async throws -> Data {
        let url = URL(string: "\(baseURL)\(path)")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        return try await performRequest(request)
    }

    private func performRequest(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw CLIError.connectionFailed(port: port)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CLIError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            var message = "Unknown error"
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorObj = json["error"] as? [String: Any],
               let msg = errorObj["message"] as? String {
                message = msg
            }
            throw CLIError.serverError(statusCode: httpResponse.statusCode, message: message)
        }

        return data
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }

    mutating func appendFormField(_ name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append(value)
        append("\r\n")
    }
}
