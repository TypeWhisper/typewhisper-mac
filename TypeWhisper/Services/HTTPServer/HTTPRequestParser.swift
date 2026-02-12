import Foundation

struct HTTPRequest {
    let method: String
    let path: String
    let queryParams: [String: String]
    let headers: [String: String]
    let body: Data
}

struct MultipartPart {
    let name: String
    let filename: String?
    let contentType: String?
    let data: Data
}

enum HTTPParseError: Error {
    case incomplete
    case malformed
    case bodyTooLarge
}

enum HTTPRequestParser {
    static let maxBodySize = 100 * 1024 * 1024 // 100 MB

    static func parse(_ data: Data) throws -> HTTPRequest {
        guard let headerEnd = data.findDoubleCRLF() else {
            throw HTTPParseError.incomplete
        }

        guard let headerString = String(data: data[data.startIndex..<headerEnd], encoding: .utf8) else {
            throw HTTPParseError.malformed
        }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw HTTPParseError.malformed }

        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { throw HTTPParseError.malformed }

        let method = String(parts[0])
        let rawPath = String(parts[1])

        let (path, queryParams) = parsePathAndQuery(rawPath)

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let bodyStart = headerEnd + 4 // skip \r\n\r\n
        let contentLength = headers["content-length"].flatMap(Int.init) ?? 0

        guard contentLength <= maxBodySize else {
            throw HTTPParseError.bodyTooLarge
        }

        let totalExpected = bodyStart + contentLength
        guard data.count >= totalExpected else {
            throw HTTPParseError.incomplete
        }

        let body = contentLength > 0 ? data[bodyStart..<(bodyStart + contentLength)] : Data()

        return HTTPRequest(
            method: method,
            path: path,
            queryParams: queryParams,
            headers: headers,
            body: Data(body)
        )
    }

    static func parseMultipart(body: Data, boundary: String) -> [MultipartPart] {
        let boundaryData = Data("--\(boundary)".utf8)
        let endBoundary = Data("--\(boundary)--".utf8)
        let crlf = Data("\r\n".utf8)
        let doubleCRLF = Data("\r\n\r\n".utf8)

        var parts: [MultipartPart] = []
        var searchStart = 0

        while searchStart < body.count {
            guard let boundaryRange = body.range(of: boundaryData, in: searchStart..<body.count) else { break }

            let afterBoundary = boundaryRange.upperBound
            guard afterBoundary + 2 <= body.count else { break }

            // Check for end boundary
            if body[boundaryRange.lowerBound..<min(boundaryRange.lowerBound + endBoundary.count, body.count)] == endBoundary {
                break
            }

            // Skip past CRLF after boundary
            let partStart = afterBoundary + crlf.count
            guard partStart < body.count else { break }

            // Find header/body separator
            guard let headerEnd = body.range(of: doubleCRLF, in: partStart..<body.count) else { break }

            let headerData = body[partStart..<headerEnd.lowerBound]
            let partBodyStart = headerEnd.upperBound

            // Find next boundary
            let nextBoundaryRange = body.range(of: boundaryData, in: partBodyStart..<body.count)
            let partBodyEnd = (nextBoundaryRange?.lowerBound ?? body.count) - crlf.count

            guard partBodyEnd >= partBodyStart else {
                searchStart = nextBoundaryRange?.lowerBound ?? body.count
                continue
            }

            let partBody = Data(body[partBodyStart..<partBodyEnd])

            // Parse part headers
            if let headerStr = String(data: headerData, encoding: .utf8) {
                var name = ""
                var filename: String?
                var contentType: String?

                for line in headerStr.components(separatedBy: "\r\n") {
                    let lower = line.lowercased()
                    if lower.hasPrefix("content-disposition:") {
                        name = extractParam(line, key: "name") ?? ""
                        filename = extractParam(line, key: "filename")
                    } else if lower.hasPrefix("content-type:") {
                        contentType = line.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)
                    }
                }

                parts.append(MultipartPart(name: name, filename: filename, contentType: contentType, data: partBody))
            }

            searchStart = nextBoundaryRange?.lowerBound ?? body.count
        }

        return parts
    }

    private static func parsePathAndQuery(_ raw: String) -> (String, [String: String]) {
        guard let qIndex = raw.firstIndex(of: "?") else {
            return (raw, [:])
        }
        let path = String(raw[raw.startIndex..<qIndex])
        let queryString = String(raw[raw.index(after: qIndex)...])
        var params: [String: String] = [:]
        for pair in queryString.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let value = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                params[key] = value
            }
        }
        return (path, params)
    }

    private static func extractParam(_ header: String, key: String) -> String? {
        let pattern = "\(key)=\""
        guard let start = header.range(of: pattern)?.upperBound else { return nil }
        guard let end = header[start...].firstIndex(of: "\"") else { return nil }
        return String(header[start..<end])
    }
}

private extension Data {
    func findDoubleCRLF() -> Int? {
        let pattern: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        guard count >= 4 else { return nil }
        for i in 0...(count - 4) {
            if self[startIndex + i] == pattern[0] &&
               self[startIndex + i + 1] == pattern[1] &&
               self[startIndex + i + 2] == pattern[2] &&
               self[startIndex + i + 3] == pattern[3] {
                return startIndex + i
            }
        }
        return nil
    }
}
