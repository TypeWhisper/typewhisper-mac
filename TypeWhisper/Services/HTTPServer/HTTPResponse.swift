import Foundation

struct HTTPResponse {
    let status: Int
    let contentType: String
    let body: Data
    let headers: [String: String]

    init(status: Int, contentType: String, body: Data, headers: [String: String] = [:]) {
        self.status = status
        self.contentType = contentType
        self.body = body
        self.headers = headers
    }

    private static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static func json(_ value: Encodable, status: Int = 200, headers: [String: String] = [:]) -> HTTPResponse {
        let data = (try? jsonEncoder.encode(AnyEncodable(value))) ?? Data()
        return HTTPResponse(status: status, contentType: "application/json", body: data, headers: headers)
    }

    static func error(status: Int, message: String, code explicitCode: String? = nil, headers: [String: String] = [:]) -> HTTPResponse {
        struct ErrorBody: Encodable {
            let error: ErrorDetail
            struct ErrorDetail: Encodable {
                let code: String
                let message: String
            }
        }
        let code = explicitCode ?? Self.defaultErrorCode(for: status)
        return .json(ErrorBody(error: .init(code: code, message: message)), status: status, headers: headers)
    }

    private static func defaultErrorCode(for status: Int) -> String {
        switch status {
        case 400: "bad_request"
        case 401: "unauthorized"
        case 403: "forbidden"
        case 404: "not_found"
        case 405: "method_not_allowed"
        case 413: "payload_too_large"
        case 503: "service_unavailable"
        default: "error"
        }
    }

    func serialized() -> Data {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 204: statusText = "No Content"
        case 400: statusText = "Bad Request"
        case 401: statusText = "Unauthorized"
        case 403: statusText = "Forbidden"
        case 404: statusText = "Not Found"
        case 405: statusText = "Method Not Allowed"
        case 409: statusText = "Conflict"
        case 413: statusText = "Payload Too Large"
        case 429: statusText = "Too Many Requests"
        case 502: statusText = "Bad Gateway"
        case 503: statusText = "Service Unavailable"
        case 504: statusText = "Gateway Timeout"
        default: statusText = "Error"
        }

        var header = "HTTP/1.1 \(status) \(statusText)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            header += "\(name): \(value)\r\n"
        }
        header += "Connection: close\r\n"
        header += "\r\n"

        var data = Data(header.utf8)
        data.append(body)
        return data
    }
}

private struct AnyEncodable: Encodable {
    private let encode: (Encoder) throws -> Void

    init(_ value: Encodable) {
        self.encode = value.encode
    }

    func encode(to encoder: Encoder) throws {
        try encode(encoder)
    }
}
