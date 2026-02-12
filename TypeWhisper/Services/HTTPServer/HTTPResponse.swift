import Foundation

struct HTTPResponse {
    let status: Int
    let contentType: String
    let body: Data

    static func json(_ value: Encodable, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONEncoder().encode(AnyEncodable(value))) ?? Data()
        return HTTPResponse(status: status, contentType: "application/json", body: data)
    }

    static func error(status: Int, message: String) -> HTTPResponse {
        struct ErrorBody: Encodable {
            let error: ErrorDetail
            struct ErrorDetail: Encodable {
                let code: String
                let message: String
            }
        }
        let code: String
        switch status {
        case 400: code = "bad_request"
        case 404: code = "not_found"
        case 405: code = "method_not_allowed"
        case 413: code = "payload_too_large"
        case 503: code = "service_unavailable"
        default: code = "error"
        }
        return .json(ErrorBody(error: .init(code: code, message: message)), status: status)
    }

    func serialized() -> Data {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 405: statusText = "Method Not Allowed"
        case 413: statusText = "Payload Too Large"
        case 503: statusText = "Service Unavailable"
        default: statusText = "Error"
        }

        var header = "HTTP/1.1 \(status) \(statusText)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        header += "Access-Control-Allow-Headers: Content-Type\r\n"
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
