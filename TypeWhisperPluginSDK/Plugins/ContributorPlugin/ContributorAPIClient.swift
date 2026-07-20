import Foundation
import TypeWhisperPluginSDK

struct ContributorAPIClient: Sendable {
    let baseURL: URL
    let token: String?

    func createSession() async throws -> ContributionSession {
        try await request(
            path: "/v1/contributors/session",
            method: "POST",
            body: EmptyBody(),
            authorization: nil
        )
    }

    func submit(
        batchId: UUID,
        records: [ContributionRecord],
        consentVersion: String,
        pluginVersion: String
    ) async throws -> ContributionBatchResponse {
        guard let token else { throw ContributorAPIError.missingToken }
        return try await request(
            path: "/v1/contributions/batches",
            method: "POST",
            body: ContributionBatchRequest(
                batchId: batchId,
                consentVersion: consentVersion,
                pluginVersion: pluginVersion,
                records: records
            ),
            authorization: "Contributor \(token)"
        )
    }

    func statuses(for ids: [UUID]) async throws -> [ContributionRemoteStatus] {
        guard let token else { throw ContributorAPIError.missingToken }
        guard !ids.isEmpty else { return [] }
        var components = URLComponents(
            url: endpoint(path: "/v1/contributions/status"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "ids", value: ids.map(\.uuidString).joined(separator: ","))
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Contributor \(token)", forHTTPHeaderField: "Authorization")
        let response = try await PluginHTTPClient.data(for: request)
        return try decodeResponse(ContributionStatusResponse.self, from: response).records
    }

    func delete(_ id: UUID) async throws {
        guard let token else { throw ContributorAPIError.missingToken }
        var request = URLRequest(url: endpoint(path: "/v1/contributions/\(id.uuidString.lowercased())"))
        request.httpMethod = "DELETE"
        request.setValue("Contributor \(token)", forHTTPHeaderField: "Authorization")
        let response = try await PluginHTTPClient.data(for: request)
        _ = try decodeResponse(EmptyResponse.self, from: response)
    }

    private func request<Body: Encodable, Response: Decodable>(
        path: String,
        method: String,
        body: Body,
        authorization: String?
    ) async throws -> Response {
        var request = URLRequest(url: endpoint(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(body)
        let response = try await PluginHTTPClient.data(for: request)
        return try decodeResponse(Response.self, from: response)
    }

    private func endpoint(path: String) -> URL {
        var url = baseURL
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        return url
    }

    private func decodeResponse<Response: Decodable>(
        _ type: Response.Type,
        from result: (Data, URLResponse)
    ) throws -> Response {
        let (data, response) = result
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ContributorAPIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let apiError = try? JSONDecoder().decode(APIErrorResponse.self, from: data)
            throw ContributorAPIError.server(
                status: httpResponse.statusCode,
                message: apiError?.error ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            )
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}

private struct EmptyBody: Encodable {}

private struct EmptyResponse: Decodable {
    let ok: Bool
}

private struct APIErrorResponse: Decodable {
    let error: String
}

enum ContributorAPIError: LocalizedError {
    case missingToken
    case invalidResponse
    case server(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .missingToken:
            "No contributor session is available."
        case .invalidResponse:
            "The contributor service returned an invalid response."
        case .server(let status, let message):
            "Contributor service error \(status): \(message)"
        }
    }
}
